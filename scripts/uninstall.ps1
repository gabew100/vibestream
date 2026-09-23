<#
.SYNOPSIS
  Removes ChildStream-installed runtime/system changes while leaving source files.
.PARAMETER RemoveGamepadDriver
  Also removes the machine-wide Vibeshine VHF virtual gamepad driver. This is
  opt-in because another Vibeshine installation may share that driver.
#>
[CmdletBinding()]
param(
    [switch]$RemoveGamepadDriver
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$statePath = Join-Path $root '.childstream-system-state.json'
$vibeshineRoot = Join-Path $root 'Vibeshine'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script as Administrator.'
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

function Restore-RegistryValueState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        $State
    )

    if ($null -eq $State) {
        return
    }

    if ([bool]$State.exists) {
        New-Item -Path $Path -Force | Out-Null
        New-ItemProperty -Path $Path -Name $Name -Value ([int64]$State.value) -PropertyType DWord -Force | Out-Null
    } else {
        Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    }
}

# Stop only the repo-local Vibeshine host, never another Sunshine/Vibeshine
# installation on the physical desktop.
foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='sunshine.exe'" -ErrorAction SilentlyContinue)) {
    if (Test-ProcessUnderPath -ExecutablePath ([string]$process.ExecutablePath) -RootPath $vibeshineRoot) {
        Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
    }
}

# Optional shared gamepad-driver removal must happen before deleting the payload.
if ($RemoveGamepadDriver) {
    $gamepadInstaller = Get-ChildItem -LiteralPath $vibeshineRoot -Filter 'install.ps1' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like '*\drivers\vhf-gamepad\install.ps1' } |
        Select-Object -First 1

    if ($gamepadInstaller) {
        $driverArgs = '-NoLogo -NonInteractive -NoProfile -ExecutionPolicy Bypass -File "{0}" -Uninstall -RemoveDriverStorePackage 1' -f $gamepadInstaller.FullName
        $driverRemove = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $driverArgs -Wait -PassThru
        if ($driverRemove.ExitCode -eq 3010) {
            Write-Warning 'Virtual gamepad driver removed; Windows requested a restart.'
        } elseif ($driverRemove.ExitCode -ne 0) {
            Write-Warning "Virtual gamepad driver removal failed with exit code $($driverRemove.ExitCode)."
        } else {
            Write-Host 'Vibeshine virtual gamepad driver removed'
        }
    } else {
        Write-Warning 'Virtual gamepad driver payload not found; driver was not removed.'
    }
}

$startupDir = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup'
Remove-Item -LiteralPath (Join-Path $startupDir 'childstream-vibeshine.cmd') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $startupDir 'childstream-sunshine.cmd') -Force -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName 'ChildStream Vibeshine' -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName 'ChildStream Sunshine' -ErrorAction SilentlyContinue

$shortcutPath = Join-Path $env:USERPROFILE 'Desktop\Child Session.lnk'
if (Test-Path -LiteralPath $shortcutPath) {
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $expectedTarget = [IO.Path]::GetFullPath((Join-Path $root 'ChildStream.exe'))
        $actualTarget = if ($shortcut.TargetPath) { [IO.Path]::GetFullPath($shortcut.TargetPath) } else { '' }
        if ($actualTarget -and $actualTarget.Equals($expectedTarget, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $shortcutPath -Force
        }
    } catch {
        Write-Warning "Could not inspect/remove desktop shortcut: $($_.Exception.Message)"
    }
}

if (Test-Path -LiteralPath $statePath) {
    try {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json

        Restore-RegistryValueState -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -State $state.fDenyTSConnections
        Restore-RegistryValueState -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations' -Name 'DWMFRAMEINTERVAL' -State $state.dwmFrameInterval
        Restore-RegistryValueState -Path 'HKCU:\Software\Microsoft\Terminal Server Client' -Name 'RemoteDesktop_SuppressWhenMinimized' -State $state.suppressWhenMinimized

        if ($null -ne $state.childSessionsEnabled -and -not [bool]$state.childSessionsEnabled) {
            if (Test-Path -LiteralPath (Join-Path $root 'ChildStream.exe')) {
                & (Join-Path $root 'ChildStream.exe') -disable
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning 'ChildStream.exe could not disable child sessions.'
                }
            } else {
                Write-Warning 'ChildStream.exe is missing; child-session enablement state was not restored.'
            }
        }

        Write-Host 'Restored pre-install Windows settings'
        Remove-Item -LiteralPath $statePath -Force
    } catch {
        Write-Warning "Could not restore saved Windows state: $($_.Exception.Message)"
    }
} else {
    Write-Warning 'No saved pre-install Windows state was found, so RDP/registry settings were left unchanged.'
}

# Remove generated runtime state, but keep the repository/source files.
Remove-Item -LiteralPath $vibeshineRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $root 'Vibeshine.old') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $root 'Vibeshine.new') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $root 'vibeshine-setup.exe') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $root 'ChildStream.exe') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $root 'cred.bin') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $root 'autostart.log') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $root 'launcher.log') -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'ChildStream runtime/system changes removed. Repository source files were kept.'
if (-not $RemoveGamepadDriver) {
    Write-Host 'The shared Vibeshine virtual gamepad driver was kept. Use -RemoveGamepadDriver if you explicitly want it removed.'
}
