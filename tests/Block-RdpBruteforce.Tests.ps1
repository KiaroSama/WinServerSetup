param()

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $projectRoot "scripts\Block-RdpBruteforce.ps1"
$testConfigPath = Join-Path $env:TEMP ("WinServerSetup-rdp-blocker-test-{0}.json" -f ([guid]::NewGuid().ToString("N")))

class TestSecurityEvent {
    [string]$Xml

    TestSecurityEvent([string]$Xml) {
        $this.Xml = $Xml
    }

    [string] ToXml() {
        return $this.Xml
    }
}

function New-TestFailedLogonEvent {
    param(
        [Parameter(Mandatory)][string]$IpAddress,
        [Parameter(Mandatory)][string]$LogonType,
        [Parameter(Mandatory)][string]$TargetUserName
    )

    $xml = @"
<Event>
  <EventData>
    <Data Name="IpAddress">$IpAddress</Data>
    <Data Name="LogonType">$LogonType</Data>
    <Data Name="TargetUserName">$TargetUserName</Data>
  </EventData>
</Event>
"@
    return [TestSecurityEvent]::new($xml)
}

$script:BlockedRules = New-Object System.Collections.Generic.List[object]
$script:LogLines = New-Object System.Collections.Generic.List[string]

function Get-WinEvent {
    param($FilterHashtable, $ErrorAction)
    return @(
        New-TestFailedLogonEvent -IpAddress "203.0.113.88" -LogonType "3" -TargetUserName "alice"
        New-TestFailedLogonEvent -IpAddress "203.0.113.88" -LogonType "10" -TargetUserName "bob"
    )
}

function Get-NetTCPConnection {
    param($State, $LocalPort, $ErrorAction)
    return @()
}

function Get-NetFirewallRule {
    param($DisplayName, $ErrorAction)
    return $null
}

function New-NetFirewallRule {
    param(
        [string]$DisplayName,
        [string]$Direction,
        [string]$RemoteAddress,
        [string]$Action,
        [string]$Profile,
        [object]$Enabled
    )
    $script:BlockedRules.Add([pscustomobject]@{
        DisplayName = $DisplayName
        RemoteAddress = $RemoteAddress
        Direction = $Direction
        Action = $Action
        Profile = $Profile
        Enabled = $Enabled
    })
    return [pscustomobject]@{ DisplayName = $DisplayName }
}

function Add-Content {
    param(
        [string]$LiteralPath,
        [string]$Value,
        [string]$Encoding
    )
    $script:LogLines.Add($Value)
}

try {
    @"
{
  "rdp": {
    "newPort": 5801,
    "oldPort": 3389
  },
  "rdpBruteforceBlocker": {
    "enabled": true,
    "threshold": 2,
    "lookbackMinutes": 30,
    "rulePrefix": "UnitTest RDP Block",
    "whitelistCIDRs": []
  }
}
"@ | Set-Content -LiteralPath $testConfigPath -Encoding UTF8

    . $scriptPath -ConfigPath $testConfigPath

    if ($script:BlockedRules.Count -ne 1) {
        throw "Expected one firewall block from combined LogonType 3 and 10 failures, got $($script:BlockedRules.Count). Logs:`n$($script:LogLines -join "`n")"
    }

    $blockedRule = $script:BlockedRules[0]
    if ($blockedRule.RemoteAddress -ne "203.0.113.88") {
        throw "Expected blocked IP 203.0.113.88, got $($blockedRule.RemoteAddress)."
    }

    $joinedLogs = $script:LogLines -join "`n"
    foreach ($expected in @("203.0.113.88", "2 failed", "3,10", "alice,bob")) {
        if ($joinedLogs -notlike "*$expected*") {
            throw "Expected blocker log output to contain '$expected'. Logs:`n$joinedLogs"
        }
    }

    Write-Host "PASS Block-RdpBruteforce detects combined LogonType 3/10 failures and logs usernames."
}
finally {
    Remove-Item -LiteralPath $testConfigPath -Force -ErrorAction SilentlyContinue
}
