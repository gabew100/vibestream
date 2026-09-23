# Runs at every logon; only acts inside a child session
# (session != physical console).
#
# Responsibilities:
#   1. Start the portable Vibeshine host in the child session only.
#   2. Suppress only processes that Windows reports as startup entries, unless
#      explicitly allowed. Arbitrary third-party apps launched by the user are
#      no longer blanket-killed during the cleanup window.
#
# Vibeshine retains the upstream Windows host filename "sunshine.exe".

Add-Type -Namespace ChildPOC -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern uint WTSGetActiveConsoleSessionId();
'@

$consoleSid = [ChildPOC.Native]::WTSGetActiveConsoleSessionId()
$mySid = (Get-Process -Id $PID).SessionId

if ($mySid -eq $consoleSid) {
    exit
}

$root = Split-Path $PSScriptRoot -Parent
$logPath = Join-Path $root 'autostart.log'

function Write-ChildLog {
    param([string]$Message)
    try {
        Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format o) $Message"
    } catch {}
}

function Get-VibeshineExe {
    $vibeshineRoot = Join-Path $root 'Vibeshine'
    if (-not (Test-Path -LiteralPath $vibeshineRoot)) {
        return $null
    }

    $candidate = Get-ChildItem -LiteralPath $vibeshineRoot -Filter 'sunshine.exe' -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } |
        Select-Object -First 1

    if ($candidate) {
        return $candidate.FullName
    }
    return $null
}

function Get-ExecutableNamesFromCommand {
    param([string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) {
        return
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Command)
    $pattern = '(?i)(?:"([^"]+?\.exe)"|((?:[A-Za-z]:\\|\\\\)[^"]*?\.exe)|(?<![A-Za-z0-9_.-])([A-Za-z0-9_.-]+\.exe))'

    foreach ($match in [regex]::Matches($expanded, $pattern)) {
        $candidate = $null
        for ($groupIndex = 1; $groupIndex -le 3; $groupIndex++) {
            if ($match.Groups[$groupIndex].Success) {
                $candidate = $match.Groups[$groupIndex].Value
                break
            }
        }

        if ($candidate) {
            [IO.Path]::GetFileNameWithoutExtension($candidate).ToLowerInvariant()
        }
    }
}

function Get-WindowsStartupProcessNames {
    $names = @()

    try {
        foreach ($entry in @(Get-CimInstance Win32_StartupCommand -ErrorAction Stop)) {
            $names += @(Get-ExecutableNamesFromCommand -Command ([string]$entry.Command))
        }
    } catch {
        Write-ChildLog "Win32_StartupCommand enumeration failed: $($_.Exception.Message)"
    }

    # Supplement WMI with direct Startup-folder resolution, especially .lnk files.
    try {
        $shell = New-Object -ComObject WScript.Shell
        $startupFolders = @(
            [Environment]::GetFolderPath('Startup'),
            [Environment]::GetFolderPath('CommonStartup')
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

        foreach ($folder in $startupFolders) {
            foreach ($item in @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue)) {
                if ($item.Extension -ieq '.lnk') {
                    $shortcut = $shell.CreateShortcut($item.FullName)
                    $names += @(Get-ExecutableNamesFromCommand -Command ([string]$shortcut.TargetPath))
                    $names += @(Get-ExecutableNamesFromCommand -Command ([string]$shortcut.Arguments))
                } elseif ($item.Extension -ieq '.exe') {
                    $names += $item.BaseName.ToLowerInvariant()
                }
            }
        }
    } catch {
        Write-ChildLog "Startup-folder enumeration failed: $($_.Exception.Message)"
    }

    @($names | Where-Object { $_ } | Sort-Object -Unique)
}

# Start Vibeshine in this child session.
$exe = Get-VibeshineExe
$running = Get-Process sunshine -ErrorAction SilentlyContinue |
    Where-Object SessionId -eq $mySid

if (-not $running -and $exe -and (Test-Path -LiteralPath $exe)) {
    try {
        $startParams = @{
            FilePath = $exe
            WorkingDirectory = (Split-Path $exe)
            WindowStyle = 'Hidden'
            Verb = 'RunAs'
        }
        Start-Process @startParams
        Write-ChildLog "started Vibeshine ($exe) in session $mySid (console=$consoleSid)"
    } catch {
        Write-ChildLog "failed to start Vibeshine: $($_.Exception.Message)"
    }
} elseif (-not $exe) {
    Write-ChildLog 'Vibeshine executable not found; run scripts\setup.ps1 again.'
}

$configPath = Join-Path $PSScriptRoot 'childsession-allowlist.json'
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-ChildLog "startup cleanup skipped: missing $configPath"
    exit
}

try {
    $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
} catch {
    Write-ChildLog "startup cleanup skipped: invalid config: $($_.Exception.Message)"
    exit
}

$initialDelay = 6
$cleanupSeconds = 45
$scanInterval = 2

if ($null -ne $cfg.initialDelaySeconds) {
    $initialDelay = [Math]::Max(0, [int]$cfg.initialDelaySeconds)
}
if ($null -ne $cfg.cleanupSeconds) {
    $cleanupSeconds = [Math]::Max(1, [int]$cfg.cleanupSeconds)
}
if ($null -ne $cfg.scanIntervalSeconds) {
    $scanInterval = [Math]::Max(1, [int]$cfg.scanIntervalSeconds)
}

$allowProcesses = @(
    $cfg.allowProcesses |
        ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } |
        Where-Object { $_ }
)

$protectDescendantsOf = @(
    $cfg.protectDescendantsOf |
        ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } |
        Where-Object { $_ }
)

$protectedPathPrefixes = @(
    $cfg.protectedPathPrefixes |
        ForEach-Object {
            $expanded = [Environment]::ExpandEnvironmentVariables([string]$_)
            if ($expanded) {
                [IO.Path]::GetFullPath($expanded).TrimEnd('\') + '\'
            }
        }
)

$startupProcessNames = @(Get-WindowsStartupProcessNames)
if ($null -ne $cfg.extraStartupProcesses) {
    $startupProcessNames += @(
        $cfg.extraStartupProcesses |
            ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } |
            Where-Object { $_ }
    )
}
$startupProcessNames = @($startupProcessNames | Sort-Object -Unique)

if ($startupProcessNames.Count -eq 0) {
    Write-ChildLog 'startup cleanup skipped: Windows reported no identifiable startup executable names.'
    exit
}

Write-ChildLog ("startup executable names: " + ($startupProcessNames -join ', '))

$neverKill = @(
    'powershell',
    'pwsh',
    'conhost',
    'explorer',
    'dwm',
    'csrss',
    'winlogon',
    'userinit',
    'rdpclip',
    'taskhostw',
    'sihost',
    'ctfmon',
    'fontdrvhost',
    'searchhost',
    'startmenuexperiencehost',
    'shellexperiencehost',
    'textinputhost',
    'runtimebroker',
    'applicationframehost'
)

function Test-AllowedName {
    param([string]$Name)

    if (-not $Name) {
        return $false
    }

    $n = $Name.ToLowerInvariant()
    if ($neverKill -contains $n) {
        return $true
    }
    if ($allowProcesses -contains $n) {
        return $true
    }
    return $false
}

function Test-ProtectedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $true
    }

    try {
        $full = [IO.Path]::GetFullPath($Path)
    } catch {
        return $true
    }

    foreach ($prefix in $protectedPathPrefixes) {
        if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Test-ProtectedAncestor {
    param(
        [int]$ProcessId,
        [hashtable]$ProcessById
    )

    $seen = @{}
    $current = $ProcessId

    for ($depth = 0; $depth -lt 32; $depth++) {
        if ($seen.ContainsKey($current)) {
            break
        }
        $seen[$current] = $true

        if (-not $ProcessById.ContainsKey($current)) {
            break
        }

        $p = $ProcessById[$current]
        $parentId = [int]$p.ParentProcessId

        if ($parentId -le 0 -or -not $ProcessById.ContainsKey($parentId)) {
            break
        }

        $parent = $ProcessById[$parentId]
        $parentName = [IO.Path]::GetFileNameWithoutExtension([string]$parent.Name).ToLowerInvariant()
        if ($protectDescendantsOf -contains $parentName) {
            return $true
        }

        $current = $parentId
    }

    return $false
}

if ($initialDelay -gt 0) {
    Start-Sleep -Seconds $initialDelay
}

$cleanupEnd = (Get-Date).AddSeconds($cleanupSeconds)
$handledStartupNames = @{}
Write-ChildLog "startup-entry cleanup active for $cleanupSeconds seconds in child session $mySid"

while ((Get-Date) -lt $cleanupEnd) {
    try {
        $sessionProcesses = @(
            Get-CimInstance Win32_Process -Filter "SessionId = $mySid" -ErrorAction Stop
        )
    } catch {
        Write-ChildLog "startup cleanup scan failed: $($_.Exception.Message)"
        Start-Sleep -Seconds $scanInterval
        continue
    }

    $byId = @{}
    foreach ($p in $sessionProcesses) {
        $byId[[int]$p.ProcessId] = $p
    }

    $handledThisScan = @{}

    foreach ($p in $sessionProcesses) {
        $pidToCheck = [int]$p.ProcessId
        if ($pidToCheck -eq $PID) {
            continue
        }

        $name = [IO.Path]::GetFileNameWithoutExtension([string]$p.Name)
        $nameLower = $name.ToLowerInvariant()

        # The key safety change: only a process whose executable name came from
        # an actual Windows startup entry (or extraStartupProcesses) is eligible.
        if ($startupProcessNames -notcontains $nameLower) {
            continue
        }
        if ($handledStartupNames.ContainsKey($nameLower)) {
            continue
        }
        if (Test-AllowedName $name) {
            continue
        }
        if (Test-ProtectedPath ([string]$p.ExecutablePath)) {
            continue
        }
        if (Test-ProtectedAncestor -ProcessId $pidToCheck -ProcessById $byId) {
            continue
        }

        try {
            Stop-Process -Id $pidToCheck -Force -ErrorAction Stop
            $handledThisScan[$nameLower] = $true
            Write-ChildLog "closed startup process '$name' pid=$pidToCheck session=$mySid"
        } catch {}
    }

    # After the first successful cleanup pass for a startup executable name, do
    # not police that name again. If the user intentionally relaunches it a few
    # seconds later, the manual instance is left alone.
    foreach ($name in $handledThisScan.Keys) {
        $handledStartupNames[$name] = $true
    }

    Start-Sleep -Seconds $scanInterval
}

Write-ChildLog "startup-entry cleanup finished for child session $mySid"
