<#
    Regression tests for follow-up findings FU-02, FU-03 and FU-05 in
    scripts\Block-RdpBruteforce.ps1.

      FU-02  Every managed block rule was written against $Config.rdp.newPort. With
             rdp.enabled=false the tool does not own the port, so the registry/listener and
             rdp.newPort legitimately disagree - and the blocker then filtered a port nothing
             listens on while the real RDP port stayed wide open. The live RDP-Tcp registry
             port, verified against the TermService listener, is the only port that may reach
             firewall-rule validation and creation, and a disagreement fails the run closed.

      FU-03  Get-WinEvent returns NEWEST records first, and the incremental query was capped
             with -MaxEvents while the caller bookmarked the MAXIMUM RecordId it saw. During a
             backlog larger than maxEventsPerRun that permanently skipped every record between
             the previous bookmark and the oldest record the capped query returned. The query
             is issued oldest-first so the bookmark can only advance across records this run
             actually read.

      FU-05  The offender loop tested maxManagedRules BEFORE calling Ensure-ManagedBlockRule
             and broke out of the loop, so once the rule count reached the cap a stale owned
             rule was never reconciled again - a blockAllInbound flip left every existing rule
             pinned to the old shape forever. The cap now gates only the creation of a rule for
             a NEW address; an existing owned rule is always validated and repaired.
#>
# -ScriptPath targets an alternate copy of the blocker so these tests can be replayed against a
# deliberately defective build to prove they still fail. CI and local runs use the default.
#
# Windows-only cmdlets are shadowed by functions. The mock signatures mirror the real cmdlets -
# including parameters this file never reads - so the code under test binds exactly as it does in
# production. In particular Get-WinEvent reproduces the real ordering contract: newest records
# first unless -Oldest is passed, with -MaxEvents capping whichever end is read first.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Cmdlets are shadowed deliberately to mock Windows-only APIs.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock signatures mirror the real cmdlets so parameter binding matches production.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', '', Justification = 'Mock parameter names must match the real cmdlet parameter names.')]
param([string]$ScriptPath = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = if ([string]::IsNullOrWhiteSpace($ScriptPath)) { Join-Path $projectRoot "scripts\Block-RdpBruteforce.ps1" } else { $ScriptPath }
. $scriptPath

. (Join-Path $PSScriptRoot '_Common.ps1')

$testRoot = Join-Path $env:TEMP ("WinServerSetup-RdpFollowup-{0}" -f ([guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$statePath = Join-Path $testRoot "state.json"

$script:Config = $null
$script:Events = @()
$script:Queries = New-Object System.Collections.Generic.List[object]
$script:FirewallRules = New-Object System.Collections.Generic.List[object]
$script:NewRuleCalls = New-Object System.Collections.Generic.List[object]
$script:LogLines = New-Object System.Collections.Generic.List[string]
# FU-02 machine state: what the RDP-Tcp registry key says, and who actually owns which listener.
$script:RegistryPort = 3389
$script:RegistryReadable = $true
$script:TermServicePid = 4321
$script:ListenerOwnerByPort = @{ 3389 = 4321 }

function Read-JsonFile { param([string]$Path) return $script:Config }
function Write-LogLine {
    param([string]$Message, [string]$Level = "INFO")
    $script:LogLines.Add("[$Level] $Message") | Out-Null
}

function New-NoMatchingEventsError {
    return (New-Object System.Management.Automation.ErrorRecord(
            (New-Object System.Exception "No events were found that match the specified selection criteria."),
            'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand',
            [System.Management.Automation.ErrorCategory]::ObjectNotFound, $null))
}

function New-TestEvent {
    param([long]$RecordId, [string]$IpAddress, [datetime]$TimeCreated = (Get-Date), [string]$LogonType = '10')
    $xml = @"
<Event>
  <System><EventRecordID>$RecordId</EventRecordID></System>
  <EventData>
    <Data Name="IpAddress">$IpAddress</Data>
    <Data Name="LogonType">$LogonType</Data>
    <Data Name="TargetUserName">victim</Data>
  </EventData>
</Event>
"@
    $item = [pscustomobject]@{ RecordId = $RecordId; TimeCreated = $TimeCreated; Xml = $xml }
    $item | Add-Member -MemberType ScriptMethod -Name ToXml -Value { return $this.Xml }
    return $item
}

function Get-WinEvent {
    param($FilterHashtable, $LogName, $FilterXPath, $MaxEvents, [switch]$Oldest, $ErrorAction)
    $channel = if ($FilterHashtable) { [string]$FilterHashtable.LogName } else { [string]$LogName }
    if ($channel -like '*RdpCoreTS*') { throw (New-NoMatchingEventsError) }

    # The "has the Security log been cleared?" probe is the newest record with no filter at all,
    # and must stay newest-first - it is the one query that genuinely wants the far end.
    if ($MaxEvents -eq 1 -and -not $FilterXPath -and -not $FilterHashtable) {
        return @($script:Events | Sort-Object RecordId -Descending | Select-Object -First 1)
    }

    $script:Queries.Add([pscustomobject]@{
            XPath = [string]$FilterXPath; Hashtable = $FilterHashtable
            Oldest = [bool]$Oldest; MaxEvents = $MaxEvents
        }) | Out-Null

    $source = @($script:Events | Sort-Object RecordId)
    if ($FilterXPath -and $FilterXPath -match 'EventRecordID\s*>\s*(\d+)') {
        $last = [long]$matches[1]
        $source = @($source | Where-Object { $_.RecordId -gt $last })
    }
    # The real cmdlet reads newest-first unless -Oldest is passed, so -MaxEvents caps the NEWEST
    # slice by default. FU-03 exists precisely because of that ordering; softening it here would
    # make the mock, not the code, the thing under test.
    if (-not $Oldest) { $source = @($source | Sort-Object RecordId -Descending) }
    if ($MaxEvents -and [int]$MaxEvents -gt 0) { $source = @($source | Select-Object -First ([int]$MaxEvents)) }
    if ($source.Count -eq 0) { throw (New-NoMatchingEventsError) }
    return $source
}

# ------------------------------------------------------------------ FU-02 live-port resolution
function Get-ItemProperty {
    param([string]$Path, [string]$Name, $ErrorAction)
    if (-not $script:RegistryReadable) { throw "Cannot find path '$Path' because it does not exist." }
    return [pscustomobject]@{ PortNumber = $script:RegistryPort }
}
function Get-CimInstance {
    param([string]$ClassName, [string]$Filter, $ErrorAction)
    return [pscustomobject]@{ Name = 'TermService'; ProcessId = $script:TermServicePid }
}
function Get-NetTCPConnection {
    param($State, $LocalPort, $OwningProcess, $ErrorAction)
    # The real cmdlet raises an error rather than returning nothing when no socket matches.
    if (-not $script:ListenerOwnerByPort.ContainsKey([int]$LocalPort)) {
        throw "No MSFT_NetTCPConnection objects found with property 'LocalPort' equal to '$LocalPort'."
    }
    return @([pscustomobject]@{
            LocalPort = [int]$LocalPort; State = 'Listen'
            OwningProcess = [int]$script:ListenerOwnerByPort[[int]$LocalPort]
        })
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
        # The real cmdlet reports 'Any' for a filter the caller never constrained.
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

function New-FollowupConfig {
    param(
        [int]$Threshold = 1,
        [int]$LookbackMinutes = 30,
        [int]$ConfiguredPort = 5801,
        [bool]$RdpEnabled = $false,
        [bool]$BlockAllInbound = $false,
        [int]$MaxEventsPerRun = 20000,
        [int]$MaxManagedRules = 2000
    )
    return [pscustomobject]@{
        rdp = [pscustomobject]@{ enabled = $RdpEnabled; newPort = $ConfiguredPort; oldPort = 3389 }
        rdpBruteforceBlocker = [pscustomobject]@{
            enabled = $true; threshold = $Threshold; lookbackMinutes = $LookbackMinutes
            taskIntervalMinutes = 1; rulePrefix = "Followup RDP Block"; whitelistCIDRs = @()
            includeNetworkLogonType3 = $false; attributionWindowSeconds = 120
            blockAllInbound = $BlockAllInbound; permanentBlock = $false
            ruleRetentionDays = 30; logMaxBytes = 65536; logRetentionFiles = 2
            maxEventsPerRun = $MaxEventsPerRun; maxOffendersPerRun = 200
            maxManagedRules = $MaxManagedRules; maxStateBytes = 5242880; maxRunSeconds = 240
            statePath = $statePath
        }
    }
}

function Reset-TestState {
    $script:Config = New-FollowupConfig
    $script:Events = @()
    $script:Queries.Clear()
    $script:FirewallRules.Clear()
    $script:NewRuleCalls.Clear()
    $script:LogLines.Clear()
    $script:RegistryPort = 3389
    $script:RegistryReadable = $true
    $script:TermServicePid = 4321
    $script:ListenerOwnerByPort = @{ 3389 = 4321 }
    Get-ChildItem -LiteralPath $testRoot -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

function Invoke-BlockerRun {
    <#
        The blocker takes a machine-wide named mutex, so ANOTHER RDP blocker run on the same
        machine - a second shell's test pass - makes this one skip. Skipping is a healthy branch,
        but it writes no state and touches no firewall rule, so every assertion here would then
        fail with a misleading "nothing happened" message. Wait for the guard to be free first
        (a bounded wait on an explicit signal, no sleeps), then run; if it was skipped anyway,
        retry a bounded number of times and finally say why.
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
        if ((@($script:LogLines | Select-Object -Skip $marker) -join "`n") -notmatch 'already running') { return $result }
    }
    throw "Every attempt was skipped because another RDP blocker run held the machine-wide guard."
}

function Get-WrittenState {
    Assert-True (Test-Path -LiteralPath $statePath) "The run must persist a state file."
    return (Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Get-ManagedRuleFor {
    param([string]$IpAddress)
    return @($script:FirewallRules | Where-Object { $_.DisplayName -eq "Followup RDP Block $IpAddress" })
}

try {
    # ================================================================= FU-02 the LIVE RDP port
    # rdp.enabled=false, so the tool does not own the port: the machine really serves RDP on
    # 3389 while rdp.newPort still reads 5801. Rules must follow the machine, never the config.
    Reset-TestState
    $script:Config = New-FollowupConfig -Threshold 2 -ConfiguredPort 5801 -RdpEnabled $false
    $script:RegistryPort = 3389
    $script:ListenerOwnerByPort = @{ 3389 = 4321 }
    $script:Events = @(
        New-TestEvent 1 "203.0.113.10"
        New-TestEvent 2 "203.0.113.10"
    )
    Assert-Equal 0 (Invoke-BlockerRun) `
        ("FU-02: a run against a verified live RDP port must succeed. Logs: {0}" -f ($script:LogLines -join " | "))
    $managed = @(Get-ManagedRuleFor "203.0.113.10")
    Assert-Equal 1 $managed.Count "FU-02: the offender must be blocked."
    Assert-Equal 'TCP' ([string]$managed[0].Protocol) "FU-02: the default block stays TCP-scoped."
    Assert-Equal '3389' ([string]$managed[0].LocalPort[0]) `
        "FU-02: the rule must target the VERIFIED live RDP port from the RDP-Tcp registry value, not rdp.newPort."
    Assert-Equal 0 @($script:NewRuleCalls | Where-Object { [string]$_.LocalPort[0] -eq '5801' }).Count `
        "FU-02: the configured rdp.newPort must never reach firewall-rule creation when the machine serves another port."

    # An existing rule pinned to the configured port is now wrong and must be repaired, because
    # the SAME verified port is what rule validation compares against.
    $script:Config.rdpBruteforceBlocker.threshold = 2
    Assert-Equal 0 (Invoke-BlockerRun) "FU-02: the reconciliation run must succeed."
    $managed = @(Get-ManagedRuleFor "203.0.113.10")
    Assert-Equal 1 $managed.Count "FU-02: reconciliation must leave exactly one managed rule."
    Assert-Equal '3389' ([string]$managed[0].LocalPort[0]) "FU-02: the repaired rule must still target the verified port."
    Assert-Equal 1 $script:NewRuleCalls.Count `
        "FU-02: a rule that already matches the verified port must be accepted, not rebuilt every run."

    # ------------------------------------------------- FU-02 fail closed on any disagreement
    foreach ($case in @(
            @{ Label = 'TermService does not own the listener'; Apply = { $script:ListenerOwnerByPort = @{ 3389 = 999 } } },
            @{ Label = 'nothing is listening on the registry port'; Apply = { $script:ListenerOwnerByPort = @{} } },
            @{ Label = 'TermService is not running'; Apply = { $script:TermServicePid = 0 } },
            @{ Label = 'the RDP-Tcp registry value cannot be read'; Apply = { $script:RegistryReadable = $false } },
            @{ Label = 'the registry port is out of range'; Apply = { $script:RegistryPort = 0; $script:ListenerOwnerByPort = @{ 0 = 4321 } } }
        )) {
        Reset-TestState
        $script:Config = New-FollowupConfig -Threshold 2 -ConfiguredPort 5801 -RdpEnabled $false
        & $case.Apply
        $script:Events = @(
            New-TestEvent 1 "203.0.113.11"
            New-TestEvent 2 "203.0.113.11"
        )
        Assert-Equal 1 (Invoke-BlockerRun) `
            ("FU-02: {0} must fail the run closed. Logs: {1}" -f $case.Label, ($script:LogLines -join " | "))
        Assert-Equal 0 $script:FirewallRules.Count `
            ("FU-02: {0} must never produce a firewall rule on an unverified port." -f $case.Label)
        Assert-True (($script:LogLines -join "`n") -match '\[ERROR\]') `
            ("FU-02: {0} must be logged as an error, not swallowed." -f $case.Label)
        Assert-Equal $false (Test-Path -LiteralPath $statePath) `
            ("FU-02: {0} must not advance the bookmark, so the events stay queued for a healthy run." -f $case.Label)
    }

    # ============================================================ FU-03 the capped backlog
    # 250 failed logons from one address, read 100 at a time. Every RecordId must be processed
    # exactly once across the runs it takes to drain them: no gap, and no double count.
    Reset-TestState
    $script:Config = New-FollowupConfig -Threshold 1000 -LookbackMinutes 1440 -MaxEventsPerRun 100
    $script:RegistryPort = 3389
    $backlog = New-Object 'System.Collections.Generic.List[object]'
    # One distinct whole second per record, so the persisted timestamps identify the exact
    # records this run processed. The base instant is captured ONCE: calling Get-Date per
    # iteration lets loop drift push two records into the same floored second, which would make
    # the uniqueness assertion below flaky rather than meaningful.
    $backlogBase = Get-Date
    for ($index = 1; $index -le 250; $index++) {
        $backlog.Add((New-TestEvent $index "198.51.100.5" ($backlogBase.AddSeconds(-$index)))) | Out-Null
    }
    $script:Events = $backlog.ToArray()

    for ($run = 1; $run -le 3; $run++) {
        Assert-Equal 0 (Invoke-BlockerRun) `
            ("FU-03: backlog run {0} must succeed. Logs: {1}" -f $run, ($script:LogLines -join " | "))
    }
    $state = Get-WrittenState
    $counters = @($state.Counters | Where-Object { [string]$_.Ip -eq '198.51.100.5' })
    Assert-Equal 1 $counters.Count "FU-03: the backlog address must be tracked."
    $times = @($counters[0].Times)
    Assert-Equal 250 $times.Count `
        ("FU-03: every backlogged record must be counted exactly once. A capped newest-first read that bookmarks its maximum RecordId skips the rest permanently. Counted={0}" -f $times.Count)
    Assert-Equal 250 (@($times | Sort-Object -Unique)).Count `
        "FU-03: no record may be counted twice - the bookmark must advance across exactly what was read."
    Assert-Equal 250 ([long]$state.LastRecordId) `
        "FU-03: draining the backlog must leave the bookmark at the highest contiguous RecordId processed."

    # .ToArray(), never @($list): casting a List[object] with @() throws "Argument types do not
    # match" on both hosts.
    $reads = $script:Queries.ToArray()
    Assert-True ($reads.Count -gt 0) "FU-03: the Security log must actually be queried."
    Assert-Equal 0 @($reads | Where-Object { -not $_.Oldest }).Count `
        "FU-03: every incremental and rebuild Security query must be issued oldest-first, or -MaxEvents silently drops the oldest end of the backlog."

    # ============================================== FU-05 a full cap still reconciles a rule
    # One managed rule and maxManagedRules=1: the cap is full from the first run onwards.
    Reset-TestState
    $script:Config = New-FollowupConfig -Threshold 2 -MaxManagedRules 1
    $script:Events = @(
        New-TestEvent 1 "203.0.113.20"
        New-TestEvent 2 "203.0.113.20"
    )
    Assert-Equal 0 (Invoke-BlockerRun) `
        ("FU-05: the seed run must succeed. Logs: {0}" -f ($script:LogLines -join " | "))
    Assert-Equal 1 @(Get-ManagedRuleFor "203.0.113.20").Count "FU-05: the seed run must create the one allowed rule."
    Assert-Equal 'TCP' ([string](Get-ManagedRuleFor "203.0.113.20")[0].Protocol) "FU-05: the seed rule is TCP-scoped."

    # A second offender appears while the cap is already full, and blockAllInbound flips.
    $script:Events += New-TestEvent 3 "203.0.113.21"
    $script:Events += New-TestEvent 4 "203.0.113.21"
    $script:Config.rdpBruteforceBlocker.blockAllInbound = $true
    Assert-Equal 0 (Invoke-BlockerRun) `
        ("FU-05: the false->true run at a full cap must succeed. Logs: {0}" -f ($script:LogLines -join " | "))
    $managed = @(Get-ManagedRuleFor "203.0.113.20")
    Assert-Equal 1 $managed.Count "FU-05: reconciliation must leave exactly one managed rule for the existing address."
    Assert-Equal 'Any' ([string]$managed[0].Protocol) `
        "FU-05: a full maxManagedRules must still repair an EXISTING owned rule - the cap governs new addresses only."
    Assert-Equal 'Any' ([string]$managed[0].LocalPort[0]) `
        "FU-05: the repaired rule must be widened to every port when blockAllInbound is on."
    Assert-Equal 0 @(Get-ManagedRuleFor "203.0.113.21").Count `
        "FU-05: the cap must still refuse a rule for a NEW address."
    Assert-Equal 0 @($script:FirewallRules | Where-Object { $_.DisplayName -like '*replacement-*' }).Count `
        "FU-05: the temporary protection rule must be cleaned up after a successful replacement."
    $state = Get-WrittenState
    Assert-Equal $true ([bool]$state.Caps.RulesCapped) "FU-05: refusing a new address at the cap must stay detectable in the written state."
    Assert-True (($script:LogLines -join "`n") -match 'maxManagedRules') "FU-05: the cap must be logged, naming the setting."

    # ...and back again, still at a full cap.
    $script:Config.rdpBruteforceBlocker.blockAllInbound = $false
    Assert-Equal 0 (Invoke-BlockerRun) `
        ("FU-05: the true->false run at a full cap must succeed. Logs: {0}" -f ($script:LogLines -join " | "))
    $managed = @(Get-ManagedRuleFor "203.0.113.20")
    Assert-Equal 1 $managed.Count "FU-05: the reverse transition must leave exactly one managed rule."
    Assert-Equal 'TCP' ([string]$managed[0].Protocol) `
        "FU-05: a full maxManagedRules must repair the existing rule back to TCP when blockAllInbound is turned off."
    Assert-Equal '3389' ([string]$managed[0].LocalPort[0]) `
        "FU-05: the narrowed rule must be re-pinned to the verified live RDP port."
    Assert-Equal 0 @(Get-ManagedRuleFor "203.0.113.21").Count "FU-05: the new address must still be refused at the cap."

    # An already-correct rule at a full cap must not be rebuilt on every run.
    $before = $script:NewRuleCalls.Count
    Assert-Equal 0 (Invoke-BlockerRun) "FU-05: the idempotent run at a full cap must succeed."
    Assert-Equal $before $script:NewRuleCalls.Count `
        "FU-05: validating an existing rule at a full cap must stay idempotent once it is correct."

    Write-Host "PASS FU-02 verified live RDP port with fail-closed disagreement, FU-03 gap-free capped backlog bookmark, FU-05 rule reconciliation at a full managed-rule cap."
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
