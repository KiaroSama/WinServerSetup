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

function Get-RdpBlockerLimits {
    <#
        H-04: resolves and validates the per-run resource caps.

        A key that is absent falls back to the shipped default, so a config written before these
        keys existed keeps running BOUNDED rather than unbounded. A key that is present but
        out of range is rejected, because a nonsense cap is an operator mistake, not a default.

        The specification table is declared inside the function on purpose: test suites in this
        repository AST-extract single functions, so a module-level $script: table would not
        travel with it.
    #>
    param([Parameter(Mandatory)]$Settings)

    $specification = @(
        @{ Name = 'maxEventsPerRun';    Default = 20000;   Minimum = 100;   Maximum = 1000000 },
        @{ Name = 'maxOffendersPerRun'; Default = 200;     Minimum = 1;     Maximum = 100000 },
        @{ Name = 'maxManagedRules';    Default = 2000;    Minimum = 1;     Maximum = 100000 },
        @{ Name = 'maxStateBytes';      Default = 5242880; Minimum = 65536; Maximum = 1073741824 },
        @{ Name = 'maxRunSeconds';      Default = 240;     Minimum = 5;     Maximum = 3600 }
    )

    $limits = @{}
    foreach ($item in $specification) {
        $raw = $Settings.($item.Name)
        if ($null -eq $raw -or [string]::IsNullOrWhiteSpace([string]$raw)) {
            $limits[$item.Name] = [long]$item.Default
            continue
        }
        $value = [long]0
        if (-not [long]::TryParse([string]$raw, [ref]$value)) {
            throw ("rdpBruteforceBlocker.{0} must be a whole number between {1} and {2}." -f $item.Name, $item.Minimum, $item.Maximum)
        }
        if ($value -lt $item.Minimum -or $value -gt $item.Maximum) {
            throw ("rdpBruteforceBlocker.{0} must be between {1} and {2}." -f $item.Name, $item.Minimum, $item.Maximum)
        }
        $limits[$item.Name] = $value
    }
    # A hashtable is an IDictionary, which PowerShell passes through as one object instead of
    # enumerating it - the same reason Get-RdpAttributedEvidence returns a Dictionary (M-02).
    return $limits
}

function Assert-RdpBlockerSettings {
    param([Parameter(Mandatory)]$Config)

    $settings = $Config.rdpBruteforceBlocker
    if ($null -eq $settings) { throw "Missing rdpBruteforceBlocker configuration." }
    # H-04: the upper bound matters because threshold sizes the per-address timestamp ring that
    # is persisted in the state file.
    if ([int]$settings.threshold -lt 1 -or [int]$settings.threshold -gt 1000) { throw "rdpBruteforceBlocker.threshold must be between 1 and 1000." }
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
    # H-04: reject a bad cap here, before a single event is read or a firewall rule is touched.
    $null = Get-RdpBlockerLimits $settings
    return $settings
}

function ConvertTo-UnixSeconds {
    param([Parameter(Mandatory)][datetime]$Value)
    $epoch = New-Object System.DateTime(1970, 1, 1, 0, 0, 0, ([System.DateTimeKind]::Utc))
    return [long][math]::Floor(($Value.ToUniversalTime() - $epoch).TotalSeconds)
}

function Add-UniqueToken {
    <#
        H-04: the per-address summary keeps a short comma-separated list of the logon types,
        usernames and evidence kinds seen, so the diagnostic log line survives the switch from
        raw event retention to counters. Bounded on purpose: an attacker choosing usernames
        must not be able to grow the state file.
    #>
    param([string]$Current, [string]$Token, [int]$MaxTokens = 6)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $Current }
    $trimmed = ([string]$Token).Trim()
    if ($trimmed.Length -gt 64) { $trimmed = $trimmed.Substring(0, 64) }
    $trimmed = $trimmed -replace ',', '_'
    $tokens = @(([string]$Current) -split ',' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($tokens -contains $trimmed) { return $Current }
    if ($tokens.Count -ge $MaxTokens) { return $Current }
    return (@($tokens) + $trimmed) -join ','
}

function Compress-CounterTimes {
    <#
        H-04: keeps only the newest $Keep timestamps that are still inside the rolling window,
        which is all the decision "at least <threshold> failures inside lookbackMinutes" can
        ever need. Retention is what bounds the state file per address, and dropping stamps
        that fall out of the window is what makes the window roll.
    #>
    param([Parameter(Mandatory)]$Counter, [int]$Keep, [long]$CutoffUnix)
    $ordered = @($Counter.Times | Where-Object { $_ -ge $CutoffUnix } | Sort-Object -Descending | Select-Object -First $Keep)
    $Counter.Times.Clear()
    foreach ($value in $ordered) { $Counter.Times.Add([long]$value) }
    return $Counter.Times.Count
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

function Test-BlockerStateSchema {
    <#
        L-03: everything the state file claims is validated BEFORE any of it is trusted.
        Returns an empty string when the state is usable, otherwise the reason it is not, so
        the caller can name it in the quarantine warning.
    #>
    param($State)
    $supportedVersion = 2
    if ($null -eq $State) { return 'the file is not valid JSON' }

    $version = 0
    if (-not [int]::TryParse([string]$State.Version, [ref]$version)) { return 'the schema version is missing or not a number' }
    if ($version -ne $supportedVersion) { return ("schema version {0} is not the supported version {1}" -f $version, $supportedVersion) }

    $lastRecordId = [long]0
    if (-not [long]::TryParse([string]$State.LastRecordId, [ref]$lastRecordId) -or $lastRecordId -lt 0) {
        return 'LastRecordId is not a whole number of zero or more'
    }
    foreach ($counter in @($State.Counters)) {
        if ($null -eq $counter) { return 'a counter entry is empty' }
        if (-not (Test-ValidIPv4 ([string]$counter.Ip))) { return ("counter address '{0}' is not a valid IPv4 address" -f $counter.Ip) }
        foreach ($stamp in @($counter.Times)) {
            $seconds = [long]0
            if (-not [long]::TryParse([string]$stamp, [ref]$seconds) -or $seconds -le 0) {
                return ("counter '{0}' carries the invalid timestamp '{1}'" -f $counter.Ip, $stamp)
            }
        }
    }
    return ''
}

function Get-BlockerQuarantinePath {
    <#
        L-03: the quarantine name is derived from the RESOLVED state path, so a traversal
        sequence in the configured path cannot place - or delete - anything outside the
        directory the state file actually lives in. The containment check is belt and braces;
        a bare file name cannot escape a Join-Path in the first place.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($full)
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $directory ("{0}.corrupt-{1}.json" -f [System.IO.Path]::GetFileName($full), $stamp)))
    if ([System.IO.Path]::GetDirectoryName($candidate) -ne $directory) {
        throw "Refusing to quarantine RDP blocker state outside its own directory: $candidate"
    }
    return $candidate
}

function Protect-QuarantineFile {
    <#
        L-03: quarantined state is attacker-influenced content kept for diagnosis, so it stops
        inheriting whatever the parent directory grants and is narrowed to SYSTEM plus the local
        Administrators group. icacls.exe is a Windows built-in, which keeps this working on both
        PowerShell hosts and inside the constrained test child where the Security module is not
        always loadable. Hardening is best effort: failing to tighten an ACL must not stop the
        blocker from recovering.
    #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        $output = & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-LogLine ("Could not restrict the quarantined state file ACL: {0}" -f (@($output) -join ' ')) "WARNING"
            return $false
        }
        return $true
    } catch {
        Write-LogLine "Could not restrict the quarantined state file ACL: $($_.Exception.Message)" "WARNING"
        return $false
    }
}

function Move-CorruptBlockerState {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Reason)
    try {
        $quarantine = Get-BlockerQuarantinePath -Path $Path
        Move-Item -LiteralPath $Path -Destination $quarantine -Force
        $null = Protect-QuarantineFile -Path $quarantine
        Write-LogLine ("RDP blocker state was unusable ({0}); quarantined it to '{1}' and rebuilding from the bounded lookback window." -f $Reason, $quarantine) "WARNING"
    } catch {
        Write-LogLine ("RDP blocker state was unusable ({0}) and could not be quarantined ({1}); rebuilding from the bounded lookback window." -f $Reason, $_.Exception.Message) "WARNING"
    }
}

function Read-BlockerState {
    <#
        L-03: a corrupt state file used to re-throw, so one bad file made every subsequent run
        of the scheduled task exit non-zero and the host stayed unprotected until an operator
        deleted it by hand. Size and schema are both checked before the content is trusted, and
        anything that fails is quarantined rather than deleted. Rebuilding is simply starting
        from LastRecordId 0, which sends the next query back over the bounded lookback window.
    #>
    param([Parameter(Mandatory)][string]$Path, [long]$MaxBytes = 5242880)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ LastRecordId = [long]0; Counters = @(); Recovered = $false }
    }

    $length = (Get-Item -LiteralPath $Path).Length
    if ($length -gt $MaxBytes) {
        Move-CorruptBlockerState -Path $Path -Reason ("it is {0} bytes, over the maxStateBytes limit of {1} bytes" -f $length, $MaxBytes)
        return [pscustomobject]@{ LastRecordId = [long]0; Counters = @(); Recovered = $true }
    }

    $state = $null
    try { $state = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $state = $null }

    $failure = Test-BlockerStateSchema -State $state
    if ($failure -ne '') {
        Move-CorruptBlockerState -Path $Path -Reason $failure
        return [pscustomobject]@{ LastRecordId = [long]0; Counters = @(); Recovered = $true }
    }
    return [pscustomobject]@{ LastRecordId = [long]$state.LastRecordId; Counters = @($state.Counters); Recovered = $false }
}

function Write-BlockerState {
    <#
        H-04: the state file is a compact per-address summary (address, a bounded ring of recent
        timestamps, and the short diagnostic token lists), never the raw events. maxStateBytes
        is the final backstop: if the summary still does not fit, the least active addresses are
        dropped, the run says so, and the Caps block records it.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$LastRecordId,
        [object[]]$Counters,
        $Caps = $null,
        [long]$MaxBytes = 5242880
    )
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    $kept = @($Counters)
    $json = ''
    for ($attempt = 0; $attempt -lt 16; $attempt++) {
        $json = [pscustomobject]@{ Version = 2; LastRecordId = $LastRecordId; Caps = $Caps; Counters = @($kept) } |
            ConvertTo-Json -Depth 6 -Compress
        if ([System.Text.Encoding]::UTF8.GetByteCount($json) -le $MaxBytes -or $kept.Count -eq 0) { break }
        $kept = @($kept | Select-Object -First ([int][math]::Floor($kept.Count / 2)))
        if ($null -ne $Caps) { $Caps.StateTrimmed = $true }
        Write-LogLine ("Blocker state exceeded maxStateBytes ({0}); dropped the least active tracked addresses down to {1}." -f $MaxBytes, $kept.Count) "WARNING"
    }

    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Set-Content -LiteralPath $temporaryPath -Value $json -Encoding UTF8
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-NewFailedLogonEvents {
    # H-04: MaxEvents is the outermost bound. Lookback alone does not limit anything during a
    # flood - a minute of it can hold hundreds of thousands of 4625 records - so every query
    # here is bounded by count as well as by time.
    param([long]$LastRecordId, [int]$LookbackMinutes, [int]$MaxEvents = 20000)

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
                MaxEvents   = $MaxEvents
            }
        }
        Write-LogLine "Security event log was cleared or reset; rebuilding the rolling window." "WARNING"
    }
    return Invoke-SecurityLogQuery @{
        FilterHashtable = @{ LogName = 'Security'; Id = 4625; StartTime = (Get-Date).AddMinutes(-$LookbackMinutes) }
        MaxEvents       = $MaxEvents
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

function Test-ManagedRuleOwned {
    # H-04: only rules this project created carry ManagedBy=WinServerSetup in the description.
    # Anything else on the machine belongs to an operator or another product and is never
    # removed, rewritten or counted against this blocker's own rule budget.
    param($Rule)
    return ([string]$Rule.Description -match 'ManagedBy=WinServerSetup(;|$)')
}

function Test-ManagedRuleCorrect {
    <#
        M-03: the whole rule is one contract - address, direction, action, enabled state,
        profile, protocol AND port - evaluated against the mode that is configured right now.

        The old body returned $true as soon as blockAllInbound was set, without ever looking at
        the protocol or port filter, so a rule created while blockAllInbound was $false stayed
        pinned to TCP/<rdp.newPort> forever after the setting was flipped. Both directions are
        repaired now because both are checked: with blockAllInbound the filters must genuinely
        be Any/Any, and without it they must be exactly TCP plus the verified RDP port.

        The address comparison also had to change shape. `@($Rule | Get-NetFirewallAddressFilter).RemoteAddress`
        collapses to a bare [string] on BOTH hosts, so `$address[0]` indexed the string and
        returned its first CHARACTER - the check could never succeed, and every scheduled run
        therefore tore down and rebuilt every managed rule. Normalising the single filter object
        with @() at the call site is the same fix as the rest of the 5.1 unwrapping family.
    #>
    param($Rule, [string]$IpAddress, [int]$RdpPort, [bool]$BlockAllInbound)

    if ([string]$Rule.Enabled -notin @('True', '1')) { return $false }
    if ([string]$Rule.Action -ne 'Block') { return $false }
    if ([string]$Rule.Direction -ne 'Inbound') { return $false }
    if ([string]$Rule.Profile -ne 'Any') { return $false }

    $addressFilter = $Rule | Get-NetFirewallAddressFilter -ErrorAction Stop
    $addresses = @($addressFilter.RemoteAddress)
    if ($addresses.Count -ne 1 -or [string]$addresses[0] -ne $IpAddress) { return $false }

    $portFilter = $Rule | Get-NetFirewallPortFilter -ErrorAction Stop
    $protocol = [string]$portFilter.Protocol
    $localPorts = @(@($portFilter.LocalPort) | ForEach-Object { [string]$_ })

    if ($BlockAllInbound) {
        # Windows reports an unconstrained filter as the literal 'Any'.
        if ($protocol -ne 'Any') { return $false }
        return ($localPorts.Count -eq 1 -and $localPorts[0] -eq 'Any')
    }
    if ($protocol -notin @('TCP', '6')) { return $false }
    return ($localPorts.Count -eq 1 -and $localPorts[0] -eq [string]$RdpPort)
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
    # Returns $true only when a NEW managed rule was created, so the caller can hold the total
    # against maxManagedRules without re-enumerating the firewall for every offender.
    param([string]$IpAddress, [string]$RulePrefix, [int]$RdpPort, [bool]$BlockAllInbound, $Offender)
    $displayName = "$RulePrefix $IpAddress"
    $existing = @(Get-NetFirewallRule -DisplayName $displayName -ErrorAction SilentlyContinue)

    # H-04: a same-named rule without ManagedBy=WinServerSetup is someone else's firewall
    # policy. Leave it completely alone rather than deleting it to make room for our own.
    $foreign = @($existing | Where-Object { -not (Test-ManagedRuleOwned $_) })
    if ($foreign.Count -gt 0) {
        Write-LogLine ("Firewall rule '{0}' exists but is not managed by WinServerSetup; leaving it untouched and skipping {1}." -f $displayName, $IpAddress) "WARNING"
        return $false
    }

    if ($existing.Count -eq 1 -and (Test-ManagedRuleCorrect $existing[0] $IpAddress $RdpPort $BlockAllInbound)) {
        Write-LogLine "Already protected: $IpAddress ($(Format-RdpOffenderSummary $Offender))."
        return $false
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
    return ($existing.Count -eq 0)
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
        $limits = Get-RdpBlockerLimits $settings
        # H-04: one wall-clock budget for the whole run, started before any log is opened, so a
        # flood can never leave this run still working when the next scheduled run begins.
        $runtime = [System.Diagnostics.Stopwatch]::StartNew()
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

        # H-04: every cap that is hit is recorded here as well as logged, so a scheduled run
        # that had to truncate is detectable afterwards instead of looking like a clean run.
        $caps = [pscustomobject]@{
            EventsRead = 0; EventsTruncated = $false
            AddressesTracked = 0; AddressesTruncated = $false
            OffendersFound = 0; OffendersTruncated = $false
            RulesCapped = $false; StateTrimmed = $false
            DeadlineExceeded = $false; StateRecovered = $false
        }

        $lookbackMinutes = [int]$settings.lookbackMinutes
        $threshold = [int]$settings.threshold
        $whitelistCidrs = @($settings.whitelistCIDRs)
        $maxEventsPerRun = [int]$limits['maxEventsPerRun']
        $maxRunSeconds = [double]$limits['maxRunSeconds']
        # The tracked-address budget comes straight from the state budget, so the two caps can
        # never disagree: roughly a kilobyte of JSON per address, floored at the offender cap.
        $maxTrackedAddresses = [int][math]::Max([long]$limits['maxOffendersPerRun'], [math]::Floor($limits['maxStateBytes'] / 1024))

        $state = Read-BlockerState -Path $statePath -MaxBytes ([long]$limits['maxStateBytes'])
        $caps.StateRecovered = [bool]$state.Recovered

        $newEvents = @(Get-NewFailedLogonEvents -LastRecordId $state.LastRecordId -LookbackMinutes $lookbackMinutes -MaxEvents $maxEventsPerRun)
        $caps.EventsRead = $newEvents.Count
        if ($newEvents.Count -ge $maxEventsPerRun) {
            $caps.EventsTruncated = $true
            Write-LogLine ("The failed-logon window filled maxEventsPerRun ({0}); this run sees only the newest {0} records and the rest stay unread." -f $maxEventsPerRun) "WARNING"
        }

        # Resolve which clients Remote Desktop itself saw and WHEN, so NLA-mode failures
        # (recorded as LogonType 3) can be attributed to RDP without counting unrelated
        # network logons that merely share an address.
        $rdpEvidence = Get-RdpAttributedEvidence -LookbackMinutes $lookbackMinutes -MaxEvents $maxEventsPerRun
        $attributionWindowSeconds = [int]$settings.attributionWindowSeconds

        # H-04: rebuild the tracked set from the compact state. A whitelisted address is dropped
        # on the way in, so a whitelist that grew since the last run takes effect immediately.
        $counters = @{}
        $whitelistDecisions = @{}
        foreach ($stored in @($state.Counters)) {
            $address = [string]$stored.Ip
            if ([string]::IsNullOrWhiteSpace($address)) { continue }
            if (Test-IsWhitelisted $address $whitelistCidrs) { continue }
            $times = New-Object 'System.Collections.Generic.List[long]'
            foreach ($stamp in @($stored.Times)) { $times.Add([long]$stamp) }
            $counters[$address] = [pscustomobject]@{
                Ip = $address; Times = $times
                Types = [string]$stored.Types; Users = [string]$stored.Users; Evidence = [string]$stored.Evidence
            }
        }

        $whitelistHits = @{}
        $processedRecordId = [long]$state.LastRecordId
        $processed = 0
        foreach ($securityEvent in $newEvents) {
            $processed++
            # Checked in blocks rather than per event: the check itself must not become the cost.
            if (($processed % 500) -eq 0 -and $runtime.Elapsed.TotalSeconds -ge $maxRunSeconds) {
                $caps.DeadlineExceeded = $true
                break
            }
            try {
                $recordId = [long]$securityEvent.RecordId
                if ($recordId -gt $processedRecordId) { $processedRecordId = $recordId }
                $item = Convert-FailedLogonEvent $securityEvent ([bool]$settings.includeNetworkLogonType3) $rdpEvidence $attributionWindowSeconds
                if ($null -eq $item) { continue }

                $address = [string]$item.IpAddress
                if (-not $whitelistDecisions.ContainsKey($address)) {
                    $whitelistDecisions[$address] = (Test-IsWhitelisted $address $whitelistCidrs)
                }
                if ($whitelistDecisions[$address]) {
                    # H-04: a whitelisted address is never tracked at all, so no cap can evict it
                    # and no cap can ever cause one to be blocked. It is only counted for the log.
                    if (-not $whitelistHits.ContainsKey($address)) { $whitelistHits[$address] = 0 }
                    $whitelistHits[$address] = $whitelistHits[$address] + 1
                    continue
                }

                $counter = $counters[$address]
                if ($null -eq $counter) {
                    if ($counters.Count -ge $maxTrackedAddresses) {
                        if (-not $caps.AddressesTruncated) {
                            $caps.AddressesTruncated = $true
                            Write-LogLine ("Tracking cap reached ({0} addresses, derived from maxStateBytes); further new addresses are not tracked by this run." -f $maxTrackedAddresses) "WARNING"
                        }
                        continue
                    }
                    $counter = [pscustomobject]@{
                        Ip = $address; Times = (New-Object 'System.Collections.Generic.List[long]')
                        Types = ''; Users = ''; Evidence = ''
                    }
                    $counters[$address] = $counter
                }
                $counter.Times.Add((ConvertTo-UnixSeconds (ConvertTo-UtcDateTime $item.TimeCreatedUtc)))
                if ($counter.Times.Count -gt ($threshold * 4)) { $null = Compress-CounterTimes $counter $threshold 0 }
                $counter.Types = Add-UniqueToken $counter.Types $item.LogonType
                $counter.Users = Add-UniqueToken $counter.Users $item.TargetUserName
                $counter.Evidence = Add-UniqueToken $counter.Evidence $item.Evidence
            } catch {
                Write-LogLine "Could not parse failed-logon event RecordId=$($securityEvent.RecordId): $($_.Exception.Message)" "WARNING"
            }
        }
        if ($runtime.Elapsed.TotalSeconds -ge $maxRunSeconds) { $caps.DeadlineExceeded = $true }
        if ($caps.DeadlineExceeded) {
            Write-LogLine ("This run reached its maxRunSeconds budget ({0}s) and stopped early; the remaining events stay queued for the next run." -f $maxRunSeconds) "WARNING"
        }

        # Roll the window: drop stamps that fell out of the lookback, drop addresses left with
        # none, and keep only the newest $threshold stamps - all the block decision can use.
        $cutoffUnix = ConvertTo-UnixSeconds ((Get-Date).ToUniversalTime().AddMinutes(-$lookbackMinutes))
        $live = New-Object System.Collections.Generic.List[object]
        foreach ($key in @($counters.Keys)) {
            $counter = $counters[$key]
            if ((Compress-CounterTimes $counter $threshold $cutoffUnix) -eq 0) {
                $counters.Remove($key)
                continue
            }
            $live.Add($counter)
        }
        $caps.AddressesTracked = $live.Count

        foreach ($address in $whitelistHits.Keys) {
            if ($whitelistHits[$address] -ge $threshold) {
                Write-LogLine ("Skipped whitelisted IP: {0} ({1} failed login attempts in this run)." -f $address, $whitelistHits[$address])
            }
        }

        $offenders = @()
        if (-not $caps.DeadlineExceeded) {
            $offenders = @($live | Where-Object { $_.Times.Count -ge $threshold } | ForEach-Object {
                [pscustomobject]@{
                    IpAddress = $_.Ip
                    Count = $_.Times.Count
                    LastSeenUnix = [long]$_.Times[0]
                    LogonTypes = @($_.Types -split ',' | Where-Object { $_ })
                    TargetUserNames = @($_.Users -split ',' | Where-Object { $_ })
                    Evidence = @($_.Evidence -split ',' | Where-Object { $_ })
                }
            })
            $caps.OffendersFound = $offenders.Count
            if ($offenders.Count -gt [int]$limits['maxOffendersPerRun']) {
                $caps.OffendersTruncated = $true
                Write-LogLine ("{0} offenders exceed maxOffendersPerRun ({1}); handling the busiest and most recent first, the rest carry over to the next run." -f $offenders.Count, $limits['maxOffendersPerRun']) "WARNING"
                $offenders = @($offenders |
                        Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'LastSeenUnix'; Descending = $true } |
                        Select-Object -First ([int]$limits['maxOffendersPerRun']))
            }

            Remove-ExpiredManagedRules ([string]$settings.rulePrefix) ([int]$settings.ruleRetentionDays) ([bool]$settings.permanentBlock)
            $managedRuleCount = @(Get-NetFirewallRule -DisplayName "$([string]$settings.rulePrefix) *" -ErrorAction SilentlyContinue |
                    Where-Object { Test-ManagedRuleOwned $_ }).Count

            foreach ($offender in $offenders) {
                if ($runtime.Elapsed.TotalSeconds -ge $maxRunSeconds) {
                    $caps.DeadlineExceeded = $true
                    Write-LogLine ("Stopped applying firewall rules at the maxRunSeconds budget ({0}s); the remaining offenders carry over to the next run." -f $maxRunSeconds) "WARNING"
                    break
                }
                if ($managedRuleCount -ge [int]$limits['maxManagedRules']) {
                    $caps.RulesCapped = $true
                    Write-LogLine ("Managed firewall rules have reached maxManagedRules ({0}); no further rules are created this run. Existing blocks stay in force - raise the cap or shorten ruleRetentionDays." -f $limits['maxManagedRules']) "WARNING"
                    break
                }
                if (Ensure-ManagedBlockRule $offender.IpAddress ([string]$settings.rulePrefix) ([int]$config.rdp.newPort) ([bool]$settings.blockAllInbound) $offender) {
                    $managedRuleCount++
                }
            }
            if ($offenders.Count -eq 0) { Write-LogLine "No abusive IPs found." }
        }

        $persisted = @($live |
                Sort-Object -Property @{ Expression = { $_.Times.Count }; Descending = $true } |
                ForEach-Object { [pscustomobject]@{ Ip = $_.Ip; Times = @($_.Times.ToArray()); Types = $_.Types; Users = $_.Users; Evidence = $_.Evidence } })
        Write-BlockerState -Path $statePath -LastRecordId $processedRecordId -Counters $persisted -Caps $caps -MaxBytes ([long]$limits['maxStateBytes'])
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
