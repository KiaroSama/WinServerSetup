# WinServerSetup v1.0.0

Initial public release of WinServerSetup, an administrator-only PowerShell provisioning project for Windows Server, Windows 10, and Windows 11.

## Summary

This release provides a configurable setup workflow for fresh Windows machines. It updates Windows, applies system settings, installs configured applications and runtimes, configures RDP safely, creates scheduled tasks, writes UTF-8 logs, defers reboot until setup is complete, and schedules a post-reboot `sfc /scannow`.

## Features

- First-run self-relocation to `C:\portable\Scripts\WinServerSetup`.
- Interactive menu and full setup mode.
- Multi-pass Windows Update with reboot suppression.
- Background application download prefetch while Windows Update runs.
- Sequential application installation so only one installer runs at a time.
- Dark mode, Explorer file extensions, Persian keyboard layout, and Search Indexing configuration.
- Safe RDP port change to TCP `5801` with firewall verification.
- Hidden, highest-privilege scheduled tasks for EmptyStandbyList, RDP brute-force blocking, and post-reboot SFC.
- Winget source repair for the known `msstore` certificate issue.
- Direct installer support for 9Proxy, Dolphin Anty, GoLogin, Everything, v2rayN, and PowerShell 7.
- PowerShell 7 Windows Terminal default profile and `.ps1` handler setup.
- 7-Zip archive associations for the current user.
- Quick Access and taskbar best-effort customization.
- Structured UTF-8 logs and concise colored console output.

## Requirements

- Windows Server, Windows 10, or Windows 11.
- Administrator privileges.
- Internet access for Windows Update, winget, GitHub release downloads, and direct installers.
- PowerShell execution allowed for the current process.

## Safety Notes

WinServerSetup performs real system changes. Review `WinServerSetup.config.json` before running it.

- It can download and run installers.
- It can edit registry keys.
- It can change the RDP port and Windows Firewall rules.
- It can create hidden scheduled tasks running as `SYSTEM`.
- It can remove configured Appx packages and Windows capabilities.
- It can clean temporary folders.
- It can restart Windows after setup completes.
- It includes an optional Windows activation helper. Use it only when you have the legal right to activate the target Windows installation.

## Quick Start

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\Run-WinServerSetup.ps1
```

Run full setup:

```powershell
.\Run-WinServerSetup.ps1 -Full
```

Run full setup without pause prompts:

```powershell
.\Run-WinServerSetup.ps1 -Full -NoPause
```

## Included Files

| File or folder | Purpose |
| --- | --- |
| `WinServerSetup.ps1` | Main setup script and menu. |
| `Run-WinServerSetup.ps1` | Auto-elevating launcher. |
| `WinServerSetup.config.json` | Main configuration file. |
| `scripts\Prefetch-AppDownloads.ps1` | Background app download helper. |
| `scripts\Block-RdpBruteforce.ps1` | RDP brute-force blocker. |
| `scripts\Run-PostRebootSfc.ps1` | Post-reboot SFC helper. |
| `default-apps\DefaultAppAssociations.xml` | Default app association template. |
| `task-scheduler\EmptyStandbyList.xml` | EmptyStandbyList task template. |
| `.github\workflows\powershell-lint.yml` | GitHub Actions parse and lint workflow. |
| `README.md` | Project documentation. |
| `LICENSE` | MIT License. |
| `ATTRIBUTION.md` | Attribution notice. |

## License

Released under the MIT License.

## Attribution

WinServerSetup - Copyright (c) 2026 Kiaro Sama  
Original author: Kiaro Sama  
GitHub: https://github.com/KiaroSama  
Original repository: https://github.com/KiaroSama/WinServerSetup  
Licensed under the MIT License.
