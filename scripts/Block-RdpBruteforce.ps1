# Block-RdpBruteforce.ps1
# Defensive script: scans Windows Security Event Log for failed RDP logons and blocks abusive source IPs.
# It is designed to be run by Task Scheduler as SYSTEM or Administrator.

[CmdletBinding()]
param(
    [string]$ConfigPath = ""
)

$ErrorActionPreference = "Stop"

function Get-ScriptRootSafe {
    if ($PSScriptRoot) { return $PSScriptRoot }
    return Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Resolve-ProjectRoot {
    $root = Split-Path -Parent (Get-ScriptRootSafe)
    return $root
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "Config file not found: $Path" }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-LogLine {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Level = "INFO"
    )
    $projectRoot = Resolve-ProjectRoot
    $logDir = Join-Path $projectRoot "logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -LiteralPath (Join-Path $logDir "rdp-blocker.log") -Value $line -Encoding UTF8
}

function Convert-IPv4ToUInt32 {
    param([Parameter(Mandatory)][string]$IpAddress)
    $bytes = [System.Net.IPAddress]::Parse($IpAddress).GetAddressBytes()
    [Array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Test-IPv4InCidr {
    param(
        [Parameter(Mandatory)][string]$IpAddress,
        [Parameter(Mandatory)][string]$Cidr
    )

    if ($IpAddress -notmatch '^(\d{1,3}\.){3}\d{1,3}$') { return $false }
    $cidrMatch = [regex]::Match($Cidr, '^(.+)/(\d{1,2})$')
    if (-not $cidrMatch.Success) { return $IpAddress -eq $Cidr }

    $network = $cidrMatch.Groups[1].Value
    $prefix = [int]$cidrMatch.Groups[2].Value
    if ($prefix -lt 0 -or $prefix -gt 32) { return $false }

    $ipInt = Convert-IPv4ToUInt32 $IpAddress
    $netInt = Convert-IPv4ToUInt32 $network
    $mask = if ($prefix -eq 0) { [uint32]0 } else { [uint32]([uint32]::MaxValue -shl (32 - $prefix)) }

    return (($ipInt -band $mask) -eq ($netInt -band $mask))
}

function Test-IsWhitelisted {
    param(
        [Parameter(Mandatory)][string]$IpAddress,
        [string[]]$WhitelistCIDRs
    )
    foreach ($cidr in $WhitelistCIDRs) {
        if ([string]::IsNullOrWhiteSpace($cidr)) { continue }
        try {
            if (Test-IPv4InCidr -IpAddress $IpAddress -Cidr $cidr) { return $true }
        } catch {
            Write-LogLine ("Whitelist CIDR check failed for {0} / {1}: {2}" -f $IpAddress, $cidr, $_.Exception.Message) "WARN"
        }
    }
    return $false
}

function Format-RdpOffenderSummary {
    param(
        [Parameter(Mandatory)][object]$Offender
    )

    $logonTypes = @($Offender.LogonTypes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object { [int]$_ } -Unique)
    $targetUsers = @($Offender.TargetUserNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

    $logonTypesText = if ($logonTypes.Count -gt 0) { $logonTypes -join "," } else { "unknown" }
    $targetUsersText = if ($targetUsers.Count -gt 0) { $targetUsers -join "," } else { "unknown" }

    return "{0} failed login attempts; logon types: {1}; targeted users: {2}" -f $Offender.Count, $logonTypesText, $targetUsersText
}

function Get-FailedLogonSourceIPs {
    param(
        [int]$LookbackMinutes,
        [int]$Threshold
    )

    $startTime = (Get-Date).AddMinutes(-1 * $LookbackMinutes)
    $events = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4625; StartTime = $startTime } -ErrorAction SilentlyContinue
    $failedLogons = New-Object System.Collections.Generic.List[object]

    foreach ($evt in $events) {
        try {
            [xml]$xml = $evt.ToXml()
            $data = @{}
            foreach ($node in $xml.Event.EventData.Data) {
                if ($node.Name) { $data[$node.Name] = $node.'#text' }
            }

            $ip = $data['IpAddress']
            $logonType = $data['LogonType']
            $targetUserName = $data['TargetUserName']

            if ([string]::IsNullOrWhiteSpace($ip)) { continue }
            if ($ip -eq '-' -or $ip -eq '::1' -or $ip -eq '127.0.0.1') { continue }
            if ($ip -notmatch '^(\d{1,3}\.){3}\d{1,3}$') { continue }

            # LogonType 3 is Network, and LogonType 10 is RemoteInteractive (RDP).
            if (@('3', '10') -notcontains [string]$logonType) { continue }

            if ([string]::IsNullOrWhiteSpace($targetUserName) -or $targetUserName -eq '-') {
                $targetUserName = "unknown"
            }

            $failedLogons.Add([pscustomobject]@{
                IpAddress = $ip
                LogonType = [string]$logonType
                TargetUserName = [string]$targetUserName
            })
        } catch {
            Write-LogLine "Could not parse failed-logon event: $($_.Exception.Message)" "WARN"
        }
    }

    return $failedLogons |
        Group-Object -Property IpAddress |
        Where-Object { $_.Count -ge $Threshold } |
        ForEach-Object {
            $groupEvents = @($_.Group)
            [pscustomobject]@{
                Name = $_.Name
                IpAddress = $_.Name
                Count = $_.Count
                LogonTypes = @($groupEvents | ForEach-Object { $_.LogonType } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
                TargetUserNames = @($groupEvents | ForEach-Object { $_.TargetUserName } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
            }
        } |
        Sort-Object Count -Descending
}

function Get-CurrentRdpClientIPs {
    param([int[]]$Ports)
    $clients = New-Object System.Collections.Generic.List[string]
    foreach ($port in @($Ports | Where-Object { $_ -gt 0 } | Select-Object -Unique)) {
        try {
            Get-NetTCPConnection -State Established -LocalPort $port -ErrorAction SilentlyContinue | ForEach-Object {
                $remote = [string]$_.RemoteAddress
                if ($remote -match '^(\d{1,3}\.){3}\d{1,3}$' -and $remote -ne '127.0.0.1') {
                    $clients.Add($remote)
                }
            }
        } catch {
            Write-LogLine ("Could not enumerate RDP clients on port {0}: {1}" -f $port, $_.Exception.Message) "WARN"
        }
    }
    return @($clients | Select-Object -Unique)
}

function Block-IpAddress {
    param(
        [Parameter(Mandatory)][string]$IpAddress,
        [Parameter(Mandatory)][string]$RulePrefix,
        [Parameter(Mandatory)][int]$Count,
        [string[]]$LogonTypes = @(),
        [string[]]$TargetUserNames = @()
    )

    $displayName = "$RulePrefix $IpAddress"
    $existing = Get-NetFirewallRule -DisplayName $displayName -ErrorAction SilentlyContinue
    $offenderSummary = Format-RdpOffenderSummary ([pscustomobject]@{
        Count = $Count
        LogonTypes = @($LogonTypes)
        TargetUserNames = @($TargetUserNames)
    })

    if ($existing) {
        Write-LogLine "Already blocked: $IpAddress ($offenderSummary)."
        return
    }

    New-NetFirewallRule `
        -DisplayName $displayName `
        -Direction Inbound `
        -RemoteAddress $IpAddress `
        -Action Block `
        -Profile Any `
        -Enabled True | Out-Null

    Write-LogLine "Blocked $IpAddress after $offenderSummary."
}

try {
    $projectRoot = Resolve-ProjectRoot
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $projectRoot "WinServerSetup.config.json"
    }

    $config = Read-JsonFile -Path $ConfigPath
    $settings = $config.rdpBruteforceBlocker

    if (-not $settings.enabled) {
        Write-LogLine "RDP blocker is disabled in config."
        exit 0
    }

    $threshold = [int]$settings.threshold
    $lookbackMinutes = [int]$settings.lookbackMinutes
    $rulePrefix = [string]$settings.rulePrefix
    $whitelist = @($settings.whitelistCIDRs)
    $rdpPorts = @()
    try {
        if ($config.rdp.newPort) { $rdpPorts += [int]$config.rdp.newPort }
        if ($config.rdp.oldPort) { $rdpPorts += [int]$config.rdp.oldPort }
    } catch {
        Write-LogLine "Could not read configured RDP ports: $($_.Exception.Message)" "WARN"
    }
    $currentRdpClients = @(Get-CurrentRdpClientIPs -Ports $rdpPorts)
    foreach ($client in $currentRdpClients) {
        Write-LogLine "Current established RDP client detected and protected from blocking: $client"
    }

    $offenders = Get-FailedLogonSourceIPs -LookbackMinutes $lookbackMinutes -Threshold $threshold

    foreach ($offender in $offenders) {
        $ip = $offender.Name
        $offenderSummary = Format-RdpOffenderSummary $offender
        if ($currentRdpClients -contains $ip) {
            Write-LogLine "Skipped active RDP client IP: $ip ($offenderSummary)"
            continue
        }
        if (Test-IsWhitelisted -IpAddress $ip -WhitelistCIDRs $whitelist) {
            Write-LogLine "Skipped whitelisted IP: $ip ($offenderSummary)"
            continue
        }
        Block-IpAddress -IpAddress $ip -RulePrefix $rulePrefix -Count $offender.Count -LogonTypes $offender.LogonTypes -TargetUserNames $offender.TargetUserNames
    }

    if (-not $offenders) {
        Write-LogLine "No abusive IPs found."
    }
}
catch {
    Write-LogLine "Error: $($_.Exception.Message)" "ERROR"
    exit 1
}
