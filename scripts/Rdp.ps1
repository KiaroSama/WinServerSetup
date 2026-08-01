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
    $previousPort = [int](Get-ItemProperty -Path $rdpPath -Name "PortNumber" -ErrorAction Stop).PortNumber
    if ((Test-TcpPortListening -Port $newPort) -and -not (Test-TermServiceOwnsTcpPort -Port $newPort)) {
        throw "TCP $newPort is already occupied by a process other than TermService; no RDP settings were changed."
    }

    Write-Info "Step 1/5: Enable Remote Desktop in registry."
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue

    Write-Info "Step 2/5: Pre-create inbound firewall rule for new port $newPort BEFORE changing service port."
    $newRule = "WinServerSetup RDP TCP $newPort"
    if (-not (Ensure-RdpFirewallRule -DisplayName $newRule -Port $newPort)) {
        throw "ABORTING RDP port change to prevent lockout because firewall setup failed."
    }

    Write-Info "Step 3/5: Backup current PortNumber=$previousPort and update registry."
    $backup = Resolve-RelativePath "backups\RDP-Tcp-PortNumber.reg"
    & reg.exe export "HKLM\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" "$backup" /y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "RDP registry backup export failed with exit code $LASTEXITCODE." }
    if ($previousPort -ne $newPort) {
        Set-ItemProperty -Path $rdpPath -Name "PortNumber" -Type DWord -Value $newPort -ErrorAction Stop
        Write-Ok "PortNumber registry value set to $newPort."
    } else {
        Write-Info "RDP PortNumber is already $newPort; validating the existing configuration."
    }

    Write-Info "Step 4/5: Restart TermService to bind the new port."
    if ($s.restartRemoteDesktopService -and -not (Test-TermServiceOwnsTcpPort -Port $newPort)) {
        Write-Warn "Restarting Remote Desktop service -- your current RDP session may briefly disconnect."
        try {
            Restart-Service TermService -Force -ErrorAction Stop
        } catch {
            try {
                Restore-RdpPort -RegistryPath $rdpPath -PreviousPort $previousPort -RestartService $true
            } catch {
                throw "TermService restart failed and rollback could not be verified: $($_.Exception.Message)"
            }
            throw "TermService restart failed; RDP port was restored to $previousPort."
        }
    } else {
        Write-Info "Skipping service restart (config). Reboot will apply the change."
        Set-PendingReboot "RDP port change requires service restart"
    }

    Write-Info "Step 5/5: Verify the new port is listening."
    if ($s.verifyListening) {
        if (Wait-TermServiceTcpPort -Port $newPort -TimeoutSeconds 30) {
            Write-Ok "Confirmed: TermService owns TCP $newPort."
            if ($s.blockOldPort -and $previousPort -ne $newPort) {
                $blockName = "WinServerSetup Block Old RDP TCP $previousPort"
                if (-not (Get-NetFirewallRule -DisplayName $blockName -ErrorAction SilentlyContinue)) {
                    try {
                        New-NetFirewallRule -DisplayName $blockName -Direction Inbound -Protocol TCP -LocalPort $previousPort -Action Block -Profile Any -ErrorAction Stop | Out-Null
                        Write-Ok "Actual previous RDP port $previousPort blocked after ownership verification."
                    } catch { throw "Could not block previous RDP port ${previousPort}: $($_.Exception.Message)" }
                }
            }
        } else {
            Restore-RdpPort -RegistryPath $rdpPath -PreviousPort $previousPort -RestartService ([bool]$s.restartRemoteDesktopService)
            if (-not (Test-TermServiceOwnsTcpPort -Port $previousPort) -and $s.restartRemoteDesktopService) {
                throw "RDP migration failed and rollback ownership verification failed for TCP $previousPort."
            }
            throw "TermService did not bind TCP $newPort; RDP PortNumber was rolled back to $previousPort."
        }
    }
}

function Install-RdpBruteforceBlocker {
    $s = $Global:Config.rdpBruteforceBlocker
    if (-not $s.enabled) { Set-StepSkipped "disabled in config"; return }
    $scriptPath = Join-Path $Global:ProjectRoot "scripts\Block-RdpBruteforce.ps1"
    if (-not (Test-Path $scriptPath)) { throw "Blocker script not found: $scriptPath" }

    $taskName = [string]$s.taskName
    $interval = [int]$s.taskIntervalMinutes; if ($interval -lt 1) { $interval = 5 }
    $hidden   = $true

    $psExe = Join-Path $env:windir "System32\WindowsPowerShell\v1.0\powershell.exe"
    $hiddenFlag = if ($hidden) { "-WindowStyle Hidden " } else { "" }
    # Always use the CURRENT resolved config path (so post-relocate runs use the new path) -- item 36.
    $arguments = "${hiddenFlag}-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" -ConfigPath `"$Global:ConfigPath`""

    $action    = New-ScheduledTaskAction    -Execute $psExe -Argument $arguments
    $trigger   = New-ScheduledTaskTrigger   -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes $interval)
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Ok ("Scheduled task registered: {0}  (hidden, highest privileges)" -f $taskName)
    Write-Info ("Task argument: {0}" -f $arguments)
    try {
        $registered = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $registeredAction = $registered.Actions | Select-Object -First 1
        Write-StructuredLog -Level TASK -Message ("{0} execute: {1}" -f $taskName, $registeredAction.Execute)
        Write-StructuredLog -Level TASK -Message ("{0} arguments: {1}" -f $taskName, $registeredAction.Arguments)
        if ([string]$registeredAction.Arguments -notlike "*$Global:ConfigPath*") {
            Write-Warn "RDP blocker task action does not appear to reference the resolved config path."
        } else {
            Write-Ok "RDP blocker task action verified with config path: $Global:ConfigPath"
        }
    } catch {
        Write-Warn "Could not verify RDP blocker scheduled task action: $($_.Exception.Message)"
    }

    Write-Info "Running blocker once now for verification..."
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ConfigPath $Global:ConfigPath
    if ($LASTEXITCODE -ne 0) { throw "Running blocker verification failed with exit code $LASTEXITCODE." }
    Write-Ok "RDP blocker verification run completed successfully."
}
