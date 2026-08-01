<#
    Regression tests for audit findings M-02 and M-05 in scripts\Block-RdpBruteforce.ps1.

    M-02  Get-RdpAttributedEvidence returned a HashSet with a bare `return`. PowerShell
          enumerates a collection on output, so a set holding exactly ONE address collapsed
          to a [string] and the caller's `.Contains($ip)` became String.Contains - a
          SUBSTRING test. With one attributed client 120.3.4.5 on record, 20.3.4.5 matched
          and an innocent address was firewall-blocked. Reproduced on 5.1 and 7.

    M-05  A LogonType 3 (NLA) failure was attributed to RDP when the address appeared
          ANYWHERE in the lookback window. A NAT gateway that legitimately used RDP an hour
          ago therefore donated RDP attribution to unrelated SMB failures from the same
          address. Attribution is now bounded by attributionWindowSeconds.
#>
# -ScriptPath targets an alternate copy of the blocker so these tests can be replayed against a
# deliberately defective build to prove they still fail. CI and local runs use the default.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Cmdlets are shadowed deliberately to mock Windows-only APIs.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock signatures mirror the real cmdlets so parameter binding matches production.')]
param([string]$ScriptPath = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = if ([string]::IsNullOrWhiteSpace($ScriptPath)) { Join-Path $projectRoot "scripts\Block-RdpBruteforce.ps1" } else { $ScriptPath }
. $scriptPath

. (Join-Path $PSScriptRoot '_Common.ps1')

$script:RdpEvents = @()
$script:LogLines = New-Object System.Collections.Generic.List[string]
function Write-LogLine {
    param([string]$Message, [string]$Level = "INFO")
    $script:LogLines.Add("[$Level] $Message") | Out-Null
}
function Get-WinEvent {
    param($FilterHashtable, $LogName, $FilterXPath, $MaxEvents, $ErrorAction)
    if ($script:RdpEvents.Count -eq 0) {
        throw (New-Object System.Management.Automation.ErrorRecord(
                (New-Object System.Exception "No events were found."),
                'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand',
                [System.Management.Automation.ErrorCategory]::ObjectNotFound, $null))
    }
    return @($script:RdpEvents)
}

# An RdpCoreTS 131/140 record: the client address is not in a fixed field, so production
# scans every EventData value for an IPv4 literal. The fixture mirrors that shape.
function New-RdpEvidenceEvent {
    param([string]$IpAddress, [datetime]$TimeCreatedUtc)
    $xml = @"
<Event>
  <System><EventRecordID>1</EventRecordID></System>
  <EventData><Data Name="ClientIP">$IpAddress</Data></EventData>
</Event>
"@
    $item = [pscustomobject]@{ TimeCreated = $TimeCreatedUtc; Xml = $xml }
    $item | Add-Member -MemberType ScriptMethod -Name ToXml -Value { return $this.Xml }
    return $item
}

# A Security 4625 failed logon at LogonType 3 - the shape NLA produces.
function New-FailedLogonEvent {
    param([string]$IpAddress, [datetime]$TimeCreatedUtc, [string]$LogonType = '3')
    $xml = @"
<Event>
  <System><EventRecordID>50</EventRecordID></System>
  <EventData>
    <Data Name="IpAddress">$IpAddress</Data>
    <Data Name="LogonType">$LogonType</Data>
    <Data Name="TargetUserName">victim</Data>
  </EventData>
</Event>
"@
    $item = [pscustomobject]@{ RecordId = 50; TimeCreated = $TimeCreatedUtc; Xml = $xml }
    $item | Add-Member -MemberType ScriptMethod -Name ToXml -Value { return $this.Xml }
    return $item
}

$now = (Get-Date).ToUniversalTime()

# ---- M-02: the evidence map must keep its type and match exactly at 0, 1 and n entries. ----
foreach ($case in @(
        @{ Ips = @(); Label = 'empty' },
        @{ Ips = @('120.3.4.5'); Label = 'single' },
        @{ Ips = @('120.3.4.5', '8.8.8.8'); Label = 'multiple' })) {

    $script:RdpEvents = @($case.Ips | ForEach-Object { New-RdpEvidenceEvent -IpAddress $_ -TimeCreatedUtc $now })
    $evidence = Get-RdpAttributedEvidence -LookbackMinutes 30

    Assert-True ($null -ne $evidence) "M-02 ($($case.Label)): the evidence map must never come back as `$null."
    Assert-True ($evidence.GetType().Name -like 'Dictionary*') `
        "M-02 ($($case.Label)): the contract must stay a Dictionary, not collapse to a scalar. Got $($evidence.GetType().Name)."
    Assert-Equal $case.Ips.Count $evidence.Count "M-02 ($($case.Label)): every distinct address must be retained."
}

# The exact defect: one attributed address, and a shorter address that is its suffix.
$script:RdpEvents = @(New-RdpEvidenceEvent -IpAddress '120.3.4.5' -TimeCreatedUtc $now)
$evidence = Get-RdpAttributedEvidence -LookbackMinutes 30
Assert-Equal $false (Test-RdpTimeCorrelated -Evidence $evidence -IpAddress '20.3.4.5' -WhenUtc $now -WindowSeconds 120) `
    "M-02: 20.3.4.5 must NOT match a map holding only 120.3.4.5 - a substring hit here blocks an innocent address."
Assert-Equal $true (Test-RdpTimeCorrelated -Evidence $evidence -IpAddress '120.3.4.5' -WhenUtc $now -WindowSeconds 120) `
    "M-02: the exact address must still correlate."

# End to end through the converter, which is where the substring test actually bit.
$innocent = Convert-FailedLogonEvent (New-FailedLogonEvent -IpAddress '20.3.4.5' -TimeCreatedUtc $now) $false $evidence 120
Assert-Equal $null $innocent "M-02: a LogonType 3 failure from 20.3.4.5 must not be attributed to RDP by substring."
$genuine = Convert-FailedLogonEvent (New-FailedLogonEvent -IpAddress '120.3.4.5' -TimeCreatedUtc $now) $false $evidence 120
Assert-True ($null -ne $genuine) "M-02: the genuine NLA offender must still be counted."
Assert-Equal 'Network+RdpChannel' $genuine.Evidence "M-02: attribution must be recorded as RDP-channel evidence."

# ---- M-05: attribution must be bounded in time, not 'anywhere in the lookback'. ----
$script:RdpEvents = @(New-RdpEvidenceEvent -IpAddress '203.0.113.9' -TimeCreatedUtc $now.AddMinutes(-25))
$evidence = Get-RdpAttributedEvidence -LookbackMinutes 30

# Same address, same lookback window, but 25 minutes later: a shared NAT/SMB failure.
$distant = Convert-FailedLogonEvent (New-FailedLogonEvent -IpAddress '203.0.113.9' -TimeCreatedUtc $now) $false $evidence 120
Assert-Equal $null $distant `
    "M-05: RDP evidence 25 minutes away must not attribute an unrelated LogonType 3 failure inside the same lookback."

# Same address, close in time: genuine NLA brute force.
$near = Convert-FailedLogonEvent (New-FailedLogonEvent -IpAddress '203.0.113.9' -TimeCreatedUtc $now.AddMinutes(-25).AddSeconds(30)) $false $evidence 120
Assert-True ($null -ne $near) "M-05: RDP evidence 30s away must still attribute the failure."

# The RDP record may land either side of the 4625 for the same attempt.
$before = Convert-FailedLogonEvent (New-FailedLogonEvent -IpAddress '203.0.113.9' -TimeCreatedUtc $now.AddMinutes(-25).AddSeconds(-30)) $false $evidence 120
Assert-True ($null -ne $before) "M-05: correlation must be symmetric - RDP evidence after the failure counts too."

# Exact window boundaries.
$anchor = $now.AddMinutes(-25)
Assert-Equal $true  (Test-RdpTimeCorrelated -Evidence $evidence -IpAddress '203.0.113.9' -WhenUtc $anchor.AddSeconds(120) -WindowSeconds 120) "M-05: exactly at the window edge must correlate."
Assert-Equal $false (Test-RdpTimeCorrelated -Evidence $evidence -IpAddress '203.0.113.9' -WhenUtc $anchor.AddSeconds(121) -WindowSeconds 120) "M-05: one second past the edge must not correlate."

# An address with no RDP evidence at all is never attributed.
Assert-Equal $false (Test-RdpTimeCorrelated -Evidence $evidence -IpAddress '198.51.100.7' -WhenUtc $anchor -WindowSeconds 120) "M-05: an address absent from the map must never correlate."

# LogonType 10 stays unambiguous and needs no correlation.
$interactive = Convert-FailedLogonEvent (New-FailedLogonEvent -IpAddress '198.51.100.7' -TimeCreatedUtc $now -LogonType '10') $false $evidence 120
Assert-True ($null -ne $interactive) "M-05: LogonType 10 is unambiguously RDP and must not require correlation."
Assert-Equal 'RemoteInteractive' $interactive.Evidence "M-05: LogonType 10 evidence must stay RemoteInteractive."

# The explicit opt-in still counts every network logon, correlated or not.
$optIn = Convert-FailedLogonEvent (New-FailedLogonEvent -IpAddress '198.51.100.7' -TimeCreatedUtc $now) $true $evidence 120
Assert-True ($null -ne $optIn) "M-05: includeNetworkLogonType3 must still count uncorrelated network logons."
Assert-Equal 'Network(opt-in)' $optIn.Evidence "M-05: opt-in evidence must be distinguishable from RDP-channel evidence."

# ---- The configured window is validated and bounded. ----
function New-BlockerSettings {
    param($Window)
    return [pscustomobject]@{
        rdp = [pscustomobject]@{ newPort = 5801 }
        rdpBruteforceBlocker = [pscustomobject]@{
            enabled = $true; threshold = 7; lookbackMinutes = 30; taskIntervalMinutes = 1
            rulePrefix = 'WinServerSetup RDP Block'; ruleRetentionDays = 30
            logMaxBytes = 5242880; logRetentionFiles = 3; whitelistCIDRs = @('127.0.0.1/32')
            attributionWindowSeconds = $Window
        }
    }
}
Assert-True ($null -ne (Assert-RdpBlockerSettings (New-BlockerSettings 120))) "M-05: a valid window must be accepted."
foreach ($bad in @(0, -1, 3601)) {
    $rejected = $false
    try { Assert-RdpBlockerSettings (New-BlockerSettings $bad) | Out-Null } catch { $rejected = $true }
    Assert-Equal $true $rejected "M-05: attributionWindowSeconds=$bad must be rejected by validation."
}

Write-Host "PASS M-02 exact-address attribution (no substring match at any map size) and M-05 time-bounded LogonType 3 correlation with a validated window."
