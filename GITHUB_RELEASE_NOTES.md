# WinServerSetup v1.1.0

**Suggested tag:** `v1.1.0`

## Summary

WinServerSetup v1.1.0 is a reliability, safety, and release-documentation update for the Windows Server setup automation project. It focuses on preventing data loss, reducing RDP lockout risk, improving download validation, making cleanup safer, and improving release readiness.

## Added

- App download prefetch support while Windows Update is running.
- Optional `expectedSha256` validation for direct installer entries.
- Optional `requireValidSignature` validation for direct installer entries.
- Per-step full setup task recording so the final summary reflects real workflow progress.
- Winget source reset fallback when source listing, removal, or update fails.
- Changelog file for versioned release tracking.

## Changed

- Default parallel download limit is now `4`.
- v2rayN refresh now copies new files without purging user configuration files.
- User temp cleanup is now scoped to WinServerSetup-owned artifacts instead of wiping the whole `%TEMP%` folder.
- RDP brute-force blocking now counts only RemoteInteractive logon failures.
- RDP brute-force threshold is now `7`, preserving the intended "more than 6 failed attempts" behavior.
- Windows Terminal settings updates now handle legacy `profiles` array files.
- Default app import messaging now clarifies that DISM imports apply to new user profiles.
- GitHub release notes now target the next versioned release instead of the initial release.

## Fixed

- Fixed RDP port-change rollback when Remote Desktop Services cannot restart after the registry update.
- Fixed RDP listener verification by waiting for the new port before blocking the old port.
- Fixed post-reboot SFC output capture and logging.
- Fixed winget package detection to prefer JSON output and avoid table truncation where possible.
- Fixed `.ps1` PowerShell 7 file association metadata by adding a friendly name, icon, and edit flags.
- Fixed relocation cleanup script leakage from `%TEMP%`.
- Fixed scheduled task hidden/highest-privilege behavior for project-created scheduled tasks.
- Fixed `Publish-ToGitHub.ps1` remote validation so accidental non-GitHub pushes are blocked unless forced.
- Fixed `Run-WinServerSetup.ps1` elevated process exit-code propagation.
- Fixed EmptyStandbyList task template start boundary for manual imports.

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
- It can change the RDP port and Windows Firewall rules.
- It can create hidden scheduled tasks running as `SYSTEM`.
- It can remove configured Appx packages and Windows capabilities.
- It can clean configured cache/temp locations.
- It can restart Windows after setup completes.
- It includes an optional Windows activation helper. Use it only when you have the legal right to activate the target Windows installation.

## Upgrade Notes

- Review `WinServerSetup.config.json` before running this version.
- Direct installer entries may optionally use `expectedSha256` and `requireValidSignature`; existing entries continue to work without those fields.
- The RDP brute-force threshold is now `7`, which preserves the intended default behavior of blocking after more than 6 failed RemoteInteractive logons.
- The default download cache remains `%TEMP%\WinServerSetup-downloads`.

## License and Attribution

Released under the MIT License.

WinServerSetup - Copyright (c) 2026 Kiaro Sama  
Original author: Kiaro Sama  
GitHub: https://github.com/KiaroSama  
Original repository: https://github.com/KiaroSama/WinServerSetup  
Licensed under the MIT License.
