# WinServerSetup v1.2.0

**Tag:** `v1.2.0`

## Summary

WinServerSetup v1.2.0 adds Windows long paths enablement to the automated setup workflow, exposes the same action as a standalone menu option, and improves release/runtime diagnostics.

## Added

- Windows long paths enablement through `LongPathsEnabled=1` under `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem`.
- Full setup now runs the Windows long paths step automatically.
- Main menu now includes a standalone `Enable Windows long paths` option.
- New `filesystem.enableLongPaths` configuration toggle.
- Script version logging in the console transcript and structured log header.
- Windows long paths state in the health check output.

## Changed

- Documentation now lists Windows long paths as part of the system configuration workflow.
- Winget source repair now avoids `source reset --force` when `msstore` is already absent and only `winget source update` fails.

## Fixed

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
