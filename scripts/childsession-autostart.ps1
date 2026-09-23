# Runs at every logon; only acts inside a child session
# (session != physical console).
#
# Responsibilities:
#   1. Start the portable Vibeshine host in the child session only.
#   2. During a short startup window, close non-allowed third-party startup
#      processes only in this child session.
#
# Vibeshine still names its Windows host binary "sunshine.exe".

Add-Type -Namespace ChildPOC -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern uint WTSGetActiveConsoleSessionId();
'@

$consoleSid = [ChildPOC.Native]::WTSGetActiveConsoleSessionId()
$mySid = (Get-Process -Id $PID).SessionId

# Physical desktop: do absolutely nothing.
if ($mySid -eq $consoleSid) {
    exit
}

$root = Split-Path $PSScriptRoot -Parent
$logPath = Join-Path $root 'autostart.log'

function Write-ChildLog {
    param([string]$Message)
    try {
        Add-Content -Path $logPath -Value "$(Get-Date -Format o) $Message"
    } catch {}
}

function Get-VibeshineExe {
    $vibeshineRoot = Join-Path $root 'Vibeshine'
    if (-not (Test-Path $vibeshineRoot)) { return $null }

    $candidate = Get-ChildItem -Path $vibeshineRoot -Filter 'sunshine.exe' -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } |
        Select-Object -First 1

    if ($candidate) { return $candidate.FullName }
    return $null
}

# ---------------------------------------------------------------------------
# Start Vibeshine in this child session.
# ---------------------------------------------------------------------------
$exe = Get-VibeshineExe
$running = Get-Process sunshine -ErrorAction SilentlyContinue |
    Where-Object SessionId -eq $mySid

if (-not $running -and $exe -and (Test-Path $exe)) {
    try {
        # Keep the original ChildStream behavior of elevating the streaming host
        # so input can reach elevated games (UIPI).
        Start-Process $exe `
            -WorkingDirectory (Split-Path $exe) `
            -WindowStyle Hidden `
            -Verb RunAs

        Write-ChildLog "started Vibeshine ($exe) in session $mySid (console=$consoleSid)"
    } catch {
        Write-ChildLog "failed to start Vibeshine: $($_.Exception.Message)"
    }
} elseif (-not $exe) {
    Write-ChildLog 'Vibeshine executable not found; run scripts\setup.ps1 again.'
}

# ---------------------------------------------------------------------------
# Load startup allow-list.
# ---------------------------------------------------------------------------
$configPath = Join-Path $PSScriptRoot 'childsession-allowlist.json'

if (-not (Test-Path $configPath)) {
    Write-ChildLog "startup cleanup skipped: missing $configPath"
    exit
}

try {
    $cfg = Get-Content -Path $configPath -Raw | ConvertFrom-Json
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

# Built-in safety floor. These remain protected even if removed from the JSON.
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

    if (-not $Name) { return $false }
    $n = $Name.ToLowerInvariant()

    if ($neverKill -contains $n) { return $true }
    if ($allowProcesses -contains $n) { return $true }

    return $false
}

function Test-ProtectedPath {
    param([string]$Path)

    # Unknown/inaccessible path => fail safe and do not terminate it.
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
        [int]$Pid,
        [hashtable]$ProcessById
    )

    $seen = @{}
    $current = $Pid

    # Walk at most 32 parents to avoid malformed/cyclic process snapshots.
    for ($depth = 0; $depth -lt 32; $depth++) {
        if ($seen.ContainsKey($current)) { break }
        $seen[$current] = $true

        if (-not $ProcessById.ContainsKey($current)) { break }

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
Write-ChildLog "startup cleanup active for $cleanupSeconds seconds in child session $mySid"

while ((Get-Date) -lt $cleanupEnd) {
    try {
        # CIM gives SessionId, executable path, and parent PID in one snapshot.
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

    foreach ($p in $sessionProcesses) {
        $pidToCheck = [int]$p.ProcessId

        # Never target this cleanup script itself.
        if ($pidToCheck -eq $PID) { continue }

        $name = [IO.Path]::GetFileNameWithoutExtension([string]$p.Name)

        if (Test-AllowedName $name) { continue }
        if (Test-ProtectedPath ([string]$p.ExecutablePath)) { continue }
        if (Test-ProtectedAncestor -Pid $pidToCheck -ProcessById $byId) { continue }

        try {
            Stop-Process -Id $pidToCheck -Force -ErrorAction Stop
            Write-ChildLog "closed startup process '$name' pid=$pidToCheck session=$mySid"
        } catch {
            # It may already have exited, or the process may deny access.
        }
    }

    Start-Sleep -Seconds $scanInterval
}

Write-ChildLog "startup cleanup finished for child session $mySid"
