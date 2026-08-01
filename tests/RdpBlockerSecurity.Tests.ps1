# This harness mocks Windows-only cmdlets by shadowing them with functions. The mock signatures
# must mirror the real cmdlets - including parameters this file never reads - so the code under
# test binds exactly as it does in production.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Cmdlets are shadowed deliberately to mock Windows-only APIs.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock signatures mirror the real cmdlets so parameter binding matches production.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', '', Justification = 'Mock parameter names must match the real cmdlet parameter names.')]
param()

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $projectRoot "scripts\Block-RdpBruteforce.ps1"
$source = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw ("{0} Expected={1}; Actual={2}" -f $Message, $Expected, $Actual) }
}

Assert-True ($source -notmatch 'function\s+Get-CurrentRdpClientIPs') "Established TCP connections must never bypass the RDP blocker."
Assert-True ($source -match 'function\s+Invoke-RdpBruteforceBlocker') "The blocker needs a callable entry point for mocked behavioral tests."

. $scriptPath

$testRoot = Join-Path $env:TEMP ("WinServerSetup-RdpSecurity-{0}" -f ([guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

function New-TestEvent {
    param(
        [long]$RecordId,
        [string]$IpAddress,
        [string]$LogonType,
        [string]$TargetUserName,
        [datetime]$TimeCreated = (Get-Date)
    )
    $xml = @"
<Event>
  <System><EventRecordID>$RecordId</EventRecordID></System>
  <EventData>
    <Data Name="IpAddress">$IpAddress</Data>
    <Data Name="LogonType">$LogonType</Data>
    <Data Name="TargetUserName">$TargetUserName</Data>
  </EventData>
</Event>
"@
    $event = [pscustomobject]@{ RecordId = $RecordId; TimeCreated = $TimeCreated; Xml = $xml }
    $event | Add-Member -MemberType ScriptMethod -Name ToXml -Value { return $this.Xml }
    return $event
}

$script:Config = $null
$script:Events = @()
$script:RdpEvents = @()
$script:EventReadFailure = $false
$script:EventQueries = New-Object System.Collections.Generic.List[string]
$script:FirewallRules = New-Object System.Collections.Generic.List[object]
$script:NewRuleCalls = New-Object System.Collections.Generic.List[object]
$script:LogLines = New-Object System.Collections.Generic.List[string]
$script:TcpConnectionCalls = 0

function Read-JsonFile { param([string]$Path) return $script:Config }
function Write-LogLine {
    param([string]$Message, [string]$Level = "INFO")
    $script:LogLines.Add("[$Level] $Message") | Out-Null
}
function Get-NetTCPConnection {
    $script:TcpConnectionCalls++
    throw "Get-NetTCPConnection must not be called by the blocker."
}
function New-TestRdpEvent {
    param([long]$RecordId, [string]$IpAddress)
    $xml = @"
<Event>
  <System><EventRecordID>$RecordId</EventRecordID></System>
  <EventData>
    <Data Name="IPString">$IpAddress</Data>
  </EventData>
</Event>
"@
    $event = [pscustomobject]@{ RecordId = $RecordId; TimeCreated = (Get-Date); Xml = $xml }
    $event | Add-Member -MemberType ScriptMethod -Name ToXml -Value { return $this.Xml }
    return $event
}

function Get-WinEvent {
    param($FilterHashtable, $LogName, $FilterXPath, $MaxEvents, $ErrorAction)
    # The RdpCoreTS channel is a separate log from Security; return only what was seeded for it.
    $channel = if ($FilterHashtable) { [string]$FilterHashtable.LogName } else { [string]$LogName }
    if ($channel -like '*RdpCoreTS*') { return @($script:RdpEvents) }
    if ($script:EventReadFailure) { throw "Security log access denied" }
    if ($FilterXPath) { $script:EventQueries.Add([string]$FilterXPath) | Out-Null }
    if ($MaxEvents) { return @($script:Events | Sort-Object RecordId -Descending | Select-Object -First 1) }
    if ($FilterXPath -and $FilterXPath -match 'EventRecordID\s*&gt;\s*(\d+)|EventRecordID\s*>\s*(\d+)') {
        $last = if ($matches[1]) { [long]$matches[1] } else { [long]$matches[2] }
        return @($script:Events | Where-Object { $_.RecordId -gt $last })
    }
    return @($script:Events)
}
function Get-NetFirewallRule {
    param([string]$DisplayName, $ErrorAction)
    if ([string]::IsNullOrWhiteSpace($DisplayName)) { return @($script:FirewallRules) }
    return @($script:FirewallRules | Where-Object { $_.DisplayName -like $DisplayName })
}
function Get-NetFirewallAddressFilter {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)]$InputObject)
    process { return [pscustomobject]@{ RemoteAddress = @($InputObject.RemoteAddress) } }
}
function Get-NetFirewallPortFilter {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)]$InputObject)
    process { return [pscustomobject]@{ Protocol = $InputObject.Protocol; LocalPort = @($InputObject.LocalPort) } }
}
function New-NetFirewallRule {
    param(
        [string]$DisplayName,
        [string]$Direction,
        [string]$RemoteAddress,
        [string]$Action,
        [string]$Profile,
        [object]$Enabled,
        [string]$Protocol,
        [object]$LocalPort,
        [string]$Description,
        $ErrorAction
    )
    $rule = [pscustomobject]@{
        DisplayName = $DisplayName
        Direction = $Direction
        RemoteAddress = $RemoteAddress
        Action = $Action
        Profile = $Profile
        Enabled = [string]$Enabled
        Protocol = $Protocol
        LocalPort = @($LocalPort)
        Description = $Description
    }
    $script:NewRuleCalls.Add($rule) | Out-Null
    $script:FirewallRules.Add($rule) | Out-Null
    return $rule
}
function Remove-NetFirewallRule {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)]$InputObject, [string]$DisplayName)
    process {
        $name = if ($InputObject) { [string]$InputObject.DisplayName } else { $DisplayName }
        for ($index = $script:FirewallRules.Count - 1; $index -ge 0; $index--) {
            if ($script:FirewallRules[$index].DisplayName -eq $name) { $script:FirewallRules.RemoveAt($index) }
        }
    }
}

function New-TestConfig {
    param([string[]]$Whitelist = @())
    return [pscustomobject]@{
        rdp = [pscustomobject]@{ newPort = 5801; oldPort = 3389 }
        rdpBruteforceBlocker = [pscustomobject]@{
            enabled = $true
            threshold = 2
            lookbackMinutes = 30
            taskIntervalMinutes = 1
            rulePrefix = "UnitTest RDP Block"
            whitelistCIDRs = @($Whitelist)
            includeNetworkLogonType3 = $false
            blockAllInbound = $false
            permanentBlock = $false
            ruleRetentionDays = 30
            logMaxBytes = 65536
            logRetentionFiles = 2
            statePath = (Join-Path $testRoot "state.json")
        }
    }
}

function Reset-TestState {
    $script:Config = New-TestConfig
    $script:Events = @()
    $script:RdpEvents = @()
    $script:EventReadFailure = $false
    $script:EventQueries.Clear()
    $script:FirewallRules.Clear()
    $script:NewRuleCalls.Clear()
    $script:LogLines.Clear()
    $script:TcpConnectionCalls = 0
    Remove-Item -LiteralPath (Join-Path $testRoot "state.json") -Force -ErrorAction SilentlyContinue
}

try {
    Reset-TestState
    $script:Config = New-TestConfig -Whitelist @("203.0.113.30/32")
    $script:Events = @(
        New-TestEvent 1 "203.0.113.10" "10" "renamed-admin"
        New-TestEvent 2 "203.0.113.10" "10" "renamed-admin"
        New-TestEvent 3 "203.0.113.20" "3" "network-user"
        New-TestEvent 4 "203.0.113.20" "3" "network-user"
        New-TestEvent 5 "203.0.113.30" "10" "whitelisted-user"
        New-TestEvent 6 "203.0.113.30" "10" "whitelisted-user"
    )

    $result = Invoke-RdpBruteforceBlocker -ResolvedConfigPath "ignored.json"
    Assert-Equal 0 $result ("Valid blocker run must succeed. Logs: {0}" -f ($script:LogLines -join " | "))
    Assert-Equal 0 $script:TcpConnectionCalls "Established TCP sessions must not be consulted."
    Assert-Equal 1 $script:FirewallRules.Count "Only the RemoteInteractive non-whitelisted offender must be blocked."
    $rule = $script:FirewallRules[0]
    Assert-Equal "203.0.113.10" $rule.RemoteAddress "Wrong offender was blocked."
    Assert-Equal "TCP" $rule.Protocol "Default block must be TCP-scoped."
    Assert-Equal "5801" ([string]$rule.LocalPort[0]) "Default block must target the configured RDP port."
    Assert-True (($script:LogLines -join "`n") -match 'renamed-admin') "Logs must preserve the actual TargetUserName."
    Assert-True (($script:LogLines -join "`n") -match 'whitelisted') "Whitelist decisions must be logged."

    Reset-TestState
    $script:Config.rdpBruteforceBlocker.includeNetworkLogonType3 = $true
    $script:Events = @(
        New-TestEvent 7 "203.0.113.21" "3" "network-user"
        New-TestEvent 8 "203.0.113.21" "3" "network-user"
    )
    Assert-Equal 0 (Invoke-RdpBruteforceBlocker -ResolvedConfigPath "ignored.json") "Opt-in Logon Type 3 run failed."
    Assert-Equal 1 $script:FirewallRules.Count "Logon Type 3 must be blockable only when explicitly enabled."

    # Network Level Authentication is the default on current Windows Server, and it records a
    # failed RDP sign-in as 4625 LogonType 3 rather than LogonType 10. Matching only LogonType 10
    # therefore misses the ordinary attack. The RdpCoreTS channel is the RDP-specific evidence
    # that lets those failures be attributed without counting unrelated network logons.
    Reset-TestState
    $script:Config.rdpBruteforceBlocker.includeNetworkLogonType3 = $false
    $script:Events = @(
        New-TestEvent 20 "203.0.113.50" "3" "administrator"
        New-TestEvent 21 "203.0.113.50" "3" "administrator"
        New-TestEvent 22 "198.51.100.9" "3" "fileshare-user"
        New-TestEvent 23 "198.51.100.9" "3" "fileshare-user"
    )
    # Only the first address actually spoke RDP to this host.
    $script:RdpEvents = @(New-TestRdpEvent 1 "203.0.113.50")

    Assert-Equal 0 (Invoke-RdpBruteforceBlocker -ResolvedConfigPath "ignored.json") `
        ("NLA-attributed run failed. Logs: {0}" -f ($script:LogLines -join " | "))
    Assert-Equal 1 $script:FirewallRules.Count `
        "An NLA-mode RDP attacker (LogonType 3 confirmed by the RDP channel) must be blocked, and a plain network logon must not."
    Assert-Equal "203.0.113.50" $script:FirewallRules[0].RemoteAddress `
        "The blocked address must be the one the RDP channel attributed, not the unrelated network logon."
    Assert-True (($script:LogLines -join "`n") -match 'Network\+RdpChannel') `
        "Logs must record WHY a LogonType 3 failure was counted as RDP."

    Reset-TestState
    $script:Config.rdpBruteforceBlocker.threshold = 0
    $result = Invoke-RdpBruteforceBlocker -ResolvedConfigPath "ignored.json"
    Assert-Equal 1 $result "Invalid threshold must fail the task."
    Assert-Equal 0 $script:FirewallRules.Count "Invalid config must not change firewall state."

    Reset-TestState
    $script:EventReadFailure = $true
    $result = Invoke-RdpBruteforceBlocker -ResolvedConfigPath "ignored.json"
    Assert-Equal 1 $result "Security log read failure must return nonzero."
    $failureLogs = $script:LogLines -join "`n"
    Assert-True ($failureLogs -match '\[ERROR\].*Security log access denied') "Security log read failure must be logged as an error."
    Assert-True ($failureLogs -notmatch 'No abusive IPs found') "Read failure must not be reported as an empty result."

    Reset-TestState
    $script:Events = @(
        New-TestEvent 10 "203.0.113.40" "10" "user-a"
        New-TestEvent 11 "203.0.113.40" "10" "user-a"
    )
    Assert-Equal 0 (Invoke-RdpBruteforceBlocker -ResolvedConfigPath "ignored.json") "Initial stateful run failed."
    $script:Events += New-TestEvent 12 "203.0.113.41" "10" "user-b"
    $script:Events += New-TestEvent 13 "203.0.113.41" "10" "user-b"
    $incrementalResult = Invoke-RdpBruteforceBlocker -ResolvedConfigPath "ignored.json"
    Assert-Equal 0 $incrementalResult ("Incremental stateful run failed. Logs: {0}" -f ($script:LogLines -join " | "))
    Assert-True (($script:EventQueries -join "`n") -match 'EventRecordID.*11') "Second run must query after the persisted RecordId instead of reparsing the full window."

    # A run that overlaps an in-progress run is an ordinary scheduling overlap, not a failure.
    # Returning non-zero sets the task's LastTaskResult=1, and the health check treats anything
    # other than 0/267011 as unhealthy - so a harmless overlap made the health check report this
    # security control as broken and masked whether it was genuinely failing.
    #
    # The mutex must be held on ANOTHER thread: a named mutex is re-entrant for the thread that
    # already owns it, so taking it on this thread would let WaitOne(0) succeed and never exercise
    # the contention path. A second runspace gives a real competing thread with no blind sleeps -
    # both handoffs are bounded waits on explicit signals.
    Reset-TestState
    $acquiredSignal = New-Object System.Threading.ManualResetEventSlim($false)
    $releaseSignal = New-Object System.Threading.ManualResetEventSlim($false)
    $mutexHolder = [powershell]::Create()
    $null = $mutexHolder.AddScript({
            param($Acquired, $Release)
            $heldMutex = New-Object System.Threading.Mutex($false, 'Global\WinServerSetup-RdpBlocker')
            try {
                if (-not $heldMutex.WaitOne(30000)) { return }
                $Acquired.Set()
                $null = $Release.Wait(60000)
                $heldMutex.ReleaseMutex()
            } finally { $heldMutex.Dispose() }
        }).AddArgument($acquiredSignal).AddArgument($releaseSignal)
    $holderHandle = $mutexHolder.BeginInvoke()
    try {
        Assert-True ($acquiredSignal.Wait(30000)) "The competing thread could not take the blocker mutex; the overlap case never ran."
        $overlapResult = Invoke-RdpBruteforceBlocker -ResolvedConfigPath "ignored.json"
        $overlapLogs = $script:LogLines -join "`n"
        Assert-Equal 0 $overlapResult ("A concurrent run must exit 0 so the scheduled task does not record a failure. Logs: {0}" -f ($script:LogLines -join " | "))
        Assert-True ($overlapLogs -match '\[INFO\].*already running') "A concurrent run must be logged at INFO."
        Assert-True ($overlapLogs -notmatch '\[ERROR\]') "A concurrent run must not be logged as an error."
        Assert-Equal 0 $script:FirewallRules.Count "A skipped concurrent run must not touch firewall state."
    } finally {
        $releaseSignal.Set()
        $null = $mutexHolder.EndInvoke($holderHandle)
        $mutexHolder.Dispose()
        $acquiredSignal.Dispose()
        $releaseSignal.Dispose()
    }

    Write-Host "PASS RDP blocker security behavior, scoped firewall rules, validation, failures, state bookmark, and benign concurrent-run exit code."
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
