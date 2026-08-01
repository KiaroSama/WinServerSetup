<#
    Behavioral tests for the health check, the scheduled-task contract check, and the safe
    directory-cleanup helper in WinServerSetup.ps1.

    This file used to be ten regex matches against source text. Two of them were close to
    unfalsifiable - `Enabled\s*=` and `return \[pscustomobject\]@\{[^}]*Passed` match somewhere in a
    4000-line file almost regardless of what the health check actually does. Neither could tell the
    difference between "a disabled feature is skipped" and "a disabled feature is reported as
    broken", which is the entire point of the Enabled flag.

    The tests below run the real functions. Invoke-HealthCheck is driven through a synthetic
    $Global:Config so the pass/fail/skip arithmetic is checked directly; Test-ScheduledTaskContract
    runs against a shadowed Task Scheduler; Remove-DirectoryContentsSafe deletes real files inside a
    temp directory this suite created, and its refusal path is additionally fenced with recording
    stubs so a regression in the guard cannot delete anything.
#>
# -MainScript targets an alternate copy so these tests can be replayed against a deliberately
# defective build to prove they still fail. CI and local runs use the default.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Cmdlets are shadowed deliberately to mock Windows-only APIs and to fence the delete path.')]
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
Assert-True ($parseErrors.Count -eq 0) "WinServerSetup.ps1 must parse before its cleanup and health paths can be tested."

function Import-FunctionUnderTest {
    param([string]$Name)
    $definition = $ast.FindAll({
            param($node)
            ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq $Name)
        }, $true) | Select-Object -First 1
    if ($null -eq $definition) { throw "WinServerSetup.ps1 must define $Name." }
    return $definition.Extent.Text
}

foreach ($name in @('Invoke-HealthCheck', 'Test-ScheduledTaskContract', 'Remove-DirectoryContentsSafe',
        'Test-UnsafeReplaceTarget', 'Test-ConfiguredWingetPackage', 'Restore-ServiceState')) {
    . ([scriptblock]::Create((Import-FunctionUnderTest $name)))
}

# ---- Captured console/log output. Nothing may reach the real console, and nothing may leak into
#      the output stream: Invoke-HealthCheck RETURNS its counts, so a chatty stub would corrupt it.
$script:Log = New-Object System.Collections.Generic.List[string]
function Write-Section { param([string]$Message) $script:Log.Add("SECTION $Message") | Out-Null }
function Write-Info { param([string]$Message) $script:Log.Add("INFO $Message") | Out-Null }
function Write-Ok { param([string]$Message) $script:Log.Add("OK $Message") | Out-Null }
function Write-Warn { param([string]$Message) $script:Log.Add("WARN $Message") | Out-Null }
function Write-Fail { param([string]$Message) $script:Log.Add("FAIL $Message") | Out-Null }
function Write-StructuredLog {
    param([string]$Level = 'INFO', [string]$Message = '', [string]$Section = '')
    $script:Log.Add("LOG $Level $Message") | Out-Null
}

# The only health item this suite drives through a stub; every other enabled-by-default item is
# switched off in the synthetic config so the arithmetic below is fully determined.
$script:PwshProbe = 'true'
function Test-CommandExists {
    param([string]$Name)
    if ($script:PwshProbe -eq 'throw') { throw "probe exploded" }
    return ($script:PwshProbe -eq 'true')
}

$testRoot = Join-Path $env:TEMP ("WinServerSetup-Cleanup-{0}" -f ([guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

function New-HealthConfig {
    <#
        Every switch defaults to $false, so a health run over this config must report every item as
        Skipped. Individual cases then turn on exactly the items they intend to measure.
    #>
    param([bool]$PowerShellEnabled = $false, [bool]$FoldersEnabled = $false, [string]$PortablePath = "", [string]$ScriptsPath = "")
    return [pscustomobject]@{
        winget           = [pscustomobject]@{ installIfMissing = $false; packages = @() }
        customFolders    = [pscustomobject]@{
            enabled = $FoldersEnabled; portablePath = $PortablePath; scriptsPath = $ScriptsPath
            createCompressedInDownloads = $false; excludeCompressedFromDefender = $false; compressedFolderName = 'Compressed'
        }
        powershell       = [pscustomobject]@{ enabled = $PowerShellEnabled; setPs1DefaultApp = $false }
        windowsTerminal  = [pscustomobject]@{ enabled = $false }
        v2rayN           = [pscustomobject]@{ enabled = $false; installDir = ""; finalFolderName = ""; exeName = "" }
        directInstallers = @()
        indexing         = [pscustomobject]@{ enabled = $false }
        rdp              = [pscustomobject]@{ enabled = $false; newPort = 3389 }
        emptyStandbyList = [pscustomobject]@{ enabled = $false; taskName = ""; installDir = ""; exeName = ""; argument = "" }
        rdpBruteforceBlocker = [pscustomobject]@{ enabled = $false; taskName = "" }
        appearance       = [pscustomobject]@{ showFileExtensions = $false; darkMode = $false }
        filesystem       = [pscustomobject]@{ enableLongPaths = $false }
        sevenZipDefaults = [pscustomobject]@{ enabled = $false }
    }
}

$previousConfig = $Global:Config
try {
    $portable = Join-Path $testRoot 'portable'
    $scripts = Join-Path $testRoot 'scripts'
    New-Item -ItemType Directory -Path $portable, $scripts -Force | Out-Null
    $missing = Join-Path $testRoot 'does-not-exist'

    # ---- 1. CONFIG-AWARE SKIPPING. Everything disabled must be Skipped, never Failed. Reporting a
    #         feature the operator deliberately turned off as broken is what makes a health summary
    #         worthless. This also establishes the item count the later cases are relative to. ----
    $script:Log.Clear()
    $Global:Config = New-HealthConfig
    $allDisabled = Invoke-HealthCheck
    Assert-Equal 0 $allDisabled.Failed "A fully disabled configuration must report zero failures."
    Assert-Equal 0 $allDisabled.Passed "A fully disabled configuration must report zero passes."
    Assert-True ($allDisabled.Skipped -gt 0) "A fully disabled configuration must report its items as skipped."
    $itemCount = $allDisabled.Skipped
    Assert-True ((($script:Log) -join "`n") -match 'disabled; skipped') "A skipped item must say why it was skipped."

    # ---- 2. All enabled checks passing. Two items are enabled: one filesystem-backed, one stubbed.
    $script:Log.Clear()
    $script:PwshProbe = 'true'
    $Global:Config = New-HealthConfig -PowerShellEnabled $true -FoldersEnabled $true -PortablePath $portable -ScriptsPath $scripts
    $healthy = Invoke-HealthCheck
    Assert-Equal 2 $healthy.Passed "Both enabled checks must pass."
    Assert-Equal 0 $healthy.Failed "No enabled check may fail when both conditions hold."
    Assert-Equal ($itemCount - 2) $healthy.Skipped "Enabling two items must move exactly two out of the skipped bucket."

    # ---- 3. One failing check must be counted once, and must not disturb the other counts. ----
    $script:Log.Clear()
    $script:PwshProbe = 'false'
    $Global:Config = New-HealthConfig -PowerShellEnabled $true -FoldersEnabled $true -PortablePath $portable -ScriptsPath $scripts
    $oneFailed = Invoke-HealthCheck
    Assert-Equal 1 $oneFailed.Failed "A single failing check must be counted exactly once."
    Assert-Equal 1 $oneFailed.Passed "A failing check must not suppress the passing one."
    Assert-Equal ($itemCount - 2) $oneFailed.Skipped "A failure must not change the skipped count."

    # ---- 3b. An enabled item whose directories are missing must FAIL, not be skipped. ----
    $script:PwshProbe = 'true'
    $Global:Config = New-HealthConfig -PowerShellEnabled $true -FoldersEnabled $true -PortablePath $missing -ScriptsPath $scripts
    $missingFolders = Invoke-HealthCheck
    Assert-Equal 1 $missingFolders.Failed "An enabled feature whose target is absent must be reported as failed."

    # ---- 3c. A probe that THROWS must be counted as a failure, not abort the whole health run. ----
    $script:PwshProbe = 'throw'
    $Global:Config = New-HealthConfig -PowerShellEnabled $true -FoldersEnabled $true -PortablePath $portable -ScriptsPath $scripts
    $threw = Invoke-HealthCheck
    Assert-Equal 1 $threw.Failed "A probe that throws must be recorded as a failed item."
    Assert-Equal 1 $threw.Passed "One exploding probe must not take the rest of the health check down with it."
    Assert-Equal ($itemCount - 2) $threw.Skipped "An exception must not change the skipped count."

    # =========================================================================================
    # Test-ScheduledTaskContract against a shadowed Task Scheduler.
    # =========================================================================================
    $script:TaskExists = $true
    $script:TaskExecute = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:TaskArguments = '-File "C:\tools\blocker.ps1" -ConfigPath "C:\tools\config.json"'
    $script:TaskUser = 'SYSTEM'
    $script:TaskRunLevel = 'Highest'
    $script:TaskTriggers = @([pscustomobject]@{ Enabled = $true })
    $script:TaskState = 'Ready'
    $script:TaskLastResult = 0
    $script:TaskNextRun = (Get-Date).AddHours(1)

    function Get-ScheduledTask {
        param([string]$TaskName, $ErrorAction)
        if (-not $script:TaskExists) { throw "No MSFT_ScheduledTask objects found with property 'TaskName' equal to '$TaskName'." }
        return [pscustomobject]@{
            TaskName  = $TaskName
            State     = $script:TaskState
            Actions   = @([pscustomobject]@{ Execute = $script:TaskExecute; Arguments = $script:TaskArguments })
            Principal = [pscustomobject]@{ UserId = $script:TaskUser; RunLevel = $script:TaskRunLevel }
            Triggers  = $script:TaskTriggers
        }
    }
    function Get-ScheduledTaskInfo {
        param([string]$TaskName, $ErrorAction)
        return [pscustomobject]@{ LastTaskResult = $script:TaskLastResult; NextRunTime = $script:TaskNextRun }
    }

    $expectedExe = $script:TaskExecute
    $expectedArgs = [regex]::Escape('C:\tools\blocker.ps1')

    # ---- 4a. A healthy task satisfies the contract. ----
    Assert-Equal $true (Test-ScheduledTaskContract -TaskName 'T' -ExpectedExecutable $expectedExe -ExpectedArgumentPattern $expectedArgs -RequireHealthyLastResult) `
        "A SYSTEM/Highest task with the right action, a trigger, LastTaskResult 0 and a next run is healthy."

    # ---- 4b. 267011 is "has not yet run", which is healthy for a freshly registered task. ----
    $script:TaskLastResult = 267011
    Assert-Equal $true (Test-ScheduledTaskContract -TaskName 'T' -ExpectedExecutable $expectedExe -ExpectedArgumentPattern $expectedArgs -RequireHealthyLastResult) `
        "A task that has not yet run must not be reported as unhealthy."

    # ---- 4c. Any other last result means the control silently stopped working. ----
    $script:TaskLastResult = 1
    Assert-Equal $false (Test-ScheduledTaskContract -TaskName 'T' -ExpectedExecutable $expectedExe -ExpectedArgumentPattern $expectedArgs -RequireHealthyLastResult) `
        "A task whose last run failed must not be reported as healthy."
    # ... but without the switch, the contract check is about registration only.
    Assert-Equal $true (Test-ScheduledTaskContract -TaskName 'T' -ExpectedExecutable $expectedExe -ExpectedArgumentPattern $expectedArgs) `
        "Without -RequireHealthyLastResult the check must only validate the registration contract."

    # ---- 4d. A disabled task protects nothing. ----
    $script:TaskLastResult = 0
    $script:TaskState = 'Disabled'
    Assert-Equal $false (Test-ScheduledTaskContract -TaskName 'T' -ExpectedExecutable $expectedExe -ExpectedArgumentPattern $expectedArgs -RequireHealthyLastResult) `
        "A disabled task must never be reported as healthy."

    # ---- 4e. No next run means it will never fire again. ----
    $script:TaskState = 'Ready'
    $script:TaskNextRun = $null
    Assert-Equal $false (Test-ScheduledTaskContract -TaskName 'T' -ExpectedExecutable $expectedExe -ExpectedArgumentPattern $expectedArgs -RequireHealthyLastResult) `
        "A task with no scheduled next run must not be reported as healthy."

    # ---- 4f. Registration-contract violations. ----
    $script:TaskNextRun = (Get-Date).AddHours(1)
    $script:TaskUser = 'mobin'
    Assert-Equal $false (Test-ScheduledTaskContract -TaskName 'T' -ExpectedExecutable $expectedExe -ExpectedArgumentPattern $expectedArgs) `
        "A task not running as SYSTEM must fail the contract."
    $script:TaskUser = 'SYSTEM'
    $script:TaskRunLevel = 'Limited'
    Assert-Equal $false (Test-ScheduledTaskContract -TaskName 'T' -ExpectedExecutable $expectedExe -ExpectedArgumentPattern $expectedArgs) `
        "A task without Highest run level must fail the contract."
    $script:TaskRunLevel = 'Highest'
    $script:TaskTriggers = @()
    Assert-Equal $false (Test-ScheduledTaskContract -TaskName 'T' -ExpectedExecutable $expectedExe -ExpectedArgumentPattern $expectedArgs) `
        "A task with no trigger can never run and must fail the contract."
    $script:TaskTriggers = @([pscustomobject]@{ Enabled = $true })
    $script:TaskArguments = '-File "C:\somewhere\else.ps1"'
    Assert-Equal $false (Test-ScheduledTaskContract -TaskName 'T' -ExpectedExecutable $expectedExe -ExpectedArgumentPattern $expectedArgs) `
        "A task pointing at a different script must fail the contract."
    $script:TaskArguments = '-File "C:\tools\blocker.ps1" -ConfigPath "C:\tools\config.json"'
    $script:TaskExecute = 'C:\Windows\System32\cmd.exe'
    Assert-Equal $false (Test-ScheduledTaskContract -TaskName 'T' -ExpectedExecutable $expectedExe -ExpectedArgumentPattern $expectedArgs) `
        "A task launched through a different executable must fail the contract."

    # ---- 4g. A missing task must be false, not an exception escaping into the health run. ----
    $script:TaskExecute = $expectedExe
    $script:TaskExists = $false
    Assert-Equal $false (Test-ScheduledTaskContract -TaskName 'T' -ExpectedExecutable $expectedExe -ExpectedArgumentPattern $expectedArgs) `
        "An absent task must yield false rather than propagating the lookup error."
    $script:TaskExists = $true

    # =========================================================================================
    # Restore-ServiceState - the finally-block collaborator that puts wuauserv/BITS back.
    # =========================================================================================
    $script:ServiceActions = New-Object System.Collections.Generic.List[string]
    function Start-Service { param([string]$Name, $ErrorAction) $script:ServiceActions.Add("START $Name") | Out-Null }
    function Stop-Service { param([string]$Name, [switch]$Force, $ErrorAction) $script:ServiceActions.Add("STOP $Name") | Out-Null }

    Restore-ServiceState -Name 'wuauserv' -WasRunning $true
    Assert-Equal 'START wuauserv' ($script:ServiceActions -join ';') "A service that was running must be started again."
    $script:ServiceActions.Clear()
    Restore-ServiceState -Name 'bits' -WasRunning $false
    Assert-Equal 'STOP bits' ($script:ServiceActions -join ';') "A service that was stopped must be left stopped."

    # =========================================================================================
    # Remove-DirectoryContentsSafe - REAL deletion, inside this suite's own temp tree.
    # =========================================================================================
    # ---- 5a. Successful cleanup reports the real removed count and keeps the directory itself. ----
    $cacheDir = Join-Path $testRoot 'cache'
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    1..3 | ForEach-Object { Set-Content -LiteralPath (Join-Path $cacheDir "file$_.tmp") -Value 'x' -Encoding UTF8 }
    New-Item -ItemType Directory -Path (Join-Path $cacheDir 'nested') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $cacheDir 'nested\deep.tmp') -Value 'x' -Encoding UTF8

    $cleaned = Remove-DirectoryContentsSafe -Path $cacheDir
    Assert-Equal $true $cleaned.Succeeded "Cleaning a writable directory must succeed."
    Assert-Equal $false $cleaned.Unsafe "A normal application directory must not be flagged unsafe."
    Assert-Equal 4 $cleaned.Removed "The removed count must be the real number of top-level entries deleted."
    Assert-Equal 0 $cleaned.Failed "Nothing may be reported as failed when every delete succeeded."
    Assert-Equal 0 (@(Get-ChildItem -LiteralPath $cacheDir -Force).Count) "The directory contents must actually be gone."
    Assert-True (Test-Path -LiteralPath $cacheDir) "Only the CONTENTS are removed; the directory itself must survive."

    # ---- 5b. A path that does not exist is a no-op success, not a failure. ----
    $absent = Remove-DirectoryContentsSafe -Path $missing
    Assert-Equal $true $absent.Succeeded "An absent cache directory is nothing to clean, not an error."
    Assert-Equal 0 $absent.Removed "Nothing can be removed from a directory that does not exist."

    # ---- 5c. THE REFUSAL PATH. A configured downloadRoot of "C:\" would otherwise enumerate and
    #         recursively delete every child of the system drive.
    #
    #         Get-ChildItem and Remove-Item are shadowed with recording stubs FIRST, so this case
    #         cannot delete anything even if the guard itself regressed. The assertion is both that
    #         the result says Unsafe and that neither stub was ever reached. ----
    $script:EnumeratedPaths = New-Object System.Collections.Generic.List[string]
    $script:RemovedPaths = New-Object System.Collections.Generic.List[string]
    function Get-ChildItem {
        param([string]$LiteralPath, [string]$Path, [switch]$Force, [switch]$File, [string]$Filter, $ErrorAction)
        $script:EnumeratedPaths.Add([string]$LiteralPath) | Out-Null
        return @()
    }
    function Remove-Item {
        param([string]$LiteralPath, [switch]$Recurse, [switch]$Force, $ErrorAction)
        $script:RemovedPaths.Add([string]$LiteralPath) | Out-Null
    }

    $driveRoot = [System.IO.Path]::GetPathRoot($testRoot)
    $refused = Remove-DirectoryContentsSafe -Path $driveRoot
    Assert-Equal $true $refused.Unsafe "A drive root must be refused as a cleanup target."
    Assert-Equal $false $refused.Succeeded "A refused cleanup must not report success."
    Assert-Equal 0 $script:EnumeratedPaths.Count "A refused target must not even be enumerated."
    Assert-Equal 0 $script:RemovedPaths.Count "A refused target must have nothing deleted under it."

    foreach ($protectedPath in @($env:SystemRoot, $env:ProgramFiles, $env:ProgramData)) {
        if ([string]::IsNullOrWhiteSpace($protectedPath)) { continue }
        $protectedResult = Remove-DirectoryContentsSafe -Path $protectedPath
        Assert-Equal $true $protectedResult.Unsafe ("A protected system directory must be refused: {0}" -f $protectedPath)
    }
    Assert-Equal 0 $script:RemovedPaths.Count "No protected system directory may reach the delete call."

    # ---- Retained source greps: cheap smoke checks over the orchestration these functions sit in
    #      (Clear-WinServerSetupTempAndCache stops real services; the exit path is covered by
    #      tests/SetupOutcome.Tests.ps1). ----
    Assert-True ($source -match 'finally[\s\S]{0,500}Restore-ServiceState') "Service restoration must run even when cleanup fails."
    Assert-True ($source -match 'Cleanup failed') "Partial deletion failures must not be reported as clean success."
    Assert-True ($source -match 'Full setup completed with failures') "Full setup must report partial failure explicitly."
    Assert-True ($source -notmatch 'Write-Ok "Full setup completed\."') "Full setup must not print unconditional success."
    Assert-True ($source -match 'Invoke-FullSetupWithActiveTimer') "Noninteractive/full invocation must run the timed full setup."
    Assert-True ($source -match 'exit \(\[int\]\$exitCode\)') "Noninteractive/full invocation must coerce a real integer exit code when setup is partial."

    Write-Host ("PASS health check counts disabled items as Skipped and throwing probes as Failed over {0} items, the scheduled-task contract rejects every unhealthy shape, and safe cleanup deletes real contents while refusing drive roots and protected system directories." -f $itemCount)
} finally {
    $Global:Config = $previousConfig
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
