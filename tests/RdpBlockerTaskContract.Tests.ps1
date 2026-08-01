<#
    Behavioral tests for the RDP brute-force blocker's SYSTEM scheduled task.

    Four findings meet here, because they are all properties of the same registration:

      M-01  the blocker writes its block rules on $Config.rdp.newPort, so a task registered while
            the machine is actually listening on a different port protects nothing at all.
      M-04  a task with no ExecutionTimeLimit inherits Task Scheduler's PT72H default; combined
            with MultipleInstances=IgnoreNew one hung run silently disarms the control for days.
      H-02  everything a SYSTEM task executes or reads must be un-plantable by a non-administrator.
      L-02  "the task exists" is not a health check. The exact action, principal, trigger,
            settings, ACL and target hash are the contract.

    Nothing here touches the real Task Scheduler, registry, firewall, event log or ACL: the
    installer and the health check run against shadowed cmdlets inside a temp sandbox this suite
    creates and removes.
#>
# -MainScript targets an alternate copy so these tests can be replayed against a deliberately
# defective build to prove they still fail. CI and local runs use the default.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Cmdlets are shadowed deliberately to mock Windows-only APIs.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock signatures mirror the real cmdlets so parameter binding matches production.')]
param([string]$MainScript = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$mainScript = if ([string]::IsNullOrWhiteSpace($MainScript)) { Join-Path $projectRoot "WinServerSetup.ps1" } else { $MainScript }

. (Join-Path $PSScriptRoot '_Common.ps1')

$setupSourceNames = @('WinServerSetup.ps1') + @('Console', 'Core', 'Download', 'Rdp', 'Install', 'SystemSettings', 'Maintenance' |
        ForEach-Object { "scripts\{0}.ps1" -f $_ })
$setupSourceFiles = @(@($mainScript) + @($setupSourceNames | ForEach-Object { Join-Path $projectRoot $_ })) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique

$setupAsts = @(foreach ($setupFile in $setupSourceFiles) {
        $tokens = $null
        $parseErrors = $null
        $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($setupFile, [ref]$tokens, [ref]$parseErrors)
        Assert-True ($parseErrors.Count -eq 0) "$setupFile must parse before the blocker task contract can be tested."
        $fileAst
    })

foreach ($name in @('Get-TermServiceProcessId', 'Test-TermServiceOwnsTcpPort', 'Test-TcpPortListening',
        'Get-Sha256Hex', 'ConvertTo-CanonicalPath', 'Get-RdpRegistryPortNumber', 'Test-RdpPortAgreement',
        'Assert-RdpPortAgreement', 'Test-TrustedTaskTargetPath', 'Assert-TrustedTaskTarget',
        'Copy-TaskTargetToStaging', 'Save-StagedTaskConfig',
        'Get-TaskTrustManifestPath', 'Save-TaskTrustManifest', 'Get-TaskTrustManifest',
        'ConvertFrom-ScheduledTaskDuration', 'ConvertFrom-ScheduledTaskArgument', 'Test-BlockerTaskArgumentContract',
        'Get-BlockerExecutionTimeLimitMinutes', 'New-BlockerTaskArgument', 'Test-RdpBlockerTaskHealth',
        'Get-TrustedPrincipalSid', 'Install-RdpBruteforceBlocker')) {
    . ([scriptblock]::Create((Import-FunctionUnderTest $name $setupAsts)))
}

# ---- Fake Windows state -------------------------------------------------------------------
$script:TermServicePid    = 4321
$script:ListenersByPort   = @{}
$script:RegistryPort      = 5801
$script:RegisteredTasks   = @{}
$script:RegisterCalls     = New-Object System.Collections.Generic.List[string]
$script:LastSettings      = $null
$script:VerificationRuns  = 0
$script:UntrustedWriters  = @{}
$script:PathOwners        = @{}
$script:ReplaceCapable    = @{}
$script:ReparsePaths      = @()
$script:HardenedPaths     = New-Object System.Collections.Generic.List[string]
$script:HardeningFixes    = $true
$script:Log               = New-Object System.Collections.Generic.List[string]

function Write-Info { param([string]$Message) $script:Log.Add("INFO $Message") | Out-Null }
function Write-Ok { param([string]$Message) $script:Log.Add("OK $Message") | Out-Null }
function Write-Warn { param([string]$Message) $script:Log.Add("WARN $Message") | Out-Null }
function Write-Fail { param([string]$Message) $script:Log.Add("FAIL $Message") | Out-Null }
function Write-StructuredLog { param([string]$Level = 'INFO', [string]$Message = '', [string]$Section = '') $script:Log.Add("LOG $Level $Message") | Out-Null }
function Set-StepSkipped { param([string]$Reason) $script:Log.Add("SKIP $Reason") | Out-Null }

function Get-CimInstance {
    param([string]$ClassName, [string]$Filter, $ErrorAction)
    return [pscustomobject]@{ Name = 'TermService'; ProcessId = $script:TermServicePid }
}
function Get-NetTCPConnection {
    param([string]$State, [int]$LocalPort, $ErrorAction)
    $owners = @(@($script:ListenersByPort[$LocalPort]) | Where-Object { $_ })
    if ($owners.Count -eq 0) { throw "No MSFT_NetTCPConnection objects found with property 'LocalPort' equal to '$LocalPort'." }
    return @($owners | ForEach-Object { [pscustomobject]@{ LocalPort = $LocalPort; State = 'Listen'; OwningProcess = $_ } })
}
function Get-ItemProperty {
    param([string]$Path, [string]$Name, $ErrorAction)
    return [pscustomobject]@{ PortNumber = $script:RegistryPort }
}

# ---- Shadowed ACL primitives. The real ones live in scripts\Core.ps1 and are exercised for
#      real in the PowerShell 7 case at the end of this file; here they are scripted so every
#      trust decision can be driven deterministically without touching a real DACL. ----
function Get-UntrustedAclWriter {
    param([string]$Path)
    $key = [string]$Path
    if ($script:UntrustedWriters.ContainsKey($key)) { return @($script:UntrustedWriters[$key]) }
    return @()
}
function Test-PathContainsReparsePoint {
    param([string]$Path)
    return ($script:ReparsePaths -contains [string]$Path)
}
# FU-01: the owner and the parent walk are scripted here for the same reason as the DACL - so the
# installer's routing can be driven deterministically. Both are exercised against REAL owners and
# REAL DACLs in tests\TaskTargetOwnership.Tests.ps1; this suite is about what the installer does
# with the verdict. Defaults are the safe values, so a case opts in to being untrusted.
function Get-PathOwnerSid {
    param([string]$Path)
    if ($script:PathOwners.ContainsKey([string]$Path)) { return $script:PathOwners[[string]$Path] }
    return 'S-1-5-32-544'
}
function Get-ReplaceCapableUntrustedPrincipal {
    param([string]$Path)
    if ($script:ReplaceCapable.ContainsKey([string]$Path)) { return @($script:ReplaceCapable[[string]$Path]) }
    return @()
}
function Initialize-TrustedTaskAcl {
    param([string]$Path)
    $script:HardenedPaths.Add([string]$Path) | Out-Null
    if ($script:HardeningFixes) {
        # Production hardening rewrites the DACL AND takes ownership, throwing if either fails.
        $script:UntrustedWriters.Remove([string]$Path) | Out-Null
        $script:PathOwners.Remove([string]$Path) | Out-Null
        $script:ReplaceCapable.Remove([string]$Path) | Out-Null
    }
    return $Path
}
function Initialize-TrustedDirectory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    return $Path
}

# ---- Shadowed Task Scheduler ---------------------------------------------------------------
function New-ScheduledTaskAction {
    param([string]$Execute, [string]$Argument)
    return [pscustomobject]@{ Execute = $Execute; Arguments = $Argument }
}
function New-ScheduledTaskTrigger {
    param([switch]$Once, $At, $RepetitionInterval, [switch]$AtStartup, $RandomDelay)
    $interval = if ($null -ne $RepetitionInterval) { [System.Xml.XmlConvert]::ToString([timespan]$RepetitionInterval) } else { '' }
    return [pscustomobject]@{ Enabled = $true; StartBoundary = [string]$At; Repetition = [pscustomobject]@{ Interval = $interval } }
}
function New-ScheduledTaskPrincipal {
    param([string]$UserId, [string]$RunLevel)
    return [pscustomobject]@{ UserId = $UserId; RunLevel = $RunLevel }
}
function New-ScheduledTaskSettingsSet {
    param([string]$MultipleInstances, [switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries,
        [switch]$Hidden, [switch]$StartWhenAvailable, $ExecutionTimeLimit)
    $script:LastSettings = [pscustomobject]@{
        MultipleInstances  = $MultipleInstances
        ExecutionTimeLimit = $(if ($null -ne $ExecutionTimeLimit) { [System.Xml.XmlConvert]::ToString([timespan]$ExecutionTimeLimit) } else { '' })
    }
    return $script:LastSettings
}
function Register-ScheduledTask {
    param([string]$TaskName, $Action, $Trigger, $Principal, $Settings, [switch]$Force)
    $script:RegisterCalls.Add([string]$TaskName) | Out-Null
    $script:RegisteredTasks[$TaskName] = [pscustomobject]@{
        TaskName = $TaskName; State = 'Ready'
        Actions = @($Action); Triggers = @($Trigger); Principal = $Principal; Settings = $Settings
    }
    return $script:RegisteredTasks[$TaskName]
}
function Unregister-ScheduledTask {
    # -Confirm is declared explicitly because the production call site passes -Confirm:$false and
    # this mock must bind exactly as the real cmdlet does. SupportsShouldProcess would turn it
    # into an advanced function, whose automatic -Confirm then collides with that same call.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '', Justification = 'Mock mirrors the real cmdlet signature; see comment above.')]
    param([string]$TaskName, [switch]$Confirm, $ErrorAction)
    $script:RegisteredTasks.Remove([string]$TaskName) | Out-Null
}
function Get-ScheduledTask {
    param([string]$TaskName, $ErrorAction)
    if (-not $script:RegisteredTasks.ContainsKey($TaskName)) {
        throw "No MSFT_ScheduledTask objects found with property 'TaskName' equal to '$TaskName'."
    }
    return $script:RegisteredTasks[$TaskName]
}
function Get-ScheduledTaskInfo {
    param([string]$TaskName, $ErrorAction)
    return [pscustomobject]@{ LastTaskResult = $script:TaskLastResult; NextRunTime = $script:TaskNextRun; LastRunTime = $script:TaskLastRun }
}
function Invoke-BlockerVerificationRun {
    param([string]$PowerShellExe, [string]$ScriptPath, [string]$ConfigPath)
    $script:VerificationRuns++
}

# GetFullPath, not a bare Join-Path: the code under test canonicalises every path it validates
# through ConvertTo-CanonicalPath, and GetFullPath EXPANDS an 8.3 alias while Join-Path preserves
# it. GitHub Actions windows-latest exposes %TEMP% as C:\Users\RUNNER~1\AppData\Local\Temp, so
# without this the mocked ACL lookups below are keyed on the short spelling, the production code
# asks about the long one, no key ever matches, and every H-02 case silently stops refusing.
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $env:TEMP ("WinServerSetup-BlockerTask-{0}" -f ([guid]::NewGuid().ToString("N")))))
$previousConfig = $Global:Config
$previousRoot = $Global:ProjectRoot
$previousConfigPath = $Global:ConfigPath
try {
    $sandboxRoot = Join-Path $testRoot 'project'
    $sandboxScripts = Join-Path $sandboxRoot 'scripts'
    New-Item -ItemType Directory -Path $sandboxScripts -Force | Out-Null
    $script:TrustRoot = Join-Path $testRoot 'trust'
    New-Item -ItemType Directory -Path $script:TrustRoot -Force | Out-Null
    $script:StagingRoot = ConvertTo-CanonicalPath (Join-Path $testRoot 'staging')
    New-Item -ItemType Directory -Path $script:StagingRoot -Force | Out-Null

    $blockerScript = Join-Path $sandboxScripts 'Block-RdpBruteforce.ps1'
    Set-Content -LiteralPath $blockerScript -Value '# blocker under test' -Encoding UTF8
    $sandboxConfig = Join-Path $sandboxRoot 'WinServerSetup.config.json'
    Set-Content -LiteralPath $sandboxConfig -Value '{}' -Encoding UTF8

    $Global:ProjectRoot = $sandboxRoot
    $Global:ConfigPath = $sandboxConfig
    $taskName = 'WinServerSetup RDP Bruteforce Blocker'

    # The manifest lives under %ProgramData% in production; redirected into the sandbox here so
    # no case can write outside its own temp tree. That the production root is ACL-hardened is
    # asserted directly against its source at the bottom of this file.
    function Get-TaskTrustManifestRoot { return $script:TrustRoot }
    # FU-01: same for the staging root. In production this is %ProgramData%\WinServerSetup\tasks,
    # created, owned and hardened by Get-TaskStagingRoot; redirected here so the installer under
    # test never touches the real machine. The production root's own hardening is asserted
    # against its source at the bottom of this file.
    function Get-TaskStagingRoot { return $script:StagingRoot }

    # FU-01: what the task is actually registered against - the COPIES, never the checkout.
    $stagedScript = ConvertTo-CanonicalPath (Join-Path $script:StagingRoot 'Block-RdpBruteforce.ps1')
    $stagedConfig = ConvertTo-CanonicalPath (Join-Path $script:StagingRoot 'Block-RdpBruteforce.config.json')

    function New-BlockerConfig {
        param([int]$RdpPort = 5801, [int]$Interval = 1, $LimitMinutes = 5, [bool]$Enabled = $true, [bool]$RdpEnabled = $true)
        return [pscustomobject]@{
            rdp = [pscustomobject]@{ enabled = $RdpEnabled; newPort = $RdpPort }
            rdpBruteforceBlocker = [pscustomobject]@{
                enabled = $Enabled; taskName = 'WinServerSetup RDP Bruteforce Blocker'
                taskIntervalMinutes = $Interval; executionTimeLimitMinutes = $LimitMinutes
            }
        }
    }
    function Reset-BlockerState {
        param([int]$RegistryPort = 5801, [hashtable]$Listeners = @{ 5801 = @(4321) })
        $script:RegistryPort = $RegistryPort
        $script:ListenersByPort = $Listeners
        $script:RegisteredTasks = @{}
        $script:RegisterCalls.Clear()
        $script:LastSettings = $null
        $script:VerificationRuns = 0
        $script:UntrustedWriters = @{}
        $script:PathOwners = @{}
        $script:ReplaceCapable = @{}
        $script:ReparsePaths = @()
        $script:HardenedPaths.Clear()
        $script:HardeningFixes = $true
        $script:TaskLastResult = 267011
        $script:TaskNextRun = (Get-Date).AddMinutes(1)
        $script:TaskLastRun = (Get-Date).AddMinutes(-1)
        $script:Log.Clear()
        Get-ChildItem -LiteralPath $script:TrustRoot -Force -ErrorAction SilentlyContinue |
            ForEach-Object { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $_.FullName -Force -Recurse -ErrorAction SilentlyContinue }
    }
    function Invoke-InstallExpectingFailure {
        $installError = $null
        try { Install-RdpBruteforceBlocker } catch { $installError = [string]$_.Exception.Message }
        Assert-True ($null -ne $installError) "The blocker installation must throw instead of registering a task it cannot vouch for."
        return $installError
    }

    # =========================================================================================
    # M-01 - the task may only be registered when config, registry and listener all agree.
    # =========================================================================================
    # ---- M-01.1 The machine really listens on 3389 while the config says 5801. Registering
    #      here produces a task that looks healthy and writes every block rule on a port nobody
    #      is attacking. ----
    $Global:Config = New-BlockerConfig -RdpPort 5801
    Reset-BlockerState -RegistryPort 3389 -Listeners @{ 3389 = @(4321) }
    $installError = Invoke-InstallExpectingFailure
    Assert-True ($installError -match '3389' -and $installError -match '5801') `
        ("M-01: the refusal must name both the configured and the actual port. Got: {0}" -f $installError)
    Assert-Equal 0 $script:RegisterCalls.Count "M-01: a port disagreement must not register the blocker task."
    Assert-Equal 0 $script:VerificationRuns "M-01: a port disagreement must not run the blocker either."

    # ---- M-01.2 Completed migration: registry, config and the live listener all say 5801. ----
    Reset-BlockerState -RegistryPort 5801 -Listeners @{ 5801 = @(4321) }
    Install-RdpBruteforceBlocker
    Assert-Equal 1 $script:RegisterCalls.Count "M-01: a fully agreeing port state must register the task."
    Assert-Equal 1 $script:VerificationRuns "M-01: a successful registration must still run the blocker once for verification."

    # ---- M-01.3 Pending migration: the registry already carries the new port but TermService is
    #      still on the old one, so the blocker would filter a port that is not serving RDP. ----
    Reset-BlockerState -RegistryPort 5801 -Listeners @{ 3389 = @(4321) }
    $installError = Invoke-InstallExpectingFailure
    Assert-True ($installError -match 'restart|reboot|pending') `
        ("M-01: a pending port change must be reported as pending. Got: {0}" -f $installError)
    Assert-Equal 0 $script:RegisterCalls.Count "M-01: a pending port change must not register the blocker task."

    # ---- M-01.4 Something that is NOT TermService owns the configured port. ----
    Reset-BlockerState -RegistryPort 5801 -Listeners @{ 5801 = @(9999) }
    $installError = Invoke-InstallExpectingFailure
    Assert-True ($installError -match 'TermService') `
        ("M-01: a foreign listener must be reported as not being TermService. Got: {0}" -f $installError)
    Assert-Equal 0 $script:RegisterCalls.Count "M-01: a foreign listener on the RDP port must not register the blocker task."

    # =========================================================================================
    # M-04 - a single run must be bounded.
    # =========================================================================================
    Reset-BlockerState
    Install-RdpBruteforceBlocker
    Assert-True ($null -ne $script:LastSettings) "M-04: the task must be registered with an explicit settings set."
    Assert-Equal 'PT5M' ([string]$script:LastSettings.ExecutionTimeLimit) `
        "M-04: the task must carry the configured ExecutionTimeLimit instead of Task Scheduler's PT72H default."
    Assert-Equal 'IgnoreNew' ([string]$script:LastSettings.MultipleInstances) `
        "M-04: MultipleInstances must stay IgnoreNew, which is only safe alongside the execution time limit."

    # ---- M-04.2 A missing limit must fall back to a bounded value, never to "unbounded". ----
    $Global:Config = New-BlockerConfig -LimitMinutes 0
    Reset-BlockerState
    Install-RdpBruteforceBlocker
    Assert-Equal 'PT5M' ([string]$script:LastSettings.ExecutionTimeLimit) `
        "M-04: an absent executionTimeLimitMinutes must fall back to a bounded default."

    # =========================================================================================
    # FU-01 - the task must be registered against a COPY the project owns, not the checkout.
    #
    # The project root is not a defensible location for a SYSTEM task target: measured on a real
    # machine it was owned by the interactive user and granted FullControl to BUILTIN\Users. The
    # script and the effective config are therefore staged into a directory this project creates,
    # owns and hardens, and only the staged copies are registered, validated and health-checked.
    # =========================================================================================
    $Global:Config = New-BlockerConfig
    Reset-BlockerState
    Install-RdpBruteforceBlocker
    $registered = $script:RegisteredTasks[$taskName]
    $registeredArguments = [string]@($registered.Actions)[0].Arguments

    Assert-True (Test-Path -LiteralPath $stagedScript) "FU-01: the blocker script must be COPIED into the staging root before the task is registered."
    Assert-Equal (Get-Content -LiteralPath $blockerScript -Raw -Encoding UTF8) (Get-Content -LiteralPath $stagedScript -Raw -Encoding UTF8) `
        "FU-01: the staged copy must be byte-identical to the checkout it was taken from."
    Assert-True ($registeredArguments -match [regex]::Escape($stagedScript)) `
        ("FU-01: the registered action must execute the STAGED copy. Got: {0}" -f $registeredArguments)
    Assert-True ($registeredArguments -notmatch [regex]::Escape($blockerScript)) `
        ("FU-01: the registered action must not reference the checkout script at all. Got: {0}" -f $registeredArguments)
    Assert-True ($registeredArguments -notmatch [regex]::Escape($sandboxConfig)) `
        ("FU-01: the registered action must not reference the checkout config either. Got: {0}" -f $registeredArguments)

    # The manifest is what the health check re-proves later, so it has to name the copies too -
    # otherwise the health check would keep validating a file the task never runs.
    $manifest = Get-TaskTrustManifest -TaskName $taskName
    Assert-Equal $stagedScript ([string]$manifest.ScriptPath) "FU-01: the trust manifest must record the staged script, so the health check validates what actually runs."
    Assert-Equal $stagedConfig ([string]$manifest.ConfigPath) "FU-01: the trust manifest must record the staged config."
    Assert-Equal (Get-Sha256Hex -Path $stagedScript) ([string]$manifest.ScriptSha256) "FU-01: the recorded hash must be the hash of the staged copy."

    # ---- FU-01: the staged config is the EFFECTIVE config, reduced to what the blocker reads.
    #      The merged configuration can carry an activation product key from the ignored local
    #      override, and the staged file is readable by BUILTIN\Users - so an allowlist, not a
    #      copy of the whole thing. ----
    $Global:Config = New-BlockerConfig -RdpPort 5801 -Interval 7
    $Global:Config | Add-Member -NotePropertyName activation -NotePropertyValue ([pscustomobject]@{ enabled = $true; productKey = 'SUPER-SECRET-KEY-0001' })
    Reset-BlockerState
    Install-RdpBruteforceBlocker
    $stagedConfigText = Get-Content -LiteralPath $stagedConfig -Raw -Encoding UTF8
    Assert-True ($stagedConfigText -notmatch 'SUPER-SECRET-KEY-0001') `
        "FU-01: the staged config is world-readable, so it must carry only the sections the blocker consumes - never an activation product key from the local override."
    $stagedConfigObject = $stagedConfigText | ConvertFrom-Json
    Assert-Equal 5801 ([int]$stagedConfigObject.rdp.newPort) "FU-01: the staged config must carry rdp.newPort, which the blocker uses for every rule it writes."
    Assert-Equal 7 ([int]$stagedConfigObject.rdpBruteforceBlocker.taskIntervalMinutes) `
        "FU-01: the staged config must be the EFFECTIVE configuration, not a copy of the tracked file - an override the task never saw was the quiet half of this finding."

    # =========================================================================================
    # H-02 - every file the SYSTEM task executes or reads must be un-plantable.
    # =========================================================================================
    # ---- H-02.1 A destination that grants Modify to Users is hardened, then re-validated. ----
    $Global:Config = New-BlockerConfig
    Reset-BlockerState
    $script:UntrustedWriters[$script:StagingRoot] = @('BUILTIN\Users (S-1-5-32-545) : Modify')
    Install-RdpBruteforceBlocker
    Assert-True ($script:HardenedPaths -contains $script:StagingRoot) `
        "H-02: a task target writable by a non-administrative SID must be hardened before the task is registered."
    Assert-Equal 1 $script:RegisterCalls.Count "H-02: registration may continue once the target has actually been hardened."

    # ---- H-02.2 ... and when hardening does NOT fix it, the registration must fail closed. ----
    Reset-BlockerState
    $script:HardeningFixes = $false
    $script:UntrustedWriters[$stagedScript] = @('NT AUTHORITY\Authenticated Users (S-1-5-11) : Modify')
    $installError = Invoke-InstallExpectingFailure
    Assert-True ($installError -match 'Authenticated Users') `
        ("H-02: the refusal must name the principal that can write the target. Got: {0}" -f $installError)
    Assert-Equal 0 $script:RegisterCalls.Count "H-02: a target that stays writable after hardening must not be registered."

    # ---- H-02.3 Root-only validation is not enough: the CONFIG the task consumes counts too. ----
    Reset-BlockerState
    $script:HardeningFixes = $false
    $script:UntrustedWriters[$stagedConfig] = @('BUILTIN\Users (S-1-5-32-545) : Modify')
    $installError = Invoke-InstallExpectingFailure
    Assert-True ($installError -match [regex]::Escape($stagedConfig)) `
        ("H-02: the config the task consumes must be validated by name. Got: {0}" -f $installError)
    Assert-Equal 0 $script:RegisterCalls.Count "H-02: a writable config file must not be registered as a task input."

    # ---- FU-01.6 An untrusted OWNER must route to -Harden exactly like a writable DACL does:
    #      the same hardening pass takes ownership, so refusing outright would abort installs it
    #      can actually repair. What must NOT happen is registering anyway. ----
    Reset-BlockerState
    $script:PathOwners[$stagedScript] = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
    Install-RdpBruteforceBlocker
    Assert-True ($script:HardenedPaths -contains $stagedScript) `
        "FU-01: a task target with an untrusted owner must be hardened - taking ownership is exactly what that pass does."
    Assert-Equal 1 $script:RegisterCalls.Count "FU-01: registration may continue once ownership has actually been taken."

    # ---- FU-01.7 ... and when ownership cannot be taken, registration must fail closed. ----
    Reset-BlockerState
    $script:HardeningFixes = $false
    $script:PathOwners[$stagedScript] = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
    $installError = Invoke-InstallExpectingFailure
    Assert-True ($installError -match 'S-1-5-21-1111111111-2222222222-3333333333-1001') `
        ("FU-01: the refusal must name the owner that still holds WRITE_DAC. Got: {0}" -f $installError)
    Assert-Equal 0 $script:RegisterCalls.Count "FU-01: a target still owned by a non-administrative principal must not be registered."

    # ---- FU-01.8 A replace-capable PARENT is not repairable by hardening the target, so it must
    #      end the installation rather than be registered against. ----
    Reset-BlockerState
    $script:HardeningFixes = $false
    $script:ReplaceCapable[$script:StagingRoot] = @('BUILTIN\Users (S-1-5-32-545) : FullControl')
    $installError = Invoke-InstallExpectingFailure
    Assert-True ($installError -match 'can be replaced by') `
        ("FU-01: the refusal must say the component can be REPLACED, which is a different failure from being writable. Got: {0}" -f $installError)
    Assert-Equal 0 $script:RegisterCalls.Count "FU-01: a task target whose parent can be swapped must not be registered."

    # ---- H-02.4 A junction anywhere in the chain must fail closed and must never be "hardened"
    #      into looking safe - hardening a reparse point writes the ACL of its target. ----
    Reset-BlockerState
    $script:ReparsePaths = @($script:StagingRoot)
    $installError = Invoke-InstallExpectingFailure
    Assert-True ($installError -match 'reparse') ("H-02: a reparse point must be named in the refusal. Got: {0}" -f $installError)
    Assert-Equal 0 $script:HardenedPaths.Count "H-02: a path containing a reparse point must never be hardened in place."
    Assert-Equal 0 $script:RegisterCalls.Count "H-02: a reparse point in the target chain must not be registered."

    # =========================================================================================
    # M-04 unit level - the limit and the duration normalisation the health check depends on.
    # =========================================================================================
    Assert-Equal 5  (Get-BlockerExecutionTimeLimitMinutes -ConfiguredMinutes 0 -IntervalMinutes 1) "M-04: a missing limit must fall back to a bounded default."
    Assert-Equal 3  (Get-BlockerExecutionTimeLimitMinutes -ConfiguredMinutes 3 -IntervalMinutes 1) "M-04: a configured limit must be honoured."
    Assert-Equal 5  (Get-BlockerExecutionTimeLimitMinutes -ConfiguredMinutes 720 -IntervalMinutes 1) `
        "M-04: a limit far beyond the repetition interval must be clamped; IgnoreNew would otherwise skip 720 triggers."
    Assert-Equal 10 (Get-BlockerExecutionTimeLimitMinutes -ConfiguredMinutes 10 -IntervalMinutes 30) `
        "M-04: a longer repetition interval must allow a proportionally longer run."

    Assert-Equal 5 ((ConvertFrom-ScheduledTaskDuration -Duration 'PT5M').TotalMinutes) "M-04: 'PT5M' must normalise to five minutes."
    Assert-Equal 5 ((ConvertFrom-ScheduledTaskDuration -Duration 'PT300S').TotalMinutes) "M-04: 'PT300S' is the same five minutes spelled differently."
    Assert-Equal 5 ((ConvertFrom-ScheduledTaskDuration -Duration 'PT0H5M0S').TotalMinutes) "M-04: 'PT0H5M0S' is the same five minutes again."
    Assert-Equal $null (ConvertFrom-ScheduledTaskDuration -Duration '') "M-04: an absent duration must not be read as a limit."
    Assert-Equal $null (ConvertFrom-ScheduledTaskDuration -Duration 'forever') "M-04: an unparseable duration must not be read as a limit."

    # ---- L-02 unit level: the argument tokeniser is what makes 'contains the config path'
    #      different from 'passes the config path'. ----
    $parsed = ConvertFrom-ScheduledTaskArgument -Arguments '-NoProfile -File "C:\a b\x.ps1" -ConfigPath "C:\c.json"'
    Assert-Equal 'C:\a b\x.ps1' ([string]$parsed['-file']) "L-02: a quoted path containing spaces must survive tokenisation."
    Assert-Equal 'C:\c.json' ([string]$parsed['-configpath']) "L-02: -ConfigPath must be read as a switch/value pair."
    Assert-Equal $true ($parsed.ContainsKey('-noprofile')) "L-02: a valueless switch must still be recorded."

    # =========================================================================================
    # L-02 - the health check must reject every malformed shape, not just a missing task.
    # =========================================================================================
    function Reset-HealthyTask {
        Reset-BlockerState
        Install-RdpBruteforceBlocker
        Assert-Equal $true (Test-RdpBlockerTaskHealth -TaskName $taskName) "L-02: a freshly registered task must satisfy its own contract."
        return $script:RegisteredTasks[$taskName]
    }

    $Global:Config = New-BlockerConfig
    $task = Reset-HealthyTask
    $goodArguments = [string]@($task.Actions)[0].Arguments

    # ---- L-02.1 A different executable. ----
    @($task.Actions)[0].Execute = 'C:\Windows\System32\cmd.exe'
    Assert-Equal $false (Test-RdpBlockerTaskHealth -TaskName $taskName) "L-02: a task launched through another executable must not be healthy."

    # ---- L-02.2 A different script. ----
    $task = Reset-HealthyTask
    @($task.Actions)[0].Arguments = $goodArguments.Replace('Block-RdpBruteforce.ps1', 'Something-Else.ps1')
    Assert-Equal $false (Test-RdpBlockerTaskHealth -TaskName $taskName) "L-02: a task pointing at another script must not be healthy."

    # ---- L-02.3 THE case the old substring check got wrong: the config path is present in the
    #      argument string but is never passed to the blocker. ----
    $task = Reset-HealthyTask
    @($task.Actions)[0].Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Unrelated "{1}"' -f $stagedScript, $stagedConfig)
    Assert-Equal $false (Test-RdpBlockerTaskHealth -TaskName $taskName) `
        "L-02: an unrelated argument that merely CONTAINS the config path must not be considered healthy."

    # ---- L-02.4 ... and a malformed -ConfigPath value that only starts with the right path. ----
    $task = Reset-HealthyTask
    @($task.Actions)[0].Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1} extra"' -f $stagedScript, $stagedConfig)
    Assert-Equal $false (Test-RdpBlockerTaskHealth -TaskName $taskName) "L-02: a malformed -ConfigPath value must not be considered healthy."

    # ---- L-02.5 Principal and run level. ----
    $task = Reset-HealthyTask
    $task.Principal.UserId = 'mobin'
    Assert-Equal $false (Test-RdpBlockerTaskHealth -TaskName $taskName) "L-02: a task not running as SYSTEM must not be healthy."
    $task = Reset-HealthyTask
    $task.Principal.RunLevel = 'Limited'
    Assert-Equal $false (Test-RdpBlockerTaskHealth -TaskName $taskName) "L-02: a task without the highest run level must not be healthy."

    # ---- L-02.6 Trigger presence and repetition interval. ----
    $task = Reset-HealthyTask
    $task.Triggers = @()
    Assert-Equal $false (Test-RdpBlockerTaskHealth -TaskName $taskName) "L-02: a task with no trigger can never run and must not be healthy."
    $task = Reset-HealthyTask
    @($task.Triggers)[0].Repetition.Interval = 'PT30M'
    Assert-Equal $false (Test-RdpBlockerTaskHealth -TaskName $taskName) `
        "L-02: a repetition interval that no longer matches the registered one must not be healthy."

    # ---- M-04/L-02.7 The execution time limit itself. ----
    $task = Reset-HealthyTask
    $task.Settings.ExecutionTimeLimit = ''
    Assert-Equal $false (Test-RdpBlockerTaskHealth -TaskName $taskName) "M-04: a task with no ExecutionTimeLimit must not be healthy."
    $task = Reset-HealthyTask
    $task.Settings.ExecutionTimeLimit = 'PT72H'
    Assert-Equal $false (Test-RdpBlockerTaskHealth -TaskName $taskName) "M-04: Task Scheduler's PT72H default must not be accepted as the limit."
    # ... but the SAME limit spelled differently must still pass: this is a duration check, not
    # a string comparison.
    $task = Reset-HealthyTask
    $task.Settings.ExecutionTimeLimit = 'PT300S'
    Assert-Equal $true (Test-RdpBlockerTaskHealth -TaskName $taskName) "M-04: an equivalent duration spelling must remain healthy."

    # ---- M-04/L-02.8 MultipleInstances. IgnoreNew is only safe with the limit above. ----
    $task = Reset-HealthyTask
    $task.Settings.MultipleInstances = 'Parallel'
    Assert-Equal $false (Test-RdpBlockerTaskHealth -TaskName $taskName) "M-04: MultipleInstances must stay IgnoreNew."

    # ---- M-04.9 A run that is STILL RUNNING past its limit is the hang IgnoreNew hides. ----
    $task = Reset-HealthyTask
    $task.State = 'Running'
    $script:TaskLastResult = 267009
    $script:TaskLastRun = (Get-Date).AddMinutes(-30)
    Assert-Equal $false (Test-RdpBlockerTaskHealth -TaskName $taskName) `
        "M-04: an active run that has outlived its execution time limit must be reported as unhealthy."
    Assert-True ((($script:Log) -join "`n") -match 'outlived its') "M-04: the over-long run must be logged with its remediation."
    # ... while a run still inside its limit is normal IgnoreNew behaviour, not a failure.
    $task = Reset-HealthyTask
    $task.State = 'Running'
    $script:TaskLastResult = 267009
    $script:TaskLastRun = (Get-Date).AddSeconds(-20)
    Assert-Equal $true (Test-RdpBlockerTaskHealth -TaskName $taskName) `
        "M-04: a run inside its limit is IgnoreNew working as intended and must stay healthy."

    # ---- H-02.5 The STAGED blocker script modified after registration - the exact TOCTOU this
    #      manifest exists to catch, now aimed at the file the task really executes. ----
    $task = Reset-HealthyTask
    Set-Content -LiteralPath $stagedScript -Value '# blocker under test, tampered' -Encoding UTF8
    Assert-Equal $false (Test-RdpBlockerTaskHealth -TaskName $taskName) `
        "H-02: a blocker script changed after registration must fail the health check."
    # The next Reset-HealthyTask re-copies from the checkout, so the tamper does not leak forward.

    # ---- H-02.6 A target that became writable, or reachable through a junction, after the fact. ----
    $task = Reset-HealthyTask
    $script:UntrustedWriters[$stagedScript] = @('BUILTIN\Users (S-1-5-32-545) : Modify')
    Assert-Equal $false (Test-RdpBlockerTaskHealth -TaskName $taskName) "H-02: a task target that became writable must fail the health check."
    $task = Reset-HealthyTask
    $script:ReparsePaths = @($stagedConfig)
    Assert-Equal $false (Test-RdpBlockerTaskHealth -TaskName $taskName) "H-02: a task target reached through a reparse point must fail the health check."

    # ---- H-02.7 No manifest at all means nothing can be vouched for. ----
    $task = Reset-HealthyTask
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath (Get-TaskTrustManifestPath -TaskName $taskName) -Force
    Assert-Equal $false (Test-RdpBlockerTaskHealth -TaskName $taskName) "L-02: without a trust manifest the task contract cannot be verified and must not pass."
    # ... and a manifest in a location a non-administrator can write is worth no more than none.
    $task = Reset-HealthyTask
    $script:UntrustedWriters[(Get-TaskTrustManifestPath -TaskName $taskName)] = @('BUILTIN\Users (S-1-5-32-545) : Modify')
    Assert-Equal $false (Test-RdpBlockerTaskHealth -TaskName $taskName) `
        "H-02: a writable trust manifest is not a trust boundary and must not be believed."

    # =========================================================================================
    # H-02 - the blocker is not the only SYSTEM task. The post-reboot SFC task runs as SYSTEM at
    # the highest run level too, so its own targets must be validated before it is registered.
    # =========================================================================================
    # Only the two functions this section adds. The ACL mocks and the trust functions imported at
    # the top of the file are still in scope - re-declaring them here duplicated the mock bodies,
    # and the copies then missed the owner and replace-capability state added for FU-01.
    . ([scriptblock]::Create((Import-FunctionUnderTest 'Test-ScheduledTaskContract' $setupAsts)))
    . ([scriptblock]::Create((Import-FunctionUnderTest 'Register-PostRebootSfcTask' $setupAsts)))
    $sfcScriptPath = Join-Path $sandboxScripts 'Run-PostRebootSfc.ps1'
    Set-Content -LiteralPath $sfcScriptPath -Value '# post-reboot sfc under test' -Encoding UTF8
    $stagedSfc = ConvertTo-CanonicalPath (Join-Path $script:StagingRoot 'Run-PostRebootSfc.ps1')
    $Global:Config = New-BlockerConfig
    $Global:Config | Add-Member -NotePropertyName autoReboot -NotePropertyValue ([pscustomobject]@{ scheduleSfcAfterReboot = $true })

    Reset-BlockerState
    Register-PostRebootSfcTask
    Assert-Equal 1 $script:RegisterCalls.Count "H-02: the post-reboot SFC task must still register when every target is trusted."
    $sfcArguments = [string]@($script:RegisteredTasks['WinServerSetup Post-Reboot SFC'].Actions)[0].Arguments
    Assert-True (Test-Path -LiteralPath $stagedSfc) "FU-01: the post-reboot SFC helper must be staged as well; it runs as SYSTEM at the highest run level too."
    Assert-True ($sfcArguments -match [regex]::Escape($stagedSfc)) `
        ("FU-01: the SFC task must execute the staged copy. Got: {0}" -f $sfcArguments)
    Assert-True ($sfcArguments -notmatch [regex]::Escape($sfcScriptPath)) `
        ("FU-01: the SFC task must not reference the checkout helper. Got: {0}" -f $sfcArguments)
    # Without -ProjectRoot the helper resolves its own root from $PSScriptRoot and logs beside the
    # staged script, inside the hardened tree. Passing the checkout made SYSTEM write into a
    # directory a non-administrator may control - a junction on logs\ turns that into a SYSTEM
    # file-write primitive.
    Assert-True ($sfcArguments -notmatch '-ProjectRoot') `
        ("FU-01: the SFC task must not be pointed back at the checkout for its log directory. Got: {0}" -f $sfcArguments)

    Reset-BlockerState
    $script:HardeningFixes = $false
    $script:UntrustedWriters[$stagedSfc] = @('BUILTIN\Users (S-1-5-32-545) : Modify')
    $sfcError = $null
    try { Register-PostRebootSfcTask } catch { $sfcError = [string]$_.Exception.Message }
    Assert-True ($null -ne $sfcError) "H-02: a writable post-reboot SFC script must abort registration, not be scheduled for SYSTEM."
    Assert-Equal 0 $script:RegisterCalls.Count "H-02: no SYSTEM task may be registered against a target a non-administrator can rewrite."

    # =========================================================================================
    # H-02 / FU-01 with a REAL DACL. Everything above is scripted; this proves the hardening pass
    # really removes every non-administrative writer AND really takes ownership.
    #
    # Taking ownership for BUILTIN\Administrators needs an elevated token - a non-elevated shell
    # holds that SID deny-only and Windows refuses it as an owner - so the case is gated on a
    # measured probe rather than on an assumption about the runner. GitHub Actions
    # windows-latest runs elevated and executes it; a developer shell usually skips it.
    # Test-TrustedTaskTargetPath is deliberately NOT asserted true afterwards: %TEMP% is by
    # design replace-capable by the interactive user, so the full walk can never pass there.
    # That walk is proven end to end against real owners in tests\TaskTargetOwnership.Tests.ps1.
    # =========================================================================================
    $aclAvailable = ($null -ne (Get-Command Get-Acl -ErrorAction SilentlyContinue)) -and ($null -ne (Get-Command Set-Acl -ErrorAction SilentlyContinue))
    foreach ($name in @('Get-UntrustedAclWriter', 'Test-PathContainsReparsePoint', 'Initialize-TrustedTaskAcl',
            'Test-TrustedTaskTargetPath', 'Get-PathOwnerSid', 'Get-ReplaceCapableUntrustedPrincipal')) {
        . ([scriptblock]::Create((Import-FunctionUnderTest $name $setupAsts)))
    }
    $aclDir = Join-Path $testRoot 'acl-probe'
    New-Item -ItemType Directory -Path $aclDir -Force | Out-Null
    $canTakeOwnership = $false
    if ($aclAvailable) {
        try {
            $ownershipProbe = New-Object System.Security.AccessControl.DirectorySecurity
            $ownershipProbe.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
            Set-Acl -LiteralPath $aclDir -AclObject $ownershipProbe -ErrorAction Stop
            $canTakeOwnership = ((Get-PathOwnerSid -Path $aclDir) -eq 'S-1-5-32-544')
        } catch { $canTakeOwnership = $false }
    }
    if (-not $aclAvailable) {
        Write-Host "SKIP H-02 real-DACL case: Get-Acl/Set-Acl are not loadable in this guarded host; the other host covers it."
    } elseif (Test-PathContainsReparsePoint -Path $aclDir) {
        Write-Host "SKIP H-02 real-DACL case: this machine's temp path chain contains a reparse point."
    } elseif (-not $canTakeOwnership) {
        Write-Host "SKIP H-02/FU-01 real-DACL case: this host cannot make BUILTIN\Administrators the owner of a file, which the hardening pass requires by design. Run elevated (CI does) to execute it."
    } else {
        $probeAcl = Get-Acl -LiteralPath $aclDir
        $probeAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')),
                    [System.Security.AccessControl.FileSystemRights]::Modify,
                    ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow)))
        Set-Acl -LiteralPath $aclDir -AclObject $probeAcl
        try {
            # Every assertion below reads the DACL that was written. Nothing here depends on what
            # THIS process can still open, so the case behaves identically whether the test host
            # is elevated (CI, where the process stays in BUILTIN\Administrators and therefore
            # keeps full access to the hardened directory) or not (a normal developer shell).
            # Resolved from the well-known SID rather than the name, which is localizable.
            $usersSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
            $usersName = ''
            try { $usersName = [string]$usersSid.Translate([System.Security.Principal.NTAccount]).Value } catch { $usersName = '' }
            $writeMask = [int]([System.Security.AccessControl.FileSystemRights]::Write -bor
                [System.Security.AccessControl.FileSystemRights]::Delete -bor
                [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
                [System.Security.AccessControl.FileSystemRights]::TakeOwnership)
            function Get-ProbeUsersAce {
                return @((Get-Acl -LiteralPath $aclDir).Access | Where-Object {
                        $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
                        [string]$_.IdentityReference.Value -in @($usersSid.Value, $usersName)
                    })
            }

            # Precondition: the ACE this case plants really does grant a write-class right, so the
            # "after" assertion cannot pass vacuously.
            $before = @(Get-ProbeUsersAce)
            Assert-True ($before.Count -ge 1) "H-02: the probe must actually grant BUILTIN\Users an ACE before hardening."
            Assert-True (@($before | Where-Object { ([int]$_.FileSystemRights -band $writeMask) -ne 0 }).Count -ge 1) `
                "H-02: the planted ACE must really carry a write-class right, or the hardening assertion proves nothing."
            Assert-Equal $false (Test-TrustedTaskTargetPath -Path $aclDir).Trusted `
                "H-02: a directory a non-administrative SID can write must be reported as an untrusted task target."

            Initialize-TrustedTaskAcl -Path $aclDir | Out-Null

            # The security property itself, read straight off the resulting DACL and independent of
            # Get-UntrustedAclWriter, so a defect in that helper cannot make both sides agree.
            $after = @(Get-ProbeUsersAce)
            Assert-Equal 0 (@($after | Where-Object { ([int]$_.FileSystemRights -band $writeMask) -ne 0 }).Count) `
                "H-02: BUILTIN\Users must keep no write, delete or ownership right on a hardened SYSTEM task target."
            Assert-Equal $true (Get-Acl -LiteralPath $aclDir).AreAccessRulesProtected `
                "H-02: hardening must disable inheritance, or a permissive parent re-opens the hole."
            Assert-Equal 0 (@(Get-UntrustedAclWriter -Path $aclDir).Count) "H-02: no untrusted writer may remain after hardening."
            # FU-01: the half a clean DACL cannot express. An owner keeps WRITE_DAC whatever the
            # DACL says, so hardening that does not also move ownership leaves the hole open.
            Assert-Equal 'S-1-5-32-544' (Get-PathOwnerSid -Path $aclDir) `
                "FU-01: hardening must leave BUILTIN\Administrators as the OWNER; anyone else keeps WRITE_DAC and can undo the DACL above."
            Assert-Equal 0 (@(Get-ReplaceCapableUntrustedPrincipal -Path $aclDir).Count) `
                "FU-01: a hardened target must leave no non-administrative principal able to delete or replace it."
        } finally {
            # Correct at either privilege level: an elevated run still holds Administrators
            # FullControl on the hardened directory, and a non-elevated run - which has no access
            # left to it at all - is authorised by the parent's DELETE_CHILD, which %TEMP% grants.
            # Wrapped so cleanup can never mask the assertion that actually failed.
            try { [System.IO.Directory]::Delete($aclDir, $false) }
            catch { Remove-Item -LiteralPath $aclDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    # ---- Targeted source assertion: the manifest directory is redirected into the sandbox above,
    #      so the production root's own hardening is pinned here instead. ----
    Assert-True ((Import-FunctionUnderTest 'Get-TaskTrustManifestRoot' $setupAsts) -match 'Initialize-TrustedDirectory') `
        "H-02: the trust manifest directory must itself be ACL-hardened, or the manifest is just another writable file."

    # ---- The REAL Get-TaskStagingRoot, run last so nothing above is affected. It is redirected
    #      into the sandbox for every install case, so its own layout is exercised here instead:
    #      %ProgramData% is pointed at a temp tree and the hardening pass is recorded rather than
    #      performed, which needs no elevation and works on both hosts. ----
    . ([scriptblock]::Create((Import-FunctionUnderTest 'Get-TaskStagingRoot' $setupAsts)))
    function Initialize-TrustedTaskAcl { param([string]$Path) $script:HardenedPaths.Add([string]$Path) | Out-Null; return $Path }
    $previousProgramData = $env:ProgramData
    try {
        $env:ProgramData = (New-Item -ItemType Directory -Path (Join-Path $testRoot 'programdata') -Force).FullName
        $script:HardenedPaths.Clear()
        $realStaging = Get-TaskStagingRoot

        Assert-Equal (ConvertTo-CanonicalPath (Join-Path $env:ProgramData 'WinServerSetup\tasks')) $realStaging `
            "FU-01: the SYSTEM task staging root must be %ProgramData%\WinServerSetup\tasks, not anywhere in the checkout."
        Assert-True (Test-Path -LiteralPath $realStaging) "FU-01: the staging root must be created, not merely named."
        Assert-True ($script:HardenedPaths -contains (Join-Path $env:ProgramData 'WinServerSetup\tasks')) `
            "FU-01: the staging root must be ACL-hardened and owned by us, or copying into it achieves nothing."
        # The parent is the component a replace-capable principal would swap to substitute the
        # whole hardened directory without ever touching a file inside it.
        Assert-True ($script:HardenedPaths -contains (Join-Path $env:ProgramData 'WinServerSetup')) `
            "FU-01: the staging root's PARENT must be hardened too - replacing it replaces the hardened directory wholesale."
    } finally {
        $env:ProgramData = $previousProgramData
    }

    Write-Host "PASS blocker task registration stages its script and effective config into the directory this project owns, refuses a port disagreement, bounds a single run, validates every SYSTEM task target, and the health check re-proves the whole action/principal/trigger/settings/ACL/hash contract against the staged copies."
} finally {
    $Global:Config = $previousConfig
    $Global:ProjectRoot = $previousRoot
    $Global:ConfigPath = $previousConfigPath
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
