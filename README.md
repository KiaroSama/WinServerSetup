# WinServerSetup

Administrator-only PowerShell automation for preparing a fresh Windows Server, Windows 10, or Windows 11 machine.

WinServerSetup updates Windows, applies system and Explorer settings, installs a configured set of applications and runtimes, configures Remote Desktop safely, registers scheduled tasks, improves usability and security defaults, writes UTF-8 logs, defers reboot until setup is complete, and schedules a post-reboot `sfc /scannow`.

Author: Kiaro Sama  
GitHub: https://github.com/KiaroSama

## Features

- First-run self-relocation to `C:\portable\Scripts\WinServerSetup`.
- Unified color menu-driven and full unattended setup modes. Pressing Enter at `Select: [1]` runs the full setup by default.
- Multi-pass Windows Update with Microsoft Update support and reboot suppression.
- Application download prefetch while Windows Update is running.
- Sequential application installation so only one installer runs at a time.
- Optional SHA256 and required Authenticode validation for direct installer downloads.
- Dark mode, Explorer file extensions, Windows long paths, Persian keyboard layout, and Windows Search Indexing.
- Safe RDP port change to TCP `5801` with firewall verification before registry changes.
- Hidden, highest-privilege scheduled tasks for EmptyStandbyList, RDP brute-force blocking, and post-reboot SFC.
- PowerShell 7 install, Windows Terminal default profile configuration, and `.ps1` open handler setup.
- 7-Zip archive file associations for the current user.
- Quick Access pinning for configured folders and Recycle Bin.
- Startup cleanup and optional removal of configured Windows components.
- Structured UTF-8 logs, per-run launcher diagnostics, and concise, readable colored console output.

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

The main menu shows the default action as `Select: [1]`. Press Enter without typing a value to run option `1`, the full setup workflow.

The launcher treats Windows Terminal as the first-priority console host whenever it is available, then selects PowerShell 7 (`pwsh.exe`) as the shell and falls back to Windows PowerShell 5 only when needed. Runs started outside Windows Terminal are moved into a tab in the most recent Terminal window, including already-elevated ConsoleHost sessions. An already-elevated Windows Terminal session stays in its current tab, and first-run self-relocation keeps the selected PowerShell process in that same Terminal console.

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
2. Enables Windows long paths.
3. Adds the Persian keyboard layout without removing existing layouts.
4. Creates configured portable folders.
5. Starts app download prefetch with the configured safe parallel limit.
6. Runs multi-pass Windows Update while downloads continue in the background.
7. Applies QoS and Windows Update bandwidth policies.
8. Installs configured applications and runtimes sequentially.
9. Configures default browser, media player, 7-Zip associations, PowerShell 7, and Windows Terminal where Windows allows it.
10. Changes the RDP port safely.
11. Enables Windows Search Indexing.
12. Registers scheduled tasks.
13. Disables configured startup entries and removes configured Windows components.
14. Pins configured Quick Access entries and replaces taskbar pins where Windows allows it.
15. Runs health checks and cleanup.
16. Prints the final summary.
17. Schedules post-reboot SFC and restarts only after all setup tasks finish when a reboot is required.

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

Separate Windows Terminal section:

- Windows Terminal is handled by the top-level `windowsTerminal` config section and installed/configured through winget when enabled.

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

Before winget installation, the script removes the `msstore` winget source when configured, refreshes winget sources, and attempts `winget source reset --force` as a fallback for source/certificate corruption.

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
| `CHANGELOG.md` | Versioned release changelog. |
| `LICENSE` | MIT License and attribution notice. |
| `ATTRIBUTION.md` | Attribution summary. |
| `GITHUB_RELEASE_NOTES.md` | Draft release notes for the next GitHub release. |

## Configuration

Most behavior can be enabled, disabled, or adjusted in `WinServerSetup.config.json`.

Important sections:

| Config area | Purpose |
| --- | --- |
| `selfRelocate` | Controls first-run relocation. |
| `parallel` | Controls safe parallel download/background work. |
| `windowsUpdate` | Controls Windows Update behavior and pass count. |
| `activation` | Controls optional Windows activation helper behavior. |
| `filesystem` | Controls Windows long paths enablement. |
| `rdp` | Controls RDP port, old-port blocking, and service restart behavior. |
| `winget.packages` | Controls winget-installed applications. |
| `directInstallers` | Controls direct installer downloads. |
| `runtimes` | Controls .NET and Visual C++ runtime installation. |
| `rdpBruteforceBlocker` | Controls failed-login blocking threshold and schedule. |
| `autoReboot` | Controls final automatic reboot and post-reboot SFC scheduling. |
| `cleanup` | Controls project download cache cleanup, scoped WinServerSetup user-temp cleanup, Windows temp cleanup, and optional recycle bin cleanup. |

## Logs and Output

The script separates concise console output from detailed diagnostics. A run opens with a centered banner over a full-width rule, then reports startup facts as plain `Label: value` lines (`Source`, `Target`, `Copied`, `Relaunch script`, `PowerShell host`, `Version`, `Logging to`, and so on) with labels, paths, values, and success text in distinct colors. Long-running task output keeps its aligned `[INFO]`, `[OK]`, `[WARN]`, and `[ERROR]` severity column so problems stay scannable across a full provisioning run. The machine-readable state names (`COPY`, `RUN`, `SHELL`, `LOG`, `CLEAN`, `NEXT`, `SKIP`, `VERSION`) are still recorded in the structured log.

The banner, startup lines, and menu header render in true-color ANSI on PowerShell 7 in a virtual-terminal console, and fall back to the built-in ConsoleColor palette on Windows PowerShell 5.1 or when output is redirected, which keeps escape sequences out of transcript logs and pipes. All text labels remain intact when `-NoColor` or `NO_COLOR` disables color.

Logs are written under the resolved project `logs` directory:

| Log file | Purpose |
| --- | --- |
| `Run-WinServerSetup_<timestamp>_UTC.log` | Launcher diagnostics, elevation flow, resolved paths, selected PowerShell host, Windows Terminal session detection, selected launcher route, forwarded switches, launch exit code, and launcher failures. |
| `WinServerSetup-<timestamp>.log` | Console transcript. |
| `WinServerSetup-structured-<timestamp>.log` | Structured task, command, output, warning, and summary log. |
| `WinServerSetup-prefetch-<timestamp>.log` | Background app prefetch log. |
| `rdp-blocker.log` | RDP brute-force blocker log. |
| `sfc-result.log` | Post-reboot SFC result log. |

The launcher log is created before elevation, relative to the launcher directory, so double-click and UAC failures still leave a diagnostic file. The launcher keeps the console open after elevation or child-process failures so the error text can be read before closing the window.

The running script version is printed to the console transcript and written in the structured log header.

The default download cache is `%TEMP%\WinServerSetup-downloads`. The project no longer creates `C:\portable\_downloads` unless you explicitly configure a permanent download root.

When `cleanup.cleanUserTemp` is enabled, the script removes only WinServerSetup-owned artifacts from the user temp folder, such as `WinServerSetup-downloads`, relocation logs, partial downloads, and relocation cleanup scripts. It does not wipe the whole `%TEMP%` directory.

Direct installer entries may optionally define `expectedSha256` and `requireValidSignature`. SHA256 mismatches reject the download. Authenticode signatures are logged for executable package types (`.exe`, `.msi`, `.msix`, `.appx`, and bundle variants), and invalid or non-applicable signatures are rejected when `requireValidSignature` is true for that installer.

## Safety Notes

This project performs real system changes. Review `WinServerSetup.config.json` before running it.

- It must run as Administrator.
- It can download and execute installers.
- It can install or upgrade applications.
- It can edit registry keys.
- It can enable Windows long paths through `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled`.
- It can change the RDP port.
- It can add, update, or remove Windows Firewall rules.
- It can create hidden scheduled tasks running as `SYSTEM`.
- It can remove configured Appx packages and Windows capabilities.
- It can clean temporary folders.
- It can restart Windows after the setup workflow completes.
- It includes an optional Windows activation helper. Use it only when you have the legal right to activate the target Windows installation.

The RDP port change is implemented defensively: the firewall rule for the new port is created and verified before the registry port is changed, and the old port is blocked only after the new port is confirmed listening where possible.

If Remote Desktop Services cannot be restarted after the registry update, the script rolls the RDP port value back to the previous port. If the service restarts but the new port is slow to bind, the script waits and leaves the old port open unless the new port is confirmed.

The Persian keyboard layout is appended to the current user's language list. Existing layouts are not removed, but Windows may refresh the input method order when the language list is written.

Default app association XML imports through DISM apply to new user profiles. Current-user defaults are also attempted where the project has safe per-user logic, but Windows may still require manual selection in Settings for protected defaults.

The RDP brute-force blocker scans failed **RemoteInteractive** logons (`LogonType` 10) and blocks sources that meet the configured threshold. The default threshold is `7`, which means more than 6 failed attempts in the lookback window. Block messages include IP address, fail count, logon type(s), and the targeted username(s) exactly as recorded in the event, so a renamed built-in Administrator account is reported under its real name.

**Network Level Authentication changes which events an attack produces, and this matters.** NLA is the default on current Windows and Windows Server. Because NLA authenticates *before* any interactive session exists, a failed RDP sign-in is written to Security event 4625 as `LogonType` **3** (Network), not `LogonType` 10. A blocker that matches only `LogonType` 10 therefore misses the ordinary attack completely.

`LogonType` 3 on its own is ambiguous — SMB and other network logons produce it too — so counting every type 3 failure would cause false positives. The blocker resolves this with RDP-specific evidence: it reads `Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational` events **140** (failed RDP authentication) and **131** (accepted RDP connection), both of which carry the client address. A `LogonType` 3 failure is counted only when that same address is confirmed to have spoken RDP to this host inside the lookback window. Every block records the evidence class (`RemoteInteractive`, `Network+RdpChannel`, or `Network(opt-in)`) so you can see why an address was counted.

If that channel is unavailable or disabled, the blocker logs a warning and falls back to `LogonType` 10 only — meaning NLA-mode attacks will be invisible until you enable the channel or set `rdpBruteforceBlocker.includeNetworkLogonType3`. That opt-in counts **all** network-logon failures regardless of RDP attribution; it is broader and more prone to false positives, so prefer the channel.

Known limitation: RdpCoreTS event 140 is not written when the attempted username actually exists on the host, which is why event 131 (connection attempts) is read as well.

Blocks are scoped to the configured RDP TCP port, not to all inbound traffic from the address, unless `rdpBruteforceBlocker.blockAllInbound` is explicitly enabled. Managed rules expire after `ruleRetentionDays` unless `permanentBlock` is set, so the rule set cannot grow without bound. Only explicit `whitelistCIDRs` entries bypass blocking. The blocker is IPv4-only: IPv6 sources and IPv6 CIDR whitelist entries are rejected by configuration validation rather than silently ignored.

### Security-sensitive defaults

These defaults are deliberately conservative. Each is opt-in because enabling it weakens the machine or trusts a third party:

| Setting | Default | Why |
| --- | --- | --- |
| `activation.enabled`, `activation.productKey`, `activation.kmsServer` | disabled / empty | No third-party KMS server is shipped enabled. Activate only where you hold the legal right; put keys in the git-ignored `WinServerSetup.config.local.json`, never in the tracked config. |
| `runtimes.includeUnsupportedDotNetVersions` | `false` | Out-of-support runtimes receive no security fixes. |
| `customFolders.excludeCompressedFromDefender` | `false` | A Defender exclusion on a user-writable Downloads subfolder is a malware-staging path. |
| `emptyStandbyList.enabled` | `false` | The upstream binary is fetched from a branch, not a pinned release, and would run as `SYSTEM`. |
| `rdpBruteforceBlocker.includeNetworkLogonType3` | `false` | `LogonType` 3 is not RDP-specific and causes false positives. |
| `rdpBruteforceBlocker.blockAllInbound` | `false` | Host-wide blocks are far broader than the threat. |
| `administratorAccount.enabled` | `false` | Renaming the built-in account is an explicit, interactive decision. |
| `accountLockout.disableLocalAccountLockout` | `false` | Machine-wide: it removes lockout for **every** local account, trading login-flood resistance for unlimited password guessing. Only pair it with a strong password plus RDP allowlisting or VPN. |

Direct installers require a valid Authenticode signature from an expected publisher (`requireValidSignature`, `allowedSignerSubjects`) and are constrained to `allowedDownloadHosts`. Downloads reject non-HTTPS URLs and validate the final URI after redirects.

## Troubleshooting

### The script says it must run as Administrator

Run `Run-WinServerSetup.ps1` by right-clicking it and choosing **Run with PowerShell**, or start PowerShell as Administrator and run the script manually.

### The launcher closes after a red error

The launcher now writes `logs\Run-WinServerSetup_<timestamp>_UTC.log` and keeps the console open after elevation or child-process failures. Review the newest launcher log for the resolved script path, selected PowerShell host, Windows Terminal detection, elevation status, forwarded switches, launch exit code, and stack details.

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

Check Task Scheduler for `WinServerSetup Post-Reboot SFC` and review the newest `logs\Run-PostRebootSfc_<timestamp>_UTC.log`. Each execution writes its own timestamped log instead of overwriting a single file, so earlier attempts stay available.

The task unregisters itself **only after a successful run**. If SFC fails, the task stays registered and retries on the next startup, up to its bounded retry count. If it never succeeds, run `sfc /scannow` manually and remove the task once the machine is healthy:

```powershell
Unregister-ScheduledTask -TaskName "WinServerSetup Post-Reboot SFC" -Confirm:$false
```

## Recovery Procedures

### Roll back the RDP port

The port change is verified before the old port is closed, and a failed change is rolled back automatically. To reverse a completed change manually, set the registry value back and restart the service:

```powershell
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name PortNumber -Value 3389 -Type DWord
Restart-Service TermService -Force
Get-NetTCPConnection -LocalPort 3389 -State Listen
```

Confirm the listener belongs to Remote Desktop Services, then allow the restored port in Windows Firewall **and** at every other layer (VPS provider firewall, NAT rule, cloud security group).

### Undo an accidental firewall block

Blocker rules are named `<rulePrefix> <ip>` and tagged `ManagedBy=WinServerSetup` in their description. Inspect and remove a specific block:

```powershell
Get-NetFirewallRule -DisplayName "WinServerSetup RDP Block *" | Select-Object DisplayName, Enabled, Action, Description
Remove-NetFirewallRule -DisplayName "WinServerSetup RDP Block 203.0.113.10"
```

To stop the blocker entirely while you investigate, disable its scheduled task; to clear its rolling counters, delete the state file:

```powershell
Disable-ScheduledTask -TaskName "WinServerSetup RDP Bruteforce Blocker"
Remove-Item .\state\rdp-blocker-state.json -ErrorAction SilentlyContinue
```

### Whitelist your own address before locking yourself out

Add your source network to `rdpBruteforceBlocker.whitelistCIDRs` **before** enabling the blocker on a remote machine. Only these entries bypass blocking; an established RDP session is not trusted on its own.

```jsonc
"whitelistCIDRs": [ "127.0.0.1/32", "203.0.113.0/24" ]
```

Entries must be valid IPv4 addresses or IPv4 CIDR ranges; anything else fails configuration validation at startup.

### Failed self-relocation

The relocated copy must publish a readiness marker containing this run's token and the expected target path before the original directory is ever removed. If the handshake times out or the child fails, **the original is preserved** — nothing is deleted. Verify the copy under `targetProjectRoot`, review the newest launcher and relocation logs, and delete the old directory by hand only after confirming the new location runs. Set `selfRelocate.enabled` to `false` to run in place.

### Restore account-security changes

Both account-security operations write a secret-free recovery record under `backups\` (git-ignored). Passwords are never written to any record, log, or config. Use the paired restore functions to revert the built-in account name or the local lockout policy from the newest record.

## Public Release Hygiene

Do not publish local runtime artifacts. The `.gitignore` excludes logs, comments, command notes, local tool state, downloaded installers, backups, caches, temporary files, secret patterns, and generated output.

Expected public files include the PowerShell scripts, configuration template, README, changelog, license, attribution file, release notes, GitHub workflow, default app XML, scheduled task XML, and installer instructions.

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
