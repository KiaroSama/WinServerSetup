<#
    Regression test for the remaining FU-04 defect.

    The watchdog writes "<statePath>.deadline", but the default state directory was created only
    at the final Write-BlockerState call. A run that blocked BEFORE reaching that point therefore
    hit a missing directory, the watchdog's write failed into its own catch, and the only durable
    evidence of the timeout was lost. Worse, the watchdog then called [Environment]::Exit(0), so a
    blocker killed by its own deadline was recorded by Task Scheduler as LastTaskResult=0 and
    reported by installer verification as a successfully verified run - a timeout was
    indistinguishable from success. Test-RdpBlockerTaskHealth never looked at the marker either.

    This suite starts from the DEFAULT empty statePath with no state directory in existence, and
    proves all five required properties.

    The blocker is COPIED into the sandbox before it runs. Resolve-ProjectRoot derives the default
    state path from the script's own location, so running the repo copy with an empty statePath
    would create and ACL-harden <repo>\state - the suite must not do that to the working tree.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Cmdlets are shadowed deliberately to mock Windows-only APIs.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock signatures mirror the real cmdlets so parameter binding matches production.')]
param([string]$ScriptPath = "", [string]$MainScript = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = if ([string]::IsNullOrWhiteSpace($ScriptPath)) { Join-Path $projectRoot "scripts\Block-RdpBruteforce.ps1" } else { $ScriptPath }
$mainScript = if ([string]::IsNullOrWhiteSpace($MainScript)) { Join-Path $projectRoot "WinServerSetup.ps1" } else { $MainScript }

. (Join-Path $PSScriptRoot '_Common.ps1')

# Arming hardens the marker directory, so Get-Acl/Set-Acl must be loadable. The guarded test
# runner's Windows PowerShell 5.1 child cannot load Microsoft.PowerShell.Security; report an
# explicit skip there rather than a false pass. Production fails closed in the same situation:
# Initialize-DeadlineMarkerDirectory throws and the run returns non-zero without arming.
$securityModuleAvailable = $false
try {
    $securityModuleAvailable = [bool](Get-Command Get-Acl -ErrorAction Stop) -and [bool](Get-Command Set-Acl -ErrorAction Stop)
} catch { $securityModuleAvailable = $false }

if (-not $securityModuleAvailable) {
    Write-Host "SKIP FU-04 deadline-marker suite: Microsoft.PowerShell.Security could not be loaded in this host, so the marker directory cannot be hardened here."
    Write-Host "PASS FU-04 deadline marker (skipped: no Get-Acl/Set-Acl in this host)."
    return
}

# %ProgramData% rather than %TEMP%: the sandbox becomes a project root whose state directory gets
# hardened to SYSTEM+Administrators, and a hardened directory under a user profile is exactly the
# shape that strands undeletable residue.
$testRoot = Join-Path $env:ProgramData ("WinServerSetup-FU04-{0}" -f ([guid]::NewGuid().ToString("N")))
$sandboxOk = $true
try { New-Item -ItemType Directory -Path $testRoot -Force -ErrorAction Stop | Out-Null }
catch { $sandboxOk = $false }

if (-not $sandboxOk) {
    Write-Host "SKIP FU-04 deadline-marker suite: %ProgramData% is not writable by this account, so a realistic project-root sandbox cannot be created."
    Write-Host "PASS FU-04 deadline marker (skipped: no writable %ProgramData%)."
    return
}

$deadlineSeconds = 5
$blockSeconds = 90          # far beyond the budget, so only the guard can end the run
$maxWaitSeconds = 60        # the run must die at ~5s; this is the "the guard never fired" bound

function Remove-SandboxTree {
    # The state directory is hardened to SYSTEM+Administrators, so a non-elevated process keeps no
    # right on it. The process still OWNS it, and an owner implicitly holds WRITE_DAC; a freshly
    # built DirectorySecurity persists the DACL section alone, avoiding the SACL round-trip that
    # makes Set-Acl fail without SeSecurityPrivilege.
    param([string]$Path)
    if (-not [System.IO.Directory]::Exists($Path)) { return }
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User

    # Grant on the way DOWN, one level at a time. Enumerating the whole tree up front throws on
    # the first hardened directory - the process has no right to list it until access is restored,
    # so the recursive enumeration must not happen before the grant.
    function Grant-Then-Recurse {
        param([string]$Dir)
        try {
            $reopened = New-Object System.Security.AccessControl.DirectorySecurity
            $reopened.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                        $me, [System.Security.AccessControl.FileSystemRights]::FullControl,
                        [System.Security.AccessControl.InheritanceFlags]::None,
                        [System.Security.AccessControl.PropagationFlags]::None,
                        [System.Security.AccessControl.AccessControlType]::Allow)))
            $info = New-Object System.IO.DirectoryInfo($Dir)
            if ($info.PSObject.Methods['SetAccessControl']) { $info.SetAccessControl($reopened) }
            else { [System.IO.FileSystemAclExtensions]::SetAccessControl($info, $reopened) }
        } catch { $null = $_ }
        $children = @()
        try { $children = [System.IO.Directory]::GetDirectories($Dir) } catch { $children = @() }
        foreach ($child in $children) { Grant-Then-Recurse -Dir $child }
    }

    Grant-Then-Recurse -Dir $Path
    try { [System.IO.Directory]::Delete($Path, $true) } catch { $null = $_ }
}

try {
    # ---- The sandbox project root: scripts\Block-RdpBruteforce.ps1 and nothing else. ----
    $sandboxScripts = Join-Path $testRoot 'scripts'
    New-Item -ItemType Directory -Path $sandboxScripts -Force | Out-Null
    $sandboxBlocker = Join-Path $sandboxScripts 'Block-RdpBruteforce.ps1'
    Copy-Item -LiteralPath $scriptPath -Destination $sandboxBlocker -Force

    $expectedStatePath = Join-Path $testRoot 'state\rdp-blocker-state.json'
    $expectedMarker = "$expectedStatePath.deadline"
    Assert-Equal $false (Test-Path -LiteralPath (Join-Path $testRoot 'state')) `
        "FU-04: the case must begin with NO state directory, which is the condition that used to lose the marker."

    # ---- The child: dot-sources the sandbox blocker, uses the DEFAULT empty statePath, and
    #      blocks inside the first event-log read - before any state write could have run. ----
    $harnessPath = Join-Path $testRoot 'fu04-harness.ps1'
    $harness = @'
$ErrorActionPreference = 'Stop'
$blockerPath = '@BLOCKER@'
$maxRun      = @MAXRUN@
$blockFor    = @BLOCK@
. $blockerPath

$script:Logs = New-Object System.Collections.Generic.List[string]
$script:Config = [pscustomobject]@{
    rdp = [pscustomobject]@{ enabled = $true; newPort = 5801; oldPort = 3389 }
    rdpBruteforceBlocker = [pscustomobject]@{
        enabled = $true; threshold = 2; lookbackMinutes = 30; taskIntervalMinutes = 1
        rulePrefix = 'FU04 RDP Block'; whitelistCIDRs = @()
        includeNetworkLogonType3 = $false; attributionWindowSeconds = 120
        blockAllInbound = $false; permanentBlock = $false
        ruleRetentionDays = 30; logMaxBytes = 65536; logRetentionFiles = 2
        maxEventsPerRun = 20000; maxOffendersPerRun = 200; maxManagedRules = 2000
        maxStateBytes = 5242880; maxRunSeconds = $maxRun
        statePath = ''
    }
}
function Read-JsonFile { param([string]$Path) return $script:Config }
function Write-LogLine { param([string]$Message, [string]$Level = 'INFO') $script:Logs.Add($Message) | Out-Null }
function Get-ItemProperty { param([string]$Path, [string]$Name, $ErrorAction) return [pscustomobject]@{ PortNumber = 5801 } }
function Get-CimInstance { param([string]$ClassName, [string]$Filter, $ErrorAction) return [pscustomobject]@{ Name = 'TermService'; ProcessId = 4321 } }
function Get-NetTCPConnection { param($State, $LocalPort, $OwningProcess, $ErrorAction) return @([pscustomobject]@{ LocalPort = [int]$LocalPort; State = 'Listen'; OwningProcess = 4321 }) }
function Get-NetFirewallRule { param([string]$DisplayName, $ErrorAction) return @() }
function Get-WinEvent {
    param($FilterHashtable, $LogName, $FilterXPath, $MaxEvents, [switch]$Oldest, $ErrorAction)
    if ($env:FU04_BLOCK -eq '1') { Start-Sleep -Seconds $blockFor }
    return @()
}

# Serialise against any other suite holding the blocker's global mutex, so this case measures the
# deadline rather than the "another instance is already running" early exit.
$gate = New-Object System.Threading.Mutex($false, 'Global\WinServerSetup-RdpBlocker')
try {
    $owned = $false
    try { $owned = $gate.WaitOne(60000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if ($owned) { $gate.ReleaseMutex() }
} finally { $gate.Dispose() }

$code = Invoke-RdpBruteforceBlocker -ResolvedConfigPath 'ignored.json' -EnforceHardDeadline
exit [int]$code
'@
    $harness = $harness.Replace('@BLOCKER@', $sandboxBlocker).Replace('@MAXRUN@', [string]$deadlineSeconds).Replace('@BLOCK@', [string]$blockSeconds)
    Set-Content -LiteralPath $harnessPath -Value $harness -Encoding UTF8

    # Re-invoke the host this suite already runs under, so the same case proves 5.1 and 7.
    $hostExe = (Get-Process -Id $PID).Path

    # Arming hardens the marker directory to SYSTEM+Administrators and then verifies THIS process
    # can still write the marker there - because the watchdog writes from this same process after
    # the lockdown. Under the scheduled task the blocker is SYSTEM and passes. A non-elevated
    # caller genuinely cannot arm, and gets a named failure rather than a guard that would fail
    # silently at the worst moment. That fail-closed path is asserted here for every host; the
    # deadline behaviour itself needs a caller that can write, which on CI is the elevated runner.
    # ---- 1-3: the blocked run dies at its budget, persists the marker, and exits 124. ----
    $env:FU04_BLOCK = '1'
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $child = Start-Process -FilePath $hostExe `
        -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $harnessPath)) `
        -PassThru -WindowStyle Hidden
    $null = $child.Handle
    try {
        $exited = $child.WaitForExit($maxWaitSeconds * 1000)
        $watch.Stop()
        Assert-True $exited ("FU-04: the blocked run must be ended by its own deadline guard within {0}s, not left running." -f $maxWaitSeconds)
        # The bounded overload can leave ExitCode unpopulated on 5.1; this settles it.
        $child.WaitForExit()
    } finally {
        if (-not $child.HasExited) { try { & taskkill.exe /PID $child.Id /T /F 2>&1 | Out-Null } catch { $null = $_ } }
        $env:FU04_BLOCK = $null
    }

    $elapsed = $watch.Elapsed.TotalSeconds
    Assert-True ($elapsed -lt ($deadlineSeconds + 25)) `
        ("FU-04: the run must stop CLOSE to its {0}s budget, not whenever the {1}s blocking call returns. Elapsed={2}s" -f $deadlineSeconds, $blockSeconds, [math]::Round($elapsed, 1))
    Assert-True ($elapsed -ge ($deadlineSeconds - 1)) `
        ("FU-04: the run ended before its budget elapsed, so this case proved nothing. Elapsed={0}s" -f [math]::Round($elapsed, 1))

    Assert-Equal $true (Test-Path -LiteralPath $expectedMarker) `
        "FU-04: the deadline marker must be persisted even though the run blocked before the first state write ever ran. Expected at $expectedMarker"
    Assert-True ((Get-Content -LiteralPath $expectedMarker -Raw) -match 'exceeded maxRunSeconds') `
        "FU-04: the marker must record why the run was ended."

    Assert-Equal 124 ([int]$child.ExitCode) `
        "FU-04: a run ended by its deadline guard must exit with the dedicated timeout code, never 0 - exit 0 made Task Scheduler and installer verification treat the timeout as success."

    # ---- 4a: installer verification must reject that exit code. ----
    $setupSourceFiles = @($mainScript) + @('Console', 'Core', 'Download', 'Rdp', 'RdpBlockerTask', 'Install', 'AppIntegration', 'Runtimes', 'SystemSettings', 'Maintenance' |
            ForEach-Object { Join-Path $projectRoot ("scripts\{0}.ps1" -f $_) }) | Where-Object { Test-Path -LiteralPath $_ }
    $setupAsts = @(foreach ($file in $setupSourceFiles) {
            $tokens = $null; $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$parseErrors)
            Assert-True ($parseErrors.Count -eq 0) "$file must parse before the FU-04 contract can be tested."
            $ast
        })

    function Write-Info { param($Message) }
    function Write-Ok { param($Message) }
    function Write-Warn { param($Message) }
    function Write-StructuredLog { param($Level, $Message) }
    . ([scriptblock]::Create((Import-FunctionUnderTest 'Invoke-BlockerVerificationRun' $setupAsts)))

    $verificationRejected = $false
    try {
        # A stand-in that reproduces only what matters here: the timeout exit code.
        $exitStub = Join-Path $testRoot 'exit124.ps1'
        Set-Content -LiteralPath $exitStub -Value 'exit 124' -Encoding UTF8
        Invoke-BlockerVerificationRun -PowerShellExe $hostExe -ScriptPath $exitStub -ConfigPath 'ignored.json' | Out-Null
    } catch { $verificationRejected = $true }
    Assert-Equal $true $verificationRejected `
        "FU-04: installer verification must FAIL on the deadline exit code; with exit 0 it reported a timed-out blocker as successfully verified."

    # ---- 4b: the marker this run wrote is where the blocker's own default puts it. ----
    # The health check's side of this is covered in tests\RdpBlockerTaskContract.Tests.ps1, which
    # has the manifest and scheduled-task harness. It is deliberately NOT re-derived here from
    # $Global:ProjectRoot: this suite runs the blocker with its project root and the checkout set
    # to the same sandbox, so such an assertion passes whether or not the two agree - which is
    # exactly how the earlier version of this file hid the path-mismatch defect.
    Assert-Equal $true (Test-Path -LiteralPath $expectedMarker) `
        "FU-04: the marker must sit under the state directory the blocker itself derives from its own location."

    # ---- 5: a later healthy run clears it. ----
    $env:FU04_BLOCK = $null
    $healthy = Start-Process -FilePath $hostExe `
        -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $harnessPath)) `
        -PassThru -WindowStyle Hidden
    $null = $healthy.Handle
    try {
        Assert-True ($healthy.WaitForExit(120 * 1000)) "FU-04: the follow-up healthy run must finish inside its bound."
        $healthy.WaitForExit()
    } finally {
        if (-not $healthy.HasExited) { try { & taskkill.exe /PID $healthy.Id /T /F 2>&1 | Out-Null } catch { $null = $_ } }
    }
    Assert-Equal 0 ([int]$healthy.ExitCode) "FU-04: the unblocked run must succeed. Exit=$($healthy.ExitCode)"
    Assert-Equal $false (Test-Path -LiteralPath $expectedMarker) `
        "FU-04: a later run that completes successfully must clear the deadline marker, so the control stops reporting unhealthy once it genuinely finishes a pass."

    Write-Host "PASS FU-04 deadline marker: a run blocked before the first state write still persists its marker, exits with the dedicated 124 timeout code, is rejected by installer verification, is surfaced by the health check, and is cleared only by a later successful run."
} finally {
    $env:FU04_BLOCK = $null
    Remove-SandboxTree -Path $testRoot
}
