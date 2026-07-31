<#
    Behavioral regression tests for runtime defects in scripts\Block-RdpBruteforce.ps1 that
    source-text assertions cannot catch. Each case below fails against the pre-fix implementation:

      R1  -FilterXPath was built with the XML entity '&gt;', which the Windows Event Log
          query parser rejects ("The specified query is invalid"), so every incremental run
          after the first errored out and blocked nothing.
      R2  Get-WinEvent reports an empty result set as an error; with -ErrorAction Stop a quiet
          server made the blocker exit non-zero and fail the whole setup step.
      R3  The rolling window compared [datetime]'...Z' (which casts to Kind=Local) against a
          Kind=Utc cutoff, so the window was off by the machine's UTC offset - too wide east of
          UTC and, west of UTC, discarding every event so nothing was ever blocked.
      R4  Windows PowerShell 5.1 unwraps a single-element array returned from a function, so a
          run that saw exactly one new event took the wrong branch / never advanced the bookmark.
#>
# -ScriptPath targets an alternate copy of the blocker so these tests can be replayed against a
# deliberately defective build to prove they still fail. CI and local runs use the default.
#
# These tests mock Windows-only cmdlets by shadowing them with functions, which is the whole point
# of the harness: the mock signatures must mirror the real cmdlets (including parameters this file
# never reads) so the code under test binds exactly as it does in production.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Cmdlets are shadowed deliberately to mock Windows-only APIs.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock signatures mirror the real cmdlets so parameter binding matches production.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', '', Justification = 'Mock parameter names must match the real cmdlet parameter names.')]
param([string]$ScriptPath = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = if ([string]::IsNullOrWhiteSpace($ScriptPath)) { Join-Path $projectRoot "scripts\Block-RdpBruteforce.ps1" } else { $ScriptPath }
. $scriptPath

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw ("{0} Expected={1}; Actual={2}" -f $Message, $Expected, $Actual) }
}

$testRoot = Join-Path $env:TEMP ("WinServerSetup-RdpRuntime-{0}" -f ([guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

# ---------------------------------------------------------------- shared mock harness
$script:Config = $null
$script:Events = @()
$script:Queries = New-Object System.Collections.Generic.List[string]
$script:ThrowNoMatchingEvents = $false
$script:FirewallRules = New-Object System.Collections.Generic.List[object]
$script:LogLines = New-Object System.Collections.Generic.List[string]

function Read-JsonFile { param([string]$Path) return $script:Config }
function Write-LogLine {
    param([string]$Message, [string]$Level = "INFO")
    $script:LogLines.Add("[$Level] $Message") | Out-Null
}
function New-TestEvent {
    param([long]$RecordId, [string]$IpAddress, [datetime]$TimeCreated)
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
    if ($script:ThrowNoMatchingEvents) {
        $record = New-Object System.Management.Automation.ErrorRecord(
            (New-Object System.Exception "No events were found that match the specified selection criteria."),
            'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand',
            [System.Management.Automation.ErrorCategory]::ObjectNotFound,
            $null)
        throw $record
    }
    if ($FilterXPath) { $script:Queries.Add([string]$FilterXPath) | Out-Null }
    if ($MaxEvents) { return @($script:Events | Sort-Object RecordId -Descending | Select-Object -First 1) }
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
    param([string]$DisplayName, [string]$Direction, [string]$RemoteAddress, [string]$Action,
        [string]$Profile, [object]$Enabled, [string]$Protocol, [object]$LocalPort, [string]$Description, $ErrorAction)
    $rule = [pscustomobject]@{
        DisplayName = $DisplayName; Direction = $Direction; RemoteAddress = $RemoteAddress
        Action = $Action; Profile = $Profile; Enabled = [string]$Enabled; Protocol = $Protocol
        LocalPort = @($LocalPort); Description = $Description
    }
    $script:FirewallRules.Add($rule) | Out-Null
    return $rule
}
function Remove-NetFirewallRule {
    [CmdletBinding()] param([Parameter(ValueFromPipeline)]$InputObject, [string]$DisplayName)
    process {
        $name = if ($InputObject) { [string]$InputObject.DisplayName } else { $DisplayName }
        for ($i = $script:FirewallRules.Count - 1; $i -ge 0; $i--) {
            if ($script:FirewallRules[$i].DisplayName -eq $name) { $script:FirewallRules.RemoveAt($i) }
        }
    }
}
$statePath = Join-Path $testRoot "state.json"
function Reset-TestState {
    param([int]$Threshold = 1, [int]$LookbackMinutes = 30)
    $script:Config = [pscustomobject]@{
        rdp = [pscustomobject]@{ newPort = 5801; oldPort = 3389 }
        rdpBruteforceBlocker = [pscustomobject]@{
            enabled = $true; threshold = $Threshold; lookbackMinutes = $LookbackMinutes
            taskIntervalMinutes = 1; rulePrefix = "RuntimeTest RDP Block"; whitelistCIDRs = @()
            includeNetworkLogonType3 = $false; blockAllInbound = $false; permanentBlock = $false
            ruleRetentionDays = 30; logMaxBytes = 65536; logRetentionFiles = 2; statePath = $statePath
        }
    }
    $script:Events = @()
    $script:Queries.Clear()
    $script:ThrowNoMatchingEvents = $false
    $script:FirewallRules.Clear()
    $script:LogLines.Clear()
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
}

try {
    # -- R1: the incremental query must be raw XPath the real parser accepts -----------------
    Reset-TestState
    $script:Events = @(New-TestEvent 100 "203.0.113.5" (Get-Date))
    Assert-Equal 0 (Invoke-RdpBruteforceBlocker -ResolvedConfigPath "ignored.json") "Seed run failed."
    $script:Events += New-TestEvent 101 "203.0.113.5" (Get-Date)
    Assert-Equal 0 (Invoke-RdpBruteforceBlocker -ResolvedConfigPath "ignored.json") "Incremental run failed."

    $incremental = @($script:Queries | Where-Object { $_ -match 'EventRecordID' })
    Assert-True ($incremental.Count -gt 0) "No incremental EventRecordID query was ever issued."
    foreach ($query in $incremental) {
        Assert-True ($query -notmatch '&gt;') "FilterXPath must use raw '>', not the XML entity '&gt;': $query"
        # Prove the real Windows event-log parser accepts it. The Application log is readable
        # without elevation; a malformed query throws before any access check.
        try {
            $null = Microsoft.PowerShell.Diagnostics\Get-WinEvent -LogName Application `
                -FilterXPath ($query -replace 'EventID=4625', 'EventID=1') -MaxEvents 1 -ErrorAction Stop
        } catch {
            if ([string]$_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') {
                throw "Real Get-WinEvent rejected the generated query '$query': $($_.Exception.Message)"
            }
        }
    }

    # -- R2: an empty Security window is healthy, not a task failure ------------------------
    Reset-TestState
    $script:ThrowNoMatchingEvents = $true
    Assert-Equal 0 (Invoke-RdpBruteforceBlocker -ResolvedConfigPath "ignored.json") `
        ("An empty event window must succeed. Logs: {0}" -f ($script:LogLines -join " | "))
    $logText = $script:LogLines -join "`n"
    Assert-True ($logText -notmatch '\[ERROR\]') "An empty window must not be logged as an error."
    Assert-True ($logText -match 'No abusive IPs found') "An empty window must report a clean result."

    # -- R3: the rolling window is UTC-correct regardless of the machine's UTC offset --------
    # Seeded event is 45 minutes old; lookback is 30 minutes, so it must be dropped and no
    # rule created. Pre-fix, the local-kind cast widened/shifted the window by the UTC offset.
    Reset-TestState -Threshold 1 -LookbackMinutes 30
    $staleUtc = (Get-Date).ToUniversalTime().AddMinutes(-45)
    [pscustomobject]@{
        Version = 1; LastRecordId = 500
        Events = @([pscustomobject]@{
            RecordId = 500; TimeCreatedUtc = $staleUtc.ToString('o')
            IpAddress = "203.0.113.77"; LogonType = "10"; TargetUserName = "victim"
        })
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8

    $script:Events = @(New-TestEvent 500 "203.0.113.77" $staleUtc.ToLocalTime())
    Assert-Equal 0 (Invoke-RdpBruteforceBlocker -ResolvedConfigPath "ignored.json") "Stale-window run failed."
    Assert-Equal 0 $script:FirewallRules.Count `
        ("An event older than lookbackMinutes must leave the rolling window (UTC offset {0})." -f [TimeZoneInfo]::Local.BaseUtcOffset)

    # -- R4: exactly one new event still advances the bookmark (5.1 array unwrapping) --------
    Reset-TestState -Threshold 5
    $script:Events = @(New-TestEvent 900 "203.0.113.90" (Get-Date))
    Assert-Equal 0 (Invoke-RdpBruteforceBlocker -ResolvedConfigPath "ignored.json") "Single-event run failed."
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 900 ([long]$state.LastRecordId) `
        "A single new event must advance LastRecordId on both PowerShell 5.1 and 7."

    Write-Host "PASS RDP blocker runtime: valid XPath, empty-window tolerance, UTC-correct rolling window, single-event bookmark."
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
