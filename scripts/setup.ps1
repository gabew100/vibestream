<#
.SYNOPSIS
  One-shot setup for ChildStream: second-desktop game streaming via Windows child sessions.
.NOTES
  Run from an elevated PowerShell in the repo root:  .\scripts\setup.ps1

  Vibeshine is kept portable inside this repo. Its normal machine-wide
  SunshineService is intentionally not installed because that service targets
  the active console session, not the ChildStream child session.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$statePath = Join-Path $root '.childstream-system-state.json'
$vibeshineRoot = Join-Path $root 'Vibeshine'
$versionMarker = Join-Path $vibeshineRoot '.childstream-vibeshine-version'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script as Administrator.'
}

function Get-RegistryValueState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    try {
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return [pscustomobject]@{
            exists = $true
            value = [int64]$item.$Name
        }
    } catch {
        return [pscustomobject]@{
            exists = $false
            value = $null
        }
    }
}

function Get-VibeshineExe {
    param([Parameter(Mandatory = $true)][string]$SearchRoot)

    if (-not (Test-Path -LiteralPath $SearchRoot)) {
        return $null
    }

    $candidate = Get-ChildItem -LiteralPath $SearchRoot -Filter 'sunshine.exe' -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } |
        Select-Object -First 1

    if ($candidate) {
        return $candidate.FullName
    }
    return $null
}

function Test-ProcessUnderPath {
    param(
        [string]$ExecutablePath,
        [string]$RootPath
    )

    if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
        return $false
    }

    try {
        $fullExe = [IO.Path]::GetFullPath($ExecutablePath)
        $fullRoot = [IO.Path]::GetFullPath($RootPath).TrimEnd('\') + '\'
        return $fullExe.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Set-ConfigValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value,
        [bool]$OverwriteExisting
    )

    $lines = @()
    if (Test-Path -LiteralPath $Path) {
        $lines = @(Get-Content -LiteralPath $Path)
    }

    $pattern = '^\s*' + [regex]::Escape($Name) + '\s*='
    $found = $false
    $updated = foreach ($line in $lines) {
        if ($line -match $pattern) {
            $found = $true
            if ($OverwriteExisting) {
                "$Name = $Value"
            } else {
                $line
            }
        } else {
            $line
        }
    }

    if (-not $found) {
        $updated = @($updated) + "$Name = $Value"
    }

    Set-Content -LiteralPath $Path -Value $updated
}

# 1. Compile the launcher.
$csc = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$iconArg = if (Test-Path -LiteralPath "$root\app.ico") { "/win32icon:$root\app.ico" } else { $null }
& $csc /nologo /target:winexe $iconArg /out:"$root\ChildStream.exe" /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Security.dll /r:Microsoft.CSharp.dll "$root\src\ChildStream.cs"
if ($LASTEXITCODE -ne 0) {
    throw "Failed to compile ChildStream.exe (csc exit code $LASTEXITCODE)."
}
Write-Host 'Compiled ChildStream.exe'

# 2. Save the original Windows settings once so uninstall.ps1 can restore the
# exact pre-ChildStream state instead of guessing.
if (-not (Test-Path -LiteralPath $statePath)) {
    & "$root\ChildStream.exe" -check
    $childSessionsWereEnabled = ($LASTEXITCODE -eq 0)

    $state = [pscustomobject]@{
        schema = 1
        childSessionsEnabled = $childSessionsWereEnabled
        fDenyTSConnections = Get-RegistryValueState -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections'
        dwmFrameInterval = Get-RegistryValueState -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations' -Name 'DWMFRAMEINTERVAL'
        suppressWhenMinimized = Get-RegistryValueState -Path 'HKCU:\Software\Microsoft\Terminal Server Client' -Name 'RemoteDesktop_SuppressWhenMinimized'
    }

    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath
    Write-Host "Saved pre-install Windows state to $statePath"
}

# 3. Enable child sessions.
& "$root\ChildStream.exe" -enable
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to enable child sessions.'
}
Write-Host 'Child sessions enabled'

# 4. Allow RDP connections and raise the child-session composition rate.
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations' -Name DWMFRAMEINTERVAL -Value 8 -Type DWord
Write-Host 'RDP enabled and composition rate raised'

# Keep rendering the session while the viewer window is minimized.
New-Item -Path 'HKCU:\Software\Microsoft\Terminal Server Client' -Force | Out-Null
Set-ItemProperty 'HKCU:\Software\Microsoft\Terminal Server Client' -Name RemoteDesktop_SuppressWhenMinimized -Value 2 -Type DWord

# 5. Resolve the latest stable Vibeshine release every time setup runs.
$headers = @{ 'User-Agent' = 'ChildStream-Vibeshine-Setup' }
$release = Invoke-RestMethod -Headers $headers 'https://api.github.com/repos/Nonary/vibeshine/releases/latest'
$asset = $release.assets |
    Where-Object { $_.name -like 'VibeshineSetup-*.exe' } |
    Select-Object -First 1

if (-not $asset) {
    throw 'Latest Vibeshine release does not contain a VibeshineSetup-*.exe asset.'
}

$latestTag = [string]$release.tag_name
if ([string]::IsNullOrWhiteSpace($latestTag)) {
    throw 'Latest Vibeshine release did not provide a tag name.'
}

$digest = [string]$asset.digest
if ($digest -notmatch '^sha256:([0-9a-fA-F]{64})$') {
    throw 'Latest Vibeshine installer does not publish a usable SHA-256 digest; refusing an unverified update.'
}
$expectedSha256 = $Matches[1].ToLowerInvariant()

$vibeshineExe = Get-VibeshineExe -SearchRoot $vibeshineRoot
$installedTag = if (Test-Path -LiteralPath $versionMarker) {
    (Get-Content -LiteralPath $versionMarker -Raw).Trim()
} else {
    ''
}

$hadExistingConfig = $false
if ($vibeshineExe) {
    $existingConfigDir = Join-Path (Split-Path $vibeshineExe -Parent) 'config'
    $hadExistingConfig = Test-Path -LiteralPath (Join-Path $existingConfigDir 'sunshine.conf')
}
$legacyConfigDir = Join-Path $root 'Sunshine\Sunshine\config'
$hadLegacyConfig = Test-Path -LiteralPath (Join-Path $legacyConfigDir 'sunshine.conf')

$needsUpdate = (-not $vibeshineExe) -or ($installedTag -ne $latestTag)

if ($needsUpdate) {
    $localHosts = @()
    if (Test-Path -LiteralPath $vibeshineRoot) {
        foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='sunshine.exe'" -ErrorAction SilentlyContinue)) {
            if (Test-ProcessUnderPath -ExecutablePath ([string]$process.ExecutablePath) -RootPath $vibeshineRoot) {
                $localHosts += $process
            }
        }
    }

    if ($localHosts.Count -gt 0) {
        throw 'The repo-local Vibeshine host is running. Sign out of the ChildStream child session, then run setup again.'
    }

    if ($installedTag) {
        Write-Host "Updating Vibeshine $installedTag -> $latestTag"
    } else {
        Write-Host "Installing Vibeshine $latestTag"
    }

    $installer = Join-Path $root 'vibeshine-setup.exe'
    $stageRoot = Join-Path $root 'Vibeshine.new'
    $oldRoot = Join-Path $root 'Vibeshine.old'
    $configBackup = $null

    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $oldRoot -Recurse -Force -ErrorAction SilentlyContinue

    if ($vibeshineExe -and $hadExistingConfig) {
        $configBackup = Join-Path $env:TEMP ("ChildStream-Vibeshine-config-" + [guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath (Join-Path (Split-Path $vibeshineExe -Parent) 'config') -Destination $configBackup -Recurse -Force
    }

    try {
        Invoke-WebRequest -Headers $headers -UseBasicParsing -Uri $asset.browser_download_url -OutFile $installer
        $actualSha256 = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualSha256 -ne $expectedSha256) {
            throw "Vibeshine installer SHA-256 mismatch. Expected $expectedSha256 but received $actualSha256."
        }
        Write-Host 'Vibeshine installer SHA-256 verified'

        New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
        $adminArgs = '/a /qn TARGETDIR="{0}" INSTALL_VIRTUAL_DISPLAY_DRIVER=0 INSTALL_VIRTUAL_GAMEPAD_DRIVER=0' -f $stageRoot
        $extract = Start-Process -FilePath $installer -ArgumentList $adminArgs -Wait -PassThru
        if ($extract.ExitCode -notin @(0, 1641, 3010)) {
            throw "Vibeshine administrative extraction failed with exit code $($extract.ExitCode)."
        }

        $stagedExe = Get-VibeshineExe -SearchRoot $stageRoot
        if (-not $stagedExe) {
            throw "Vibeshine extraction completed, but sunshine.exe was not found under $stageRoot."
        }

        $hadOldPayload = Test-Path -LiteralPath $vibeshineRoot
        if ($hadOldPayload) {
            Move-Item -LiteralPath $vibeshineRoot -Destination $oldRoot
        }

        try {
            Move-Item -LiteralPath $stageRoot -Destination $vibeshineRoot

            $vibeshineExe = Get-VibeshineExe -SearchRoot $vibeshineRoot
            if (-not $vibeshineExe) {
                throw 'Updated Vibeshine payload is missing sunshine.exe.'
            }

            if ($configBackup) {
                $newConfigDir = Join-Path (Split-Path $vibeshineExe -Parent) 'config'
                New-Item -ItemType Directory -Path $newConfigDir -Force | Out-Null
                Get-ChildItem -LiteralPath $configBackup -Force |
                    Copy-Item -Destination $newConfigDir -Recurse -Force
            }

            Set-Content -LiteralPath $versionMarker -Value $latestTag
            Remove-Item -LiteralPath $oldRoot -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "Vibeshine $latestTag ready"
        } catch {
            # Roll back the entire portable payload if anything after the swap
            # fails (including executable validation or config restoration).
            Remove-Item -LiteralPath $vibeshineRoot -Recurse -Force -ErrorAction SilentlyContinue
            if ($hadOldPayload -and (Test-Path -LiteralPath $oldRoot)) {
                Move-Item -LiteralPath $oldRoot -Destination $vibeshineRoot
            }
            throw
        }
    } finally {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
        if ($configBackup) {
            Remove-Item -LiteralPath $configBackup -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} else {
    Write-Host "Vibeshine $latestTag is already current"
}

$vibeshineExe = Get-VibeshineExe -SearchRoot $vibeshineRoot
if (-not $vibeshineExe) {
    throw 'Vibeshine host executable was not found after setup.'
}
$hostRoot = Split-Path $vibeshineExe -Parent
$confDir = Join-Path $hostRoot 'config'
New-Item -ItemType Directory -Path $confDir -Force | Out-Null

# 6. Migrate the old ChildStream Sunshine state when present. The migration
# helper also removes the legacy firewall/startup hook.
& "$root\scripts\migrate.ps1" -DestinationConfig $confDir

# Preserve user choices on existing/migrated installs. On a genuinely fresh
# install, force only the three ChildStream defaults while leaving any other
# packaged Vibeshine settings intact.
$configPath = Join-Path $confDir 'sunshine.conf'
$preserveExistingSettings = $hadExistingConfig -or $hadLegacyConfig
Set-ConfigValue -Path $configPath -Name 'sunshine_name' -Value "$env:COMPUTERNAME-Child" -OverwriteExisting (-not $preserveExistingSettings)
Set-ConfigValue -Path $configPath -Name 'port' -Value '48989' -OverwriteExisting (-not $preserveExistingSettings)
Set-ConfigValue -Path $configPath -Name 'capture' -Value 'wgc' -OverwriteExisting (-not $preserveExistingSettings)
Write-Host 'Vibeshine config preserved; missing ChildStream defaults were added.'

# 7. Install only Vibeshine's machine-wide virtual gamepad driver. We
# intentionally do not install Vibeshine's streaming service or display driver.
$gamepadInstaller = Join-Path $hostRoot 'drivers\vhf-gamepad\install.ps1'
if (Test-Path -LiteralPath $gamepadInstaller) {
    $driverArgs = '-NoLogo -NonInteractive -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $gamepadInstaller
    $driverInstall = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $driverArgs -Wait -PassThru

    if ($driverInstall.ExitCode -eq 3010) {
        Write-Warning 'Vibeshine virtual gamepad driver installed but Windows requested a restart.'
    } elseif ($driverInstall.ExitCode -ne 0) {
        Write-Warning "Vibeshine virtual gamepad driver install failed with exit code $($driverInstall.ExitCode). Controller streaming may not work until this is fixed."
    } else {
        Write-Host 'Vibeshine virtual gamepad driver installed/verified'
    }
} else {
    Write-Warning 'Vibeshine virtual gamepad driver installer was not found in the extracted payload.'
}

# 8. Firewall rule for the portable child-session host.
Remove-NetFirewallRule -DisplayName 'ChildStream Sunshine' -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName 'ChildStream Vibeshine' -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName 'ChildStream Vibeshine' -Direction Inbound -Program $vibeshineExe -Action Allow -Profile Any | Out-Null

# 9. Startup hook. The PowerShell script exits immediately on the physical
# console and only starts Vibeshine / suppresses startup apps in child sessions.
$startupDir = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup'
$legacyHook = Join-Path $startupDir 'childstream-sunshine.cmd'
$hook = Join-Path $startupDir 'childstream-vibeshine.cmd'
Remove-Item -LiteralPath $legacyHook -Force -ErrorAction SilentlyContinue
Set-Content -LiteralPath $hook -Value ('powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $root 'scripts\childsession-autostart.ps1'))

# 10. Desktop shortcut.
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut("$env:USERPROFILE\Desktop\Child Session.lnk")
$lnk.TargetPath = "$root\ChildStream.exe"
$lnk.WorkingDirectory = $root
$lnk.Description = 'Second desktop for game streaming'
$lnk.Save()

Write-Host ''
Write-Host 'Done. Launch "Child Session" from the desktop and enter your Windows password once.'
Write-Host 'Then pair Moonlight/Artemis with <host-ip>:48989.'
Write-Host 'Only processes identified from Windows startup entries are suppressed in the child session.'
Write-Host 'Run .\scripts\uninstall.ps1 to undo ChildStream system changes later.'
