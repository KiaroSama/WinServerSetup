# Rdp.ps1 - RDP listener checks, the port-migration safety path with its rollback, the
# firewall rule, and installation of the bruteforce blocker scheduled task.
#
# Dot-sourced by WinServerSetup.ps1. Contains function definitions only; it reads the
# globals initialized there ($Global:Config, $Global:ConfigPath, $Global:RunStats) at
# call time, never at load time.

# =============================================================================
# SECTION 12: RDP PORT SAFETY (item 8) + bruteforce blocker (items 34, 36)
# =============================================================================
function Test-TcpPortListening {
    param([Parameter(Mandatory)][int]$Port)
    try {
        $conns = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop
        return [bool]$conns
    } catch { return $false }
}

function Test-DirectInstallerInstalled {
    param([string]$Name, [string]$RegistryName)
    if ([string]::IsNullOrWhiteSpace($RegistryName)) {
        Write-Warn "$Name has no independent verification contract."
        return $false
    }
    return -not [string]::IsNullOrWhiteSpace([string](Get-InstalledRegistryDisplayName -NameLike $RegistryName))
}

function Get-TermServiceProcessId {
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='TermService'" -ErrorAction Stop
    return [int]$service.ProcessId
}

function Test-TermServiceOwnsTcpPort {
    param([Parameter(Mandatory)][int]$Port)
    try {
        $servicePid = Get-TermServiceProcessId
        if ($servicePid -le 0) { return $false }
        return [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop | Where-Object { [int]$_.OwningProcess -eq $servicePid })
    } catch { return $false }
}

function Wait-TermServiceTcpPort {
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutSeconds = 30
    )
    $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSeconds))
    while ((Get-Date) -lt $deadline) {
        if (Test-TermServiceOwnsTcpPort -Port $Port) {
            Clear-StatusInPlace
            return $true
        }
        $remaining = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalSeconds)
        Write-StatusInPlace ("Waiting for TermService to own TCP {0}... {1}s" -f $Port, $remaining)
        Start-Sleep -Seconds 1
    }
    Clear-StatusInPlace
    return (Test-TermServiceOwnsTcpPort -Port $Port)
}

function Restore-RdpPort {
    param([string]$RegistryPath, [int]$PreviousPort, [bool]$RestartService, [int]$WaitTimeoutSeconds = 30)
    Set-ItemProperty -Path $RegistryPath -Name "PortNumber" -Type DWord -Value $PreviousPort -ErrorAction Stop
    if ($RestartService) {
        Restart-Service TermService -Force -ErrorAction Stop
        if (-not (Wait-TermServiceTcpPort -Port $PreviousPort -TimeoutSeconds $WaitTimeoutSeconds)) {
            throw "Rollback wrote PortNumber=$PreviousPort, but TermService did not reclaim that listener."
        }
    } else {
        Set-PendingReboot "RDP rollback to TCP $PreviousPort requires a reboot"
    }
    Write-Warn "Rolled RDP PortNumber back to $PreviousPort."
}

function Get-RdpRegistryPortNumber {
    param([string]$RegistryPath = "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp")
    return [int](Get-ItemProperty -Path $RegistryPath -Name "PortNumber" -ErrorAction Stop).PortNumber
}

function Test-RdpPortAgreement {
    <#
        M-01: three sources have to say the same thing before anything may be bound to "the RDP
        port" - the configuration, the RDP-Tcp registry value, and which process actually owns
        that listener. They routinely disagree: a migration that has not rebooted yet, a
        migration that never happened, or another service squatting on the port.

        Returns the disagreement rather than throwing, so callers can phrase their own refusal.
    #>
    param(
        [Parameter(Mandatory)][int]$ConfiguredPort,
        [Parameter(Mandatory)][int]$RegistryPort,
        [bool]$RdpManaged = $true
    )
    $reasons = New-Object System.Collections.Generic.List[string]
    # With rdp.enabled off the tool does not own the port, so the registry is the authority.
    $effective = if ($RdpManaged) { $ConfiguredPort } else { $RegistryPort }
    if ($effective -lt 1 -or $effective -gt 65535) {
        $reasons.Add(("the effective RDP port {0} is outside 1-65535" -f $effective)) | Out-Null
    } elseif ($RdpManaged -and $RegistryPort -ne $ConfiguredPort) {
        $reasons.Add(("configured rdp.newPort is {0} but the RDP-Tcp registry PortNumber is {1}" -f $ConfiguredPort, $RegistryPort)) | Out-Null
    } elseif (-not (Test-TermServiceOwnsTcpPort -Port $effective)) {
        if (Test-TcpPortListening -Port $effective) {
            $reasons.Add(("TCP {0} is listening but its owner is not TermService" -f $effective)) | Out-Null
        } else {
            $reasons.Add(("TermService does not own a listener on TCP {0}; the port change is still pending a service restart or reboot" -f $effective)) | Out-Null
        }
    }
    return [pscustomobject]@{
        ConfiguredPort = $ConfiguredPort
        RegistryPort   = $RegistryPort
        EffectivePort  = $effective
        Agreed         = ($reasons.Count -eq 0)
        Reasons        = $reasons.ToArray()
    }
}

function Assert-RdpPortAgreement {
    param([string]$Purpose = "the RDP brute-force blocker")
    $rdp = $Global:Config.rdp
    $state = Test-RdpPortAgreement -ConfiguredPort ([int]$rdp.newPort) -RegistryPort (Get-RdpRegistryPortNumber) -RdpManaged ([bool]$rdp.enabled)
    if (-not $state.Agreed) {
        throw ("Refusing to install {0}: config, registry and listener disagree about the RDP port - {1}." -f $Purpose, ($state.Reasons -join '; '))
    }
    Write-Ok ("Verified RDP port {0}: the registry and the live TermService listener agree with the configuration." -f $state.EffectivePort)
    return $state.EffectivePort
}

# --------------------------------------------------------------------- M-10 firewall rollback
# The migration used to roll back only the registry. The inbound allow rule for the new port is
# created BEFORE the port is changed (deliberately - the alternative is a lockout), so a failed
# migration left an allow rule published for a port nothing listens on, or an operator's own
# pre-existing rule silently rewritten to the tool's settings. Both halves are now captured
# before the change and restored together.

function Get-ManagedFirewallRuleState {
    param([Parameter(Mandatory)][string]$DisplayName)
    $state = [pscustomobject]@{
        DisplayName = $DisplayName; Existed = $false
        Enabled = $null; Action = $null; Direction = $null; Profile = $null; Protocol = $null; LocalPort = $null
    }
    $rule = Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue
    if (-not $rule) { return $state }
    $filter = $rule | Get-NetFirewallPortFilter
    $state.Existed   = $true
    $state.Enabled   = [string]$rule.Enabled
    $state.Action    = [string]$rule.Action
    $state.Direction = [string]$rule.Direction
    $state.Profile   = [string]$rule.Profile
    $state.Protocol  = [string]$filter.Protocol
    # Left unconverted on purpose: LocalPort can be a multi-value property, and flattening it to
    # a single string would restore a different rule than the one that was captured.
    $state.LocalPort = $filter.LocalPort
    return $state
}

function Restore-ManagedFirewallRuleState {
    param([Parameter(Mandatory)]$State)
    $existing = Get-NetFirewallRule -DisplayName $State.DisplayName -ErrorAction SilentlyContinue
    if (-not $State.Existed) {
        # This run created the rule, so removing it restores the machine exactly. A rule that was
        # never created (the failure happened first) is simply nothing to undo.
        if ($existing) { $existing | Remove-NetFirewallRule -ErrorAction Stop }
        return
    }
    if (-not $existing) {
        throw ("Managed firewall rule '{0}' existed before the migration but is gone; it cannot be restored." -f $State.DisplayName)
    }
    $existing | Set-NetFirewallRule -Enabled $State.Enabled -Action $State.Action -Direction $State.Direction -Profile $State.Profile -ErrorAction Stop
    Get-NetFirewallRule -DisplayName $State.DisplayName -ErrorAction Stop |
        Get-NetFirewallPortFilter |
        Set-NetFirewallPortFilter -Protocol $State.Protocol -LocalPort $State.LocalPort -ErrorAction Stop
}

function Invoke-RdpMigrationRollback {
    <#
        M-10: undo BOTH halves of a failed migration and report honestly whether that worked.

        The registry goes first, because that is what restores reachability; the firewall rule is
        restored afterwards. Neither failure aborts the other, and a rollback that did not fully
        succeed is never reported as one.
    #>
    param(
        [Parameter(Mandatory)]$FirewallState,
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][int]$PreviousPort,
        [bool]$RegistryChanged = $true,
        [bool]$RestartService = $true,
        [int]$WaitTimeoutSeconds = 30
    )
    $failures = New-Object System.Collections.Generic.List[string]
    $registryRestored = $true
    if ($RegistryChanged) {
        $registryRestored = $false
        try {
            Restore-RdpPort -RegistryPath $RegistryPath -PreviousPort $PreviousPort -RestartService $RestartService -WaitTimeoutSeconds $WaitTimeoutSeconds
            $registryRestored = $true
        } catch {
            $failures.Add(("RDP PortNumber rollback to {0} failed: {1}" -f $PreviousPort, $_.Exception.Message)) | Out-Null
        }
    }
    $firewallRestored = $false
    try {
        Restore-ManagedFirewallRuleState -State $FirewallState
        $firewallRestored = $true
    } catch {
        $failures.Add(("Firewall rollback for '{0}' failed: {1}" -f $FirewallState.DisplayName, $_.Exception.Message)) | Out-Null
    }

    $result = [pscustomobject]@{
        Succeeded        = ($failures.Count -eq 0)
        RegistryRestored = $registryRestored
        FirewallRestored = $firewallRestored
        Failures         = $failures.ToArray()
    }
    if ($result.Succeeded) {
        Write-Ok ("RDP migration rolled back: PortNumber {0}, firewall rule '{1}' restored." -f $PreviousPort, $FirewallState.DisplayName)
    } else {
        foreach ($entry in $result.Failures) { Write-Fail $entry }
        Write-StructuredLog -Level RDP -Message ("Rollback incomplete: {0}" -f ($result.Failures -join '; '))
    }
    return $result
}

function Invoke-RdpServicePortActivation {
    <#
        M-09: binding the service to the desired port has EXACTLY three outcomes, and only the
        third one is a genuine pending reboot.

          AlreadyBound  - TermService already owns the port. Nothing to do: no restart, and no
                          reboot request. This is the rerun case that used to flag a reboot on
                          every single repeat run because the old condition fell through to its
                          else branch whenever a restart was not needed.
          Restarted     - the port is not owned and config allows the restart. Ownership is
                          verified afterwards; an unverified restart is a failure, not a reboot.
          RebootPending - the port is not owned and config forbids the restart. The ONLY place
                          Set-PendingReboot is called.
    #>
    param(
        [Parameter(Mandatory)][int]$DesiredPort,
        [bool]$RestartAllowed,
        [int]$WaitTimeoutSeconds = 30
    )
    if (Test-TermServiceOwnsTcpPort -Port $DesiredPort) {
        Write-Ok ("TermService already owns TCP {0}; no service restart and no reboot are required." -f $DesiredPort)
        return [pscustomobject]@{ Outcome = 'AlreadyBound'; Restarted = $false; RebootRequested = $false; Verified = $true }
    }
    if (-not $RestartAllowed) {
        Set-PendingReboot ("RDP port change to TCP {0} requires a service restart" -f $DesiredPort)
        return [pscustomobject]@{ Outcome = 'RebootPending'; Restarted = $false; RebootRequested = $true; Verified = $false }
    }
    Write-Warn "Restarting Remote Desktop service -- your current RDP session may briefly disconnect."
    Restart-Service TermService -Force -ErrorAction Stop
    $verified = Wait-TermServiceTcpPort -Port $DesiredPort -TimeoutSeconds $WaitTimeoutSeconds
    return [pscustomobject]@{ Outcome = 'Restarted'; Restarted = $true; RebootRequested = $false; Verified = $verified }
}

function Backup-RdpRegistryKey {
    # Extracted from Configure-RdpPortAndFirewall so the whole migration path can be exercised
    # end to end in tests without shelling out to reg.exe against the live registry.
    $backup = Resolve-RelativePath "backups\RDP-Tcp-PortNumber.reg"
    & reg.exe export "HKLM\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" "$backup" /y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "RDP registry backup export failed with exit code $LASTEXITCODE." }
    return $backup
}

function Ensure-RdpFirewallRule {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][int]$Port
    )
    try {
        $rule = Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue
        if (-not $rule) {
            New-NetFirewallRule -DisplayName $DisplayName -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Any -ErrorAction Stop | Out-Null
        } else {
            $rule | Set-NetFirewallRule -Enabled True -Action Allow -Profile Any -ErrorAction Stop
            $rule | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -Protocol TCP -LocalPort $Port -ErrorAction Stop
        }

        $verifyRule = Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction Stop
        $verifyPort = $verifyRule | Get-NetFirewallPortFilter
        if ($verifyRule.Enabled -ne 'True' -or $verifyRule.Action -ne 'Allow' -or $verifyRule.Direction -ne 'Inbound' -or
            $verifyRule.Profile -ne 'Any' -or [string]$verifyPort.Protocol -notin @('TCP', '6') -or
            -not (@($verifyPort.LocalPort) -contains [string]$Port)) {
            throw "Firewall verification failed for $DisplayName."
        }
        Write-Ok "Firewall rule verified: $DisplayName allows TCP $Port."
        return $true
    } catch {
        Write-Fail "Failed to create/verify firewall rule for TCP ${Port}: $($_.Exception.Message)"
        return $false
    }
}

function Configure-RdpPortAndFirewall {
    $s = $Global:Config.rdp
    if (-not $s.enabled) { Set-StepSkipped "disabled in config"; return }
    $newPort = [int]$s.newPort
    if ($newPort -lt 1 -or $newPort -gt 65535) { throw "Invalid RDP port: $newPort" }

    $rdpPath = "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
    $previousPort = Get-RdpRegistryPortNumber -RegistryPath $rdpPath
    if ((Test-TcpPortListening -Port $newPort) -and -not (Test-TermServiceOwnsTcpPort -Port $newPort)) {
        throw "TCP $newPort is already occupied by a process other than TermService; no RDP settings were changed."
    }

    Write-Info "Step 1/5: Enable Remote Desktop in registry."
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue

    Write-Info "Step 2/5: Pre-create inbound firewall rule for new port $newPort BEFORE changing service port."
    $newRule = "WinServerSetup RDP TCP $newPort"
    # M-10: capture the managed rule EXACTLY as it is before this run touches it, so a failure
    # anywhere below can put it back - or delete it, if this run is the one that created it.
    $firewallState = Get-ManagedFirewallRuleState -DisplayName $newRule
    $registryChanged = $false
    if (-not (Ensure-RdpFirewallRule -DisplayName $newRule -Port $newPort)) {
        $rollback = Invoke-RdpMigrationRollback -FirewallState $firewallState -RegistryPath $rdpPath -PreviousPort $previousPort `
            -RegistryChanged $false -RestartService ([bool]$s.restartRemoteDesktopService)
        if (-not $rollback.Succeeded) {
            throw ("ABORTING RDP port change to prevent lockout because firewall setup failed, AND rollback failed: {0}" -f ($rollback.Failures -join '; '))
        }
        throw "ABORTING RDP port change to prevent lockout because firewall setup failed; the firewall rule was rolled back."
    }

    try {
        Write-Info "Step 3/5: Backup current PortNumber=$previousPort and update registry."
        Backup-RdpRegistryKey | Out-Null
        if ($previousPort -ne $newPort) {
            Set-ItemProperty -Path $rdpPath -Name "PortNumber" -Type DWord -Value $newPort -ErrorAction Stop
            $registryChanged = $true
            Write-Ok "PortNumber registry value set to $newPort."
        } else {
            Write-Info "RDP PortNumber is already $newPort; validating the existing configuration."
        }

        Write-Info "Step 4/5: Bind TermService to TCP $newPort."
        $activation = Invoke-RdpServicePortActivation -DesiredPort $newPort -RestartAllowed ([bool]$s.restartRemoteDesktopService)
        if ($activation.Outcome -eq 'Restarted' -and -not $activation.Verified) {
            throw "TermService restarted but did not bind TCP $newPort."
        }

        Write-Info "Step 5/5: Verify the new port is listening."
        if ($activation.Outcome -eq 'RebootPending') {
            Write-Info "Service restart is disabled in config; the reboot will apply and verify the change."
        } elseif ($s.verifyListening -and -not (Wait-TermServiceTcpPort -Port $newPort -TimeoutSeconds 30)) {
            throw "TermService did not bind TCP $newPort."
        } else {
            Write-Ok "Confirmed: TermService owns TCP $newPort."
        }
    } catch {
        $failureReason = $_.Exception.Message
        $rollback = Invoke-RdpMigrationRollback -FirewallState $firewallState -RegistryPath $rdpPath -PreviousPort $previousPort `
            -RegistryChanged $registryChanged -RestartService ([bool]$s.restartRemoteDesktopService)
        if (-not $rollback.Succeeded) {
            throw ("RDP port migration failed ({0}) AND rollback failed: {1}" -f $failureReason, ($rollback.Failures -join '; '))
        }
        throw ("RDP port migration failed ({0}); RDP was rolled back to TCP {1}." -f $failureReason, $previousPort)
    }

    # Only reachable once TermService demonstrably owns the new port, so blocking the old one
    # cannot strand the operator. A deferred (reboot-pending) change deliberately stops above.
    if ($activation.Outcome -ne 'RebootPending' -and $s.blockOldPort -and $previousPort -ne $newPort) {
        $blockName = "WinServerSetup Block Old RDP TCP $previousPort"
        if (-not (Get-NetFirewallRule -DisplayName $blockName -ErrorAction SilentlyContinue)) {
            try {
                New-NetFirewallRule -DisplayName $blockName -Direction Inbound -Protocol TCP -LocalPort $previousPort -Action Block -Profile Any -ErrorAction Stop | Out-Null
                Write-Ok "Actual previous RDP port $previousPort blocked after ownership verification."
            } catch { throw "Could not block previous RDP port ${previousPort}: $($_.Exception.Message)" }
        }
    }
}

# ------------------------------------------------------ H-02 / L-02 / M-04 task trust contract
# The blocker runs as SYSTEM every few minutes. Anything it executes or reads is therefore a
# privilege-escalation primitive if a non-administrator can replace it, and "a task with that
# name exists" is not evidence that the control still does its job. The functions below validate
# every target before registration, record the exact contract in an ACL-hardened manifest, and
# re-prove that contract - including the target hash and an over-long active run - at health time.

function Test-TrustedTaskTargetPath {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    $result = [pscustomobject]@{ Path = $Path; Trusted = $false; Reason = '' }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        $result.Reason = 'the path does not exist'
        return $result
    }
    if (Test-PathContainsReparsePoint -Path $Path) {
        $result.Reason = 'a reparse point exists in the parent or target chain'
        return $result
    }
    $writers = @(Get-UntrustedAclWriter -Path $Path)
    if ($writers.Count -gt 0) {
        $result.Reason = ('writable by non-administrative principal(s): {0}' -f ($writers -join ', '))
        return $result
    }
    $result.Trusted = $true
    return $result
}

function Initialize-TrustedTaskAcl {
    <#
        Deterministic hardening for a SYSTEM task target: inheritance disabled, inherited ACEs
        dropped, full control for SYSTEM and Administrators, read+execute for BUILTIN\Users.

        Fail-closed alone is not usable here: a directory freshly created under C:\ inherits
        "Authenticated Users: Modify" from the volume root, so the shipped relocation target is
        writable by default and every install would abort. Users keep read+execute so the
        non-elevated launcher can still start the tool, but nobody outside the administrative
        set can write a file that SYSTEM later executes, nor delete and replace its directory.
    #>
    param([Parameter(Mandatory)][string]$Path)
    # Never harden through a link: Set-Acl would follow it and rewrite the target's DACL.
    if (Test-PathContainsReparsePoint -Path $Path) { throw "Refusing to harden a path that contains a reparse point: $Path" }
    $inheritance = if (Test-Path -LiteralPath $Path -PathType Container) {
        [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else {
        [System.Security.AccessControl.InheritanceFlags]::None
    }
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($existing in @($acl.Access)) { $null = $acl.RemoveAccessRule($existing) }
    foreach ($grant in @(
            @{ Sid = 'S-1-5-18';     Rights = 'FullControl' },      # LOCAL SYSTEM
            @{ Sid = 'S-1-5-32-544'; Rights = 'FullControl' },      # BUILTIN\Administrators
            @{ Sid = 'S-1-5-32-545'; Rights = 'ReadAndExecute' })) {  # BUILTIN\Users
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    (New-Object System.Security.Principal.SecurityIdentifier($grant.Sid)),
                    [System.Security.AccessControl.FileSystemRights]$grant.Rights,
                    $inheritance,
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow)))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
    return $Path
}

function Assert-TrustedTaskTarget {
    <#
        H-02: validate every path a SYSTEM task executes or reads, plus the directories that
        could be used to replace them. -Harden repairs a writable directory or file once and
        re-validates; anything still untrusted afterwards - and every reparse point - fails
        closed rather than being registered.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Path,
        [switch]$Harden
    )
    foreach ($target in $Path) {
        $state = Test-TrustedTaskTargetPath -Path $target
        if (-not $state.Trusted -and $Harden -and $state.Reason -like 'writable by*') {
            Write-Warn ("Hardening SYSTEM task target {0}: {1}" -f $target, $state.Reason)
            Initialize-TrustedTaskAcl -Path $target | Out-Null
            $state = Test-TrustedTaskTargetPath -Path $target
        }
        if (-not $state.Trusted) {
            throw ("Refusing to register a SYSTEM scheduled task: {0} is not a trusted target ({1})." -f $target, $state.Reason)
        }
        Write-StructuredLog -Level TASK -Message ("Trusted SYSTEM task target verified: {0}" -f $target)
    }
    return $true
}

function Get-TaskTrustManifestRoot {
    # The manifest records what the health check trusts, so it must not itself be writable by a
    # non-administrator. It lives beside the download cache and gets the same hardening.
    $base = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($base)) { $base = Join-Path $env:SystemDrive 'ProgramData' }
    return (Initialize-TrustedDirectory -Path (Join-Path $base 'WinServerSetup\trust'))
}

function Get-TaskTrustManifestPath {
    param([Parameter(Mandatory)][string]$TaskName)
    $safeName = $TaskName -replace '[^A-Za-z0-9 ._-]', '_'
    return (Join-Path (Get-TaskTrustManifestRoot) ("{0}.json" -f $safeName))
}

function Save-TaskTrustManifest {
    param([Parameter(Mandatory)][string]$TaskName, [Parameter(Mandatory)]$Contract)
    $path = Get-TaskTrustManifestPath -TaskName $TaskName
    $Contract | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Get-TaskTrustManifest {
    param([Parameter(Mandatory)][string]$TaskName)
    $path = Get-TaskTrustManifestPath -TaskName $TaskName
    $state = Test-TrustedTaskTargetPath -Path $path
    if (-not $state.Trusted) {
        Write-StructuredLog -Level HEALTH -Message ("Task trust manifest is unusable ({0}): {1}" -f $state.Reason, $path)
        return
    }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch {
        Write-StructuredLog -Level HEALTH -Message ("Task trust manifest could not be parsed: {0}" -f $_.Exception.Message)
        return
    }
}

function ConvertFrom-ScheduledTaskDuration {
    <#
        Task Scheduler reports durations as ISO-8601, and the same value has several spellings
        ('PT5M', 'PT300S', 'PT0H5M0S'). Normalising through XmlConvert means the health check
        compares durations rather than strings. Absent or unparseable input returns nothing,
        which every caller reads as "no limit is set".
    #>
    param([AllowEmptyString()][string]$Duration)
    if ([string]::IsNullOrWhiteSpace($Duration)) { return }
    try { return [System.Xml.XmlConvert]::ToTimeSpan($Duration.Trim()) } catch { return }
}

function ConvertFrom-ScheduledTaskArgument {
    <#
        L-02: splits a task action argument string into its -Switch/value pairs, honouring
        quoting. A substring match is not a contract - '-Foo "C:\cfg.json"' contains the config
        path but never passes it to the blocker, and would have been reported as healthy.
    #>
    param([AllowEmptyString()][string]$Arguments)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($Arguments)) { return $map }
    $tokens = @([regex]::Matches($Arguments, '"[^"]*"|\S+') | ForEach-Object { $_.Value })
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $switchName = $tokens[$i]
        if ($switchName[0] -ne '-') { continue }
        $value = ''
        if (($i + 1) -lt $tokens.Count -and $tokens[$i + 1][0] -ne '-') {
            $value = $tokens[$i + 1].Trim('"')
            $i++
        }
        $map[$switchName.ToLowerInvariant()] = $value
    }
    return $map
}

function Test-BlockerTaskArgumentContract {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Arguments,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ConfigPath
    )
    $map = ConvertFrom-ScheduledTaskArgument -Arguments $Arguments
    foreach ($required in @('-noprofile', '-noninteractive')) {
        if (-not $map.ContainsKey($required)) { return $false }
    }
    if ([string]$map['-executionpolicy'] -ne 'Bypass') { return $false }
    try {
        if (-not [string]::Equals((ConvertTo-CanonicalPath ([string]$map['-file'])), (ConvertTo-CanonicalPath $ScriptPath), [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        if (-not [string]::Equals((ConvertTo-CanonicalPath ([string]$map['-configpath'])), (ConvertTo-CanonicalPath $ConfigPath), [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    } catch { return $false }
    return $true
}

function Get-BlockerExecutionTimeLimitMinutes {
    <#
        M-04: Task Scheduler's default ExecutionTimeLimit is PT72H. Combined with
        MultipleInstances=IgnoreNew, a single run that hangs suppresses every later trigger for
        three days while the task still looks registered and enabled.
    #>
    param([int]$ConfiguredMinutes = 0, [int]$IntervalMinutes = 5)
    $minutes = if ($ConfiguredMinutes -ge 1) { $ConfiguredMinutes } else { 5 }
    # Bounded relative to the repetition interval, because IgnoreNew means a run that outlives
    # its window skips triggers. Five windows is the ceiling, so the shipped 1-minute interval
    # allows the shipped 5-minute limit and nothing longer.
    $maximum = [Math]::Max(5, 5 * [Math]::Max(1, $IntervalMinutes))
    if ($minutes -gt $maximum) { $minutes = $maximum }
    return $minutes
}

function New-BlockerTaskArgument {
    # Always the CURRENT resolved config path, so post-relocate runs use the new path -- item 36.
    param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][string]$ConfigPath)
    return ('-WindowStyle Hidden -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $ScriptPath, $ConfigPath)
}

function Test-RdpBlockerTaskHealth {
    <#
        L-02 and M-04. The blocker is a security control, so the health check re-proves the whole
        contract recorded at registration: trusted executable, exact script path, exact canonical
        config path, argument shape, SYSTEM principal at the highest run level, trigger and
        repetition interval, ExecutionTimeLimit, MultipleInstances, the ACL and hash of every
        target, and that no active run has outlived its limit.
    #>
    param([Parameter(Mandatory)][string]$TaskName)
    $manifest = Get-TaskTrustManifest -TaskName $TaskName
    if ($null -eq $manifest) {
        Write-StructuredLog -Level HEALTH -Message ("No usable trust manifest for task {0}; re-run the RDP blocker step to register it." -f $TaskName)
        return $false
    }
    $task = $null
    $info = $null
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
    } catch {
        Write-StructuredLog -Level HEALTH -Message ("Task {0} could not be read: {1}" -f $TaskName, $_.Exception.Message)
        return $false
    }

    $reasons = New-Object System.Collections.Generic.List[string]
    $action = @($task.Actions)[0]
    $systemPowerShell = Join-Path $env:windir "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not [string]::Equals([string]$action.Execute, [string]$manifest.Execute, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$action.Execute, $systemPowerShell, [System.StringComparison]::OrdinalIgnoreCase)) {
        $reasons.Add(("the action executable is '{0}', not the registered system PowerShell" -f $action.Execute)) | Out-Null
    }
    if (-not (Test-BlockerTaskArgumentContract -Arguments ([string]$action.Arguments) -ScriptPath ([string]$manifest.ScriptPath) -ConfigPath ([string]$manifest.ConfigPath))) {
        $reasons.Add("the action arguments do not match the registered -File/-ConfigPath contract") | Out-Null
    }
    if ([string]$task.Principal.UserId -ne 'SYSTEM') { $reasons.Add(("the principal is '{0}', not SYSTEM" -f $task.Principal.UserId)) | Out-Null }
    if ([string]$task.Principal.RunLevel -ne 'Highest') { $reasons.Add(("the run level is '{0}', not Highest" -f $task.Principal.RunLevel)) | Out-Null }

    $trigger = @($task.Triggers)[0]
    if ($null -eq $trigger) {
        $reasons.Add("the task has no trigger and can never run") | Out-Null
    } else {
        $interval = ConvertFrom-ScheduledTaskDuration -Duration ([string]$trigger.Repetition.Interval)
        if ($null -eq $interval -or [int]$interval.TotalMinutes -ne [int]$manifest.IntervalMinutes) {
            $reasons.Add(("the trigger repetition is '{0}', not the registered {1} minute(s)" -f $trigger.Repetition.Interval, $manifest.IntervalMinutes)) | Out-Null
        }
    }

    $limit = ConvertFrom-ScheduledTaskDuration -Duration ([string]$task.Settings.ExecutionTimeLimit)
    if ($null -eq $limit -or $limit.TotalMinutes -le 0 -or [int]$limit.TotalMinutes -ne [int]$manifest.ExecutionTimeLimitMinutes) {
        $reasons.Add(("ExecutionTimeLimit is '{0}', not the registered {1} minute(s)" -f $task.Settings.ExecutionTimeLimit, $manifest.ExecutionTimeLimitMinutes)) | Out-Null
    }
    if ([string]$task.Settings.MultipleInstances -ne 'IgnoreNew') {
        $reasons.Add(("MultipleInstances is '{0}', not IgnoreNew" -f $task.Settings.MultipleInstances)) | Out-Null
    }

    foreach ($target in @([string]$manifest.ScriptPath, [string]$manifest.ConfigPath)) {
        $state = Test-TrustedTaskTargetPath -Path $target
        if (-not $state.Trusted) { $reasons.Add(("task target {0} is not trusted ({1})" -f $target, $state.Reason)) | Out-Null }
    }
    try {
        if (-not [string]::Equals((Get-Sha256Hex -Path ([string]$manifest.ScriptPath)), [string]$manifest.ScriptSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            $reasons.Add("the blocker script has changed since it was registered") | Out-Null
        }
    } catch {
        $reasons.Add(("the blocker script could not be hashed: {0}" -f $_.Exception.Message)) | Out-Null
    }

    # M-04: IgnoreNew is only safe while an over-long ACTIVE run counts as a failure. Without
    # this, a hung instance quietly suppresses every later trigger and the task still looks fine.
    if ([string]$task.State -eq 'Running' -and $null -ne $limit -and $null -ne $info.LastRunTime -and
        ((Get-Date) - [datetime]$info.LastRunTime) -gt $limit) {
        $reasons.Add(("a run started at {0} has outlived its {1} limit; end that instance and re-run the RDP blocker step" -f $info.LastRunTime, $task.Settings.ExecutionTimeLimit)) | Out-Null
    }
    if ([string]$task.State -eq 'Disabled') { $reasons.Add("the task is disabled") | Out-Null }
    # 0 = success, 267011 (0x00041303) = has not yet run, 267009 (0x00041301) = currently running.
    $lastResult = [int]$info.LastTaskResult
    if ($lastResult -notin @(0, 267011, 267009)) { $reasons.Add(("the last run result was {0}" -f $lastResult)) | Out-Null }
    if (-not $info.NextRunTime -and [string]$task.State -ne 'Running') { $reasons.Add("no next run is scheduled") | Out-Null }

    if ($reasons.Count -gt 0) {
        foreach ($reason in $reasons) { Write-StructuredLog -Level HEALTH -Message ("RDP blocker task {0}: {1}" -f $TaskName, $reason) }
        Write-Warn ("RDP blocker task contract failed - {0}. Re-run the RDP brute-force blocker step to repair it." -f ($reasons -join '; '))
        return $false
    }
    return $true
}

function Install-RdpBruteforceBlocker {
    $s = $Global:Config.rdpBruteforceBlocker
    if (-not $s.enabled) { Set-StepSkipped "disabled in config"; return }
    $scriptPath = ConvertTo-CanonicalPath (Join-Path $Global:ProjectRoot "scripts\Block-RdpBruteforce.ps1")
    if (-not (Test-Path $scriptPath)) { throw "Blocker script not found: $scriptPath" }
    $configPath = ConvertTo-CanonicalPath $Global:ConfigPath

    # M-01: the blocker writes every block rule on rdp.newPort. Registering while the machine
    # actually serves RDP on a different port produces a control that looks healthy and filters
    # nothing, so config, registry and the live listener must agree before anything is created.
    $rdpPort = Assert-RdpPortAgreement

    $psExe = Join-Path $env:windir "System32\WindowsPowerShell\v1.0\powershell.exe"
    # H-02: every path this SYSTEM task executes or reads, plus the directories that could be
    # used to replace them. Root-only validation is not enough - the exact action target and the
    # config the task consumes are validated by name.
    Assert-TrustedTaskTarget -Harden -Path @(
        $psExe, (ConvertTo-CanonicalPath $Global:ProjectRoot), (Split-Path -Parent $scriptPath), $scriptPath, $configPath) | Out-Null

    $taskName = [string]$s.taskName
    $interval = [int]$s.taskIntervalMinutes; if ($interval -lt 1) { $interval = 5 }
    $limitMinutes = Get-BlockerExecutionTimeLimitMinutes -ConfiguredMinutes ([int]$s.executionTimeLimitMinutes) -IntervalMinutes $interval
    $arguments = New-BlockerTaskArgument -ScriptPath $scriptPath -ConfigPath $configPath

    $action    = New-ScheduledTaskAction    -Execute $psExe -Argument $arguments
    $trigger   = New-ScheduledTaskTrigger   -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes $interval)
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    # M-04: the explicit ExecutionTimeLimit is what makes MultipleInstances=IgnoreNew safe.
    $settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden `
        -ExecutionTimeLimit (New-TimeSpan -Minutes $limitMinutes)

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Ok ("Scheduled task registered: {0}  (hidden, highest privileges, RDP port {1}, {2} min run limit)" -f $taskName, $rdpPort, $limitMinutes)
    Write-Info ("Task argument: {0}" -f $arguments)

    # L-02: record the contract the health check has to re-prove later, including the hash of the
    # exact file SYSTEM will execute.
    Save-TaskTrustManifest -TaskName $taskName -Contract ([pscustomobject]@{
            TaskName                  = $taskName
            Execute                   = $psExe
            Arguments                 = $arguments
            ScriptPath                = $scriptPath
            ConfigPath                = $configPath
            ScriptSha256              = (Get-Sha256Hex -Path $scriptPath)
            IntervalMinutes           = $interval
            ExecutionTimeLimitMinutes = $limitMinutes
            RdpPort                   = $rdpPort
            RegisteredUtc             = (Get-Date).ToUniversalTime().ToString('o')
        }) | Out-Null

    if (-not (Test-RdpBlockerTaskHealth -TaskName $taskName)) {
        throw "RDP blocker task '$taskName' did not satisfy its own registration contract immediately after being registered."
    }
    Write-Ok "RDP blocker task verified against its recorded trust contract."

    Invoke-BlockerVerificationRun -PowerShellExe $psExe -ScriptPath $scriptPath -ConfigPath $configPath
}

function Invoke-BlockerVerificationRun {
    # Extracted from Install-RdpBruteforceBlocker so the installer can be exercised in tests
    # without launching the real blocker against the live event log and firewall.
    param(
        [Parameter(Mandatory)][string]$PowerShellExe,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ConfigPath
    )
    Write-Info "Running blocker once now for verification..."
    & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -ConfigPath $ConfigPath
    if ($LASTEXITCODE -ne 0) { throw "Running blocker verification failed with exit code $LASTEXITCODE." }
    Write-Ok "RDP blocker verification run completed successfully."
}
