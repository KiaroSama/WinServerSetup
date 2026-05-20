# WinServerSetup

Administrator-only PowerShell automation for preparing a fresh Windows Server, Windows 10, or Windows 11 machine.

WinServerSetup updates Windows, applies system and Explorer settings, installs a configured set of applications and runtimes, configures Remote Desktop safely, registers scheduled tasks, improves usability and security defaults, writes UTF-8 logs, defers reboot until setup is complete, and schedules a post-reboot `sfc /scannow`.

Author: Kiaro Sama  
GitHub: https://github.com/KiaroSama

## Features

- First-run self-relocation to `C:\portable\Scripts\WinServerSetup`.
- Menu-driven and full unattended setup modes.
- Multi-pass Windows Update with Microsoft Update support and reboot suppression.
- Application download prefetch while Windows Update is running.
- Sequential application installation so only one installer runs at a time.
- Dark mode, Explorer file extensions, Persian keyboard layout, and Windows Search Indexing.
- Safe RDP port change to TCP `5801` with firewall verification before registry changes.
- Hidden, highest-privilege scheduled tasks for EmptyStandbyList, RDP brute-force blocking, and post-reboot SFC.
- PowerShell 7 install, Windows Terminal default profile configuration, and `.ps1` open handler setup.
- 7-Zip archive file associations for the current user.
- Quick Access pinning for configured folders and Recycle Bin.
- Startup cleanup and optional removal of configured Windows components.
- Structured UTF-8 logs and concise colored console output.

## Supported Platforms

- Windows Server where PowerShell and Windows scheduled tasks are available.
- Windows 10.
- Windows 11.

The script is written for Windows PowerShell 5.1 compatibility and can also run from newer PowerShell hosts where the required Windows cmdlets are available.

## Requirements

- Run as Administrator.
- Internet access for Windows Update, winget, GitHub release downloads, and direct installers.
- PowerShell execution allowed for the current process.
- Remote access to the new RDP port must also be allowed by any upstream firewall, NAT, VPS provider firewall, or cloud security group.

## Installation

Download or clone this repository, then run the launcher from an elevated PowerShell session or by right-clicking it:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\Run-WinServerSetup.ps1
```

On first run, if `selfRelocate.enabled` is true, the project copies itself to:

```text
C:\portable\Scripts\WinServerSetup
```

It then relaunches from that location and exits the original process.

## Usage

Interactive menu:

```powershell
.\Run-WinServerSetup.ps1
```

Full setup:

```powershell
.\Run-WinServerSetup.ps1 -Full
```

Full setup without pause prompts:

```powershell
.\Run-WinServerSetup.ps1 -Full -NoPause
```

Prevent automatic reboot:

```powershell
.\Run-WinServerSetup.ps1 -Full -NoReboot
```

Run from the current folder without self-relocation:

```powershell
.\WinServerSetup.ps1 -NoRelocate
```

### Main switches

| Switch | Description |
| --- | --- |
| `-Full` | Run the full workflow without showing the menu. |
| `-NoPause` | Skip interactive `Press any key to continue...` prompts. |
| `-NoColor` | Disable colored terminal output. |
| `-NoReboot` | Do not restart automatically even if a reboot is pending. |
| `-NoRelocate` | Do not move the project to `C:\portable\Scripts\WinServerSetup`. |

## Full Setup Workflow

The full setup workflow performs these actions:

1. Applies dark mode and Explorer settings.
2. Adds the Persian keyboard layout without removing existing layouts.
3. Creates configured portable folders.
4. Starts safe parallel registry tasks and app download prefetch.
5. Runs multi-pass Windows Update while downloads continue in the background.
6. Applies QoS and Windows Update bandwidth policies.
7. Installs configured applications and runtimes sequentially.
8. Configures default browser, media player, 7-Zip associations, PowerShell 7, and Windows Terminal where Windows allows it.
9. Changes the RDP port safely.
10. Enables Windows Search Indexing.
11. Registers scheduled tasks.
12. Disables configured startup entries and removes configured Windows components.
13. Pins configured Quick Access entries and replaces taskbar pins where Windows allows it.
14. Runs health checks and cleanup.
15. Prints the final summary.
16. Schedules post-reboot SFC and restarts only after all setup tasks finish when a reboot is required.

## Configured Applications

Winget packages:

- FFmpeg
- 7-Zip
- Brave Browser
- qBittorrent
- Python 3.11
- K-Lite Codec Pack Mega
- Notepad++
- Telegram Desktop
- Windows Terminal

Direct or GitHub downloads:

| Application | Source |
| --- | --- |
| 9Proxy | `https://static.9proxy-cdn.net/download/latest/windows/9proxy-windows-installer.exe` |
| Dolphin Anty | `https://app.dolphin-anty-mirror3.net/anty-app/dolphin-anty-win-latest.exe` |
| GoLogin | `https://dl.gologin.com/gologin.exe` |
| Everything | Latest x64 installer parsed from `https://www.voidtools.com/downloads/` |
| v2rayN | Latest GitHub release from `2dust/v2rayN` matching `v2rayN-windows-64.zip` |
| PowerShell 7 | Latest GitHub release from `PowerShell/PowerShell` matching the configured MSI regex |
| EmptyStandbyList | Configured GitHub source or `apps\installers\EmptyStandbyList.exe` |

Before winget installation, the script removes the `msstore` winget source when configured and refreshes winget sources to avoid known `0x8a15005e` certificate errors.

## Important Repository Files

| File or folder | Purpose |
| --- | --- |
| `WinServerSetup.ps1` | Main provisioning script and menu. |
| `Run-WinServerSetup.ps1` | Auto-elevating launcher. |
| `WinServerSetup.config.json` | Main configuration file. |
| `scripts\Prefetch-AppDownloads.ps1` | Background app download prefetch helper. |
| `scripts\Block-RdpBruteforce.ps1` | Scheduled RDP brute-force blocker. |
| `scripts\Run-PostRebootSfc.ps1` | One-time post-reboot SFC runner. |
| `default-apps\DefaultAppAssociations.xml` | Default app association template. |
| `task-scheduler\EmptyStandbyList.xml` | EmptyStandbyList scheduled task template. |
| `apps\installers\PUT_INSTALLERS_HERE.txt` | Notes for optional local installers. |
| `.github\workflows\powershell-lint.yml` | GitHub Actions parse and lint workflow. |
| `Publish-ToGitHub.ps1` | Optional local helper for initializing and pushing a Git repo. |
| `LICENSE` | MIT License and attribution notice. |
| `ATTRIBUTION.md` | Attribution summary. |
| `GITHUB_RELEASE_NOTES.md` | Draft release notes for the first GitHub release. |

## Configuration

Most behavior can be enabled, disabled, or adjusted in `WinServerSetup.config.json`.

Important sections:

| Config area | Purpose |
| --- | --- |
| `selfRelocate` | Controls first-run relocation. |
| `parallel` | Controls safe parallel download/background work. |
| `windowsUpdate` | Controls Windows Update behavior and pass count. |
| `activation` | Controls optional Windows activation helper behavior. |
| `rdp` | Controls RDP port, old-port blocking, and service restart behavior. |
| `winget.packages` | Controls winget-installed applications. |
| `directInstallers` | Controls direct installer downloads. |
| `runtimes` | Controls .NET and Visual C++ runtime installation. |
| `rdpBruteforceBlocker` | Controls failed-login blocking threshold and schedule. |
| `autoReboot` | Controls final automatic reboot and post-reboot SFC scheduling. |
| `cleanup` | Controls temporary file cleanup. |

## Logs and Output

The script separates concise console output from detailed diagnostics.

Logs are written under the resolved project `logs` directory:

| Log file | Purpose |
| --- | --- |
| `WinServerSetup-<timestamp>.log` | Console transcript. |
| `WinServerSetup-structured-<timestamp>.log` | Structured task, command, output, warning, and summary log. |
| `WinServerSetup-prefetch-<timestamp>.log` | Background app prefetch log. |
| `rdp-blocker.log` | RDP brute-force blocker log. |
| `sfc-result.log` | Post-reboot SFC result log. |

The default download cache is `%TEMP%\WinServerSetup-downloads`. The project no longer creates `C:\portable\_downloads` unless you explicitly configure a permanent download root.

## Safety Notes

This project performs real system changes. Review `WinServerSetup.config.json` before running it.

- It must run as Administrator.
- It can download and execute installers.
- It can install or upgrade applications.
- It can edit registry keys.
- It can change the RDP port.
- It can add, update, or remove Windows Firewall rules.
- It can create hidden scheduled tasks running as `SYSTEM`.
- It can remove configured Appx packages and Windows capabilities.
- It can clean temporary folders.
- It can restart Windows after the setup workflow completes.
- It includes an optional Windows activation helper. Use it only when you have the legal right to activate the target Windows installation.

The RDP port change is implemented defensively: the firewall rule for the new port is created and verified before the registry port is changed, and the old port is blocked only after the new port is confirmed listening where possible.

## Troubleshooting

### The script says it must run as Administrator

Run `Run-WinServerSetup.ps1` by right-clicking it and choosing **Run with PowerShell**, or start PowerShell as Administrator and run the script manually.

### Winget fails with an `msstore` certificate error

The script removes the `msstore` source before package installs when `winget.removeMsstoreSource` is true. If the error persists, run:

```powershell
winget source list
winget source remove msstore
winget source update
```

Then run the application installation step again.

### Windows blocks default app changes

Windows 10 and Windows 11 protect some per-user default app selections with `UserChoice` hashes. The script attempts safe current-user associations and logs a warning if Windows blocks the change. Use Windows Settings as a manual fallback.

### Taskbar pinning does not change

Modern Windows builds often block programmatic taskbar pinning and unpinning. The script logs a warning and continues. Pin Brave or unpin Edge manually if needed.

### RDP does not connect after a port change

Check all network layers, not only Windows Firewall. The new port must be allowed by the VPS provider firewall, router/NAT rule, cloud security group, and any external firewall. The configured target port is TCP `5801`.

### Post-reboot SFC did not run

Check Task Scheduler for `WinServerSetup Post-Reboot SFC` and review `logs\sfc-result.log`. The task unregisters itself after it runs.

## Public Release Hygiene

Do not publish local runtime artifacts. The `.gitignore` excludes logs, comments, command notes, local tool state, downloaded installers, backups, caches, temporary files, secret patterns, and generated output.

Expected public files include the PowerShell scripts, configuration template, README, license, attribution file, release notes, GitHub workflow, default app XML, scheduled task XML, and installer instructions.

## License and Attribution

This project is released under the MIT License.

You are free to use, copy, modify, publish, distribute, sublicense, and use this project in your own projects, including free or commercial projects.

However, if you copy, modify, publish, distribute, or include substantial parts of this project in another project, you must keep the original copyright and license notice.

Please preserve this attribution:

WinServerSetup - Copyright (c) 2026 Kiaro Sama  
Original author: Kiaro Sama  
GitHub: https://github.com/KiaroSama  
Original repository: https://github.com/KiaroSama/WinServerSetup  
Licensed under the MIT License.

## Donate

If this project helps you, donations are appreciated.

| Currency | Network | Address |
| --- | --- | --- |
| Bitcoin (BTC) | Bitcoin | `bc1qmth5m03pu5hujw5xw5jmywam3jj3sqwqupesdt` |
| USDT, BNB, USDC, etc. | BEP20 | `0x0Bd0BA443a8B9cf15922bf7f0Bb0a4b495fD06Ef` |
| USDT, TRX, USDC, etc. | TRC20 | `TWBA3xFTqgZAeAYMxqo85xWnzvty3DcAhw` |
| Ethereum (ETH) | ERC20 | `0x0Bd0BA443a8B9cf15922bf7f0Bb0a4b495fD06Ef` |
| TON | TON | `UQCN8Umo_OfOWqImZetQsrNStPcmLkMAKajFyiCOhso23NDb` |
| Litecoin (LTC) | LTC | `ltc1qntqnnrunadurnw4cshv3qgspywrueyyeyngwuy` |
| Solana (SOL) | Solana | `7B2wkczUjmkDhETwQuknBL8sUsbuV7nErxc317TmQuwR` |
| Polygon (POL) | Polygon | `0x0Bd0BA443a8B9cf15922bf7f0Bb0a4b495fD06Ef` |

## Author

Kiaro Sama  
GitHub: https://github.com/KiaroSama
