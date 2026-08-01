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
param([string]$MainScript = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$mainScript = if ([string]::IsNullOrWhiteSpace($MainScript)) { Join-Path $projectRoot "WinServerSetup.ps1" } else { $MainScript }
$source = Get-Content -LiteralPath $mainScript -Raw -Encoding UTF8

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw ("{0} Expected={1}; Actual={2}" -f $Message, $Expected, $Actual) }
}

# ---- Import only the functions under test; the main script self-executes if dot-sourced. ----
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($mainScript, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) "WinServerSetup.ps1 must parse before its RDP migration path can be tested."

function Import-FunctionUnderTest {
    param([string]$Name)
    $definition = $ast.FindAll({
            param($node)
            ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq $Name)
        }, $true) | Select-Object -First 1
    if ($null -eq $definition) { throw "WinServerSetup.ps1 must define $Name." }
    return $definition.Extent.Text
}

foreach ($name in @('Get-TermServiceProcessId', 'Test-TermServiceOwnsTcpPort', 'Wait-TermServiceTcpPort', 'Restore-RdpPort')) {
    . ([scriptblock]::Create((Import-FunctionUnderTest $name)))
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

# ---- Retained source greps: cheap smoke checks over call sites that are not directly invoked
#      here (Configure-RdpPortAndFirewall drives real registry and firewall APIs). ----
Assert-True ($source -match 'function\s+Test-TermServiceOwnsTcpPort') "RDP verification must prove TermService owns the listener."
Assert-True ($source -match 'already occupied by a process other than TermService') "RDP migration must abort on a conflicting listener before changing the registry."
Assert-True ($source -match 'function\s+Restore-RdpPort') "Failed bind/restart paths need a shared rollback routine."
Assert-True ($source -match 'Block Old RDP TCP \$previousPort') "The firewall must block the actual previous registry port, not a stale configured value."
Assert-True ($source -match 'Test-TermServiceOwnsTcpPort -Port \$previousPort') "Rollback must verify that TermService reclaimed the previous port."

Write-Host "PASS RDP listener ownership, the collision guard, the bounded wait, and every rollback branch execute correctly against mocked Windows APIs."
