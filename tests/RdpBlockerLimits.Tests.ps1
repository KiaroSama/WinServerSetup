<#
    Regression tests for audit finding H-04 in scripts\Block-RdpBruteforce.ps1: the blocker ran
    with no bound on anything it consumed.

      * rdpBruteforceBlocker.maxEventsPerRun / maxOffendersPerRun / maxManagedRules /
        maxStateBytes / maxRunSeconds were present in the tracked config and read by nothing.
      * Both Security queries and the RdpCoreTS query ran without -MaxEvents, so one flood
        pulled the entire window into memory.
      * Every parsed 4625 was persisted verbatim in the JSON state, so the state file grew with
        the attack instead of with the host.
      * There was no cap on offenders handled per run, no cap on managed firewall rules, and no
        wall-clock budget, so a run could still be working when the next minute's run started.

    A cap that is hit must be loud (WARNING) and detectable (flags in the written state), never
    a crash and never a silent discard. Whitelisted addresses are outside every cap: they are
    never tracked, so no cap can evict one and no cap can cause one to be blocked.
#>
# -ScriptPath targets an alternate copy of the blocker so these tests can be replayed against a
# deliberately defective build to prove they still fail. CI and local runs use the default.
#
# Windows-only cmdlets are shadowed by functions. The mock signatures mirror the real cmdlets -
# including parameters this file never reads - so the code under test binds exactly as it does
# in production, and Get-WinEvent honours -MaxEvents exactly as the real cmdlet does.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Cmdlets are shadowed deliberately to mock Windows-only APIs.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock signatures mirror the real cmdlets so parameter binding matches production.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', '', Justification = 'Mock parameter names must match the real cmdlet parameter names.')]
param([string]$ScriptPath = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = if ([string]::IsNullOrWhiteSpace($ScriptPath)) { Join-Path $projectRoot "scripts\Block-RdpBruteforce.ps1" } else { $ScriptPath }
. $scriptPath

. (Join-Path $PSScriptRoot '_Common.ps1')

# A .NET-shaped fixture rather than a pscustomobject + Add-Member: the stress cases build
# 100,000 of these, and Add-Member per object dominates the run time at that size.
class SyntheticFailedLogon {
    [long]$RecordId
    [datetime]$TimeCreated
    [string]$Ip
    [string] ToXml() {
        return ('<Event><System><EventRecordID>{0}</EventRecordID></System><EventData>' +
            '<Data Name="IpAddress">{1}</Data><Data Name="LogonType">10</Data>' +
            '<Data Name="TargetUserName">victim</Data></EventData></Event>') -f $this.RecordId, $this.Ip
    }
}

$testRoot = Join-Path $env:TEMP ("WinServerSetup-RdpLimits-{0}" -f ([guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$statePath = Join-Path $testRoot "state.json"

$script:Config = $null
$script:Events = @()
$script:SecurityQueryMaxEvents = New-Object System.Collections.Generic.List[object]
$script:RdpQueryMaxEvents = New-Object System.Collections.Generic.List[object]
$script:RdpChannelDelaySeconds = 0
$script:FirewallRules = New-Object System.Collections.Generic.List[object]
$script:NewRuleCalls = New-Object System.Collections.Generic.List[object]
$script:LogLines = New-Object System.Collections.Generic.List[string]

function Read-JsonFile { param([string]$Path) return $script:Config }
function Write-LogLine {
    param([string]$Message, [string]$Level = "INFO")
    $script:LogLines.Add("[$Level] $Message") | Out-Null
}

function New-SyntheticEvents {
    # Returns a real array, never the backing List. `@($aListOfObject)` throws
    # "Argument types do not match" on BOTH hosts - only .ToArray() or a pipeline is safe.
    param([int]$Count, [datetime]$TimeCreated = (Get-Date))
    $list = New-Object 'System.Collections.Generic.List[object]'
    for ($index = 1; $index -le $Count; $index++) {
        $item = [SyntheticFailedLogon]::new()
        $item.RecordId = [long]$index
        $item.TimeCreated = $TimeCreated
        # Unique for every index below 2^24, which covers the 100,000-address case.
        $item.Ip = "10.{0}.{1}.{2}" -f (($index -shr 16) -band 255), (($index -shr 8) -band 255), ($index -band 255)
        $list.Add($item)
    }
    return , $list.ToArray()
}

function Get-WinEvent {
    param($FilterHashtable, $LogName, $FilterXPath, $MaxEvents, $ErrorAction)
    $channel = if ($FilterHashtable) { [string]$FilterHashtable.LogName } else { [string]$LogName }
    if ($channel -like '*RdpCoreTS*') {
        $script:RdpQueryMaxEvents.Add($MaxEvents) | Out-Null
        if ($script:RdpChannelDelaySeconds -gt 0) {
            # Deliberate bounded wait. The behaviour under test IS the wall-clock budget, so the
            # only way to exercise it is to consume wall time; there is no signal to wait on.
            # Used once, in the deadline case only.
            Start-Sleep -Milliseconds ([int]($script:RdpChannelDelaySeconds * 1000))
        }
        throw (New-Object System.Management.Automation.ErrorRecord(
                (New-Object System.Exception "No events were found."),
                'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand',
                [System.Management.Automation.ErrorCategory]::ObjectNotFound, $null))
    }
    # The "has the log been cleared?" probe: newest record only, no filter of any kind.
    if ($MaxEvents -eq 1 -and -not $FilterXPath -and -not $FilterHashtable) {
        return @($script:Events | Select-Object -Last 1)
    }
    $script:SecurityQueryMaxEvents.Add($MaxEvents) | Out-Null
    $source = @($script:Events)
    if ($FilterXPath -and $FilterXPath -match 'EventRecordID\s*>\s*(\d+)') {
        $last = [long]$matches[1]
        $source = @($source | Where-Object { $_.RecordId -gt $last })
    }
    # The real cmdlet returns everything the filter matches when -MaxEvents is absent. That is
    # exactly the unbounded read this finding is about, so the mock must not soften it.
    if ($null -eq $MaxEvents -or [int]$MaxEvents -le 0) { return $source }
    return @($source | Select-Object -First ([int]$MaxEvents))
}

function Get-NetFirewallRule {
    param([string]$DisplayName, $ErrorAction)
    if ([string]::IsNullOrWhiteSpace($DisplayName)) { return @($script:FirewallRules) }
    return @($script:FirewallRules | Where-Object { $_.DisplayName -like $DisplayName })
}
function Get-NetFirewallAddressFilter {
    [CmdletBinding()] param([Parameter(ValueFromPipeline)]$InputObject)
    process { return [pscustomobject]@{ RemoteAddress = @($InputObject.RemoteAddress) } }
}
function Get-NetFirewallPortFilter {
    [CmdletBinding()] param([Parameter(ValueFromPipeline)]$InputObject)
    process { return [pscustomobject]@{ Protocol = $InputObject.Protocol; LocalPort = @($InputObject.LocalPort) } }
}
function New-NetFirewallRule {
    param(
        [string]$DisplayName, [string]$Direction, [string]$RemoteAddress, [string]$Action,
        [string]$Profile, [object]$Enabled,
        [string]$Protocol = 'Any', [object]$LocalPort = 'Any',
        [string]$Description, $ErrorAction
    )
    $rule = [pscustomobject]@{
        DisplayName = $DisplayName; Direction = $Direction; RemoteAddress = $RemoteAddress
        Action = $Action; Profile = $Profile; Enabled = [string]$Enabled; Protocol = $Protocol
        LocalPort = @($LocalPort); Description = $Description
    }
    $script:NewRuleCalls.Add($rule) | Out-Null
    $script:FirewallRules.Add($rule) | Out-Null
    return $rule
}
function Remove-NetFirewallRule {
    [CmdletBinding()] param([Parameter(ValueFromPipeline)]$InputObject, [string]$DisplayName)
    process {
        $name = if ($InputObject) { [string]$InputObject.DisplayName } else { $DisplayName }
        for ($index = $script:FirewallRules.Count - 1; $index -ge 0; $index--) {
            if ($script:FirewallRules[$index].DisplayName -eq $name) { $script:FirewallRules.RemoveAt($index) }
        }
    }
}

function New-LimitsConfig {
    param(
        [int]$Threshold = 1,
        $MaxEventsPerRun = 20000,
        $MaxOffendersPerRun = 200,
        $MaxManagedRules = 2000,
        $MaxStateBytes = 5242880,
        $MaxRunSeconds = 240,
        [string[]]$Whitelist = @()
    )
    return [pscustomobject]@{
        rdp = [pscustomobject]@{ newPort = 5801; oldPort = 3389 }
        rdpBruteforceBlocker = [pscustomobject]@{
            enabled = $true; threshold = $Threshold; lookbackMinutes = 30; taskIntervalMinutes = 1
            rulePrefix = "Limits RDP Block"; whitelistCIDRs = @($Whitelist)
            includeNetworkLogonType3 = $false; attributionWindowSeconds = 120
            blockAllInbound = $false; permanentBlock = $false
            ruleRetentionDays = 30; logMaxBytes = 65536; logRetentionFiles = 2
            maxEventsPerRun = $MaxEventsPerRun; maxOffendersPerRun = $MaxOffendersPerRun
            maxManagedRules = $MaxManagedRules; maxStateBytes = $MaxStateBytes
            maxRunSeconds = $MaxRunSeconds
            statePath = $statePath
        }
    }
}
function Reset-TestState {
    $script:Config = New-LimitsConfig
    $script:Events = @()
    $script:SecurityQueryMaxEvents.Clear()
    $script:RdpQueryMaxEvents.Clear()
    $script:RdpChannelDelaySeconds = 0
    $script:FirewallRules.Clear()
    $script:NewRuleCalls.Clear()
    $script:LogLines.Clear()
    Get-ChildItem -LiteralPath $testRoot -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}
function Invoke-BlockerRun {
    <#
        The blocker is guarded by a machine-wide named mutex, so ANOTHER RDP blocker run on the
        same machine makes this one skip. Skipping is a healthy branch, but it writes no state
        and touches no rule, which here would look like a cap failure. So: wait for the guard to
        be free (a bounded wait on an explicit signal - no sleeps), run, and if the run was
        skipped anyway, try again a bounded number of times before failing with the real reason.
    #>
    param([int]$Attempts = 3)
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $gate = New-Object System.Threading.Mutex($false, 'Global\WinServerSetup-RdpBlocker')
        try {
            $owned = $false
            try { $owned = $gate.WaitOne(60000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
            if ($owned) { $gate.ReleaseMutex() }
        } finally { $gate.Dispose() }

        $marker = $script:LogLines.Count
        $result = Invoke-RdpBruteforceBlocker -ResolvedConfigPath "ignored.json"
        $fresh = @($script:LogLines | Select-Object -Skip $marker) -join "`n"
        if ($fresh -notmatch 'already running') { return $result }
    }
    throw "H-04: every attempt was skipped because another RDP blocker run held the machine-wide guard."
}
function Get-WrittenState {
    Assert-True (Test-Path -LiteralPath $statePath) "H-04: the run must persist a state file."
    return (Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Get-StateByteCount {
    return (Get-Item -LiteralPath $statePath).Length
}

try {
    # ------------------------------------------------------- H-04 the caps are validated at all
    $invalid = @(
        @{ Key = 'maxEventsPerRun';    Value = 0 }
        @{ Key = 'maxEventsPerRun';    Value = 2000000 }
        @{ Key = 'maxOffendersPerRun'; Value = 0 }
        @{ Key = 'maxOffendersPerRun'; Value = 500000 }
        @{ Key = 'maxManagedRules';    Value = 0 }
        @{ Key = 'maxManagedRules';    Value = 500000 }
        @{ Key = 'maxStateBytes';      Value = 1024 }
        @{ Key = 'maxStateBytes';      Value = 4294967296 }
        @{ Key = 'maxRunSeconds';      Value = 0 }
        @{ Key = 'maxRunSeconds';      Value = 7200 }
        @{ Key = 'maxRunSeconds';      Value = 'soon' }
    )
    foreach ($case in $invalid) {
        Reset-TestState
        $script:Config.rdpBruteforceBlocker.($case.Key) = $case.Value
        $script:Events = New-SyntheticEvents -Count 5
        $result = Invoke-BlockerRun
        Assert-Equal 1 $result ("H-04: rdpBruteforceBlocker.{0}={1} is out of range and must fail the run." -f $case.Key, $case.Value)
        Assert-Equal 0 $script:FirewallRules.Count ("H-04: an out-of-range {0} must not change firewall state." -f $case.Key)
        Assert-True (($script:LogLines -join "`n") -match [regex]::Escape($case.Key)) `
            ("H-04: rejecting {0} must name the offending key in the log." -f $case.Key)
    }

    # A config written before these keys existed keeps working, on the shipped defaults, rather
    # than failing closed or running unbounded.
    Reset-TestState
    foreach ($key in @('maxEventsPerRun', 'maxOffendersPerRun', 'maxManagedRules', 'maxStateBytes', 'maxRunSeconds')) {
        $script:Config.rdpBruteforceBlocker.PSObject.Properties.Remove($key)
    }
    $script:Events = New-SyntheticEvents -Count 3
    Assert-Equal 0 (Invoke-BlockerRun) `
        ("H-04: a config without the cap keys must fall back to the shipped defaults. Logs: {0}" -f ($script:LogLines -join " | "))
    Assert-True (@($script:SecurityQueryMaxEvents | Where-Object { $_ }).Count -gt 0) `
        "H-04: the default cap must still be applied to the event query."

    # ------------------------------------------------------- H-04 every event query is bounded
    Reset-TestState
    $script:Config = New-LimitsConfig -MaxEventsPerRun 500
    $script:Events = New-SyntheticEvents -Count 20
    Assert-Equal 0 (Invoke-BlockerRun) "H-04: the seeded run must succeed."
    Assert-True ($script:SecurityQueryMaxEvents.Count -gt 0) "H-04: the Security log must actually be queried."
    foreach ($seen in $script:SecurityQueryMaxEvents) {
        Assert-Equal 500 ([int]$seen) "H-04: every Security query must pass the configured maxEventsPerRun as -MaxEvents."
    }
    foreach ($seen in $script:RdpQueryMaxEvents) {
        Assert-Equal 500 ([int]$seen) "H-04: the RdpCoreTS attribution query must be bounded by maxEventsPerRun too."
    }
    # The incremental (FilterXPath) query is a separate code path and must be bounded as well.
    $script:SecurityQueryMaxEvents.Clear()
    $script:Events = New-SyntheticEvents -Count 25
    Assert-Equal 0 (Invoke-BlockerRun) "H-04: the incremental run must succeed."
    foreach ($seen in $script:SecurityQueryMaxEvents) {
        Assert-Equal 500 ([int]$seen) "H-04: the incremental EventRecordID query must also pass -MaxEvents."
    }

    # ------------------------------------------------------- H-04 the state is a compact summary
    Reset-TestState
    $script:Config = New-LimitsConfig -Threshold 3
    $script:Events = New-SyntheticEvents -Count 4
    Assert-Equal 0 (Invoke-BlockerRun) "H-04: the compact-state run must succeed."
    $state = Get-WrittenState
    Assert-Equal 2 ([int]$state.Version) "H-04: bounded state is schema version 2."
    Assert-True ($null -eq $state.Events) `
        "H-04: raw failed-logon records must no longer be retained in the state file."
    $stateText = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
    Assert-True ($stateText -notmatch 'TargetUserName') `
        "H-04: the state must hold a compact per-address summary, not whole event objects."
    $counters = @($state.Counters)
    Assert-Equal 4 $counters.Count "H-04: one counter per distinct address."
    foreach ($counter in $counters) {
        Assert-True (Test-ValidIPv4 ([string]$counter.Ip)) "H-04: every counter must carry a valid IPv4 address."
        Assert-True (@($counter.Times).Count -ge 1) "H-04: every counter must carry at least one timestamp."
    }

    # ------------------------------------------------------- H-04 offender / rule / address caps
    Reset-TestState
    $script:Config = New-LimitsConfig -Threshold 1 -MaxOffendersPerRun 5 -MaxManagedRules 3
    $script:Events = New-SyntheticEvents -Count 40
    Assert-Equal 0 (Invoke-BlockerRun) `
        ("H-04: a capped run must succeed, not crash. Logs: {0}" -f ($script:LogLines -join " | "))
    $logText = $script:LogLines -join "`n"
    Assert-True ($script:FirewallRules.Count -le 3) `
        ("H-04: managed firewall rules must stop at maxManagedRules. Created={0}" -f $script:FirewallRules.Count)
    Assert-True ($logText -match 'maxOffendersPerRun') "H-04: hitting the offender cap must log a warning naming the setting."
    Assert-True ($logText -match 'maxManagedRules') "H-04: hitting the managed-rule cap must log a warning naming the setting."
    Assert-True ($logText -match '\[WARNING\]') "H-04: a cap that is hit must be a WARNING, not a silent discard."
    $state = Get-WrittenState
    Assert-Equal $true ([bool]$state.Caps.OffendersTruncated) "H-04: the offender cap must be detectable in the written state."
    Assert-Equal $true ([bool]$state.Caps.RulesCapped) "H-04: the managed-rule cap must be detectable in the written state."
    Assert-True ([int]$state.Caps.OffendersFound -ge 40) "H-04: the state must record how many offenders were actually found."

    # ------------------------------------------------------- H-04 whitelisted IPs outrank caps
    # The whitelisted address is the single worst offender, and every cap is set to its minimum.
    # It must still never be blocked and never be tracked, so no cap can evict it.
    Reset-TestState
    $script:Config = New-LimitsConfig -Threshold 1 -MaxOffendersPerRun 1 -MaxManagedRules 1 -Whitelist @('10.0.0.7/32')
    $burst = New-Object 'System.Collections.Generic.List[object]'
    for ($index = 1; $index -le 30; $index++) {
        $item = [SyntheticFailedLogon]::new()
        $item.RecordId = [long](1000 + $index)
        $item.TimeCreated = (Get-Date)
        $item.Ip = '10.0.0.7'
        $burst.Add($item)
    }
    $item = [SyntheticFailedLogon]::new()
    $item.RecordId = [long]2000; $item.TimeCreated = (Get-Date); $item.Ip = '10.0.0.8'
    $burst.Add($item)
    $script:Events = $burst.ToArray()
    Assert-Equal 0 (Invoke-BlockerRun) `
        ("H-04: the whitelist-under-cap run must succeed. Logs: {0}" -f ($script:LogLines -join " | "))
    Assert-Equal 0 @($script:FirewallRules | Where-Object { $_.RemoteAddress -eq '10.0.0.7' }).Count `
        "H-04: a whitelisted address must never be blocked, however many events it produces."
    $state = Get-WrittenState
    Assert-Equal 0 @($state.Counters | Where-Object { [string]$_.Ip -eq '10.0.0.7' }).Count `
        "H-04: a whitelisted address must never enter the tracked set, so no cap can ever evict it."
    Assert-Equal 1 @($script:FirewallRules | Where-Object { $_.RemoteAddress -eq '10.0.0.8' }).Count `
        "H-04: excluding the whitelisted address must leave the cap budget for the real offender."

    # ------------------------------------------------------- H-04 the wall-clock budget is real
    Reset-TestState
    $script:Config = New-LimitsConfig -Threshold 1 -MaxRunSeconds 5
    $script:RdpChannelDelaySeconds = 6
    $script:Events = New-SyntheticEvents -Count 10
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-BlockerRun
    $watch.Stop()
    Assert-Equal 0 $result ("H-04: exceeding maxRunSeconds must stop the run cleanly, not fail the task. Logs: {0}" -f ($script:LogLines -join " | "))
    Assert-True (($script:LogLines -join "`n") -match 'maxRunSeconds') "H-04: exceeding the wall-clock budget must log a warning naming the setting."
    $state = Get-WrittenState
    Assert-Equal $true ([bool]$state.Caps.DeadlineExceeded) "H-04: the wall-clock stop must be detectable in the written state."
    Assert-Equal 0 $script:FirewallRules.Count "H-04: a run that stopped on its deadline must not act on a half-processed window."
    Assert-True ($watch.Elapsed.TotalSeconds -lt 120) `
        ("H-04: the deadline case must not run away. Elapsed={0}s" -f [math]::Round($watch.Elapsed.TotalSeconds, 1))

    # ------------------------------------------------------- H-04 stress: 10,000 unique addresses
    Reset-TestState
    $script:Config = New-LimitsConfig -Threshold 1 -MaxEventsPerRun 100000 -MaxOffendersPerRun 25 -MaxManagedRules 10
    $script:Events = New-SyntheticEvents -Count 10000
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-BlockerRun
    $watch.Stop()
    Assert-Equal 0 $result ("H-04: 10,000 unique addresses must be handled, not crash. Logs: {0}" -f (($script:LogLines | Select-Object -First 8) -join " | "))
    Assert-True ($script:FirewallRules.Count -le 10) `
        ("H-04: 10,000 offenders must still respect maxManagedRules. Created={0}" -f $script:FirewallRules.Count)
    Assert-True ($script:NewRuleCalls.Count -le 25) `
        ("H-04: 10,000 offenders must still respect maxOffendersPerRun. Rule calls={0}" -f $script:NewRuleCalls.Count)
    $bytes = Get-StateByteCount
    Assert-True ($bytes -le 5242880) ("H-04: 10,000 unique addresses must not push the state past maxStateBytes. Bytes={0}" -f $bytes)
    $state = Get-WrittenState
    $tracked = @($state.Counters).Count
    Assert-True ($tracked -lt 10000) ("H-04: the tracked address set must be capped below the flood size. Tracked={0}" -f $tracked)
    Assert-Equal $true ([bool]$state.Caps.AddressesTruncated) "H-04: dropping addresses at the cap must be detectable in the written state."
    Assert-True (($script:LogLines -join "`n") -match '\[WARNING\]') "H-04: a 10,000-address flood must produce warnings."
    Write-Host ("      10,000 unique addresses: {0}s, tracked={1}, rules={2}, state={3} bytes" -f `
        [math]::Round($watch.Elapsed.TotalSeconds, 1), $tracked, $script:FirewallRules.Count, $bytes)

    # ------------------------------------------------------ H-04 stress: 100,000 unique addresses
    # maxEventsPerRun is the outermost cap: the query itself must refuse to hand the run more
    # than that, so the flood size stops mattering.
    Reset-TestState
    $script:Config = New-LimitsConfig -Threshold 1 -MaxEventsPerRun 20000 -MaxOffendersPerRun 25 -MaxManagedRules 10
    $script:Events = New-SyntheticEvents -Count 100000
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-BlockerRun
    $watch.Stop()
    Assert-Equal 0 $result ("H-04: 100,000 unique addresses must be handled, not crash. Logs: {0}" -f (($script:LogLines | Select-Object -First 8) -join " | "))
    $state = Get-WrittenState
    Assert-True ([int]$state.Caps.EventsRead -le 20000) `
        ("H-04: the run must never read more than maxEventsPerRun events. EventsRead={0}" -f $state.Caps.EventsRead)
    Assert-Equal $true ([bool]$state.Caps.EventsTruncated) "H-04: hitting the event cap must be detectable in the written state."
    Assert-True ($script:FirewallRules.Count -le 10) `
        ("H-04: 100,000 offenders must still respect maxManagedRules. Created={0}" -f $script:FirewallRules.Count)
    Assert-True ($script:NewRuleCalls.Count -le 25) `
        ("H-04: 100,000 offenders must still respect maxOffendersPerRun. Rule calls={0}" -f $script:NewRuleCalls.Count)
    $bytes = Get-StateByteCount
    Assert-True ($bytes -le 5242880) ("H-04: 100,000 unique addresses must not push the state past maxStateBytes. Bytes={0}" -f $bytes)
    Assert-True (@($state.Counters).Count -lt 100000) "H-04: the tracked address set must stay capped under a 100,000-address flood."
    # Generously toleranced on purpose: this asserts the run does not become unbounded, not that
    # any particular machine is fast.
    Assert-True ($watch.Elapsed.TotalSeconds -lt 150) `
        ("H-04: a 100,000-address flood must not run away. Elapsed={0}s" -f [math]::Round($watch.Elapsed.TotalSeconds, 1))
    Write-Host ("      100,000 unique addresses: {0}s, read={1}, tracked={2}, rules={3}, state={4} bytes" -f `
        [math]::Round($watch.Elapsed.TotalSeconds, 1), $state.Caps.EventsRead, @($state.Counters).Count, $script:FirewallRules.Count, $bytes)

    Write-Host "PASS H-04 validated resource caps: bounded event queries, compact bounded state, capped offenders and managed rules, wall-clock deadline, whitelist immunity, at 10,000 and 100,000 unique addresses."
} finally {
    # Grant this identity back before cleaning up: a quarantined state file is hardened down to
    # SYSTEM + Administrators (L-03), which would otherwise leave the fixture directory behind.
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach ($file in @(Get-ChildItem -LiteralPath $testRoot -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        & icacls.exe $file.FullName '/grant' ("*{0}:(F)" -f $sid) 2>&1 | Out-Null
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
