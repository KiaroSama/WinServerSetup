<#
    Regression tests for audit findings M-03 and L-03 in scripts\Block-RdpBruteforce.ps1.

    M-03  Test-ManagedRuleCorrect short-circuited with `if ($BlockAllInbound) { return $true }`,
          so it never inspected the protocol or the port filter. A rule created while
          blockAllInbound was $false stayed TCP/<rdp.newPort>-scoped forever: flipping the
          setting to $true left a narrow rule that no longer matched the configured contract,
          and flipping back was equally unreconciled because the "already correct" branch was
          reached for a rule that was not correct.

    L-03  Read-BlockerState re-threw on malformed JSON, so a single corrupt state file made
          every subsequent run of the scheduled task exit non-zero. The blocker stopped
          protecting the host until an operator deleted the file by hand, and nothing was
          logged that named the file.
#>
# -ScriptPath targets an alternate copy of the blocker so these tests can be replayed against a
# deliberately defective build to prove they still fail. CI and local runs use the default.
#
# The Windows-only firewall cmdlets are shadowed by functions. The mock signatures mirror the
# real cmdlets - including parameters this file never reads, and including the real defaults
# (Protocol/LocalPort report 'Any' when the rule was created without them) - so the code under
# test binds and reconciles exactly as it does in production.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Cmdlets are shadowed deliberately to mock Windows-only APIs.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock signatures mirror the real cmdlets so parameter binding matches production.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', '', Justification = 'Mock parameter names must match the real cmdlet parameter names.')]
param([string]$ScriptPath = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = if ([string]::IsNullOrWhiteSpace($ScriptPath)) { Join-Path $projectRoot "scripts\Block-RdpBruteforce.ps1" } else { $ScriptPath }
. $scriptPath

. (Join-Path $PSScriptRoot '_Common.ps1')

$testRoot = Join-Path $env:TEMP ("WinServerSetup-RdpContract-{0}" -f ([guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$script:Config = $null
$script:Events = @()
$script:FirewallRules = New-Object System.Collections.Generic.List[object]
$script:NewRuleCalls = New-Object System.Collections.Generic.List[object]
$script:RemovedRules = New-Object System.Collections.Generic.List[string]
$script:LogLines = New-Object System.Collections.Generic.List[string]

function Read-JsonFile { param([string]$Path) return $script:Config }
function Write-LogLine {
    param([string]$Message, [string]$Level = "INFO")
    $script:LogLines.Add("[$Level] $Message") | Out-Null
}

function New-TestEvent {
    param([long]$RecordId, [string]$IpAddress, [datetime]$TimeCreated = (Get-Date))
    $xml = @"
<Event>
  <System><EventRecordID>$RecordId</EventRecordID></System>
  <EventData>
    <Data Name="IpAddress">$IpAddress</Data>
    <Data Name="LogonType">10</Data>
    <Data Name="TargetUserName">victim</Data>
  </EventData>
</Event>
"@
    $item = [pscustomobject]@{ RecordId = $RecordId; TimeCreated = $TimeCreated; Xml = $xml }
    $item | Add-Member -MemberType ScriptMethod -Name ToXml -Value { return $this.Xml }
    return $item
}

function Get-WinEvent {
    param($FilterHashtable, $LogName, $FilterXPath, $MaxEvents, $ErrorAction)
    $channel = if ($FilterHashtable) { [string]$FilterHashtable.LogName } else { [string]$LogName }
    if ($channel -like '*RdpCoreTS*') {
        throw (New-Object System.Management.Automation.ErrorRecord(
                (New-Object System.Exception "No events were found."),
                'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand',
                [System.Management.Automation.ErrorCategory]::ObjectNotFound, $null))
    }
    # The "has the log been cleared?" probe: newest record only, no filter of any kind.
    if ($MaxEvents -eq 1 -and -not $FilterXPath -and -not $FilterHashtable) {
        return @($script:Events | Sort-Object RecordId -Descending | Select-Object -First 1)
    }
    if ($FilterXPath -and $FilterXPath -match 'EventRecordID\s*>\s*(\d+)') {
        return @($script:Events | Where-Object { $_.RecordId -gt [long]$matches[1] })
    }
    return @($script:Events)
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
        $script:RemovedRules.Add($name) | Out-Null
        for ($index = $script:FirewallRules.Count - 1; $index -ge 0; $index--) {
            if ($script:FirewallRules[$index].DisplayName -eq $name) { $script:FirewallRules.RemoveAt($index) }
        }
    }
}

function New-FakeRule {
    param(
        [string]$DisplayName = "Contract RDP Block 203.0.113.10",
        [string]$RemoteAddress = "203.0.113.10",
        [string]$Protocol = 'Any',
        [object]$LocalPort = 'Any',
        [string]$Direction = 'Inbound',
        [string]$Action = 'Block',
        [string]$Profile = 'Any',
        [string]$Enabled = 'True',
        [string]$Description = "ManagedBy=WinServerSetup;CreatedUtc=$((Get-Date).ToUniversalTime().ToString('o'))"
    )
    return [pscustomobject]@{
        DisplayName = $DisplayName; RemoteAddress = $RemoteAddress; Protocol = $Protocol
        LocalPort = @($LocalPort); Direction = $Direction; Action = $Action; Profile = $Profile
        Enabled = $Enabled; Description = $Description
    }
}

$statePath = Join-Path $testRoot "state.json"
function New-TestConfig {
    param([bool]$BlockAllInbound = $false, [string]$StatePath = $statePath, [long]$MaxStateBytes = 5242880)
    return [pscustomobject]@{
        rdp = [pscustomobject]@{ newPort = 5801; oldPort = 3389 }
        rdpBruteforceBlocker = [pscustomobject]@{
            enabled = $true; threshold = 2; lookbackMinutes = 30; taskIntervalMinutes = 1
            rulePrefix = "Contract RDP Block"; whitelistCIDRs = @()
            includeNetworkLogonType3 = $false; attributionWindowSeconds = 120
            blockAllInbound = $BlockAllInbound; permanentBlock = $false
            ruleRetentionDays = 30; logMaxBytes = 65536; logRetentionFiles = 2
            maxEventsPerRun = 20000; maxOffendersPerRun = 200; maxManagedRules = 2000
            maxStateBytes = $MaxStateBytes; maxRunSeconds = 240
            statePath = $StatePath
        }
    }
}
function Get-QuarantineFiles {
    return @(Get-ChildItem -LiteralPath $testRoot -Filter 'state.json.corrupt-*.json' -File -ErrorAction SilentlyContinue)
}
function Restore-QuarantineAccess {
    # Production hardens a quarantined file down to SYSTEM + Administrators, which is the point
    # of L-03. A non-elevated test process therefore cannot delete its own fixtures until it
    # grants itself back in. SID form so it does not depend on the account name or locale.
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $testRoot ("/grant:r") ("*{0}:(OI)(CI)(F)" -f $sid) /T /C /Q 2>&1 | Out-Null
}
function Remove-TestRoot {
    Restore-QuarantineAccess
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
function Reset-TestState {
    param([bool]$BlockAllInbound = $false)
    Restore-QuarantineAccess
    $script:Config = New-TestConfig -BlockAllInbound $BlockAllInbound
    $script:Events = @()
    $script:FirewallRules.Clear()
    $script:NewRuleCalls.Clear()
    $script:RemovedRules.Clear()
    $script:LogLines.Clear()
    Get-ChildItem -LiteralPath $testRoot -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}
function Get-ManagedRuleFor {
    param([string]$IpAddress)
    return @($script:FirewallRules | Where-Object { $_.DisplayName -eq "Contract RDP Block $IpAddress" })
}

function Invoke-BlockerRun {
    <#
        The blocker is guarded by a machine-wide named mutex, so ANOTHER RDP blocker run on the
        same machine - a second shell's test pass - makes this one skip. Skipping is a healthy
        branch, but it writes no state and touches no firewall rule, so every assertion here
        would then fail with a misleading "nothing happened" message. Wait for the guard to be
        free first (a bounded wait on an explicit signal, no sleeps), then run; if it was skipped
        anyway, retry a bounded number of times and finally say why.
    #>
    param([int]$Attempts = 3)
    $configArgument = "ignored.json"
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $gate = New-Object System.Threading.Mutex($false, 'Global\WinServerSetup-RdpBlocker')
        try {
            $owned = $false
            try { $owned = $gate.WaitOne(60000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
            if ($owned) { $gate.ReleaseMutex() }
        } finally { $gate.Dispose() }

        $marker = $script:LogLines.Count
        $result = Invoke-RdpBruteforceBlocker -ResolvedConfigPath $configArgument
        if ((@($script:LogLines | Select-Object -Skip $marker) -join "`n") -notmatch 'already running') { return $result }
    }
    throw "Every attempt was skipped because another RDP blocker run held the machine-wide guard."
}

try {
    # ---------------------------------------------------------------- M-03 unit contract
    # blockAllInbound=$true means the rule must genuinely block every protocol and every port.
    # A leftover TCP/<rdpPort> rule satisfies none of that and must be reported as incorrect.
    Assert-Equal $false (Test-ManagedRuleCorrect (New-FakeRule -Protocol 'TCP' -LocalPort '5801') "203.0.113.10" 5801 $true) `
        "M-03: with blockAllInbound=true a TCP/port-scoped rule must be reported as incorrect so it gets repaired."
    Assert-Equal $true (Test-ManagedRuleCorrect (New-FakeRule -Protocol 'Any' -LocalPort 'Any') "203.0.113.10" 5801 $true) `
        "M-03: with blockAllInbound=true an Any/Any rule is the only correct shape."
    Assert-Equal $false (Test-ManagedRuleCorrect (New-FakeRule -Protocol 'Any' -LocalPort 'Any') "203.0.113.10" 5801 $false) `
        "M-03: with blockAllInbound=false an Any/Any rule is wider than configured and must be repaired."
    Assert-Equal $true (Test-ManagedRuleCorrect (New-FakeRule -Protocol 'TCP' -LocalPort '5801') "203.0.113.10" 5801 $false) `
        "M-03: with blockAllInbound=false exactly TCP plus the verified RDP port is correct."
    Assert-Equal $false (Test-ManagedRuleCorrect (New-FakeRule -Protocol 'TCP' -LocalPort '3389') "203.0.113.10" 5801 $false) `
        "M-03: a rule pinned to a stale RDP port must be repaired."
    Assert-Equal $false (Test-ManagedRuleCorrect (New-FakeRule -Protocol 'UDP' -LocalPort '5801') "203.0.113.10" 5801 $false) `
        "M-03: the protocol filter is part of the contract."

    # The rest of the contract is validated as one unit, in both blockAllInbound modes.
    foreach ($mode in @($true, $false)) {
        $wide = [bool]$mode
        $protocol = if ($wide) { 'Any' } else { 'TCP' }
        $port = if ($wide) { 'Any' } else { '5801' }
        Assert-Equal $false (Test-ManagedRuleCorrect (New-FakeRule -Protocol $protocol -LocalPort $port -Enabled 'False') "203.0.113.10" 5801 $wide) `
            "M-03: a disabled rule is not correct (blockAllInbound=$wide)."
        Assert-Equal $false (Test-ManagedRuleCorrect (New-FakeRule -Protocol $protocol -LocalPort $port -Action 'Allow') "203.0.113.10" 5801 $wide) `
            "M-03: an Allow rule is not correct (blockAllInbound=$wide)."
        Assert-Equal $false (Test-ManagedRuleCorrect (New-FakeRule -Protocol $protocol -LocalPort $port -Direction 'Outbound') "203.0.113.10" 5801 $wide) `
            "M-03: an outbound rule is not correct (blockAllInbound=$wide)."
        Assert-Equal $false (Test-ManagedRuleCorrect (New-FakeRule -Protocol $protocol -LocalPort $port -Profile 'Domain') "203.0.113.10" 5801 $wide) `
            "M-03: a profile-scoped rule is not correct (blockAllInbound=$wide)."
        Assert-Equal $false (Test-ManagedRuleCorrect (New-FakeRule -Protocol $protocol -LocalPort $port -RemoteAddress '198.51.100.4') "203.0.113.10" 5801 $wide) `
            "M-03: the remote address is part of the contract (blockAllInbound=$wide)."
    }

    # ---------------------------------------------------------------- M-03 both transitions
    Reset-TestState -BlockAllInbound $false
    $script:Events = @(
        New-TestEvent 1 "203.0.113.10"
        New-TestEvent 2 "203.0.113.10"
    )
    Assert-Equal 0 (Invoke-BlockerRun) `
        ("M-03: the port-scoped seed run must succeed. Logs: {0}" -f ($script:LogLines -join " | "))
    $managed = @(Get-ManagedRuleFor "203.0.113.10")
    Assert-Equal 1 $managed.Count "M-03: the seed run must leave exactly one managed rule."
    Assert-Equal 'TCP' ([string]$managed[0].Protocol) "M-03: blockAllInbound=false must create a TCP rule."
    Assert-Equal '5801' ([string]$managed[0].LocalPort[0]) "M-03: blockAllInbound=false must pin the verified RDP port."

    # false -> true must repair the existing rule, not accept it.
    $script:Config.rdpBruteforceBlocker.blockAllInbound = $true
    Assert-Equal 0 (Invoke-BlockerRun) `
        ("M-03: the false->true reconciliation run must succeed. Logs: {0}" -f ($script:LogLines -join " | "))
    $managed = @(Get-ManagedRuleFor "203.0.113.10")
    Assert-Equal 1 $managed.Count "M-03: reconciliation must leave exactly one managed rule, not a duplicate."
    Assert-Equal 'Any' ([string]$managed[0].Protocol) `
        "M-03: flipping blockAllInbound false->true must widen the existing rule to every protocol."
    Assert-Equal 'Any' ([string]$managed[0].LocalPort[0]) `
        "M-03: flipping blockAllInbound false->true must widen the existing rule to every port."
    Assert-Equal 0 @($script:FirewallRules | Where-Object { $_.DisplayName -like '*replacement-*' }).Count `
        "M-03: the temporary protection rule must be cleaned up after a successful replacement."

    # Re-running in the same mode must change nothing at all.
    $before = $script:NewRuleCalls.Count
    Assert-Equal 0 (Invoke-BlockerRun) "M-03: the idempotent true run must succeed."
    Assert-Equal $before $script:NewRuleCalls.Count "M-03: blockAllInbound=true must be idempotent once the rule is correct."
    Assert-Equal 1 @(Get-ManagedRuleFor "203.0.113.10").Count "M-03: an idempotent run must not add a second managed rule."

    # true -> false must narrow it back.
    $script:Config.rdpBruteforceBlocker.blockAllInbound = $false
    Assert-Equal 0 (Invoke-BlockerRun) `
        ("M-03: the true->false reconciliation run must succeed. Logs: {0}" -f ($script:LogLines -join " | "))
    $managed = @(Get-ManagedRuleFor "203.0.113.10")
    Assert-Equal 1 $managed.Count "M-03: the reverse transition must leave exactly one managed rule."
    Assert-Equal 'TCP' ([string]$managed[0].Protocol) "M-03: flipping blockAllInbound true->false must narrow the rule back to TCP."
    Assert-Equal '5801' ([string]$managed[0].LocalPort[0]) "M-03: flipping blockAllInbound true->false must re-pin the verified RDP port."
    $before = $script:NewRuleCalls.Count
    Assert-Equal 0 (Invoke-BlockerRun) "M-03: the idempotent false run must succeed."
    Assert-Equal $before $script:NewRuleCalls.Count "M-03: blockAllInbound=false must be idempotent once the rule is correct."

    # ---------------------------------------------------------------- H-04 foreign-rule safety
    # A rule that does not carry ManagedBy=WinServerSetup belongs to someone else. The blocker
    # must leave it completely alone rather than deleting an operator's firewall policy.
    Reset-TestState -BlockAllInbound $false
    $foreign = New-FakeRule -Description "Blocked by the site firewall standard" -Protocol 'TCP' -LocalPort '3389'
    $script:FirewallRules.Add($foreign) | Out-Null
    $script:Events = @(
        New-TestEvent 1 "203.0.113.10"
        New-TestEvent 2 "203.0.113.10"
    )
    Assert-Equal 0 (Invoke-BlockerRun) `
        ("H-04: a foreign rule must not fail the run. Logs: {0}" -f ($script:LogLines -join " | "))
    Assert-Equal 0 $script:RemovedRules.Count "H-04: the blocker must never remove a firewall rule it does not own."
    Assert-True ($script:FirewallRules -contains $foreign) "H-04: the operator's own rule must survive untouched."
    Assert-True (($script:LogLines -join "`n") -match 'not managed by WinServerSetup') `
        "H-04: skipping a foreign rule must be logged so the operator can see why the address was not blocked."

    # ---------------------------------------------------------------- L-03 corrupt state recovery
    function Test-QuarantineRecovery {
        param([string]$Label, [scriptblock]$SeedState)
        Reset-TestState
        & $SeedState
        $script:Events = @(
            New-TestEvent 41 "203.0.113.60"
            New-TestEvent 42 "203.0.113.60"
        )
        $result = Invoke-BlockerRun
        $logText = $script:LogLines -join "`n"
        Assert-Equal 0 $result ("L-03: {0} must be recovered from, not turned into a task failure. Logs: {1}" -f $Label, $logText)
        $quarantined = @(Get-QuarantineFiles)
        Assert-Equal 1 $quarantined.Count ("L-03: {0} must be moved to exactly one quarantine file next to the state file." -f $Label)
        Assert-True ($logText -match '\[WARNING\].*quarantin') ("L-03: {0} must be logged as a warning naming the quarantine." -f $Label)
        Assert-True (Test-Path -LiteralPath $statePath) ("L-03: {0} must leave a rebuilt state file behind." -f $Label)
        $rebuilt = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Equal 2 ([int]$rebuilt.Version) ("L-03: {0} must rebuild state at the supported schema version." -f $Label)
        Assert-Equal 1 @(Get-ManagedRuleFor "203.0.113.60").Count `
            ("L-03: {0} must rebuild from the bounded lookback and still block the live offender." -f $Label)
        return $quarantined[0].FullName
    }

    $quarantinePath = Test-QuarantineRecovery "malformed JSON" {
        Set-Content -LiteralPath $statePath -Value '{ "Version": 2, "LastRecordId": 5, "Counters": [ ' -Encoding UTF8
    }

    # The quarantine file is hardened: inheritance is broken so it no longer grants whatever the
    # parent directory grants. icacls.exe marks inherited entries with a literal '(I)'.
    if (Get-Command icacls.exe -ErrorAction SilentlyContinue) {
        $acl = @(& icacls.exe $quarantinePath 2>&1) -join "`n"
        Assert-True ($acl -notmatch '\(I\)') `
            ("L-03: the quarantined state file must not inherit its directory ACL. icacls said: {0}" -f $acl)
    } else {
        Write-Host "SKIP L-03 ACL assertion: icacls.exe is not available on this host."
    }

    $null = Test-QuarantineRecovery "an incompatible schema version" {
        [pscustomobject]@{ Version = 1; LastRecordId = 5; Events = @() } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
    }

    $null = Test-QuarantineRecovery "an invalid timestamp" {
        [pscustomobject]@{
            Version = 2; LastRecordId = 5
            Counters = @([pscustomobject]@{ Ip = '203.0.113.99'; Times = @('yesterday'); Types = '10'; Users = 'x'; Evidence = 'y' })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
    }

    $null = Test-QuarantineRecovery "an address that is not IPv4" {
        [pscustomobject]@{
            Version = 2; LastRecordId = 5
            Counters = @([pscustomobject]@{ Ip = 'not-an-address'; Times = @(1754000000); Types = '10'; Users = 'x'; Evidence = 'y' })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
    }

    # An oversized state file must be rejected on its size BEFORE any parse is attempted.
    Reset-TestState
    $script:Config = New-TestConfig -MaxStateBytes 65536
    Set-Content -LiteralPath $statePath -Value ('x' * 70000) -Encoding UTF8
    $script:Events = @(New-TestEvent 51 "203.0.113.61"; New-TestEvent 52 "203.0.113.61")
    Assert-Equal 0 (Invoke-BlockerRun) `
        ("L-03: an oversized state file must be recovered from. Logs: {0}" -f ($script:LogLines -join " | "))
    Assert-Equal 1 @(Get-QuarantineFiles).Count `
        "L-03: an oversized state file must be quarantined."
    Assert-True (($script:LogLines -join "`n") -match 'maxStateBytes|byte limit|bytes') `
        "L-03: the size rejection must say what the limit was."

    # Recovery must stay inside the state directory even when the configured path contains a
    # traversal sequence: the quarantine name is derived from the RESOLVED path.
    Reset-TestState
    $nested = Join-Path $testRoot "nested"
    New-Item -ItemType Directory -Path $nested -Force | Out-Null
    $traversalPath = Join-Path $nested "..\state.json"
    $script:Config = New-TestConfig -StatePath $traversalPath
    Set-Content -LiteralPath $statePath -Value 'not json at all' -Encoding UTF8
    $outsideBefore = @(Get-ChildItem -LiteralPath (Split-Path -Parent $testRoot) -Filter '*.corrupt-*.json' -File -ErrorAction SilentlyContinue).Count
    Assert-Equal 0 (Invoke-BlockerRun) `
        ("L-03: a traversal-shaped state path must still recover. Logs: {0}" -f ($script:LogLines -join " | "))
    Assert-Equal 1 @(Get-QuarantineFiles).Count `
        "L-03: the quarantine file must land in the resolved state directory."
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $nested -File -ErrorAction SilentlyContinue).Count `
        "L-03: recovery must not write into an unrelated directory."
    Assert-Equal $outsideBefore @(Get-ChildItem -LiteralPath (Split-Path -Parent $testRoot) -Filter '*.corrupt-*.json' -File -ErrorAction SilentlyContinue).Count `
        "L-03: recovery must never create or delete files outside the state directory."

    # A healthy state file is never quarantined.
    Reset-TestState
    $script:Events = @(New-TestEvent 61 "203.0.113.62"; New-TestEvent 62 "203.0.113.62")
    Assert-Equal 0 (Invoke-BlockerRun) "L-03: the healthy seed run must succeed."
    Assert-Equal 0 (Invoke-BlockerRun) "L-03: the healthy second run must succeed."
    Assert-Equal 0 @(Get-QuarantineFiles).Count `
        "L-03: a state file the blocker itself just wrote must never be quarantined."

    Write-Host "PASS M-03 blockAllInbound reconciliation in both directions and L-03 quarantine-and-rebuild recovery from corrupt blocker state."
} finally {
    Remove-TestRoot
}
