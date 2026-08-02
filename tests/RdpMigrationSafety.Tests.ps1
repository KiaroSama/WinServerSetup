<#
    Behavioral tests for the RDP port-migration safety path in WinServerSetup.ps1.

    This file used to consist entirely of five regex matches against the source text. That
    reported green for any refactor that kept the names and literals intact while inverting a
    condition or reordering a rollback - and the failure mode of this code path is "the
    administrator can no longer reach the server".

    The tests below extract the real functions and run them against shadowed Windows cmdlets, so
    a behavioral regression fails the suite. The original greps are retained at the end as cheap
    smoke checks, but they are no longer the only coverage.

    This harness mocks Windows-only cmdlets by shadowing them with functions. The mock signatures
    must mirror the real cmdlets - including parameters this file never reads - so the code under
    test binds exactly as it does in production.
#>
# -MainScript targets an alternate copy so these tests can be replayed against a deliberately
# defective build to prove they still fail. CI and local runs use the default.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Cmdlets are shadowed deliberately to mock Windows-only APIs.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock signatures mirror the real cmdlets so parameter binding matches production.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', '', Justification = 'The firewall mocks mirror New-/Set-NetFirewallRule, whose real parameter is named -Profile.')]
param([string]$MainScript = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$mainScript = if ([string]::IsNullOrWhiteSpace($MainScript)) { Join-Path $projectRoot "WinServerSetup.ps1" } else { $MainScript }

. (Join-Path $PSScriptRoot '_Common.ps1')

# ---- Import only the functions under test; the main script self-executes if dot-sourced. ----
# WinServerSetup.ps1 dot-sources its function library from scripts\; search that whole
# partition so extraction by name keeps working wherever a function lives. $mainScript is
# searched first, so a -MainScript copy still shadows the on-disk original when replaying
# against a deliberately defective build.
$setupSourceFiles = @(Get-SetupSourceFile -ProjectRoot $projectRoot -MainScript $mainScript)
$setupAsts = @(Get-SetupAst -Files $setupSourceFiles -Because 'its RDP migration path can be tested')
# Raw text of the same partition, for the retained source assertions further down.
$source = ($setupSourceFiles | ForEach-Object { Get-Content -LiteralPath $_ -Raw -Encoding UTF8 }) -join "`r`n"

foreach ($name in @('Get-TermServiceProcessId', 'Test-TermServiceOwnsTcpPort', 'Wait-TermServiceTcpPort', 'Restore-RdpPort',
        'Test-TcpPortListening', 'Ensure-RdpFirewallRule', 'Read-RdpTargetPort', 'Configure-RdpPortAndFirewall',
        'Get-ManagedFirewallRuleState', 'Restore-ManagedFirewallRuleState', 'Invoke-RdpMigrationRollback',
        'Invoke-RdpServicePortActivation', 'Get-RdpRegistryPortNumber')) {
    . ([scriptblock]::Create((Import-FunctionUnderTest $name $setupAsts)))
}

# ---- Fake Windows state. Every case drives these instead of touching the real machine. ----
$script:TermServicePid       = 4321
$script:ListenerOwningPids   = @()
$script:TcpQueryCount        = 0
$script:RestartCount         = 0
$script:RestartGrantsPort    = $false
$script:SetItemPropertyCalls = New-Object System.Collections.Generic.List[object]
$script:PendingRebootReasons = New-Object System.Collections.Generic.List[string]
$script:Warnings             = New-Object System.Collections.Generic.List[string]

function Get-CimInstance {
    param([string]$ClassName, [string]$Filter, $ErrorAction)
    return [pscustomobject]@{ Name = 'TermService'; ProcessId = $script:TermServicePid }
}
function Get-NetTCPConnection {
    param([string]$State, [int]$LocalPort, $ErrorAction)
    $script:TcpQueryCount++
    if (@($script:ListenerOwningPids).Count -eq 0) {
        # The real cmdlet raises a terminating error when nothing matches, rather than returning
        # an empty set. The code under test has to absorb that, so the mock reproduces it.
        throw "No MSFT_NetTCPConnection objects found with property 'LocalPort' equal to '$LocalPort'."
    }
    return @($script:ListenerOwningPids | ForEach-Object {
            [pscustomobject]@{ LocalPort = $LocalPort; State = 'Listen'; OwningProcess = $_ }
        })
}
function Restart-Service {
    # Deliberately a simple function: a [Parameter()] attribute here would make it an advanced
    # function, and its automatic -ErrorAction common parameter would collide with the explicit
    # one the production call site passes.
    param([string]$Name, [switch]$Force, $ErrorAction)
    $script:RestartCount++
    if ($script:RestartGrantsPort) { $script:ListenerOwningPids = @($script:TermServicePid) }
}
function Set-ItemProperty {
    param([string]$Path, [string]$Name, $Type, $Value, $ErrorAction)
    $script:SetItemPropertyCalls.Add([pscustomobject]@{ Path = $Path; Name = $Name; Type = [string]$Type; Value = $Value }) | Out-Null
}

# ---- Console/logging collaborators, so nothing reaches the real console or run state. ----
function Write-Info { param([string]$Message) }
function Write-Ok { param([string]$Message) }
function Write-Warn { param([string]$Message) $script:Warnings.Add([string]$Message) | Out-Null }
function Write-Fail { param([string]$Message) $script:Warnings.Add("FAIL " + [string]$Message) | Out-Null }
function Write-StatusInPlace { param([string]$Message) }
function Clear-StatusInPlace { }
function Write-StructuredLog { param([string]$Level, [string]$Message, [string]$Section) }
function Set-PendingReboot { param([string]$Reason = "") $script:PendingRebootReasons.Add([string]$Reason) | Out-Null }

function Reset-RdpTestState {
    param([int]$ServicePid = 4321, [int[]]$ListenerPids = @(), [bool]$RestartGrantsPort = $false)
    $script:TermServicePid = $ServicePid
    $script:ListenerOwningPids = @($ListenerPids)
    $script:TcpQueryCount = 0
    $script:RestartCount = 0
    $script:RestartGrantsPort = $RestartGrantsPort
    $script:SetItemPropertyCalls.Clear()
    $script:PendingRebootReasons.Clear()
    $script:Warnings.Clear()
}

$rdpKey = 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'

# ---- 1. TermService owns the listener on the port. ----
Reset-RdpTestState -ServicePid 4321 -ListenerPids @(4321)
Assert-Equal 4321 (Get-TermServiceProcessId) "The service PID must be read from the Win32_Service record."
Assert-Equal $true (Test-TermServiceOwnsTcpPort -Port 5801) "TermService must be recognised as the owner of its own listener."

# ---- 2. Another process owns the port. This is the check that prevents a lockout: the caller
#         aborts the whole migration rather than moving RDP onto an occupied port. ----
Reset-RdpTestState -ServicePid 4321 -ListenerPids @(9999)
Assert-Equal $false (Test-TermServiceOwnsTcpPort -Port 5801) `
    "A listener owned by a different process must never be reported as TermService's."

# ---- 3. Nothing is listening: the cmdlet throws, and the check must absorb it. ----
Reset-RdpTestState -ServicePid 4321 -ListenerPids @()
Assert-Equal $false (Test-TermServiceOwnsTcpPort -Port 5801) `
    'An absent listener must yield a false result, not propagate the cmdlet exception.'

# ---- 4. TermService is not running: no port query should even be attempted. ----
Reset-RdpTestState -ServicePid 0 -ListenerPids @(4321)
Assert-Equal $false (Test-TermServiceOwnsTcpPort -Port 5801) "A stopped TermService can own nothing."
Assert-Equal 0 $script:TcpQueryCount "A stopped TermService must short-circuit before querying listeners."

# ---- 5. The bounded wait returns as soon as ownership is established. ----
Reset-RdpTestState -ServicePid 4321 -ListenerPids @(4321)
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$waited = Wait-TermServiceTcpPort -Port 5801 -TimeoutSeconds 2
$stopwatch.Stop()
Assert-Equal $true $waited "An already-owned port must satisfy the wait on the first poll."
Assert-True ($stopwatch.Elapsed.TotalSeconds -lt 2) "An already-owned port must not wait out the deadline."

# ---- 6. The wait is actually bounded by -TimeoutSeconds. If the deadline were ignored or the
#         parameter dropped, this would run for the 30 s default (or forever). ----
Reset-RdpTestState -ServicePid 4321 -ListenerPids @(9999)
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$waited = Wait-TermServiceTcpPort -Port 5801 -TimeoutSeconds 2
$stopwatch.Stop()
Assert-Equal $false $waited "A port TermService never claims must fail the wait."
Assert-True ($stopwatch.Elapsed.TotalSeconds -ge 1) "The wait must actually poll before giving up."
Assert-True ($stopwatch.Elapsed.TotalSeconds -lt 8) "The wait must honour -TimeoutSeconds instead of the 30 s default."

# ---- 7. Rollback happy path, against the real Wait-TermServiceTcpPort: write the previous port
#         back, restart, and confirm the service reclaimed the listener. ----
Reset-RdpTestState -ServicePid 4321 -ListenerPids @(9999) -RestartGrantsPort $true
Restore-RdpPort -RegistryPath $rdpKey -PreviousPort 3389 -RestartService $true
Assert-Equal 1 $script:SetItemPropertyCalls.Count "Rollback must write the registry exactly once."
Assert-Equal 'PortNumber' $script:SetItemPropertyCalls[0].Name "Rollback must write the PortNumber value."
Assert-Equal 3389 $script:SetItemPropertyCalls[0].Value "Rollback must restore the previous port, not the new one."
Assert-Equal $rdpKey $script:SetItemPropertyCalls[0].Path "Rollback must target the RDP-Tcp key."
Assert-Equal 1 $script:RestartCount "Rollback with restart requested must restart TermService once."
Assert-Equal 0 $script:PendingRebootReasons.Count "A verified live rollback must not defer to a reboot."
Assert-True ((($script:Warnings) -join "`n") -match '3389') "A rollback must be announced with the port it restored."

# ---- 9. Rollback without a restart must defer to a reboot instead of silently doing nothing. ----
Reset-RdpTestState -ServicePid 4321 -ListenerPids @(4321)
Restore-RdpPort -RegistryPath $rdpKey -PreviousPort 3389 -RestartService $false
Assert-Equal 0 $script:RestartCount "Rollback without restart must not restart the service."
Assert-Equal 1 $script:SetItemPropertyCalls.Count "Rollback without restart must still write the registry."
Assert-Equal 1 $script:PendingRebootReasons.Count "Rollback without restart must flag a pending reboot exactly once."
Assert-True ($script:PendingRebootReasons[0] -match '3389') "The pending-reboot reason must name the port being restored."

# ---- 8. Rollback must FAIL LOUDLY when the service does not reclaim the port. A silent success
#         here is the worst outcome in this file: the operator is told RDP was restored while the
#         box is unreachable.
#
#         -WaitTimeoutSeconds drives the REAL Wait-TermServiceTcpPort here. While the wait was
#         hard-coded to 30 s this branch could only be reached through a stubbed wait, which
#         proved nothing about the production wiring; now the whole path runs unmocked in about
#         two seconds. ----
Reset-RdpTestState -ServicePid 4321 -ListenerPids @(9999)
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$rollbackError = $null
try {
    Restore-RdpPort -RegistryPath $rdpKey -PreviousPort 3389 -RestartService $true -WaitTimeoutSeconds 2
} catch {
    $rollbackError = [string]$_.Exception.Message
}
$stopwatch.Stop()
Assert-True ($null -ne $rollbackError) "An unverified rollback must throw, never return quietly."
Assert-True ($rollbackError -match 'did not reclaim') "The rollback failure must say the service never reclaimed the port."
Assert-Equal 1 $script:SetItemPropertyCalls.Count "The registry must still be rolled back before the failure is raised."
Assert-Equal 1 $script:RestartCount "The failing rollback must have attempted the restart."
Assert-True ($stopwatch.Elapsed.TotalSeconds -ge 1) "The rollback must actually poll the real wait before giving up."
Assert-True ($stopwatch.Elapsed.TotalSeconds -lt 15) "Restore-RdpPort must pass -WaitTimeoutSeconds through instead of waiting out the 30 s default."

# =============================================================================================
# M-09 and M-10: Configure-RdpPortAndFirewall driven END TO END against mocked Windows APIs.
#
# Everything the migration touches - registry, firewall, service, the reg.exe backup - is
# shadowed below, so no case here can reach the live machine. Wait-TermServiceTcpPort is
# replaced with an instant probe from this point on; its real bounded-wait behaviour is already
# proven by cases 5, 6 and 8 above, and the 30 s default would otherwise dominate the run.
# =============================================================================================
$script:ListenersByPort  = @{}
$script:RestartBinds     = @()
$script:RestartFails     = $false
$script:RegistryPort     = 3389
$script:FirewallRules    = @{}
$script:FirewallCalls    = New-Object System.Collections.Generic.List[string]
$script:NewRuleThrows    = $false
$script:RemoveRuleThrows = $false
$script:VerifyRuleBroken = $false
$script:BackupCount      = 0
# One ORDERED record of the three event kinds whose relative order is the anti-lockout contract:
# the new port's allow rule, the PortNumber write, the service restart, and the old port's block
# rule. Kept separate from $script:FirewallCalls, which only ever sees firewall operations.
$script:Timeline         = New-Object System.Collections.Generic.List[string]
# Scripted operator answers for the port prompt, consumed one per Read-HostThemed call.
$script:PromptAnswers    = New-Object System.Collections.Generic.Queue[string]
$script:PromptCount      = 0
$script:PromptThrows     = $false

function Read-HostThemed {
    # Mirrors scripts\Console.ps1: a blank answer yields the offered default.
    param([Parameter(Mandatory)][string]$Prompt, [string]$DefaultValue = "")
    $script:PromptCount++
    if ($script:PromptThrows) { throw "Cannot read from the host: the input stream is redirected." }
    if ($script:PromptAnswers.Count -eq 0) { throw "The suite ran out of scripted prompt answers (prompt: $Prompt)." }
    $answer = [string]$script:PromptAnswers.Dequeue()
    if ([string]::IsNullOrWhiteSpace($answer) -and -not [string]::IsNullOrWhiteSpace($DefaultValue)) { return $DefaultValue }
    return $answer
}

function Wait-TermServiceTcpPort {
    param([int]$Port, [int]$TimeoutSeconds = 30)
    return (Test-TermServiceOwnsTcpPort -Port $Port)
}
function Get-NetTCPConnection {
    param([string]$State, [int]$LocalPort, $ErrorAction)
    $script:TcpQueryCount++
    $owners = @(@($script:ListenersByPort[$LocalPort]) | Where-Object { $_ })
    if ($owners.Count -eq 0) { throw "No MSFT_NetTCPConnection objects found with property 'LocalPort' equal to '$LocalPort'." }
    return @($owners | ForEach-Object { [pscustomobject]@{ LocalPort = $LocalPort; State = 'Listen'; OwningProcess = $_ } })
}
function Restart-Service {
    param([string]$Name, [switch]$Force, $ErrorAction)
    $script:RestartCount++
    $script:Timeline.Add('SVC-RESTART') | Out-Null
    if ($script:RestartFails) { throw "Service '$Name' could not be restarted." }
    # The service releases whatever it held and binds the port scripted for this restart. A
    # scripted 0 models "the registry value was rejected and nothing came back up".
    $index = [Math]::Min($script:RestartCount - 1, (@($script:RestartBinds).Count - 1))
    $bind = if ($index -ge 0) { [int]@($script:RestartBinds)[$index] } else { 0 }
    $script:ListenersByPort = @{}
    if ($bind -gt 0) { $script:ListenersByPort[$bind] = @($script:TermServicePid) }
}
function Get-ItemProperty {
    param([string]$Path, [string]$Name, $ErrorAction)
    return [pscustomobject]@{ PortNumber = $script:RegistryPort }
}
function Set-ItemProperty {
    param([string]$Path, [string]$Name, $Type, $Value, $ErrorAction)
    $script:SetItemPropertyCalls.Add([pscustomobject]@{ Path = $Path; Name = $Name; Type = [string]$Type; Value = $Value }) | Out-Null
    if ($Name -eq 'PortNumber') {
        $script:RegistryPort = [int]$Value
        $script:Timeline.Add("REG-PORT $Value") | Out-Null
    }
}
function Backup-RdpRegistryKey { $script:BackupCount++; return 'TestDrive:\backup.reg' }
function Set-StepSkipped { param([string]$Reason) }

function Enable-NetFirewallRule {
    param([string]$DisplayGroup, [string]$DisplayName, $ErrorAction)
    $script:FirewallCalls.Add("ENABLEGROUP $DisplayGroup") | Out-Null
}
function Get-NetFirewallRule {
    param([string]$DisplayName, [string]$DisplayGroup, $ErrorAction)
    if (-not $script:FirewallRules.ContainsKey($DisplayName)) {
        if ("$ErrorAction" -eq 'Stop') { throw "No MSFT_NetFirewallRule objects found with property 'DisplayName' equal to '$DisplayName'." }
        return
    }
    return $script:FirewallRules[$DisplayName]
}
function New-NetFirewallRule {
    param([string]$DisplayName, [string]$Direction, [string]$Protocol, $LocalPort, [string]$Action, [string]$Profile, $ErrorAction)
    $script:FirewallCalls.Add("NEW $DisplayName") | Out-Null
    $script:Timeline.Add("FW-NEW $DisplayName") | Out-Null
    if ($script:NewRuleThrows) { throw "The parameter is incorrect." }
    $script:FirewallRules[$DisplayName] = [pscustomobject]@{
        DisplayName = $DisplayName; Enabled = 'True'; Action = $Action; Direction = $Direction
        Profile = $Profile; Protocol = $Protocol; LocalPort = [string]$LocalPort
    }
    return $script:FirewallRules[$DisplayName]
}
function Remove-NetFirewallRule {
    param([string]$DisplayName, $ErrorAction)
    $piped = @($input)
    $name = if ($piped.Count -gt 0) { [string]$piped[0].DisplayName } else { $DisplayName }
    $script:FirewallCalls.Add("REMOVE $name") | Out-Null
    if ($script:RemoveRuleThrows) { throw "Access is denied." }
    $script:FirewallRules.Remove($name) | Out-Null
}
function Set-NetFirewallRule {
    param([string]$DisplayName, $Enabled, $Action, $Direction, $Profile, $ErrorAction)
    $piped = @($input)
    $name = if ($piped.Count -gt 0) { [string]$piped[0].DisplayName } else { $DisplayName }
    $script:FirewallCalls.Add("SET $name") | Out-Null
    if (-not $script:FirewallRules.ContainsKey($name)) { throw "Cannot find a rule named '$name'." }
    $rule = $script:FirewallRules[$name]
    if ($null -ne $Enabled)   { $rule.Enabled = [string]$Enabled }
    if ($null -ne $Action)    { $rule.Action = [string]$Action }
    if ($null -ne $Direction) { $rule.Direction = [string]$Direction }
    if ($null -ne $Profile)   { $rule.Profile = [string]$Profile }
}
function Get-NetFirewallPortFilter {
    param($ErrorAction)
    $piped = @($input)
    $name = if ($piped.Count -gt 0) { [string]$piped[0].DisplayName } else { '' }
    $rule = $script:FirewallRules[$name]
    return [pscustomobject]@{
        DisplayName = $name
        Protocol    = $(if ($rule) { [string]$rule.Protocol } else { '' })
        LocalPort   = $(if ($rule) { [string]$rule.LocalPort } else { '' })
    }
}
function Set-NetFirewallPortFilter {
    param($Protocol, $LocalPort, $ErrorAction)
    $piped = @($input)
    $name = if ($piped.Count -gt 0) { [string]$piped[0].DisplayName } else { '' }
    $script:FirewallCalls.Add("SETFILTER $name") | Out-Null
    if (-not $script:FirewallRules.ContainsKey($name)) { throw "Cannot find a rule named '$name'." }
    $rule = $script:FirewallRules[$name]
    if ($null -ne $Protocol) { $rule.Protocol = [string]$Protocol }
    if ($null -ne $LocalPort) {
        # One-shot sabotage so Ensure-RdpFirewallRule's own read-back verification fails AFTER it
        # has already modified a pre-existing rule. Cleared immediately so the rollback that
        # follows is measured honestly.
        if ($script:VerifyRuleBroken) { $script:VerifyRuleBroken = $false; $rule.LocalPort = '9999' }
        else { $rule.LocalPort = [string]$LocalPort }
    }
}

function New-RdpMigrationConfig {
    param([int]$NewPort = 5801, [bool]$Restart = $true, [bool]$Verify = $true, [bool]$BlockOld = $true)
    return [pscustomobject]@{
        rdp = [pscustomobject]@{
            enabled = $true; newPort = $NewPort; oldPort = 3389; blockOldPort = $BlockOld
            restartRemoteDesktopService = $Restart; verifyListening = $Verify
        }
    }
}
function New-FirewallRuleRecord {
    param([string]$DisplayName, [string]$Enabled, [string]$Action, [string]$Direction, [string]$RuleProfile, [string]$Protocol, [string]$LocalPort)
    return [pscustomobject]@{
        DisplayName = $DisplayName; Enabled = $Enabled; Action = $Action; Direction = $Direction
        Profile = $RuleProfile; Protocol = $Protocol; LocalPort = $LocalPort
    }
}
function Reset-MigrationState {
    param([int]$RegistryPort = 3389, [hashtable]$Listeners = @{}, [int[]]$RestartBinds = @(), [hashtable]$Rules = @{})
    Reset-RdpTestState -ServicePid 4321
    $script:RegistryPort     = $RegistryPort
    $script:ListenersByPort  = $Listeners
    $script:RestartBinds     = @($RestartBinds)
    $script:RestartFails     = $false
    $script:NewRuleThrows    = $false
    $script:RemoveRuleThrows = $false
    $script:VerifyRuleBroken = $false
    $script:FirewallRules    = $Rules
    $script:FirewallCalls.Clear()
    $script:BackupCount      = 0
    $script:Timeline.Clear()
    # The migration-mechanics cases below are not about the prompt, so they run the noninteractive
    # path and take the configured port. The prompt cases opt back in explicitly.
    $Global:NoPause          = $true
    $script:PromptAnswers    = New-Object System.Collections.Generic.Queue[string]
    $script:PromptCount      = 0
    $script:PromptThrows     = $false
}
function Invoke-MigrationExpectingFailure {
    $migrationError = $null
    try { Configure-RdpPortAndFirewall } catch { $migrationError = [string]$_.Exception.Message }
    Assert-True ($null -ne $migrationError) "M-10: a failed migration must throw instead of returning quietly."
    # FAIL OPEN - the single most important property of this whole file, asserted here rather than
    # per case so it covers every present and future failure injection. Whatever failed, and at
    # whatever stage, the port the operator is currently connected on must still be reachable. A
    # block rule for the previous port surviving a failed migration IS the lockout.
    Assert-Equal 0 (@($script:FirewallRules.Keys | Where-Object { $_ -like 'WinServerSetup Block Old RDP TCP *' }).Count) `
        ("FAIL-OPEN: a failed migration must never leave the previous RDP port blocked. Failure: {0}" -f $migrationError)
    Assert-Equal 0 (@($script:Timeline | Where-Object { $_ -like 'FW-NEW WinServerSetup Block Old RDP TCP *' }).Count) `
        ("FAIL-OPEN: a failed migration must never even attempt to block the previous RDP port. Failure: {0}" -f $migrationError)
    return $migrationError
}

$newRuleName = 'WinServerSetup RDP TCP 5801'

# ---- M-09.1 An already-correct state is a NO-OP: no restart, and above all NO reboot request.
#      This is the rerun every operator hits - full setup twice, or menu option 10 twice. ----
$Global:Config = New-RdpMigrationConfig
Reset-MigrationState -RegistryPort 5801 -Listeners @{ 5801 = @(4321) } `
    -Rules @{ $newRuleName = (New-FirewallRuleRecord $newRuleName 'True' 'Allow' 'Inbound' 'Any' 'TCP' '5801') }
Configure-RdpPortAndFirewall
Assert-Equal 0 $script:RestartCount "M-09: a state that is already correct must not restart TermService."
Assert-Equal 0 $script:PendingRebootReasons.Count `
    ("M-09: an already-correct RDP state must not request a reboot. Reasons: {0}" -f ($script:PendingRebootReasons -join ' | '))
Assert-Equal 0 (@($script:SetItemPropertyCalls | Where-Object { $_.Name -eq 'PortNumber' }).Count) `
    "M-09: an already-correct state must not rewrite PortNumber."

# ---- M-09.1b ... and running it a SECOND time is still a no-op. Idempotence is the contract. ----
Reset-MigrationState -RegistryPort 5801 -Listeners @{ 5801 = @(4321) } `
    -Rules @{ $newRuleName = (New-FirewallRuleRecord $newRuleName 'True' 'Allow' 'Inbound' 'Any' 'TCP' '5801') }
Configure-RdpPortAndFirewall
Assert-Equal 0 $script:PendingRebootReasons.Count "M-09: a second identical run must not request another reboot."
Assert-Equal 0 $script:RestartCount "M-09: a second identical run must not restart TermService either."

# ---- M-09.2 The port is not owned yet and the config allows a restart: restart once, verify
#      ownership, and STILL request no reboot. ----
Reset-MigrationState -RegistryPort 3389 -Listeners @{ 3389 = @(4321) } -RestartBinds @(5801)
Configure-RdpPortAndFirewall
Assert-Equal 1 $script:RestartCount "M-09: an unbound desired port with restart enabled must restart TermService exactly once."
Assert-Equal 0 $script:PendingRebootReasons.Count "M-09: a verified restart must not additionally request a reboot."
Assert-Equal 5801 $script:RegistryPort "M-09: the migration must leave PortNumber at the configured port."
Assert-True ($script:FirewallRules.ContainsKey('WinServerSetup Block Old RDP TCP 3389')) `
    "M-09: the previous port must be blocked once ownership of the new port is verified."

# ---- M-09.3 Restart disabled: the ONLY branch allowed to record a pending reboot, exactly once,
#      and it must not then report the migration as failed. ----
$Global:Config = New-RdpMigrationConfig -Restart $false
Reset-MigrationState -RegistryPort 3389 -Listeners @{ 3389 = @(4321) }
Configure-RdpPortAndFirewall
Assert-Equal 0 $script:RestartCount "M-09: a config that forbids the restart must not restart TermService."
Assert-Equal 1 $script:PendingRebootReasons.Count `
    ("M-09: a deferred port change must request exactly one reboot. Reasons: {0}" -f ($script:PendingRebootReasons -join ' | '))
Assert-Equal 5801 $script:RegistryPort "M-09: a deferred change must still leave the new port in the registry."
Assert-Equal $false ($script:FirewallRules.ContainsKey('WinServerSetup Block Old RDP TCP 3389')) `
    "M-09: the previous port must NOT be blocked while the new one is unverified - that is the lockout."

# ---- M-10.1 A rule this run CREATED must be removed again when the migration fails. Leaving it
#      behind publishes an open inbound port that nothing is listening on. ----
$Global:Config = New-RdpMigrationConfig
Reset-MigrationState -RegistryPort 3389 -Listeners @{ 3389 = @(4321) } -RestartBinds @(0, 3389)
$failure = Invoke-MigrationExpectingFailure
Assert-True ($script:FirewallCalls -contains "REMOVE $newRuleName") "M-10: a firewall rule created by a failed migration must be removed."
Assert-Equal $false ($script:FirewallRules.ContainsKey($newRuleName)) "M-10: the created rule must actually be gone after rollback."
Assert-Equal 3389 $script:RegistryPort "M-10: the registry must be rolled back to the previous port."
Assert-True ($failure -match 'rolled back|rollback') ("M-10: the failure must say the migration was rolled back. Got: {0}" -f $failure)

# ---- M-10.2 A rule that ALREADY existed must be restored property by property, never deleted. ----
$existing = New-FirewallRuleRecord $newRuleName 'False' 'Block' 'Inbound' 'Domain' 'TCP' '1234'
Reset-MigrationState -RegistryPort 3389 -Listeners @{ 3389 = @(4321) } -RestartBinds @(0, 3389) -Rules @{ $newRuleName = $existing }
$failure = Invoke-MigrationExpectingFailure
Assert-True ($script:FirewallRules.ContainsKey($newRuleName)) "M-10: a pre-existing rule must survive the rollback, not be deleted."
Assert-Equal $false ($script:FirewallCalls -contains "REMOVE $newRuleName") "M-10: rollback must never delete a rule this run did not create."
$restored = $script:FirewallRules[$newRuleName]
Assert-Equal 'False' ([string]$restored.Enabled) "M-10: rollback must restore the rule's original Enabled state."
Assert-Equal 'Block' ([string]$restored.Action) "M-10: rollback must restore the rule's original Action."
Assert-Equal 'Domain' ([string]$restored.Profile) "M-10: rollback must restore the rule's original Profile."
Assert-Equal '1234' ([string]$restored.LocalPort) "M-10: rollback must restore the rule's original LocalPort."

# ---- M-10.3 An already-correct rule is the case most likely to be special-cased into "nothing to
#      restore". It must still be restored to exactly its original values and left in place. ----
$correct = New-FirewallRuleRecord $newRuleName 'True' 'Allow' 'Inbound' 'Any' 'TCP' '5801'
Reset-MigrationState -RegistryPort 3389 -Listeners @{ 3389 = @(4321) } -RestartBinds @(0, 3389) -Rules @{ $newRuleName = $correct }
Invoke-MigrationExpectingFailure | Out-Null
Assert-Equal $false ($script:FirewallCalls -contains "REMOVE $newRuleName") "M-10: an already-correct pre-existing rule must not be deleted by rollback."
Assert-Equal '5801' ([string]$script:FirewallRules[$newRuleName].LocalPort) "M-10: an already-correct rule must keep its port after rollback."
Assert-Equal 'Allow' ([string]$script:FirewallRules[$newRuleName].Action) "M-10: an already-correct rule must keep its action after rollback."

# ---- M-10.4 Failure at the SERVICE RESTART point, not just at listener verification. ----
Reset-MigrationState -RegistryPort 3389 -Listeners @{ 3389 = @(4321) }
$script:RestartFails = $true
$failure = Invoke-MigrationExpectingFailure
Assert-True ($script:FirewallCalls -contains "REMOVE $newRuleName") "M-10: a restart failure must also roll the firewall back."
Assert-Equal 3389 $script:RegistryPort "M-10: a restart failure must roll the registry back."

# ---- M-10.5 Failure at the FIREWALL step, before the registry is ever written: the pre-existing
#      rule this run had already modified must be put back. ----
$existing = New-FirewallRuleRecord $newRuleName 'False' 'Block' 'Inbound' 'Domain' 'TCP' '1234'
Reset-MigrationState -RegistryPort 3389 -Listeners @{ 3389 = @(4321) } -Rules @{ $newRuleName = $existing }
$script:VerifyRuleBroken = $true
$failure = Invoke-MigrationExpectingFailure
Assert-Equal 3389 $script:RegistryPort "M-10: a firewall failure must abort before the registry is changed."
Assert-Equal '1234' ([string]$script:FirewallRules[$newRuleName].LocalPort) "M-10: a firewall failure must restore the rule this run had already modified."
Assert-Equal 'Block' ([string]$script:FirewallRules[$newRuleName].Action) "M-10: a firewall failure must restore the original action too."

# ---- M-10.6 A rollback that ITSELF fails must be reported separately, not folded into the
#      original failure and not swallowed. Saying "rolled back" when it did not is the worst
#      possible outcome here. ----
Reset-MigrationState -RegistryPort 3389 -Listeners @{ 3389 = @(4321) } -RestartBinds @(0, 3389)
$script:RemoveRuleThrows = $true
$failure = Invoke-MigrationExpectingFailure
Assert-True ($failure -match 'rollback failed') ("M-10: a failed rollback must be reported as such. Got: {0}" -f $failure)
Assert-True ($failure -match 'Access is denied') ("M-10: the rollback failure must carry the underlying reason. Got: {0}" -f $failure)

# =============================================================================================
# ORDER-1: the anti-lockout ORDERING, asserted as an order and not as a set of side effects.
#
# Every case above proves that some individual step happened. None of them proves the sequence,
# and the sequence is the whole contract: the new port must be reachable BEFORE the old one is
# closed. Reordering the block ahead of the restart, or ahead of the allow rule, keeps every
# other assertion in this file green while stranding the operator.
# =============================================================================================
$Global:Config = New-RdpMigrationConfig
Reset-MigrationState -RegistryPort 3389 -Listeners @{ 3389 = @(4321) } -RestartBinds @(5801)
Configure-RdpPortAndFirewall
# NOT named $timeline: PowerShell variable names are case-insensitive, so a local $timeline at
# script scope IS $script:Timeline and would replace the List with a fixed-size array.
$orderLog = @($script:Timeline)
$allowNew = [array]::IndexOf($orderLog, 'FW-NEW WinServerSetup RDP TCP 5801')
$regWrite = [array]::IndexOf($orderLog, 'REG-PORT 5801')
$restart  = [array]::IndexOf($orderLog, 'SVC-RESTART')
$blockOld = [array]::IndexOf($orderLog, 'FW-NEW WinServerSetup Block Old RDP TCP 3389')
$shown    = ($orderLog -join ' -> ')
Assert-True ($allowNew -ge 0) ("ORDER: the new port's inbound allow rule must be created. Timeline: {0}" -f $shown)
Assert-True ($regWrite -ge 0) ("ORDER: PortNumber must be written. Timeline: {0}" -f $shown)
Assert-True ($restart -ge 0)  ("ORDER: TermService must be restarted. Timeline: {0}" -f $shown)
Assert-True ($blockOld -ge 0) ("ORDER: the previous port must eventually be blocked. Timeline: {0}" -f $shown)
Assert-True ($allowNew -lt $regWrite) `
    ("ORDER: the new port must be allowed through the firewall BEFORE the service is moved onto it. Timeline: {0}" -f $shown)
Assert-True ($regWrite -lt $restart) `
    ("ORDER: PortNumber must be written before the restart that makes it take effect. Timeline: {0}" -f $shown)
Assert-True ($restart -lt $blockOld) `
    ("ORDER: the previous port may only be blocked AFTER the restart that binds the new one. Timeline: {0}" -f $shown)
Assert-Equal ($orderLog.Count - 1) $blockOld `
    ("ORDER: blocking the previous port must be the LAST action of the migration. Timeline: {0}" -f $shown)

# =============================================================================================
# PROMPT: the operator is asked which port to use before anything is touched (item 4).
#
# The configured rdp.newPort is an offered default, not a decision. Every case below drives the
# real Configure-RdpPortAndFirewall with a scripted answer.
# =============================================================================================

# ---- PROMPT.1 The ANSWERED port is the one that gets migrated to - registry, allow rule, and
#      the block rule that names the actual previous registry port.
#
#      The machine starts ON the configured port deliberately. Ignoring the answer would then be
#      an entirely successful no-op migration, so this case is caught by the assertions below
#      rather than by a downstream "did not bind" failure that would fire whatever the cause. ----
$Global:Config = New-RdpMigrationConfig -NewPort 5801
Reset-MigrationState -RegistryPort 5801 -Listeners @{ 5801 = @(4321) } -RestartBinds @(5999)
$Global:NoPause = $false
$script:PromptAnswers.Enqueue('5999')
Configure-RdpPortAndFirewall
Assert-Equal 1 $script:PromptCount "PROMPT: an interactive migration must ask for the port exactly once."
Assert-Equal 5999 $script:RegistryPort "PROMPT: the answered port must be the one written to the registry, not the configured default."
Assert-True ($script:FirewallRules.ContainsKey('WinServerSetup RDP TCP 5999')) "PROMPT: the allow rule must be created for the ANSWERED port."
Assert-Equal $false ($script:FirewallRules.ContainsKey('WinServerSetup RDP TCP 5801')) "PROMPT: no rule may be published for the configured port the operator overrode."
Assert-True ($script:FirewallRules.ContainsKey('WinServerSetup Block Old RDP TCP 5801')) "PROMPT: the previous port must still be blocked once the answered port is verified."
Assert-Equal 5999 ([int]$Global:Config.rdp.newPort) `
    "PROMPT: the chosen port must become this run's effective rdp.newPort, or the very next step (the blocker's port-agreement check) refuses."

# ---- PROMPT.2 Pressing Enter accepts the configured value. ----
$Global:Config = New-RdpMigrationConfig -NewPort 5801
Reset-MigrationState -RegistryPort 3389 -Listeners @{ 3389 = @(4321) } -RestartBinds @(5801)
$Global:NoPause = $false
$script:PromptAnswers.Enqueue('')
Configure-RdpPortAndFirewall
Assert-Equal 1 $script:PromptCount "PROMPT: an empty answer must still have gone through the prompt."
Assert-Equal 5801 $script:RegistryPort "PROMPT: an empty answer must fall back to the configured port."

# ---- PROMPT.3 A non-numeric or out-of-range answer must re-ask, never be coerced. '0' and
#      '70000' both cast to a plausible-looking int; only a range check rejects them. ----
$Global:Config = New-RdpMigrationConfig -NewPort 5801
Reset-MigrationState -RegistryPort 3389 -Listeners @{ 3389 = @(4321) } -RestartBinds @(5999)
$Global:NoPause = $false
foreach ($bad in @('not-a-port', '70000', '0')) { $script:PromptAnswers.Enqueue($bad) | Out-Null }
$script:PromptAnswers.Enqueue('5999') | Out-Null
Configure-RdpPortAndFirewall
Assert-Equal 4 $script:PromptCount "PROMPT: each invalid answer must produce another prompt."
Assert-Equal 5999 $script:RegistryPort "PROMPT: only the valid answer may reach the registry."
Assert-Equal 0 (@($script:SetItemPropertyCalls | Where-Object { $_.Name -eq 'PortNumber' -and [int]$_.Value -ne 5999 }).Count) `
    "PROMPT: an invalid answer must never be written to PortNumber."

# ---- PROMPT.4 A port another process already holds is refused at the prompt, so the operator
#      gets to correct it instead of the migration aborting after the fact. ----
$Global:Config = New-RdpMigrationConfig -NewPort 5801
Reset-MigrationState -RegistryPort 3389 -Listeners @{ 3389 = @(4321); 6000 = @(9999) } -RestartBinds @(5999)
$Global:NoPause = $false
$script:PromptAnswers.Enqueue('6000') | Out-Null
$script:PromptAnswers.Enqueue('5999') | Out-Null
Configure-RdpPortAndFirewall
Assert-Equal 2 $script:PromptCount "PROMPT: a port held by another listener must be re-asked, not accepted."
Assert-Equal 5999 $script:RegistryPort "PROMPT: the occupied port must never reach the registry."
Assert-Equal $false ($script:FirewallRules.ContainsKey('WinServerSetup RDP TCP 6000')) "PROMPT: no rule may be published for an occupied port."

# ---- PROMPT.5 An unattended run (-NoPause) must never block on the prompt. ----
$Global:Config = New-RdpMigrationConfig -NewPort 5801
Reset-MigrationState -RegistryPort 3389 -Listeners @{ 3389 = @(4321) } -RestartBinds @(5801)
Configure-RdpPortAndFirewall
Assert-Equal 0 $script:PromptCount "PROMPT: a -NoPause run must not prompt at all."
Assert-Equal 5801 $script:RegistryPort "PROMPT: a -NoPause run must migrate to the configured port."

# ---- PROMPT.6 A host with no readable console must fall back to the configured value and SAY
#      so, rather than throwing and leaving the step failed. ----
$Global:Config = New-RdpMigrationConfig -NewPort 5801
Reset-MigrationState -RegistryPort 3389 -Listeners @{ 3389 = @(4321) } -RestartBinds @(5801)
$Global:NoPause = $false
$script:PromptThrows = $true
Configure-RdpPortAndFirewall
Assert-Equal 1 $script:PromptCount "PROMPT: the unreadable console must have been attempted once."
Assert-Equal 5801 $script:RegistryPort "PROMPT: an unreadable console must fall back to the configured port, not fail the migration."
Assert-True ((($script:Warnings) -join "`n") -match '5801') "PROMPT: the fallback must be logged with the port it fell back to."

# ---- PROMPT.7 Answers that never become valid abort with NOTHING touched. This is the prompt's
#      own fail-open case: no registry write, no restart, and not one firewall call. ----
$Global:Config = New-RdpMigrationConfig -NewPort 5801
Reset-MigrationState -RegistryPort 3389 -Listeners @{ 3389 = @(4321) }
$Global:NoPause = $false
foreach ($bad in @('0', '-1', '65536', 'nope', '3389abc')) { $script:PromptAnswers.Enqueue($bad) | Out-Null }
$failure = Invoke-MigrationExpectingFailure
Assert-True ($failure -match 'no RDP settings were changed') ("PROMPT: the abort must state that nothing was changed. Got: {0}" -f $failure)
Assert-Equal 3389 $script:RegistryPort "PROMPT: an abandoned prompt must leave PortNumber alone."
Assert-Equal 0 $script:RestartCount "PROMPT: an abandoned prompt must not restart TermService."
Assert-Equal 0 $script:FirewallCalls.Count `
    ("PROMPT: the prompt must run before any firewall work, so an abort touches nothing. Calls: {0}" -f ($script:FirewallCalls -join ' | '))
Assert-Equal 0 $script:Timeline.Count "PROMPT: an abandoned prompt must produce no migration events at all."
$Global:NoPause = $true

# ---- Retained source greps: cheap smoke checks over call sites that are not directly invoked
#      here (Configure-RdpPortAndFirewall drives real registry and firewall APIs). ----
Assert-True ($source -match 'function\s+Test-TermServiceOwnsTcpPort') "RDP verification must prove TermService owns the listener."
Assert-True ($source -match 'already occupied by a process other than TermService') "RDP migration must abort on a conflicting listener before changing the registry."
Assert-True ($source -match 'function\s+Restore-RdpPort') "Failed bind/restart paths need a shared rollback routine."
Assert-True ($source -match 'Block Old RDP TCP \$previousPort') "The firewall must block the actual previous registry port, not a stale configured value."
# The old grep here matched a redundant post-rollback ownership re-check. Restore-RdpPort now
# owns that verification (it throws 'did not reclaim that listener', proven behaviorally by case
# 8), so what must be pinned instead is that no failure path can bypass the combined
# registry + firewall rollback with a bare Restore-RdpPort call.
Assert-True ($source -match 'Invoke-RdpMigrationRollback -FirewallState') `
    "M-10: every migration failure must roll back through the shared registry-plus-firewall rollback."
Assert-True ($source -notmatch '(?m)^\s*Restore-RdpPort -RegistryPath \$rdpPath') `
    "M-10: Configure-RdpPortAndFirewall must not roll the registry back on its own and leave the firewall rule behind."

Write-Host "PASS RDP listener ownership, the collision guard, the bounded wait, every rollback branch, the M-09 three-branch activation (including an idempotent rerun), the M-10 firewall rollback, the allow-before-move / block-last ordering and the operator port prompt all execute correctly against mocked Windows APIs."
