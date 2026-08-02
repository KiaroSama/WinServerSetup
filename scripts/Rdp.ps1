# Rdp.ps1 - RDP listener checks, the operator port prompt, and the port-migration safety path
# with its firewall rule and rollback.
#
# Installation of the brute-force blocker SCHEDULED TASK - target trust validation, staging, the
# trust manifest and the health contract - lives in RdpBlockerTask.ps1. Dot-sourced by
# WinServerSetup.ps1; function definitions only, globals read at call time.

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

function Read-RdpTargetPort {
    <#
        The operator picks the port BEFORE anything is enabled, written, restarted or published.
        rdp.newPort is the offered default, not the decision.

        Validating here rather than downstream is deliberate: a typo or an occupied port costs a
        re-prompt instead of a registry write plus a rollback, and abandoning the prompt leaves
        the machine exactly as it was found - current port still bound, still open, still
        reachable.

        A run that cannot ask keeps the configured value and says so. -NoPause is an unattended
        provisioning run, and a host with no readable console (redirected input, a -NonInteractive
        child) would otherwise throw here and fail a step that had a perfectly good default.
    #>
    param([Parameter(Mandatory)][int]$ConfiguredPort)

    if ($Global:NoPause) {
        Write-Info ("Noninteractive run: keeping the configured RDP port {0} without prompting." -f $ConfiguredPort)
        return $ConfiguredPort
    }
    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $answer = ''
        try {
            $answer = [string](Read-HostThemed -Prompt 'Which TCP port should Remote Desktop listen on' -DefaultValue ([string]$ConfiguredPort))
        } catch {
            Write-Warn ("No console is available to choose an RDP port ({0}); keeping the configured {1}." -f $_.Exception.Message, $ConfiguredPort)
            return $ConfiguredPort
        }
        $port = 0
        if (-not [int]::TryParse($answer.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
            Write-Warn ("'{0}' is not a TCP port number; enter a value between 1 and 65535." -f $answer)
            continue
        }
        # Refused here rather than after the migration starts, so the operator can correct it.
        if ((Test-TcpPortListening -Port $port) -and -not (Test-TermServiceOwnsTcpPort -Port $port)) {
            Write-Warn ("TCP {0} is already held by another listener; choose a port nothing else is using." -f $port)
            continue
        }
        return $port
    }
    throw ("No usable RDP port was chosen after {0} attempts; no RDP settings were changed." -f $maxAttempts)
}

function Configure-RdpPortAndFirewall {
    $s = $Global:Config.rdp
    if (-not $s.enabled) { Set-StepSkipped "disabled in config"; return }
    $configuredPort = [int]$s.newPort
    if ($configuredPort -lt 1 -or $configuredPort -gt 65535) { throw "Invalid RDP port: $configuredPort" }
    # Asked first, before Step 1 touches anything at all: an abandoned or invalid prompt must be
    # able to abort without a single registry, firewall or service change to undo.
    $newPort = Read-RdpTargetPort -ConfiguredPort $configuredPort

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

    # The registry now holds the operator's choice, so rdp.newPort has to as well: everything
    # downstream in this run reasons about it, and Assert-RdpPortAgreement would otherwise refuse
    # to install the brute-force blocker with "config, registry and listener disagree". In-memory
    # only - the tracked config file is never rewritten.
    $s.newPort = $newPort

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
