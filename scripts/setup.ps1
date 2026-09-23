<#
.SYNOPSIS
  One-shot setup for ChildStream: second-desktop game streaming via Windows child sessions.
.NOTES
  Run from an elevated PowerShell in the repo root:  .\scripts\setup.ps1

  Vibeshine is downloaded from Nonary/vibeshine and unpacked with MSI
  administrative-install mode. This keeps the host portable inside the repo
  instead of registering Vibeshine's normal machine-wide auto-start service.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script as Administrator.'
}

# 1. Compile the launcher
$csc = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$iconArg = if (Test-Path "$root\app.ico") { "/win32icon:$root\app.ico" } else { $null }
& $csc /nologo /target:winexe $iconArg /out:"$root\ChildStream.exe" /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Security.dll /r:Microsoft.CSharp.dll "$root\src\ChildStream.cs"
Write-Host 'Compiled ChildStream.exe'

# 2. Enable child sessions
& "$root\ChildStream.exe" -enable
if ($LASTEXITCODE -ne 0) { throw 'Failed to enable child sessions.' }
Write-Host 'Child sessions enabled'

# 3. Allow RDP connections (loopback requirement for child sessions)
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0

# 4. Raise session composition rate (~120 fps). Remove the value to restore default (~30 fps).
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations' -Name DWMFRAMEINTERVAL -Value 8 -Type DWord
Write-Host 'RDP composition rate raised'

# 4b. Keep rendering the session while the viewer window is minimized (prevents black stream)
New-Item -Path 'HKCU:\Software\Microsoft\Terminal Server Client' -Force | Out-Null
Set-ItemProperty 'HKCU:\Software\Microsoft\Terminal Server Client' -Name RemoteDesktop_SuppressWhenMinimized -Value 2 -Type DWord

# 5. Download and unpack portable Vibeshine if missing.
#
# Vibeshine's normal installer registers an auto-start Windows service. ChildStream
# must run the streaming host only inside the child session, so use MSI
# administrative-install mode (/a) to unpack the official payload without
# installing that service.
$vibeshineRoot = Join-Path $root 'Vibeshine'

function Get-VibeshineExe {
    if (-not (Test-Path $vibeshineRoot)) { return $null }

    $candidate = Get-ChildItem -Path $vibeshineRoot -Filter 'sunshine.exe' -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } |
        Select-Object -First 1

    if ($candidate) { return $candidate.FullName }
    return $null
}

$vibeshineExe = Get-VibeshineExe

if (-not $vibeshineExe) {
    Write-Host 'Downloading latest stable Vibeshine...'

    $headers = @{ 'User-Agent' = 'ChildStream-Vibeshine-Setup' }
    $rel = Invoke-RestMethod -Headers $headers 'https://api.github.com/repos/Nonary/vibeshine/releases/latest'
    $asset = $rel.assets |
        Where-Object { $_.name -like 'VibeshineSetup-*.exe' } |
        Select-Object -First 1

    if (-not $asset) {
        throw 'Latest Vibeshine release does not contain a VibeshineSetup-*.exe asset.'
    }

    $installer = Join-Path $root 'vibeshine-setup.exe'
    Invoke-WebRequest -Headers $headers -Uri $asset.browser_download_url -OutFile $installer

    New-Item -ItemType Directory -Path $vibeshineRoot -Force | Out-Null

    # /a performs an administrative install (payload extraction). TARGETDIR is
    # the extraction root. Driver install properties are disabled as an extra
    # safeguard; no install custom actions should be needed for ChildStream.
    $adminArgs = '/a /qn TARGETDIR="{0}" INSTALL_VIRTUAL_DISPLAY_DRIVER=0 INSTALL_VIRTUAL_GAMEPAD_DRIVER=0' -f $vibeshineRoot
    $proc = Start-Process -FilePath $installer -ArgumentList $adminArgs -Wait -PassThru

    Remove-Item $installer -Force -ErrorAction SilentlyContinue

    if ($proc.ExitCode -notin @(0, 1641, 3010)) {
        throw "Vibeshine administrative extraction failed with exit code $($proc.ExitCode)."
    }

    $vibeshineExe = Get-VibeshineExe
    if (-not $vibeshineExe) {
        throw "Vibeshine extraction completed, but sunshine.exe was not found under $vibeshineRoot."
    }
}

Write-Host "Vibeshine host: $vibeshineExe"

# 6. Vibeshine config: distinct name + ports so it can coexist with another
# host on the console session. Vibeshine retains Sunshine's executable/config
# names on Windows, so sunshine.exe and sunshine.conf are expected.
$confDir = Join-Path (Split-Path $vibeshineExe -Parent) 'config'
New-Item -ItemType Directory -Path $confDir -Force | Out-Null
@"
sunshine_name = $env:COMPUTERNAME-Child
port = 48989
capture = wgc
"@ | Set-Content (Join-Path $confDir 'sunshine.conf')
Write-Host 'Vibeshine configured (base port 48989).'
Write-Host "Set web UI credentials with: `"$vibeshineExe`" --creds <user> <pass>"

# 7. Firewall rule
Remove-NetFirewallRule -DisplayName 'ChildStream Sunshine' -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName 'ChildStream Vibeshine' -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName 'ChildStream Vibeshine' -Direction Inbound -Program $vibeshineExe -Action Allow -Profile Any | Out-Null

# 8. Startup hook (all users). The PowerShell script immediately exits on the
# physical console, and only starts Vibeshine/cleans startup apps in child sessions.
$startupDir = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup'
$legacyHook = Join-Path $startupDir 'childstream-sunshine.cmd'
$hook = Join-Path $startupDir 'childstream-vibeshine.cmd'
Remove-Item $legacyHook -Force -ErrorAction SilentlyContinue
Set-Content $hook "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$root\scripts\childsession-autostart.ps1`""

# 9. Desktop shortcut
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut("$env:USERPROFILE\Desktop\Child Session.lnk")
$lnk.TargetPath = "$root\ChildStream.exe"
$lnk.WorkingDirectory = $root
$lnk.Description = 'Second desktop for game streaming'
$lnk.Save()

Write-Host ''
Write-Host 'Done. Launch "Child Session" from the desktop and enter your Windows password once.'
Write-Host 'Then pair Moonlight/Artemis with <host-ip>:48989.'
Write-Host 'Unwanted third-party startup apps in the child session are cleaned for the first'
Write-Host '45 seconds according to scripts\childsession-allowlist.json.'
