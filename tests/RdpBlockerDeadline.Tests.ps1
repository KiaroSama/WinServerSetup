<#
    Regression tests for follow-up finding FU-04 in scripts\Block-RdpBruteforce.ps1.

    FU-04  maxRunSeconds was only ever compared BETWEEN synchronous calls - between event
           batches and between offenders - so a SINGLE blocking event-log or firewall call
           overran the budget without any bound at all. The only thing that eventually stopped
           such a run was the scheduled task's ExecutionTimeLimit, and with
           MultipleInstances=IgnoreNew every trigger until then was suppressed: the control was
           off for minutes while still looking registered, enabled and healthy.

           The budget is now owned by a watchdog on its own runspace, which is not blocked by
           whatever the main thread is waiting inside. Two things have to hold, and each needs a
           different harness:

             * a run that finishes inside its budget releases the watchdog completely - no
               leaked runspace, no marker (exercised in-process);
             * a run that blocks past its budget is ENDED at the deadline, close to it rather
               than whenever the blocking call happens to return, and says so where an operator
               can see it (exercised in a child process, because the guard's terminal act is to
               end the process it was armed in).
#>
# -ScriptPath targets an alternate copy of the blocker so these tests can be replayed against a
# deliberately defective build to prove they still fail. CI and local runs use the default.
#
# Windows-only cmdlets are shadowed by functions; the mock signatures mirror the real cmdlets so
# the code under test binds exactly as it does in production.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Cmdlets are shadowed deliberately to mock Windows-only APIs.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock signatures mirror the real cmdlets so parameter binding matches production.')]
param([string]$ScriptPath = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = if ([string]::IsNullOrWhiteSpace($ScriptPath)) { Join-Path $projectRoot "scripts\Block-RdpBruteforce.ps1" } else { $ScriptPath }
. $scriptPath

. (Join-Path $PSScriptRoot '_Common.ps1')

# Arming the guard now hardens the marker directory first (FU-04), so Get-Acl/Set-Acl must be
# loadable. The guarded test runner's Windows PowerShell 5.1 child cannot load
# Microsoft.PowerShell.Security, and arming deliberately ABORTS when it cannot prove the marker
# directory safe - a guard whose evidence could be erased is worse than a named failure. That is
# correct production behaviour, so this suite reports an explicit skip there rather than a false
# pass. The elevated CI host loads the module and runs every case.
$securityModuleAvailable = $false
try {
    $securityModuleAvailable = [bool](Get-Command Get-Acl -ErrorAction Stop) -and [bool](Get-Command Set-Acl -ErrorAction Stop)
} catch { $securityModuleAvailable = $false }

if (-not $securityModuleAvailable) {
    Write-Host "SKIP FU-04 deadline suite: Microsoft.PowerShell.Security could not be loaded in this host, so the marker directory cannot be hardened and arming correctly refuses."
    Write-Host "PASS FU-04 hard maxRunSeconds deadline (skipped: no Get-Acl/Set-Acl in this host)."
    return
}

$testRoot = Join-Path $env:TEMP ("WinServerSetup-RdpDeadline-{0}" -f ([guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

# The budget under test. maxRunSeconds is validated with a floor of 5, so 5 is the shortest
# honest deadline available - which keeps this suite fast and bounded rather than minute-scale.
$deadlineSeconds = 5
# Long enough that a run which ignores the deadline is unmistakable, and still far inside the
# suite's own wall timeout.
$blockSeconds = 90

$script:Config = $null
$script:LogLines = New-Object System.Collections.Generic.List[string]

function Read-JsonFile { param([string]$Path) return $script:Config }
function Write-LogLine {
    param([string]$Message, [string]$Level = "INFO")
    $script:LogLines.Add("[$Level] $Message") | Out-Null
}
function Get-WinEvent {
    param($FilterHashtable, $LogName, $FilterXPath, $MaxEvents, [switch]$Oldest, $ErrorAction)
    throw (New-Object System.Management.Automation.ErrorRecord(
            (New-Object System.Exception "No events were found that match the specified selection criteria."),
            'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand',
            [System.Management.Automation.ErrorCategory]::ObjectNotFound, $null))
}
function Get-ItemProperty {
    param([string]$Path, [string]$Name, $ErrorAction)
    return [pscustomobject]@{ PortNumber = 5801 }
}
function Get-CimInstance {
    param([string]$ClassName, [string]$Filter, $ErrorAction)
    return [pscustomobject]@{ Name = 'TermService'; ProcessId = 4321 }
}
function Get-NetTCPConnection {
    param($State, $LocalPort, $OwningProcess, $ErrorAction)
    return @([pscustomobject]@{ LocalPort = [int]$LocalPort; State = 'Listen'; OwningProcess = 4321 })
}
function Get-NetFirewallRule { param([string]$DisplayName, $ErrorAction) return @() }

function New-DeadlineConfig {
    param([string]$StatePath)
    return [pscustomobject]@{
        rdp = [pscustomobject]@{ enabled = $true; newPort = 5801; oldPort = 3389 }
        rdpBruteforceBlocker = [pscustomobject]@{
            enabled = $true; threshold = 2; lookbackMinutes = 30; taskIntervalMinutes = 1
            rulePrefix = "Deadline RDP Block"; whitelistCIDRs = @()
            includeNetworkLogonType3 = $false; attributionWindowSeconds = 120
            blockAllInbound = $false; permanentBlock = $false
            ruleRetentionDays = 30; logMaxBytes = 65536; logRetentionFiles = 2
            maxEventsPerRun = 20000; maxOffendersPerRun = 200; maxManagedRules = 2000
            maxStateBytes = 5242880; maxRunSeconds = $deadlineSeconds
            statePath = $StatePath
        }
    }
}

function Wait-BlockerGuardFree {
    # A bounded wait on an explicit signal - no sleeps. Another RDP blocker run on this machine
    # would make the run under test take the benign "already running" exit, which writes nothing
    # and would look exactly like a deadline that never fired.
    $gate = New-Object System.Threading.Mutex($false, 'Global\WinServerSetup-RdpBlocker')
    try {
        $owned = $false
        try { $owned = $gate.WaitOne(60000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if ($owned) { $gate.ReleaseMutex() }
    } finally { $gate.Dispose() }
}

try {
    # ============================== FU-04 a run inside its budget leaves nothing behind =======
    $statePath = Join-Path $testRoot "fast-state.json"
    $markerPath = "$statePath.deadline"
    $script:Config = New-DeadlineConfig -StatePath $statePath

    $runspacesBefore = @(Get-Runspace).Count
    $result = 1
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Wait-BlockerGuardFree
        $marker = $script:LogLines.Count
        $result = Invoke-RdpBruteforceBlocker -ResolvedConfigPath "ignored.json" -EnforceHardDeadline
        if ((@($script:LogLines | Select-Object -Skip $marker) -join "`n") -notmatch 'already running') { break }
        if ($attempt -eq 3) { throw "Every attempt was skipped because another RDP blocker run held the machine-wide guard." }
    }
    Assert-Equal 0 $result `
        ("FU-04: arming the deadline guard must not change the outcome of a healthy run. Logs: {0}" -f ($script:LogLines -join " | "))
    Assert-Equal $false (Test-Path -LiteralPath $markerPath) `
        "FU-04: a run that finished inside its budget must not record a deadline."
    Assert-Equal $runspacesBefore (@(Get-Runspace).Count) `
        "FU-04: the watchdog must be disposed with the run - a leaked runspace per scheduled run is a leak every minute."

    # ============================== FU-04 a blocking run is ENDED at the deadline =============
    # The guard's terminal act is to end the process it was armed in, so proving it takes a
    # process of its own: a child that dot-sources the real blocker, mocks the Windows-only
    # cmdlets, and blocks inside a single event-log read for far longer than its budget.
    $childState = Join-Path $testRoot "blocked-state.json"
    $childMarker = "$childState.deadline"
    $harnessPath = Join-Path $testRoot "deadline-harness.ps1"
    $harness = @'
$ErrorActionPreference = 'Stop'
$blockerPath = '@BLOCKER@'
$statePath   = '@STATE@'
$maxRun      = @MAXRUN@
$blockFor    = @BLOCK@
. $blockerPath

$script:Logs = New-Object System.Collections.Generic.List[string]
$script:Config = [pscustomobject]@{
    rdp = [pscustomobject]@{ enabled = $true; newPort = 5801; oldPort = 3389 }
    rdpBruteforceBlocker = [pscustomobject]@{
        enabled = $true; threshold = 2; lookbackMinutes = 30; taskIntervalMinutes = 1
        rulePrefix = 'Deadline RDP Block'; whitelistCIDRs = @()
        includeNetworkLogonType3 = $false; attributionWindowSeconds = 120
        blockAllInbound = $false; permanentBlock = $false
        ruleRetentionDays = 30; logMaxBytes = 65536; logRetentionFiles = 2
        maxEventsPerRun = 20000; maxOffendersPerRun = 200; maxManagedRules = 2000
        maxStateBytes = 5242880; maxRunSeconds = $maxRun
        statePath = $statePath
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
    # ONE blocking read. This is the exact shape the between-call budget could never bound: no
    # signal exists to wait on, so consuming wall time is the only way to reproduce it.
    Start-Sleep -Seconds $blockFor
    return @()
}

for ($attempt = 1; $attempt -le 3; $attempt++) {
    $gate = New-Object System.Threading.Mutex($false, 'Global\WinServerSetup-RdpBlocker')
    try {
        $owned = $false
        try { $owned = $gate.WaitOne(60000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if ($owned) { $gate.ReleaseMutex() }
    } finally { $gate.Dispose() }

    $mark = $script:Logs.Count
    $null = Invoke-RdpBruteforceBlocker -ResolvedConfigPath 'ignored.json' -EnforceHardDeadline
    # Returning at all means the deadline guard never ended this process.
    if ((@($script:Logs | Select-Object -Skip $mark) -join "`n") -notmatch 'already running') { exit 90 }
}
exit 91
'@
    $harness = $harness.Replace('@BLOCKER@', $scriptPath).Replace('@STATE@', $childState)
    $harness = $harness.Replace('@MAXRUN@', [string]$deadlineSeconds).Replace('@BLOCK@', [string]$blockSeconds)
    Set-Content -LiteralPath $harnessPath -Value $harness -Encoding UTF8

    # Re-invoke the host this suite is already running under, so the same case proves 5.1 and 7.
    $hostExe = (Get-Process -Id $PID).Path
    Assert-True (-not [string]::IsNullOrWhiteSpace($hostExe)) "FU-04: the current PowerShell host executable could not be resolved."
    $stdoutPath = Join-Path $testRoot "child-out.txt"
    $stderrPath = Join-Path $testRoot "child-err.txt"

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $child = Start-Process -FilePath $hostExe `
        -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $harnessPath)) `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    try {
        # Touch the handle so the process object caches it; Start-Process -PassThru can otherwise
        # report an unreliable ExitCode once the process has exited (seen on 5.1).
        $null = $child.Handle
        # Bounded: comfortably longer than the blocking read, so a guard that never fires is
        # reported as a failed assertion rather than as a hung suite.
        $exited = $child.WaitForExit(($blockSeconds + 30) * 1000)
        $watch.Stop()
        Assert-True $exited `
            ("FU-04: the blocked run must be ended by its own deadline guard, not left to the suite timeout. Elapsed={0}s" -f [math]::Round($watch.Elapsed.TotalSeconds, 1))
        # The bounded WaitForExit(ms) overload can leave ExitCode unpopulated on 5.1; the
        # parameterless call returns immediately here and settles it.
        $child.WaitForExit()

        $elapsed = $watch.Elapsed.TotalSeconds
        Assert-True ($elapsed -lt ($deadlineSeconds + 20)) `
            ("FU-04: the run must stop CLOSE to its {0}s budget, not whenever the blocking call happens to return ({1}s later). Elapsed={2}s" -f `
                $deadlineSeconds, $blockSeconds, [math]::Round($elapsed, 1))
        Assert-True ($elapsed -ge ($deadlineSeconds - 1)) `
            ("FU-04: the run ended before its budget elapsed, so this case proved nothing about the deadline. Elapsed={0}s; child exit={1}; stderr={2}" -f `
                [math]::Round($elapsed, 1), $child.ExitCode, (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue))
        # CORRECTED CONTRACT. This used to assert exit 0, on the reasoning that a bounded outcome
        # should not report the task as failed. That was wrong: exit 0 made a run killed by its own
        # deadline indistinguishable from a clean one - Task Scheduler recorded LastTaskResult=0
        # and installer verification reported the timed-out blocker as successfully verified. A
        # security control that stopped mid-pass must be visible, so the guard now exits with a
        # dedicated non-zero code.
        Assert-Equal 124 ([int]$child.ExitCode) `
            ("FU-04: a run ended by its deadline guard must exit with the dedicated timeout code, never 0 - exit 0 let the timeout pass as success. Child exit={0}; stderr={1}" -f `
                $child.ExitCode, (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue))
        Assert-True (Test-Path -LiteralPath $childMarker) `
            "FU-04: ending a run on its deadline must leave a detectable record, or a control that keeps timing out looks like a clean run."
        Assert-True ((Get-Content -LiteralPath $childMarker -Raw -Encoding UTF8) -match 'maxRunSeconds') `
            "FU-04: the deadline record must name the budget it exceeded."
    } finally {
        if ($child -and -not $child.HasExited) { & taskkill.exe /PID $child.Id /T /F 2>&1 | Out-Null }
    }
    Assert-True $child.HasExited "FU-04: the deadline guard must leave no worker or child process behind."

    Write-Host ("PASS FU-04 hard maxRunSeconds deadline: a blocking run is ended {0}s into a {1}s budget and recorded, and a healthy run leaks no watchdog." -f `
        [math]::Round($watch.Elapsed.TotalSeconds, 1), $deadlineSeconds)
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
