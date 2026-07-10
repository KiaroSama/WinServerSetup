# WinServerSetup Next Release Draft

**Tag:** to be selected for the next release

## Summary

This draft release improves launcher diagnostics and startup color hierarchy, makes the interactive menu more consistent on black terminals, adds an Enter-to-run-full-setup default, prioritizes PowerShell 7 and Windows Terminal, and documents the expanded RDP brute-force blocker behavior.

## Added

- Stronger `Run-WinServerSetup.ps1` launcher diagnostics with a per-run UTC log file under `logs`.
- Launcher logging for resolved paths, execution ID, user/host/runtime details, forwarded switches, elevation flow, child exit code, duration, and launcher stack details.
- A brighter unified main menu style with green option numbers and cyan option labels.
- `Select: [1]` as the main-menu default, so pressing Enter runs the full setup workflow.
- Regression coverage for menu defaults, unified menu colors, semantic startup states, PowerShell 7 launcher priority, Windows Terminal launcher priority, and launcher diagnostics.
- Windows long paths enablement through `LongPathsEnabled=1` under `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem`.
- Full setup now runs the Windows long paths step automatically.
- Main menu now includes a standalone `Enable Windows long paths` option.
- New `filesystem.enableLongPaths` configuration toggle.
- Script version logging in the console transcript and structured log header.
- Windows long paths state in the health check output.

## Changed

- RDP brute-force blocker documentation now describes LogonType `3` and `10` detection and targeted username logging.
- `Run-WinServerSetup.ps1` now prefers PowerShell 7 (`pwsh.exe`) and falls back to Windows PowerShell 5 only when PowerShell 7 is unavailable.
- Launcher routing now uses Windows Terminal `wt.exe -w 0 new-tab` as the first-priority console host whenever available, then PowerShell 7, with Windows PowerShell 5 as the final fallback.
- Self-relocation relaunches now prefer PowerShell 7 instead of hard-coded Windows PowerShell 5.
- Startup and self-relocation output now uses aligned semantic state tags with separate label, path, value, success, warning, and error colors inspired by the FFmWiz terminal design system.
- Documentation now lists Windows long paths as part of the system configuration workflow.
- Winget source repair now avoids `source reset --force` when `msstore` is already absent and only `winget source update` fails.

## Fixed

- Launcher failures are now easier to diagnose because the console remains open after elevation or child-process failures and the launcher log records the failure path.
- Windows PowerShell 5.1 no longer prints a transcript warning for the unsupported `Start-Transcript -Encoding` parameter.
- Already-elevated ConsoleHost runs no longer bypass Windows Terminal.
- First-run self-relocation remains in the current Windows Terminal console instead of opening a separate PowerShell 7 window.
- Removed unsupported `winget list --output json` package detection to avoid wasted winget calls and noisy structured logs.

## Removed

- No user-facing features were removed.

## Breaking Changes

- No breaking changes are expected.

## Requirements

- Windows Server, Windows 10, or Windows 11.
- Administrator privileges.
- Internet access for Windows Update, winget, GitHub release downloads, and direct installers.
- PowerShell execution allowed for the current process.

## Safety Notes

WinServerSetup performs real system changes. Review `WinServerSetup.config.json` before running it.

- It can download and run installers.
- It can edit registry keys.
- It can enable Windows long paths by setting `LongPathsEnabled=1`.
- It can change the RDP port and Windows Firewall rules.
- It can create hidden scheduled tasks running as `SYSTEM`.
- It can remove configured Appx packages and Windows capabilities.
- It can clean configured cache/temp locations.
- It can restart Windows after setup completes.
- It includes an optional Windows activation helper. Use it only when you have the legal right to activate the target Windows installation.

## Upgrade Notes

- Review `WinServerSetup.config.json` before running this version.
- `filesystem.enableLongPaths` defaults to `true`, so full setup enables Windows long paths automatically unless you disable that setting.
- The running script version is now included in the logs, which helps verify support reports against the released version.

## License and Attribution

Released under the MIT License.

WinServerSetup - Copyright (c) 2026 Kiaro Sama  
Original author: Kiaro Sama  
GitHub: https://github.com/KiaroSama  
Original repository: https://github.com/KiaroSama/WinServerSetup  
Licensed under the MIT License.
