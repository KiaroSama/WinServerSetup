# Changelog

## [Unreleased]

### Fixed

- Fixed the RDP brute-force blocker being blind to the ordinary attack. Network Level Authentication - the default on current Windows and Windows Server - authenticates before any interactive session exists, so a failed RDP sign-in is recorded as Security 4625 `LogonType` **3**, not `LogonType` 10. Matching only `LogonType` 10 missed it entirely. The blocker now reads RDP-specific evidence from `Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational` (event 140 failed authentication, event 131 accepted connection) and counts a `LogonType` 3 failure when that client address is confirmed to have spoken RDP inside the lookback window - closing the gap without counting unrelated SMB or other network logons. Each block records its evidence class, and an unavailable RDP channel is reported as a warning rather than silently degrading.
- Fixed the RDP brute-force blocker building its incremental query with the XML entity `&gt;` instead of raw `>`. `Get-WinEvent -FilterXPath` rejected it as an invalid query, so every run after the first one failed and blocked nothing.
- Fixed the blocker treating an empty Security-log window as a failure. `Get-WinEvent` reports "no matching events" as an error, and with `-ErrorAction Stop` a quiet server made the task exit non-zero and fail the whole setup step. Empty windows are now a normal result, while genuine read failures still fail the task.
- Fixed the blocker's rolling window comparing a `Kind=Local` timestamp against a `Kind=Utc` cutoff. The window was skewed by the machine's UTC offset - too wide east of UTC, and west of UTC it discarded every event so nothing was ever blocked.
- Fixed the blocker mishandling a single new event on Windows PowerShell 5.1, where a one-element array returned from a function is unwrapped to a scalar and has no `.Count`.
- Fixed every download failing at runtime. `Invoke-WebRequest -OutFile` returns nothing without `-PassThru`, so the redirect check dereferenced `$null` and raised a parameter-binding error that the retry loop swallowed. The final URI is now resolved through a helper that handles both the Windows PowerShell 5.1 (`HttpWebResponse.ResponseUri`) and PowerShell 7 (`HttpResponseMessage.RequestMessage.RequestUri`) shapes, and fails closed when it cannot be determined.
- Fixed `-Full` setup exiting `0` after failed steps. The recorded-step helper wrote `$null` to the output stream on failure, so the caller's `return 1` became the last element of an array and `exit` coerced it to `0`. The exit code is now derived from the last emitted value.
- Fixed `RunStats.SkippedTasks` never being populated: it was displayed in the final summary and written to the structured log but nothing ever added to it, so config-disabled steps were counted as Completed.

### Security

- Changed tracked defaults to conservative values: activation disabled with empty product key and KMS server, unsupported .NET runtimes off, the Defender exclusion for the Downloads subfolder off, and the unpinned `EmptyStandbyList` download disabled.
- Added a `WinServerSetup.config.local.json` override, git-ignored, as the only supported place for activation secrets. Product keys in the tracked config are rejected at load time and block publication.
- Added Authenticode signature and expected-publisher verification plus download host allowlists for direct installers, with non-HTTPS URLs and unverifiable redirect targets rejected.
- Removed the rule that trusted any established TCP connection on the RDP port, which let an unauthenticated attacker hold a socket open to be skipped repeatedly. Only explicit `whitelistCIDRs` entries bypass blocking.
- Added validation of existing managed firewall rules (enabled, Block, Inbound, remote address, protocol, port scope) instead of trusting a matching rule name, with atomic repair of malformed rules and retention so managed rules cannot accumulate forever.

### Added

- Added stronger `Run-WinServerSetup.ps1` launcher diagnostics with a per-run UTC log file, resolved path details, forwarded switch logging, elevation flow logging, child exit-code logging, and stack details for launcher failures.
- Added a brighter, unified main menu style that keeps option numbers green and option labels cyan for a consistent black-terminal layout.
- Added a default main-menu selection so pressing Enter at `Select: [1]` runs option `1`.
- Added a centered startup banner over a full-width rule, rendered in true-color ANSI where the host supports it.
- Added `Get-AnsiCapability` so the true-color decision is a pure, testable function, and `Get-ConsoleWidth` so banner width detection falls back to 80 columns in hosts without a console window.
- Added regression coverage for menu defaults, unified menu colors, startup line rendering, banner centering across console widths, the ANSI capability matrix, PowerShell 7 launcher priority, Windows Terminal launcher priority, and launcher diagnostics.
- Added behavioral regression suites that exercise real code paths rather than matching source text: `tests\RdpBlockerRuntime.Tests.ps1` (XPath validity, empty-window tolerance, UTC-correct rolling window, single-event bookmark), `tests\DownloadRuntime.Tests.ps1` (a real local HTTP listener, including redirect handling), and `tests\SetupOutcome.Tests.ps1` (non-zero exit on failed steps, skipped-step accounting). Each was verified to fail against the pre-fix code on both hosts.
- Added `tests\Invoke-AllTests.ps1`, which discovers suites from disk - so a new test file cannot be silently missed by CI - and runs each with a bounded wall timeout, killing the process tree on expiry.
- Added `PSScriptAnalyzerSettings.psd1` with a small, individually justified suppression list, keeping every other rule active at Error and Warning severity.
- Added `.github\parse-check.ps1` and reworked the workflow into a `PowerShell CI` job that validates the config, parse-checks every script under **both** Windows PowerShell 5.1 and PowerShell 7, runs PSScriptAnalyzer at Error and Warning severity, and executes the full test suite on both hosts.
- Added recovery procedures to the README for RDP port rollback, accidental firewall blocks, blocker whitelist configuration, failed self-relocation, failed post-reboot SFC, and account-security restoration, plus a table explaining each security-sensitive default.

### Changed

- Changed the RDP brute-force blocker to detect RemoteInteractive logons (`LogonType` 10) only. Generic network logons (`LogonType` 3) are not RDP-specific and are now opt-in through `rdpBruteforceBlocker.includeNetworkLogonType3`, logged with their logon type when enabled.
- Changed blocker firewall rules to target the configured RDP TCP port instead of all inbound traffic from the address, unless `rdpBruteforceBlocker.blockAllInbound` is explicitly enabled.
- Changed `Run-WinServerSetup.ps1` to prefer PowerShell 7 (`pwsh.exe`) and fall back to Windows PowerShell 5 only when PowerShell 7 is unavailable.
- Changed launcher routing to use Windows Terminal `wt.exe -w 0 new-tab` as the first-priority console host whenever available, then PowerShell 7, with Windows PowerShell 5 as the final fallback.
- Changed self-relocation relaunches to prefer PowerShell 7 instead of hard-coded Windows PowerShell 5.
- Changed startup and self-relocation output to plain `Label: value` lines under a centered banner. The bracketed `[COPY]`, `[RUN]`, `[SHELL]`, `[LOG]`, `[CLEAN]`, `[NEXT]`, `[SKIP]`, and `[VERSION]` startup column is gone from the console but the state names are still recorded in the structured log.
- Changed the main menu header from a boxed `==== title ====` block to a single bold header line.
- Kept the aligned `[INFO]`, `[OK]`, `[WARN]`, and `[ERROR]` severity column for long-running task output, where severity must stay scannable.

### Fixed

- Fixed launcher failure visibility by keeping the launcher console open after elevation or child-process failures.
- Fixed Windows PowerShell 5.1 transcript startup warnings by avoiding the unsupported `Start-Transcript -Encoding` parameter.
- Fixed already-elevated ConsoleHost runs bypassing Windows Terminal.
- Fixed first-run self-relocation opening a separate PowerShell 7 window instead of remaining in the current Windows Terminal console.

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
