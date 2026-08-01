# Changelog

## [Unreleased]

### Changed

- Removed three config keys that nothing read: `projectName`, `scriptsRoot` and `interactiveAnyKey`. No code, validator or document referenced any of them. `scriptsRoot` was the one worth removing on its own - it named a path (`C:\portable\Scripts`) that a reader would reasonably expect to control where the project installs, while the setting that actually does that is `targetProjectRoot`.
- Collapsed the assertion boilerplate that every test suite carried its own copy of into `tests\_Common.ps1`, dot-sourced per suite: `Assert-True` (18 byte-identical copies), `Assert-Equal` (16) and `Import-FunctionUnderTest` (10). Suites needing different behaviour keep a local definition, which shadows the shared one. `Import-FunctionUnderTest` now takes the parsed ASTs as an argument instead of reading the caller's `$setupAsts` implicitly - reaching across the file boundary works at runtime but is invisible to PSScriptAnalyzer, which then reports the suite's own `$setupAsts` as unused. The file is not picked up as a suite because discovery filters on `*.Tests.ps1`.
- Merged the two identical "spin a status line while a process runs" loops in `scripts\Download.ps1` into `Wait-ProcessWithStatus`. The two sites disagreed on one point: one broke out when `Process.Refresh()` threw, the other swallowed it and kept polling a dead handle every two seconds forever. The merged helper breaks, which is the safe reading of the two.
- Removed `Read-HostUntimed`, which only forwarded to `Read-HostThemed` and added nothing. The name implied a timed counterpart that does not exist - `Read-HostThemed` already suspends the active timer for every caller.

### Fixed

- Fixed an already-current winget package being reported as an upgrade failure. `Test-WingetUpgradeExitCode` exists precisely to treat `0x8A15002B` ("no applicable upgrade found") as success, but its only production caller open-coded `-ne 0` and never used it, so every already-current package produced a spurious "Upgrade check for X exited with code -1978335189" warning on each run. The caller now routes the exit code through the classifier; a genuine failure still warns.
- Split `WinServerSetup.ps1` into a thin entry point plus seven dot-sourced modules under `scripts\` (`Console`, `Core`, `Download`, `Rdp`, `Install`, `SystemSettings`, `Maintenance`), following the pattern the project already used for `Config.ps1` and `AccountSecurity.ps1`. The entry point drops from 4215 to 329 lines and now holds only the globals, the ordered dot-source list, the menu, and full-setup orchestration. This is a pure file partition: no function body was edited, renamed or reordered, and the set of defined function names is identical before and after - 221, none added, none lost. Globals stay global and are initialised before any module loads, because each module contains only function definitions.
- Fixed two test suites waiting on a child process with no time bound. `tests\LauncherSafety.Tests.ps1` and `tests\RelocationSafety.Tests.ps1` each waited on a `cmd /c exit N` fixture with a parameterless `WaitForExit()`, so a child that never exited would block the suite indefinitely; the runner would then kill it at the wall timeout and report a bare `TIMEOUT` with no indication of which line hung. Both are now bounded and asserted, and the parameterless call is kept immediately after because the bounded overload can leave `ExitCode` unpopulated on Windows PowerShell 5.1.
- Fixed the PowerShell 7 MSI reporting a successful install as a failure. That path open-coded its own success set of `0`/`3010` and omitted `1641` ("success, reboot already initiated"), so an installer returning `1641` was treated as failed. Installer exit codes are now interpreted in one place, `Resolve-InstallerExitCode`, which every installer consults. **Behavior change**: such an install now reports success with a pending reboot instead of failure.
- Fixed the winget uninstall-registry fallback being dead code. `Test-WingetPackageInstalled` called `Get-InstalledRegistryDisplayName -NamePattern` while the parameter is `-NameLike`; the binding error was swallowed by an empty catch, so the fallback threw on every call and returned "not installed". That fallback exists for packages winget cannot see - installed from msstore, out of band, or with no source association - which is routine here because this project removes the `msstore` source by default.
- Fixed `Get-InstalledRegistryDisplayName` never returning a scalar. `return` inside a `ForEach-Object` block exits only that iteration, so a match leaked into the pipeline, the scan continued across all three registry hives, and the closing `return $null` appended a `$null`.
- Fixed startup-entry removal counting failed deletions as successes: the delete was suppressed with `-ErrorAction SilentlyContinue` and the entry was then logged and counted unconditionally, so a run where every delete failed still reported success.
- Fixed the Everything service reporting "set to Automatic + started" without checking that it actually started.
- Fixed the RDP brute-force blocker returning a failure exit code for a benign concurrent run. A scheduling overlap made the scheduled task record `LastTaskResult=1`, which the health check reports as a failed security control - masking whether the blocker is genuinely broken.
- Fixed the RDP brute-force blocker being blind to the ordinary attack. Network Level Authentication - the default on current Windows and Windows Server - authenticates before any interactive session exists, so a failed RDP sign-in is recorded as Security 4625 `LogonType` **3**, not `LogonType` 10. Matching only `LogonType` 10 missed it entirely. The blocker now reads RDP-specific evidence from `Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational` (event 140 failed authentication, event 131 accepted connection) and counts a `LogonType` 3 failure when that client address is confirmed to have spoken RDP inside the lookback window - closing the gap without counting unrelated SMB or other network logons. Each block records its evidence class, and an unavailable RDP channel is reported as a warning rather than silently degrading.
- Fixed the RDP brute-force blocker building its incremental query with the XML entity `&gt;` instead of raw `>`. `Get-WinEvent -FilterXPath` rejected it as an invalid query, so every run after the first one failed and blocked nothing.
- Fixed the blocker treating an empty Security-log window as a failure. `Get-WinEvent` reports "no matching events" as an error, and with `-ErrorAction Stop` a quiet server made the task exit non-zero and fail the whole setup step. Empty windows are now a normal result, while genuine read failures still fail the task.
- Fixed the blocker's rolling window comparing a `Kind=Local` timestamp against a `Kind=Utc` cutoff. The window was skewed by the machine's UTC offset - too wide east of UTC, and west of UTC it discarded every event so nothing was ever blocked.
- Fixed the blocker mishandling a single new event on Windows PowerShell 5.1, where a one-element array returned from a function is unwrapped to a scalar and has no `.Count`.
- Fixed every download failing at runtime. `Invoke-WebRequest -OutFile` returns nothing without `-PassThru`, so the redirect check dereferenced `$null` and raised a parameter-binding error that the retry loop swallowed. The final URI is now resolved through a helper that handles both the Windows PowerShell 5.1 (`HttpWebResponse.ResponseUri`) and PowerShell 7 (`HttpResponseMessage.RequestMessage.RequestUri`) shapes, and fails closed when it cannot be determined.
- Fixed `-Full` setup exiting `0` after failed steps. The recorded-step helper wrote `$null` to the output stream on failure, so the caller's `return 1` became the last element of an array and `exit` coerced it to `0`. The exit code is now derived from the last emitted value.
- Fixed `RunStats.SkippedTasks` never being populated: it was displayed in the final summary and written to the structured log but nothing ever added to it, so config-disabled steps were counted as Completed.

### Security

- Fixed the publisher allowlist failing open. An installer entry with `requireValidSignature` but no `allowedSignerSubjects` accepted **any** validly-signed binary while appearing to enforce a publisher allowlist: an absent JSON property is `$null`, and `@($null)` is a one-element array, so the "no restriction configured" shortcut was skipped and the resulting `-like "**"` matched every certificate subject. The same shape made the download host check throw instead. Both helpers now normalize their list at the boundary, as does the caller.
- Tightened publisher matching from a substring of the whole distinguished name to a whole `CN` or `O` value, so an allowlist entry of `Dolphin` no longer accepts `CN=Dolphin Emulator, O=Anyone`. An entry containing `=` pins the complete distinguished name. Publisher identity is now decided in one function, `Test-SignerSubjectAllowed`.
- Required an integrity anchor for `EmptyStandbyList.exe`, which is unsigned and is registered as a repeating `SYSTEM` scheduled task. It was fetched from a mutable branch with no hash, no signature requirement and no host allowlist, so the same URL could serve different bytes over time. It now resolves through a configurable `sourceRef`, is constrained to `raw.githubusercontent.com`, and is refused outright unless a local copy exists in `apps\installers\` or `emptyStandbyList.expectedSha256` is pinned.
- Added download host allowlists and optional hash pinning to the PowerShell 7 MSI and the .NET Framework 4.8.1 installer, which previously ran with no integrity check beyond a minimum file size. Both hash keys are empty by default and are enforced only when set, because those URLs intentionally resolve to the current release.
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
