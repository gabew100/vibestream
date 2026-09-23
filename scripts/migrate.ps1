<#
.SYNOPSIS
  Migrates legacy ChildStream/Sunshine state to the portable Vibeshine host.
.PARAMETER DestinationConfig
  Vibeshine config directory to receive legacy config on first migration.
#>
[CmdletBinding()]
param(
    [string]$DestinationConfig
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this migration from an elevated Administrator PowerShell.'
}

$startupDir = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup'
$legacyHook = Join-Path $startupDir 'childstream-sunshine.cmd'
Remove-Item -LiteralPath $legacyHook -Force -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName 'ChildStream Sunshine' -ErrorAction SilentlyContinue

$legacyConfig = Join-Path $root 'Sunshine\Sunshine\config'
if ($DestinationConfig -and (Test-Path -LiteralPath $legacyConfig)) {
    $destinationConf = Join-Path $DestinationConfig 'sunshine.conf'

    # Do not overwrite an existing Vibeshine config. Migration is only for
    # users coming from the original repo-local Sunshine payload.
    if (-not (Test-Path -LiteralPath $destinationConf)) {
        New-Item -ItemType Directory -Path $DestinationConfig -Force | Out-Null
        Get-ChildItem -LiteralPath $legacyConfig -Force |
            Copy-Item -Destination $DestinationConfig -Recurse -Force
        Write-Host "Migrated legacy Sunshine config/state to $DestinationConfig"
    }
}

Write-Host 'Legacy ChildStream Sunshine startup/firewall entries cleaned.'
