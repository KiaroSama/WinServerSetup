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
$setupSourceNames = @('WinServerSetup.ps1') + @('Console', 'Core', 'Download', 'Rdp', 'Install', 'SystemSettings', 'Maintenance' |
        ForEach-Object { "scripts\{0}.ps1" -f $_ })
$setupSourceFiles = @(@($mainScript) + @($setupSourceNames | ForEach-Object { Join-Path $projectRoot $_ })) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique

# The retained source greps at the bottom cover the same partition.
$source = ($setupSourceFiles | ForEach-Object { Get-Content -LiteralPath $_ -Raw -Encoding UTF8 }) -join "`r`n"

$setupAsts = @(foreach ($setupFile in $setupSourceFiles) {
        $tokens = $null
        $parseErrors = $null
        $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($setupFile, [ref]$tokens, [ref]$parseErrors)
        Assert-True ($parseErrors.Count -eq 0) "$setupFile must parse before its RDP migration path can be tested."
        $fileAst
    })

foreach ($name in @('Get-TermServiceProcessId', 'Test-TermServiceOwnsTcpPort', 'Wait-TermServiceTcpPort', 'Restore-RdpPort',
        'Test-TcpPortListening', 'Ensure-RdpFirewallRule', 'Configure-RdpPortAndFirewall',
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
    if ($Name -eq 'PortNumber') { $script:RegistryPort = [int]$Value }
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
}
function Invoke-MigrationExpectingFailure {
    $migrationError = $null
    try { Configure-RdpPortAndFirewall } catch { $migrationError = [string]$_.Exception.Message }
    Assert-True ($null -ne $migrationError) "M-10: a failed migration must throw instead of returning quietly."
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

Write-Host "PASS RDP listener ownership, the collision guard, the bounded wait, every rollback branch, the M-09 three-branch activation (including an idempotent rerun) and the M-10 firewall rollback all execute correctly against mocked Windows APIs."
