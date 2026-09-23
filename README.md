# ChildStream + Vibeshine

**Stream games from a second Windows desktop while you keep using your PC — free, open, no license unlocks.**

This fork uses **[Vibeshine](https://github.com/Nonary/vibeshine)** as the Moonlight-compatible streaming host and adds child-session startup cleanup so normal desktop startup apps do not stay running in the streaming session.

ChildStream uses documented Windows child sessions plus a repo-local Vibeshine payload. Vibeshine's Windows host executable is still named `sunshine.exe`, and its Windows config is still `sunshine.conf`; those upstream filenames are expected.

## Requirements

- Windows 10/11 **Pro**
- A GPU with a hardware encoder (NVENC / AMF / QSV)
- .NET Framework 4.x
- A password-capable Windows account

## Setup

```powershell
# from an elevated PowerShell in the repo root
.\scripts\setup.ps1
```

The setup script:

1. Compiles `ChildStream.exe`.
2. Enables Windows child sessions and loopback RDP.
3. Raises the RDP compositor rate for high-refresh streaming.
4. Downloads the latest stable release from `Nonary/vibeshine`.
5. Uses MSI administrative mode (`/a`) to unpack Vibeshine into the repo instead of registering Vibeshine's normal machine-wide auto-start service.
6. Configures the child host on base port **48989**.
7. Adds a `ChildStream Vibeshine` firewall rule and a child-session-only startup hook.
8. Enables startup cleanup from `scripts\childsession-allowlist.json`.
9. Creates the **Child Session** desktop shortcut.

After setup, use the credential command printed by the script, launch **Child Session**, and pair Moonlight/Artemis with `<host-ip>:48989`.

## Startup allow list

Because the child session uses the same Windows user profile, Windows can launch your normal per-user startup applications there too. This fork cleans unwanted third-party startup processes from the **child session only** for a short period after logon. It does not touch matching processes on the physical console session.

Edit:

```text
scripts\childsession-allowlist.json
```

The default allow list keeps Vibeshine (`sunshine.exe`), Explorer, Steam, Steam WebHelper, GameOverlayUI, and required Windows shell processes. Processes under `%WINDIR%` are protected. Descendants of Vibeshine and Steam are protected so games launched during the cleanup window are not terminated.

To keep another app, add its process name without `.exe` to `allowProcesses`. If it is a launcher whose child processes should also survive cleanup, add it to `protectDescendantsOf` as well.

Example:

```json
{
  "allowProcesses": ["sunshine", "steam", "Playnite.FullscreenApp"],
  "protectDescendantsOf": ["sunshine", "steam", "Playnite.FullscreenApp"]
}
```

You can also change `initialDelaySeconds`, `cleanupSeconds`, and `scanIntervalSeconds` in the JSON file. The default cleanup window is 45 seconds.

## Why Vibeshine is unpacked instead of normally installed

Vibeshine's standard Windows installer registers an auto-start streaming service. That is useful for a normal single-session host but conflicts with ChildStream's goal of running the streaming host only inside the child session.

`setup.ps1` therefore invokes the official Vibeshine installer in MSI administrative/extraction mode and launches the extracted `sunshine.exe` from the child-session startup script.

## Usage notes

- Keep ChildStream running while streaming; minimizing it to the tray is fine.
- The child session itself survives viewer disconnects; sign out inside it to fully end the session.
- If an app you intentionally need disappears shortly after child-session logon, add it to `scripts\childsession-allowlist.json`.
- The cleanup is fail-safe: Windows-directory processes and processes whose executable path cannot be inspected are not terminated.

## Limitations

- One child session maximum (Windows limitation).
- The child session uses the same Windows account/profile as the console session.
- Startup cleanup happens after Windows initially creates startup processes; it is not true pre-launch suppression.
- Vibeshine features that depend on its normally installed Windows service or optional system drivers may not be available in this portable child-session configuration.
- A ChildStream RDP viewer connection must stay attached for the child display to remain capturable.

## Uninstall

- Delete the repo folder and the **Child Session** desktop shortcut.
- Delete `C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\childstream-vibeshine.cmd`.
- Remove the firewall rule `ChildStream Vibeshine`.
- If upgrading from the original version, you can also remove the legacy `childstream-sunshine.cmd`, `ChildStream Sunshine` firewall rule, and old local `Sunshine\` folder.
- Optional: restore the RDP/child-session registry settings changed by setup.

## Credits

- [mattxslv/childstream](https://github.com/mattxslv/childstream) for the original proof of concept
- [Nonary/vibeshine](https://github.com/Nonary/vibeshine) for the streaming host
- [DuoStream/Duo](https://github.com/DuoStream/Duo) for the multiseat concept
- [Artemis / moonlight-android](https://github.com/ClassicOldSong/moonlight-android) as a client
- Microsoft's documented Child Sessions API

## Disclaimer

Proof of concept, provided as-is. Use at your own risk.
