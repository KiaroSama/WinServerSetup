# Changelog

## [1.2.0] - 2026-05-28

### Added

- Added Windows long paths enablement to the full setup workflow.
- Added a standalone menu option for enabling Windows long paths.
- Added `filesystem.enableLongPaths` configuration for controlling the long paths step.
- Added script version logging to the console transcript and structured log header.
- Added Windows long paths state to the health check output.

### Changed

- Avoided winget source reset fallback when `msstore` is already absent and only `winget source update` fails.

### Fixed

- Removed unsupported `winget list --output json` package detection to avoid wasted winget calls and noisy structured logs.

## [1.1.0] - 2026-05-23

### Added

- Added app download prefetch support so installers can be downloaded while Windows Update is running.
- Added optional SHA256 validation and optional required Authenticode validation for direct installer downloads.
- Added per-step full setup task recording so the final summary reflects actual workflow progress.
- Added winget source reset fallback for source or certificate repair cases.

### Changed

- Changed the default parallel download limit to `4`.
- Changed v2rayN refresh behavior to copy updates without purging existing user configuration files.
- Changed user temp cleanup to remove only WinServerSetup-owned temporary artifacts instead of clearing the entire `%TEMP%` folder.
- Changed RDP brute-force blocking to count only RemoteInteractive logon failures and to use a threshold of `7`, preserving the intended "more than 6 attempts" behavior.
- Changed Windows Terminal settings handling to support legacy `profiles` array files.
- Changed default app import messaging to clarify that DISM imports apply to new user profiles.
- Changed GitHub release notes to target the next versioned release.

### Fixed

- Fixed RDP port-change rollback when Remote Desktop Services cannot restart after the registry update.
- Fixed RDP listener verification by waiting for the new port before blocking the old port.
- Fixed post-reboot SFC output capture and UTF-8 logging.
- Fixed winget package detection to prefer JSON output and avoid narrow-console table truncation where possible.
- Fixed `.ps1` PowerShell 7 file association metadata by adding a friendly name, icon, and edit flags.
- Fixed self-relocation cleanup script leakage by removing the temporary cleanup script after it runs.
- Fixed scheduled task visibility and highest-privilege behavior for project-created scheduled tasks.
- Fixed `Publish-ToGitHub.ps1` remote validation so accidental pushes to non-GitHub remotes are blocked unless forced.
- Fixed `Run-WinServerSetup.ps1` elevated process exit-code propagation.
- Fixed EmptyStandbyList task template start boundary so manual imports are not delayed by a future date.

### Security

- Direct installer downloads now reject configured SHA256 mismatches.
- Direct installer downloads can reject invalid or non-applicable Authenticode signatures when `requireValidSignature` is enabled for that installer.
- RDP port changes now avoid blocking the old port unless the new port is confirmed listening.

## [1.0.0] - 2026-05-23

### Added

- Initial public release of WinServerSetup.
- Added administrator-only menu and full setup workflow.
- Added Windows Update, application installation, RDP configuration, scheduled task creation, runtime installation, cleanup, logging, and post-reboot SFC support.
