# ChildStream + Vibeshine

**Stream games from a second Windows desktop while you keep using your PC — free, open, no license unlocks.**

This fork keeps the original ChildStream naming, uses **[Vibeshine](https://github.com/Nonary/vibeshine)** as the Moonlight-compatible host, and suppresses unwanted startup apps only inside the child session.

Vibeshine's Windows host executable is still named `sunshine.exe` and its config remains `sunshine.conf`; those upstream filenames are expected.

## Requirements

- Windows 10/11 **Pro**
- A GPU with a hardware encoder (NVENC / AMF / QSV)
- .NET Framework 4.x
- A password-capable Windows account

## Setup

```powershell
# elevated PowerShell in the repo root
.\scripts\setup.ps1
```

The setup script now:

1. Compiles `ChildStream.exe` and saves the original Windows/RDP settings for a reversible uninstall.
2. Enables Windows child sessions, loopback RDP, high-refresh composition, and minimized-session rendering.
3. Checks the latest stable `Nonary/vibeshine` release every run.
4. Downloads the official installer and verifies the SHA-256 digest published by GitHub before executing it.
5. Extracts Vibeshine in MSI administrative mode so the normal machine-wide `SunshineService` is **not** installed.
6. Updates the portable Vibeshine payload when a newer release exists while preserving the existing `config` directory.
7. Migrates the old repo-local Sunshine config/state on first upgrade.
8. Preserves existing Vibeshine settings; only missing ChildStream defaults are added on existing installs.
9. Installs/updates only Vibeshine's machine-wide **VHF virtual gamepad driver** for Moonlight controller support. The Vibeshine service and virtual display driver remain uninstalled.
10. Creates the firewall rule, child-session startup hook, and desktop shortcut.

After setup, use the credential command printed by the script, launch **Child Session**, and pair Moonlight/Artemis with `<host-ip>:48989`.

## Safer startup-app suppression

Windows uses the same user profile for the child session, so per-user startup apps can launch there as well. The cleanup script now queries Windows' real startup entries (`Win32_StartupCommand` plus Startup-folder shortcuts) and only considers those executable names eligible for suppression.

This means an unrelated third-party app you manually launch during the 45-second cleanup window is no longer automatically killed simply because it is not on the allow list.

Edit:

```text
scripts\childsession-allowlist.json
```

`allowProcesses` keeps specific startup apps. `extraStartupProcesses` is only for startup executables Windows fails to expose automatically. Process names omit `.exe`.

After a startup executable is successfully suppressed once, the script stops policing that executable name for the rest of the login, so manually relaunching it is allowed.

## Vibeshine updates and config preservation

Rerunning `setup.ps1` is also the updater. It compares the locally recorded Vibeshine release tag with GitHub's current stable release, verifies the published installer SHA-256, extracts the new payload to a staging directory, preserves your `config` directory, and then swaps the payload.

If the repo-local Vibeshine host is currently running, setup refuses to replace it; sign out of the child session and rerun setup.

## Why the normal Vibeshine service is not installed

Vibeshine's `SunshineService` follows the active **console** session. ChildStream needs Vibeshine to run specifically inside the Windows child session, so this fork intentionally launches the portable host from the child-session startup hook instead.

The VHF virtual gamepad driver is installed separately because controller emulation is machine-wide and useful to the child-session host.

## Migration

`setup.ps1` automatically calls:

```powershell
.\scripts\migrate.ps1
```

The migration helper removes legacy `ChildStream Sunshine` firewall/startup entries and copies the old `Sunshine\Sunshine\config` state into Vibeshine when no Vibeshine config exists yet.

## Uninstall

Run from an elevated PowerShell:

```powershell
.\scripts\uninstall.ps1
```

The uninstaller stops only the repo-local Vibeshine process, removes ChildStream's startup hooks/firewall rule/shortcut/runtime payload (including the obsolete repo-local Sunshine payload), and restores the exact Windows registry/child-session settings saved by the first new setup run.

The machine-wide Vibeshine virtual gamepad driver is deliberately kept by default because another Vibeshine installation could share it. To remove it too:

```powershell
.\scripts\uninstall.ps1 -RemoveGamepadDriver
```

## Usage notes

- Keep ChildStream running while streaming; minimizing it to the tray is fine.
- The child session itself survives viewer disconnects; sign out inside it to fully end the session.
- If a startup app that you actually need is suppressed, add its process name to `allowProcesses`.
- If a startup app is missed because Windows does not expose its executable name, add it to `extraStartupProcesses`.

## Limitations

- One child session maximum (Windows limitation).
- The child session uses the same Windows account/profile as the console session.
- Startup apps are suppressed after Windows initially creates them; this is not true pre-launch suppression.
- The normal Vibeshine service and Vibeshine virtual display driver are intentionally not installed.
- A ChildStream RDP viewer connection must stay attached for the child display to remain capturable.

## Credits

- [mattxslv/childstream](https://github.com/mattxslv/childstream) for the original proof of concept
- [Nonary/vibeshine](https://github.com/Nonary/vibeshine) for the streaming host and virtual gamepad driver
- [DuoStream/Duo](https://github.com/DuoStream/Duo) for the multiseat concept
- [Artemis / moonlight-android](https://github.com/ClassicOldSong/moonlight-android) as a client
- Microsoft's documented Child Sessions API

## Disclaimer

Proof of concept, provided as-is. Use at your own risk.
