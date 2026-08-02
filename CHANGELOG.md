# Changelog

## [Unreleased]

### Changed

- **Two oversized modules split by responsibility, proven a pure move.** `scripts\Install.ps1` had grown to ~1450 lines spanning application installation, shell/default-handler integration and runtime installation; `scripts\Rdp.ps1` to ~1120 spanning port migration and the SYSTEM scheduled-task trust machinery. They are now:

  | Module | Responsibility |
  |---|---|
  | `scripts\Install.ps1` | The shared check-then-update decision, winget packages, direct installers, v2rayN |
  | `scripts\AppIntegration.ps1` | Apps that are installed *and* wired into the shell: PowerShell 7, Windows Terminal, Brave, 7-Zip, default apps |
  | `scripts\Runtimes.ps1` | .NET Framework, .NET desktop/core and Visual C++ runtimes |
  | `scripts\Rdp.ps1` | Listener checks, the port prompt, and the port migration with its firewall rule and rollback |
  | `scripts\RdpBlockerTask.ps1` | Installing and health-checking the blocker SYSTEM task: trust validation, staging, manifest, health contract |

  `Test-DirectInstallerInstalled` moved from `Rdp.ps1` to `Install.ps1`, where it had always belonged — it verifies a direct installer and has nothing to do with RDP. The structured-log assertions likewise moved out of `tests\MenuAndLauncher.Tests.ps1` into `tests\StructuredLogging.Tests.ps1`; splitting them surfaced that three of them hardcoded the old suite's filename while asserting on call-stack-derived component attribution, so they were silently pinned to their own location — they now derive it from `$PSCommandPath`.

  Verified as a pure move the same way the original module split was: every `FunctionDefinitionAst` body across all non-test `.ps1`, normalised and compared as a multiset — 1044 definitions before and after, with exactly one deliberate difference (`Invoke-SetupStepWaveConcurrently`, whose module list had to learn the new files).

  `scripts\Block-RdpBruteforce.ps1` (1211 lines) is deliberately **not** split: it is a standalone script the scheduled task runs as its own process, with top-level statements and intentionally private helper copies. `scripts\Core.ps1` (851) is left alone too — a 6% overage whose tail mixes relocation, download helpers and the project-wide `ConvertTo-CanonicalPath`, with no clean boundary to cut on.

### Added

- **Applications that are already installed are now updated where they are, instead of installed again.** Setup checks for an existing installation first — winget's own package list for winget packages, and the registry uninstall roots for direct installers — and resolves the directory it is actually installed in from `InstallLocation`, `DisplayIcon` or `UninstallString`. An already-present application is upgraded in that directory rather than dropped into the project's default path as a second copy. When the location cannot be resolved from real evidence the existing installation is left alone and the reason is logged: an "update in place" aimed at the wrong tree is worse than not updating at all. A direct installer that reports success but relocated the application is treated as a failure, because that is a duplicate rather than an update.

  Every installer now reports a distinct outcome — installed, updated in place, already current, skipped with a reason, or failed — instead of only installed-or-failed.

- **The Remote Desktop port is now chosen by the operator, and the migration cannot lock you out.** Setup asks which TCP port RDP should listen on before it touches anything — `rdp.newPort` is the offered default, not the decision — and re-prompts on a value that is not a port or is already held by another listener. Because the question comes first, abandoning it leaves the machine exactly as it was found.

  The migration order is the part that matters: the **new** port is opened in the firewall *before* the registry is changed, then the registry is backed up and written, then TermService is restarted, then setup verifies TermService actually owns the new port — and only after that is the **old** port blocked. That last step sits outside the try/catch, so it is unreachable unless verification passed; there is never a window in which the new port is bound but firewalled off. Any failure in the registry/restart/verify window rolls back the registry, the firewall rule and the service, leaving the previous port bound and reachable.

- **A per-run diagnostic log file.** `WinServerSetup_<yyyy-MM-dd_HH-mm-ss>_UTC.log`, created with an atomic `CreateNew` so a previous run's log can never be truncated — not by a same-second restart and not by a second process racing it. Entries are `[timestamp UTC] [LEVEL] [COMPONENT] message`, with the component derived from the call stack so existing call sites gained attribution without being edited. Console output stays concise; the file stays diagnostic. If logging cannot be initialised the run continues on console output alone and says so, rather than silently claiming a log file exists.

  Secret redaction is applied at every sink — console, the in-place status line, and the file log — covering product keys, URL credentials, token-bearing query parameters, `key=value` secrets, secret-shaped command-line parameters, and `Authorization` headers.

- **Safe setup steps now run concurrently.** `Invoke-ParallelSetupSteps` runs the independent configuration steps in bounded waves instead of strictly one after another. Each step declares the resources it touches and two claimants of the same resource never share a wave — dark mode *restarts* Explorer and the file-extension change is only picked up *by* that restart, so running them together could land the write after the restart and silently not apply. The worker count comes from the existing `parallel.maxParallel`; a budget of one executes inline with no runspace at all, and any failure setting up the parallel path degrades to inline execution, so this can never turn a working sequential run into a broken parallel one.

  Installs are deliberately **not** parallelised. Windows Installer serialises every MSI behind a machine-global `_MSIExecute` mutex and returns 1618 to the loser rather than queueing it, so concurrent installs would save no wall time and would start reporting failures that are not failures. The download half was already parallel.

### Fixed

- **Setup no longer copies itself again when it is already installed at the configured target.** The "am I already in the right place?" check compared `Resolve-Path`'s output against the raw configured path. `Resolve-Path` preserves whatever spelling it is handed — an 8.3 short name stays short — and the configured value was normalised by nothing at all, so the decision was made on string *spelling* rather than on identity. A short-name project root, a forward-slash or dot-segment configured path, or a stray trailing space each missed the match and relocated the installation onto itself. Both sides now go through the project's single canonicaliser.

### Changed

- **The Administrator rename asks for the new name, and always renames the existing account.** `administratorAccount.defaultNewName` is now only the *default offered at the prompt* rather than a value applied silently — previously the configured name was passed straight through, so the prompt never ran. The account to rename is identified by the full built-in-Administrator SID shape (`S-1-5-21-…-500`) instead of a bare `-500` suffix, which also matched unrelated service principals. Non-interactive runs with a configured name now apply it and log that they did so, where they previously skipped the rename entirely.

- **Config keys can now be retired instead of deleted.** A key nothing reads any more could not simply be removed from the schema: unknown properties are rejected outright, so an operator whose `WinServerSetup.config.local.json` still carried it would have their entire run fail on upgrade. A key marked `retired` is accepted, dropped, and reported by name so it eventually gets cleaned up — and it is dropped rather than merely tolerated, because the merge step rejects an override property with no counterpart in the tracked config. Retiring one key does not make its siblings permissive. `rdp.oldPort`, `windowsUpdate.autoReboot` and `windowsTerminal.openSettingsAfterInstall` are the first three: all three were declared and never read. (`defaultApps.openSettingsAfterInstall` is a different key and is still live.)

### Fixed

- **A hung installer or prefetch child no longer blocks setup forever.** `Wait-ProcessWithStatus` — the single wait every download and installer routes through — looped on `HasExited` with no deadline. It now takes a `-TimeoutSeconds` ceiling (default one hour; a slow installer on a slow link is slow, not hung) and on expiry terminates the whole process tree with `taskkill /T /F` and logs it. Both callers already treat a non-zero exit code as failure, so the existing handling applies unchanged. The deadline lives in the shared helper rather than at each call site, where one omission would silently restore an unbounded wait.
- **Relocation no longer deletes the original directory while the original process is still running.** The deferred cleanup script waited with `Wait-Process -Id … -Timeout 60` under `$ErrorActionPreference = 'SilentlyContinue'`. `Wait-Process -Timeout` raises a *non-terminating* error on expiry, so it was swallowed and the intended `catch` fallback never ran. Liveness is now observed after the wait, and a parent that is still running is one of the conditions that refuses the deletion outright.
- **An unsafe relocation source/target pair is refused before the copy, not after it.** The existing guard against a nested pair, an identical pair or a drive root lived only in the cleanup script — which does not exist until `robocopy /E` has already run. A target nested inside the source was therefore copied into itself and merely refused afterwards, leaving a duplicated, recursed tree with no way to undo it. The same verdict now gates the copy itself.

### Changed

- The Windows Update install poll is its own function, `Wait-WindowsUpdateJob`, taking its budget as a parameter. Behaviour is unchanged — `windowsUpdate.jobTimeoutMinutes` is still validated as whole minutes with a 1-minute floor applied at the call site — but the timeout branch is now exercised by a real test instead of a source-text assertion. It previously cost 60 seconds of real `Stopwatch` time to reach, which was this project's last documented coverage gap.

### Security

- **`FU-04` follow-up — the health check and the staged task now watch the same deadline marker.** With the default empty `statePath`, the staged blocker runs from `%ProgramData%\WinServerSetup\tasks` and derives its state directory from where it *itself* lives, so it wrote its marker under `%ProgramData%\WinServerSetup\state`. `Get-BlockerDeadlineMarkerPath` instead recomputed that default from `$Global:ProjectRoot`, the checkout path — so the health check watched a file nobody writes and could report healthy while a real deadline marker still stood.

  The effective state path is now resolved to an absolute canonical path **at registration, after staging**, written into the staged config and recorded in the trust manifest. The health check reads the manifest rather than recomputing anything, rejects a recorded path that is not rooted or not canonical, and fails the contract when it does not sit under the staged task tree — so the marker location is a recorded part of the registration contract instead of two derivations that could drift.

  The earlier regression test could not catch this: it ran the blocker with its project root and the checkout set to the same sandbox, so an assertion comparing the two passed whether or not they agreed. The new case in `tests/RdpBlockerTaskContract.Tests.ps1` uses deliberately different checkout and staging roots with an empty source `statePath`.

- **`FU-04` follow-up — a deadline kill is no longer indistinguishable from success.** The blocker's watchdog wrote `<statePath>.deadline`, but the default state directory was created only at the final `Write-BlockerState` call, so a run that blocked *before* reaching that point hit a missing directory and its write failed silently — losing the only durable evidence of the timeout. The watchdog then exited **0**, so a blocker killed by its own deadline was recorded by Task Scheduler as `LastTaskResult=0` and reported by installer verification as a successfully verified run.

  The marker directory is now created and ACL-hardened *before* the guard is armed, with a reparse point anywhere in the chain rejected, the DACL re-read rather than assumed, and the marker proven writable while a failure can still be reported; anything unprovable fails the run closed. The guard exits **124** — installer verification already rejects a non-zero result, so a timeout can no longer pass as success. `Test-RdpBlockerTaskHealth` reports an existing marker, because Task Scheduler cannot describe an outcome where the process ended itself from inside. The marker is cleared **only** by a later run that completes successfully — not at arm time, and not after a run that stopped early on a cap.

  The hardening grants the account running the blocker alongside SYSTEM and Administrators. Under the scheduled task that account *is* SYSTEM; for any other caller it is the identity that owns the run, and no **other** unprivileged principal gains anything — which is the property that matters, since the risk is someone else deleting the marker to hide a timeout.

Closed a five-item follow-up (`FU-01`–`FU-05`) against the merged audit work. Each has a regression test naming its ID, shown failing against the defective behaviour first and mutation-proven on both Windows PowerShell 5.1 and PowerShell 7.

- **`FU-01` — SYSTEM task path-ownership gap (High).** `Test-TrustedTaskTargetPath` validated the DACL but never the **owner**. An owner holds `READ_CONTROL` and `WRITE_DAC` implicitly whatever the DACL says, so a user-owned file or directory with an otherwise perfect DACL could have that DACL rewritten and its content replaced before SYSTEM next executed it. Task scripts and their effective config are now copied into a dedicated `%ProgramData%\WinServerSetup\tasks` directory this project creates, owns and hardens; every task target and every replace-capable parent component must carry a trusted owner SID (SYSTEM, Administrators or TrustedInstaller); and hardening takes ownership for Administrators, **aborting registration** if that fails or does not stick. The parent-chain test deliberately checks replace capability (`Delete`, `DeleteSubdirectoriesAndFiles`, `ChangePermissions`, `TakeOwnership`, `FullControl`) rather than plain write and ignores `InheritOnly` ACEs — `%ProgramData%` grants `BUILTIN\Users` plain `Write`, which for a directory is create-only, so a plain-write rule would reject every ProgramData-based location.
- **`FU-02` — the blocker now uses the verified live RDP port.** It built firewall rules from `config.rdp.newPort`; with `rdp.enabled=false` that disagrees with the port actually in use, so every rule targeted a port nothing listened on. Each run now resolves the RDP-Tcp registry `PortNumber`, confirms `TermService` owns that listener, and passes only the verified port, failing closed on disagreement.
- **`FU-03` — a capped event-log backlog is no longer silently skipped.** `Get-WinEvent -MaxEvents` returns newest records first, and the caller bookmarked the highest RecordId it saw, so during a backlog larger than the cap every record between the previous bookmark and the oldest returned one was passed over permanently. Incremental reads are oldest-first and only the highest **contiguous** RecordId actually processed is persisted.
- **`FU-04` — `maxRunSeconds` is a hard deadline.** It was consulted only between synchronous calls, so a single blocking event-log or firewall call could overrun it without bound. Blocking work now runs behind a cancellable watchdog that ends it at the deadline, leaves a detectable deadline state and leaks no worker.
- **`FU-05` — existing firewall rules are reconciled at a full cap.** `maxManagedRules` was tested before `Ensure-ManagedBlockRule` and broke out of the offender loop, so once the rule count reached the cap no existing owned rule was validated or repaired again and a `blockAllInbound` flip left every rule pinned to its old shape permanently. The cap now governs only whether a **new** address may get a rule.

### Changed

- Scheduled task scripts and their effective config are staged into `%ProgramData%\WinServerSetup\tasks` and registered from there, rather than being executed out of the project directory. Health checks validate the staged copy — path, ACL, owner and hash — not the original.
- `tests/InstallerCacheTrust.Tests.ps1` no longer strands an unreachable sandbox in `%TEMP%` on every run. Its hardening case leaves a non-elevated process no right to enumerate the directory, which aborted the whole cleanup; the process still owns it, and a freshly built `DirectorySecurity` persists the DACL section alone without needing `SeSecurityPrivilege`.

Closed all 18 findings of the security audit against baseline `771eee0` (`H-01`–`H-04`, `M-01`–`M-10`, `L-01`–`L-04`). Each has a regression test naming its finding ID, shown failing against the defective behaviour before the fix and mutation-proven on both Windows PowerShell 5.1 and PowerShell 7.

Two were reproduced as live defects on a real machine, not inferred from reading the code:

- **`H-01` — elevated installer cache poisoning.** The download cache defaulted to `%TEMP%\WinServerSetup-downloads`, whose ACL granted Modify/FullControl to non-administrative identities, and a cache hit required only `Length >= MinimumBytes` whenever the spec carried no `expectedSha256` and did not set `requireValidSignature` (the default). An unprivileged user could plant an unsigned executable under an expected file name and the elevated run would launch it. The cache now lives under `%ProgramData%`, hardened to SYSTEM+Administrators with inheritance disabled; one validation contract covers cache hits and fresh downloads alike; an executable requires a pinned SHA256 or an allowlisted valid Authenticode signature; reparse points are refused fail-closed anywhere in the path; and the artifact is revalidated with an identity snapshot immediately before execution, so a swap between verification and launch is detected and quarantined.
- **`M-02` — substring IP matching blocked innocent addresses.** `Get-RdpAttributedAddresses` returned a `HashSet` bare. PowerShell enumerates a HashSet on output, so a set holding exactly one address collapsed to `[string]` and the caller's `.Contains($ip)` silently became a substring test: with `120.3.4.5` on record, `20.3.4.5` matched and was firewall-blocked. The evidence map is now an `IDictionary`, which PowerShell passes through intact, and lookups are exact.

The rest: `H-02` owner/DACL and reparse validation for everything a SYSTEM scheduled task executes or reads, with a trusted target hash and normalized action contract recorded in an ACL-hardened manifest; `H-03` cleanup restricted to a sentinel-marked dedicated cache plus two exact system temp paths, replacing a denylist that only matched protected roots exactly; `H-04` bounded events, offenders, managed rules, state size and run time, with a reached ceiling logged and surfaced rather than crashing or being dropped, and whitelisted addresses never evicted by a cap; `M-01` the blocker bound to the real registry port with a verified `TermService` listener; `M-03` `blockAllInbound` reconciled in both directions; `M-04` an explicit `ExecutionTimeLimit` with a health check that fails an over-long active run; `M-05` LogonType 3 attribution bounded by a validated time window instead of mere presence in the lookback; `M-06` an exact configuration schema that never coerces `"false"`, `"0"`, `0` or `1` into a Boolean; `M-07` one bounded `gpupdate` runner with process-tree termination; `M-08` independent verification for every requested runtime, with failures reaching the exit code; `M-09` three explicit RDP branches so a rerun against a correct state no longer requests a reboot; `M-10` full managed firewall rollback after a failed port migration; `L-01` removal of the ignored `hidden` key; `L-02` exact task-contract verification in health checks; `L-03` quarantine-and-rebuild for corrupt blocker state; `L-04` elevation binaries resolved from trusted fixed locations before PATH, each gated on non-reparse, trusted owner, no non-administrative writer and a valid signature.

### Changed

- **Installing the RDP blocker or the post-reboot SFC task now ACL-hardens the project root** to SYSTEM+Administrators with `BUILTIN\Users` read-only and inheritance disabled. Both tasks run as `SYSTEM`, so anything able to rewrite the script they execute has a direct path to SYSTEM, and a directory freshly created under `C:\` inherits `Authenticated Users: Modify`. **Consequence:** a non-elevated launcher run can still read and start the tool but can no longer write its diagnostic log under `<project root>\logs\`; it degrades quietly. There is deliberately no `Users: Modify` carve-out for `logs\`, which would reopen the hole the hardening closes.
- The download cache moved from `%TEMP%` to `%ProgramData%\WinServerSetup\cache`, and carries a sentinel that cleanup requires before deleting anything.
- `%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe` is no longer accepted as an elevation candidate; on a normal workstation it is a zero-byte reparse point the interactive user owns with FullControl.
- A requested runtime that fails to install now fails the run. Warning-only outcomes are gone for components that are not explicitly optional.
- Removed `rdpBruteforceBlocker.hidden`: no code read it, and the task is hard-coded hidden.
- README now states the blocker's security boundary explicitly — it is RDP brute-force mitigation, **not** DDoS protection — along with its IPv4-only scope and its weakness against genuinely distributed sources that each stay under the threshold.

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
