# Block-RdpBruteforce.ps1
# Blocks repeated failed RemoteInteractive logons with managed, RDP-scoped firewall rules.

[CmdletBinding()]
param([string]$ConfigPath = "")

$ErrorActionPreference = "Stop"
$script:BlockerLogMaxBytes = 5242880
$script:BlockerLogRetentionFiles = 3

function Get-ScriptRootSafe {
    if ($PSScriptRoot) { return $PSScriptRoot }
    return Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Resolve-ProjectRoot {
    return Split-Path -Parent (Get-ScriptRootSafe)
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Config file not found: $Path" }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-LogLine {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL")][string]$Level = "INFO"
    )

    $logDir = Join-Path (Resolve-ProjectRoot) "logs"
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $logPath = Join-Path $logDir "rdp-blocker.log"
    if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -ge $script:BlockerLogMaxBytes) {
        for ($index = $script:BlockerLogRetentionFiles - 1; $index -ge 1; $index--) {
            $source = "$logPath.$index"
            if (Test-Path -LiteralPath $source) {
                Move-Item -LiteralPath $source -Destination "$logPath.$($index + 1)" -Force
            }
        }
        Move-Item -LiteralPath $logPath -Destination "$logPath.1" -Force
    }

    $line = "[{0}] [{1}] [RDP-BLOCKER] {2}" -f (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss 'UTC'"), $Level, $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Test-ValidIPv4 {
    param([Parameter(Mandatory)][string]$IpAddress)
    $parsed = $null
    return [System.Net.IPAddress]::TryParse($IpAddress, [ref]$parsed) -and
        $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Convert-IPv4ToUInt32 {
    param([Parameter(Mandatory)][string]$IpAddress)
    if (-not (Test-ValidIPv4 $IpAddress)) { throw "Invalid IPv4 address: $IpAddress" }
    $bytes = [System.Net.IPAddress]::Parse($IpAddress).GetAddressBytes()
    [Array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Test-ValidIPv4Cidr {
    param([Parameter(Mandatory)][string]$Cidr)
    $parts = $Cidr -split '/', 2
    if (-not (Test-ValidIPv4 $parts[0])) { return $false }
    if ($parts.Count -eq 1) { return $true }
    $prefix = 0
    return [int]::TryParse($parts[1], [ref]$prefix) -and $prefix -ge 0 -and $prefix -le 32
}

function Test-IPv4InCidr {
    param(
        [Parameter(Mandatory)][string]$IpAddress,
        [Parameter(Mandatory)][string]$Cidr
    )
    if (-not (Test-ValidIPv4 $IpAddress) -or -not (Test-ValidIPv4Cidr $Cidr)) { return $false }
    $parts = $Cidr -split '/', 2
    if ($parts.Count -eq 1) { return $IpAddress -eq $parts[0] }
    $prefix = [int]$parts[1]
    $mask = if ($prefix -eq 0) { [uint32]0 } else { [uint32]([uint32]::MaxValue -shl (32 - $prefix)) }
    return (((Convert-IPv4ToUInt32 $IpAddress) -band $mask) -eq ((Convert-IPv4ToUInt32 $parts[0]) -band $mask))
}

function Test-IsWhitelisted {
    param([string]$IpAddress, [string[]]$WhitelistCIDRs)
    foreach ($cidr in $WhitelistCIDRs) {
        if (Test-IPv4InCidr -IpAddress $IpAddress -Cidr $cidr) { return $true }
    }
    return $false
}

function Assert-RdpBlockerSettings {
    param([Parameter(Mandatory)]$Config)

    $settings = $Config.rdpBruteforceBlocker
    if ($null -eq $settings) { throw "Missing rdpBruteforceBlocker configuration." }
    if ([int]$settings.threshold -lt 1) { throw "rdpBruteforceBlocker.threshold must be at least 1." }
    if ([int]$settings.lookbackMinutes -lt 1 -or [int]$settings.lookbackMinutes -gt 1440) { throw "rdpBruteforceBlocker.lookbackMinutes must be between 1 and 1440." }
    if ([int]$settings.taskIntervalMinutes -lt 1 -or [int]$settings.taskIntervalMinutes -gt 60) { throw "rdpBruteforceBlocker.taskIntervalMinutes must be between 1 and 60." }
    if ([string]::IsNullOrWhiteSpace([string]$settings.rulePrefix)) { throw "rdpBruteforceBlocker.rulePrefix must not be empty." }
    if ([int]$Config.rdp.newPort -lt 1 -or [int]$Config.rdp.newPort -gt 65535) { throw "rdp.newPort must be between 1 and 65535." }
    if ([int]$settings.ruleRetentionDays -lt 1) { throw "rdpBruteforceBlocker.ruleRetentionDays must be at least 1." }
    if ([long]$settings.logMaxBytes -lt 1024) { throw "rdpBruteforceBlocker.logMaxBytes must be at least 1024." }
    if ([int]$settings.logRetentionFiles -lt 1 -or [int]$settings.logRetentionFiles -gt 20) { throw "rdpBruteforceBlocker.logRetentionFiles must be between 1 and 20." }
    # M-05: the LogonType 3 correlation window. Too wide and a NAT gateway's old RDP session
    # attributes unrelated SMB failures; too narrow and genuine NLA attempts are missed.
    if ([int]$settings.attributionWindowSeconds -lt 1 -or [int]$settings.attributionWindowSeconds -gt 3600) { throw "rdpBruteforceBlocker.attributionWindowSeconds must be between 1 and 3600." }
    foreach ($cidr in @($settings.whitelistCIDRs)) {
        if ([string]::IsNullOrWhiteSpace([string]$cidr) -or -not (Test-ValidIPv4Cidr ([string]$cidr))) {
            throw "Invalid IPv4 whitelist entry: $cidr"
        }
    }
    return $settings
}

function ConvertTo-UtcDateTime {
    param([Parameter(Mandatory)][string]$Value)
    # Round-trip ('o') strings carry a 'Z'. A plain [datetime] cast converts them to Kind=Local,
    # which then compares wrongly against a Kind=Utc cutoff. RoundtripKind preserves Kind=Utc.
    return [datetime]::Parse(
        $Value,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

function Invoke-SecurityLogQuery {
    param([Parameter(Mandatory)][hashtable]$Parameters)
    try {
        return @(Get-WinEvent @Parameters -ErrorAction Stop)
    } catch {
        # Get-WinEvent raises an error for an empty result set. An empty window is a normal,
        # healthy state - only a genuine read failure may fail the task.
        if ([string]$_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { return @() }
        throw
    }
}

$script:RdpChannel = 'Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational'

function Get-RdpAttributedEvidence {
    <#
        Returns the set of client IPv4 addresses that Remote Desktop itself reports contacting
        this host inside the lookback window.

        WHY THIS EXISTS: with Network Level Authentication - the default on current Windows and
        Windows Server - a failed RDP sign-in is written to Security 4625 as LogonType 3
        (Network), NOT LogonType 10 (RemoteInteractive), because NLA authenticates before any
        interactive session exists. Matching only LogonType 10 therefore misses the common case
        entirely. But LogonType 3 on its own is ambiguous (SMB and other network logons produce
        it too), so counting every type 3 failure invites false positives.

        RdpCoreTS is the RDP-specific evidence that resolves it: event 140 is a failed RDP
        authentication and event 131 is an accepted RDP TCP connection, both carrying the client
        address. An address seen here is genuinely talking RDP, so its type 3 failures can be
        attributed to RDP with confidence.

        Field names differ across builds, so every EventData value is scanned for an IPv4
        literal instead of depending on one property name.

        M-02: this used to be a HashSet returned bare. PowerShell ENUMERATES a HashSet on
        output, so a set holding exactly ONE address collapsed to a [string] - and the
        caller's `.Contains($ip)` silently became String.Contains, a SUBSTRING test. With
        one attributed client 120.3.4.5 on record, `.Contains('20.3.4.5')` returned $true
        and an innocent address was firewall-blocked. Verified on both 5.1 and 7.

        The fix is the TYPE: PowerShell passes an IDictionary through as a single object
        instead of enumerating it, so the contract is identical at 0, 1 and n entries, and
        `ContainsKey` is an exact lookup rather than a substring test. The unary comma on
        each `return` below is belt-and-braces only - it is not what closes this finding.
    #>
    param([int]$LookbackMinutes, [int]$MaxEvents = 20000)

    # M-05: keep a UTC timestamp per address, not just the address. Attribution then requires
    # RDP evidence NEAR the failed logon in time, instead of the address having appeared
    # anywhere in the whole lookback window.
    $addresses = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[datetime]]'
    $events = @()
    try {
        $events = Invoke-SecurityLogQuery @{
            FilterHashtable = @{
                LogName   = $script:RdpChannel
                Id        = @(131, 140)
                StartTime = (Get-Date).AddMinutes(-$LookbackMinutes)
            }
            MaxEvents = $MaxEvents
        }
    } catch {
        # The channel can be absent or disabled. That is not fatal: fall back to LogonType 10
        # only, and say so, because the NLA case will be invisible until it is enabled.
        Write-LogLine ("RDP-specific channel unavailable ({0}); Logon Type 3 attribution is disabled. Enable '{1}' or set includeNetworkLogonType3 to catch NLA-mode attacks." -f $_.Exception.Message, $script:RdpChannel) "WARNING"
        return ,$addresses
    }

    foreach ($rdpEvent in $events) {
        try {
            $whenUtc = $rdpEvent.TimeCreated.ToUniversalTime()
            [xml]$xml = $rdpEvent.ToXml()
            foreach ($node in $xml.Event.EventData.Data) {
                $text = [string]$node.'#text'
                if ([string]::IsNullOrWhiteSpace($text)) { continue }
                foreach ($match in [regex]::Matches($text, '\b\d{1,3}(?:\.\d{1,3}){3}\b')) {
                    $candidate = $match.Value
                    if (-not (Test-ValidIPv4 $candidate) -or $candidate -eq '127.0.0.1') { continue }
                    if (-not $addresses.ContainsKey($candidate)) {
                        $addresses[$candidate] = New-Object 'System.Collections.Generic.List[datetime]'
                    }
                    $addresses[$candidate].Add($whenUtc)
                }
            }
        } catch { $null = $_ }
    }
    return ,$addresses
}

function Test-RdpTimeCorrelated {
    <#
        M-05: does RDP itself have evidence for THIS EXACT address close in time to this
        failed logon?

        Two separate defects are closed here. Lookup is `ContainsKey` on a Dictionary, which
        is exact - the old code called `.Contains()` on a value that could arrive as a bare
        [string], making it a substring test (M-02). And correlation is bounded by a window
        rather than "the address appeared somewhere in the lookback", so a NAT gateway that
        legitimately used RDP an hour ago no longer donates RDP attribution to unrelated SMB
        failures from the same address.
    #>
    param(
        $Evidence,
        [Parameter(Mandatory)][string]$IpAddress,
        [Parameter(Mandatory)][datetime]$WhenUtc,
        [Parameter(Mandatory)][int]$WindowSeconds
    )
    if ($null -eq $Evidence) { return $false }
    if (-not ($Evidence -is [System.Collections.IDictionary]) -and $Evidence.GetType().Name -notlike 'Dictionary*') { return $false }
    if (-not $Evidence.ContainsKey($IpAddress)) { return $false }
    $windowTicks = [timespan]::FromSeconds($WindowSeconds).Ticks
    foreach ($stamp in $Evidence[$IpAddress]) {
        # Absolute difference: RdpCoreTS and Security are written by different providers, so
        # the RDP evidence can land either side of the 4625 for the same attempt.
        if ([math]::Abs(($WhenUtc - $stamp).Ticks) -le $windowTicks) { return $true }
    }
    return $false
}

function Convert-FailedLogonEvent {
    param(
        [Parameter(Mandatory)]$LogEvent,
        [bool]$IncludeNetworkLogonType3,
        $RdpEvidence = $null,
        [int]$AttributionWindowSeconds = 120
    )

    [xml]$xml = $LogEvent.ToXml()
    $data = @{}
    foreach ($node in $xml.Event.EventData.Data) {
        if ($node.Name) { $data[$node.Name] = $node.'#text' }
    }
    $ip = [string]$data.IpAddress
    $logonType = [string]$data.LogonType
    if (-not (Test-ValidIPv4 $ip) -or $ip -eq '127.0.0.1') { return $null }

    # LogonType 10 is unambiguously RDP. LogonType 3 counts when RDP itself reported this client
    # close in time (the NLA case), or when the operator has explicitly opted into counting all
    # network logons.
    $whenUtc = $LogEvent.TimeCreated.ToUniversalTime()
    $attributed = $false
    if ($logonType -eq '3' -and $null -ne $RdpEvidence) {
        $attributed = Test-RdpTimeCorrelated -Evidence $RdpEvidence -IpAddress $ip -WhenUtc $whenUtc -WindowSeconds $AttributionWindowSeconds
    }
    if ($logonType -ne '10' -and -not $attributed -and -not ($IncludeNetworkLogonType3 -and $logonType -eq '3')) { return $null }

    $targetUser = [string]$data.TargetUserName
    if ([string]::IsNullOrWhiteSpace($targetUser) -or $targetUser -eq '-') { $targetUser = 'unknown' }

    $evidence = switch ($logonType) {
        '10' { 'RemoteInteractive' }
        '3'  { if ($attributed) { 'Network+RdpChannel' } else { 'Network(opt-in)' } }
        default { "LogonType$logonType" }
    }
    return [pscustomobject]@{
        RecordId = [long]$LogEvent.RecordId
        TimeCreatedUtc = $LogEvent.TimeCreated.ToUniversalTime().ToString('o')
        IpAddress = $ip
        LogonType = $logonType
        TargetUserName = $targetUser
        Evidence = $evidence
    }
}

function Read-BlockerState {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ LastRecordId = [long]0; Events = @() }
    }
    try {
        $state = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject]@{ LastRecordId = [long]$state.LastRecordId; Events = @($state.Events) }
    } catch {
        throw "RDP blocker state is invalid: $($_.Exception.Message)"
    }
}

function Write-BlockerState {
    param([Parameter(Mandatory)][string]$Path, [long]$LastRecordId, [object[]]$Events)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [pscustomobject]@{ Version = 1; LastRecordId = $LastRecordId; Events = @($Events) } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-NewFailedLogonEvents {
    param([long]$LastRecordId, [int]$LookbackMinutes)

    if ($LastRecordId -gt 0) {
        # @() must wrap the call, not the return: Windows PowerShell 5.1 unwraps a
        # single-element array on output, and a bare scalar has no .Count there.
        $latest = @(Invoke-SecurityLogQuery @{ LogName = 'Security'; MaxEvents = 1 })
        if ($latest.Count -gt 0 -and [long]$latest[0].RecordId -ge $LastRecordId) {
            # -FilterXPath takes raw XPath, not XML-escaped text: '&gt;' is rejected as an
            # invalid query, which previously failed every incremental run.
            return Invoke-SecurityLogQuery @{
                LogName     = 'Security'
                FilterXPath = "*[System[(EventID=4625) and (EventRecordID > $LastRecordId)]]"
            }
        }
        Write-LogLine "Security event log was cleared or reset; rebuilding the rolling window." "WARNING"
    }
    return Invoke-SecurityLogQuery @{
        FilterHashtable = @{ LogName = 'Security'; Id = 4625; StartTime = (Get-Date).AddMinutes(-$LookbackMinutes) }
    }
}

function Format-RdpOffenderSummary {
    param([Parameter(Mandatory)]$Offender)
    $types = @($Offender.LogonTypes | Sort-Object -Unique) -join ','
    $users = @($Offender.TargetUserNames | Sort-Object -Unique) -join ','
    $evidence = @($Offender.Evidence | Sort-Object -Unique) -join ','
    if ([string]::IsNullOrWhiteSpace($evidence)) { $evidence = 'unspecified' }
    # These are authentication failures, not a confirmed denial-of-service; the wording stays
    # factual so reports do not overstate what the evidence shows.
    return "{0} failed login attempts; logon types: {1}; evidence: {2}; targeted users: {3}" -f $Offender.Count, $types, $evidence, $users
}

function Test-ManagedRuleCorrect {
    param($Rule, [string]$IpAddress, [int]$RdpPort, [bool]$BlockAllInbound)
    if ([string]$Rule.Enabled -notin @('True', '1') -or [string]$Rule.Action -ne 'Block' -or [string]$Rule.Direction -ne 'Inbound' -or [string]$Rule.Profile -ne 'Any') { return $false }
    $address = @($Rule | Get-NetFirewallAddressFilter -ErrorAction Stop).RemoteAddress
    if ($address.Count -ne 1 -or [string]$address[0] -ne $IpAddress) { return $false }
    if ($BlockAllInbound) { return $true }
    $port = $Rule | Get-NetFirewallPortFilter -ErrorAction Stop
    return ([string]$port.Protocol -in @('TCP', '6')) -and (@($port.LocalPort) -contains [string]$RdpPort)
}

function New-ManagedBlockRule {
    param([string]$DisplayName, [string]$IpAddress, [int]$RdpPort, [bool]$BlockAllInbound)
    $parameters = @{
        DisplayName = $DisplayName; Direction = 'Inbound'; RemoteAddress = $IpAddress
        Action = 'Block'; Profile = 'Any'; Enabled = 'True'; ErrorAction = 'Stop'
        Description = "ManagedBy=WinServerSetup;CreatedUtc=$((Get-Date).ToUniversalTime().ToString('o'))"
    }
    if (-not $BlockAllInbound) { $parameters.Protocol = 'TCP'; $parameters.LocalPort = [string]$RdpPort }
    return New-NetFirewallRule @parameters
}

function Ensure-ManagedBlockRule {
    param([string]$IpAddress, [string]$RulePrefix, [int]$RdpPort, [bool]$BlockAllInbound, $Offender)
    $displayName = "$RulePrefix $IpAddress"
    $existing = @(Get-NetFirewallRule -DisplayName $displayName -ErrorAction SilentlyContinue)
    if ($existing.Count -eq 1 -and (Test-ManagedRuleCorrect $existing[0] $IpAddress $RdpPort $BlockAllInbound)) {
        Write-LogLine "Already protected: $IpAddress ($(Format-RdpOffenderSummary $Offender))."
        return
    }

    $temporaryName = "$displayName replacement-$([guid]::NewGuid().ToString('N'))"
    if ($existing.Count -gt 0) {
        New-ManagedBlockRule $temporaryName $IpAddress $RdpPort $BlockAllInbound | Out-Null
        $existing | Remove-NetFirewallRule -ErrorAction Stop
    }
    try {
        New-ManagedBlockRule $displayName $IpAddress $RdpPort $BlockAllInbound | Out-Null
        if ($existing.Count -gt 0) { Get-NetFirewallRule -DisplayName $temporaryName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue }
    } catch {
        if ($existing.Count -eq 0) { throw }
        Write-LogLine "Final rule replacement failed for $IpAddress; the temporary protection rule remains active: $($_.Exception.Message)" "ERROR"
        throw
    }
    Write-LogLine "Blocked $IpAddress after $(Format-RdpOffenderSummary $Offender)."
}

function Remove-ExpiredManagedRules {
    param([string]$RulePrefix, [int]$RetentionDays, [bool]$PermanentBlock)
    if ($PermanentBlock) { return }
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-$RetentionDays)
    foreach ($rule in @(Get-NetFirewallRule -DisplayName "$RulePrefix *" -ErrorAction SilentlyContinue)) {
        if ([string]$rule.Description -match 'ManagedBy=WinServerSetup;CreatedUtc=([^;]+)') {
            $created = [datetime]::MinValue
            if ([datetime]::TryParse($matches[1], [ref]$created) -and $created.ToUniversalTime() -lt $cutoff) {
                $rule | Remove-NetFirewallRule -ErrorAction Stop
                Write-LogLine "Removed expired managed firewall rule: $($rule.DisplayName)."
            }
        }
    }
}

function Invoke-RdpBruteforceBlocker {
    param([string]$ResolvedConfigPath = "")

    $mutex = $null
    $mutexAcquired = $false
    try {
        $projectRoot = Resolve-ProjectRoot
        if ([string]::IsNullOrWhiteSpace($ResolvedConfigPath)) { $ResolvedConfigPath = Join-Path $projectRoot "WinServerSetup.config.json" }
        $config = Read-JsonFile -Path $ResolvedConfigPath
        $settings = $config.rdpBruteforceBlocker
        if (-not $settings.enabled) { Write-LogLine "RDP blocker is disabled in config."; return 0 }
        $settings = Assert-RdpBlockerSettings $config
        $script:BlockerLogMaxBytes = [long]$settings.logMaxBytes
        $script:BlockerLogRetentionFiles = [int]$settings.logRetentionFiles

        $mutex = New-Object System.Threading.Mutex($false, 'Global\WinServerSetup-RdpBlocker')
        try { $mutexAcquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $mutexAcquired = $true }
        if (-not $mutexAcquired) {
            # A concurrent run is a normal scheduling overlap, not a failure. Returning non-zero
            # here would set LastTaskResult=1 and make the health check report this security
            # control as broken.
            Write-LogLine "Another RDP blocker instance is already running; skipping this run." "INFO"
            return 0
        }

        $statePath = [string]$settings.statePath
        if ([string]::IsNullOrWhiteSpace($statePath)) { $statePath = Join-Path $projectRoot "state\rdp-blocker-state.json" }
        $state = Read-BlockerState $statePath
        $newEvents = @(Get-NewFailedLogonEvents -LastRecordId $state.LastRecordId -LookbackMinutes ([int]$settings.lookbackMinutes))

        # Resolve which clients Remote Desktop itself saw and WHEN, so NLA-mode failures
        # (recorded as LogonType 3) can be attributed to RDP without counting unrelated
        # network logons that merely share an address.
        $rdpEvidence = Get-RdpAttributedEvidence -LookbackMinutes ([int]$settings.lookbackMinutes)
        $attributionWindowSeconds = [int]$settings.attributionWindowSeconds

        $parsed = New-Object System.Collections.Generic.List[object]
        foreach ($securityEvent in $newEvents) {
            try {
                $item = Convert-FailedLogonEvent $securityEvent ([bool]$settings.includeNetworkLogonType3) $rdpEvidence $attributionWindowSeconds
                if ($null -ne $item) { $parsed.Add($item) }
            } catch {
                Write-LogLine "Could not parse failed-logon event RecordId=$($securityEvent.RecordId): $($_.Exception.Message)" "WARNING"
            }
        }

        $cutoff = (Get-Date).ToUniversalTime().AddMinutes(-[int]$settings.lookbackMinutes)
        $allEvents = @($state.Events) + $parsed.ToArray()
        $rollingEvents = @($allEvents | Where-Object { (ConvertTo-UtcDateTime $_.TimeCreatedUtc) -ge $cutoff } | Sort-Object RecordId -Unique)
        $lastRecordId = [long]$state.LastRecordId
        if ($newEvents.Count -gt 0) { $lastRecordId = [long](@($newEvents | Measure-Object RecordId -Maximum)[0].Maximum) }
        Write-BlockerState -Path $statePath -LastRecordId $lastRecordId -Events $rollingEvents

        Remove-ExpiredManagedRules ([string]$settings.rulePrefix) ([int]$settings.ruleRetentionDays) ([bool]$settings.permanentBlock)
        $offenders = @($rollingEvents | Group-Object IpAddress | Where-Object Count -ge ([int]$settings.threshold) | ForEach-Object {
            [pscustomobject]@{
                IpAddress = $_.Name; Count = $_.Count
                LogonTypes = @($_.Group.LogonType | Sort-Object -Unique)
                TargetUserNames = @($_.Group.TargetUserName | Sort-Object -Unique)
                Evidence = @($_.Group.Evidence | Where-Object { $_ } | Sort-Object -Unique)
            }
        })
        foreach ($offender in $offenders) {
            if (Test-IsWhitelisted $offender.IpAddress @($settings.whitelistCIDRs)) {
                Write-LogLine "Skipped whitelisted IP: $($offender.IpAddress) ($(Format-RdpOffenderSummary $offender))."
                continue
            }
            Ensure-ManagedBlockRule $offender.IpAddress ([string]$settings.rulePrefix) ([int]$config.rdp.newPort) ([bool]$settings.blockAllInbound) $offender
        }
        if ($offenders.Count -eq 0) { Write-LogLine "No abusive IPs found." }
        return 0
    } catch {
        Write-LogLine "Error: $($_.Exception.Message); stack=$($_.ScriptStackTrace)" "ERROR"
        return 1
    } finally {
        if ($mutexAcquired -and $null -ne $mutex) { $mutex.ReleaseMutex() }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-RdpBruteforceBlocker -ResolvedConfigPath $ConfigPath)
}
