<#
    Behavioral tests for the Windows Update path in WinServerSetup.ps1:
    Invoke-WithPSGalleryTrust, Initialize-WindowsUpdateEnvironment, Invoke-WindowsUpdatePass and
    Invoke-SystemUpdate.

    This file used to be seven regex matches against source text. One of them - `ResultCode|Result`
    - was unfalsifiable: the substring `Result` occurs somewhere in a 4000-line script no matter
    what the update code does, so the assertion passed for every possible implementation. The
    others asserted on the presence of literals (`finally[\s\S]{0,500}Set-PSRepository`,
    `Stop-Job[\s\S]{0,300}timed out`), which means a refactor that kept the behavior could fail the
    test while a rewrite that dropped the behavior could pass it.

    The tests below run the real functions with the whole update surface shadowed. Nothing here
    contacts PSGallery, installs a module, starts a background job or asks Windows for an update:
    Install-Module, Install-WindowsUpdate and Start-Job are replaced, and Install-WindowsUpdate is
    a tripwire that fails the suite if it is ever reached.

    The wall-clock timeout trip IS exercised (this used to be a documented gap).
    Elapsed time is measured with a real System.Diagnostics.Stopwatch - a static .NET factory
    that cannot be shadowed from PowerShell - and config validates windowsUpdate.jobTimeoutMinutes
    as whole minutes with a 1-minute floor, so reaching the `Stop-Job` + throw branch through
    Invoke-WindowsUpdatePass costs at least 60 s of real time. The bounded poll is therefore its
    own function, Wait-WindowsUpdateJob, taking the budget as a [double] parameter: the trip runs
    here in milliseconds while production still applies the 1-minute floor at the call site.
    Also covered: the loop re-reads job state from Get-Job on every iteration and sleeps between
    polls (a stale-state regression would spin forever, and the Start-Sleep stub bounds that into
    a failure rather than a hang).
#>
# The Windows Update surface is mocked by shadowing cmdlets with functions; the mock signatures
# mirror the real cmdlets - including parameters this file never reads - so the code under test
# binds exactly as it does in production.
# -MainScript targets an alternate copy so these tests can be replayed against a deliberately
# defective build to prove they still fail. CI and local runs use the default.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Cmdlets are shadowed deliberately to mock PowerShellGet, PSWindowsUpdate and the job engine.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock signatures mirror the real cmdlets so parameter binding matches production.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '', Justification = 'The real cmdlets are called with -Confirm:$false, so the mocks must declare a matching Confirm switch; SupportsShouldProcess would not accept the same binding.')]
param([string]$MainScript = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$mainScript = if ([string]::IsNullOrWhiteSpace($MainScript)) { Join-Path $projectRoot "WinServerSetup.ps1" } else { $MainScript }

. (Join-Path $PSScriptRoot '_Common.ps1')
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    if ($null -eq $caught) { throw ("{0} Nothing was thrown." -f $Message) }
    $text = [string]$caught.Exception.Message
    if ($Pattern -and ($text -notmatch $Pattern)) {
        throw ("{0} Expected a message matching '{1}'; Actual='{2}'" -f $Message, $Pattern, $text)
    }
    return $text
}

# ---- Import only the functions under test; the main script self-executes if dot-sourced. ----
# WinServerSetup.ps1 dot-sources its function library from scripts\; search that whole
# partition so extraction by name keeps working wherever a function lives. $mainScript is
# searched first, so a -MainScript copy still shadows the on-disk original when replaying
# against a deliberately defective build.
$setupSourceFiles = @(Get-SetupSourceFile -ProjectRoot $projectRoot -MainScript $mainScript)
$setupAsts = @(Get-SetupAst -Files $setupSourceFiles -Because 'its Windows Update path can be tested')
# Raw text of the same partition, for the retained source assertions further down.
$source = ($setupSourceFiles | ForEach-Object { Get-Content -LiteralPath $_ -Raw -Encoding UTF8 }) -join "`r`n"

foreach ($name in @('Invoke-WithPSGalleryTrust', 'Initialize-WindowsUpdateEnvironment',
        'Wait-WindowsUpdateJob', 'Invoke-WindowsUpdatePass', 'Invoke-SystemUpdate')) {
    . ([scriptblock]::Create((Import-FunctionUnderTest $name $setupAsts)))
}

# ---- Captured console/log output. Nothing may reach the real console, and nothing may leak into
#      the output stream: Invoke-WindowsUpdatePass RETURNS the update count, so a chatty stub
#      would corrupt it. ----
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
function Write-StatusInPlace { param([string]$Message) $script:StatusWrites++ }
function Clear-StatusInPlace { $script:StatusClears++ }
function Set-StepSkipped { param([string]$Reason) $script:SkipReason = $Reason }
function Set-PendingReboot { param([string]$Reason = "") $script:PendingReboot = $Reason }
function Test-WindowsRebootRequired { return $script:RebootRequired }
function Get-LogText { return ($script:Log -join "`n") }

# =============================================================================
# Shadowed PowerShellGet / PSWindowsUpdate / job surface.
# =============================================================================
$script:RepositoryPolicy = 'Untrusted'
$script:PolicyWrites = New-Object System.Collections.Generic.List[string]
$script:RepositoryLookupFails = $false

function Get-PSRepository {
    param([string]$Name, $ErrorAction)
    if ($script:RepositoryLookupFails) { throw "Unable to find repository '$Name'." }
    return [pscustomobject]@{ Name = $Name; InstallationPolicy = $script:RepositoryPolicy }
}
function Set-PSRepository {
    param([string]$Name, [string]$InstallationPolicy, $ErrorAction)
    $script:RepositoryPolicy = $InstallationPolicy
    $script:PolicyWrites.Add($InstallationPolicy) | Out-Null
}

$script:AvailableModules = @()
$script:InstallModuleCalls = New-Object System.Collections.Generic.List[string]
$script:PolicyDuringInstall = New-Object System.Collections.Generic.List[string]
$script:ImportedModules = New-Object System.Collections.Generic.List[string]
$script:ServiceManagerCalls = 0
$script:InstallModuleFails = $false

# No [Parameter()] attributes on these stubs: one would make the function advanced, and PowerShell
# then supplies its own -ErrorAction, colliding with the explicit parameter the real cmdlet needs.
function Get-Module {
    param([string]$Name, [switch]$ListAvailable)
    return @($script:AvailableModules | Where-Object { $_ -eq $Name })
}
function Import-Module {
    param([string]$Name, [switch]$Force, $ErrorAction)
    $script:ImportedModules.Add([string]$Name) | Out-Null
}
function Install-Module {
    param([string]$Name, [switch]$Force, [switch]$AllowClobber, [switch]$Confirm, $ErrorAction)
    # Recording the live policy at call time is the whole point: it proves PSGallery was actually
    # trusted while the install ran, not merely that Set-PSRepository appears somewhere nearby.
    $script:PolicyDuringInstall.Add($script:RepositoryPolicy) | Out-Null
    $script:InstallModuleCalls.Add([string]$Name) | Out-Null
    if ($script:InstallModuleFails) { throw "PSGallery is unreachable." }
}
function Get-PackageProvider {
    param([string]$Name, $ErrorAction)
    return [pscustomobject]@{ Name = $Name }
}
function Install-PackageProvider {
    param([string]$Name, [string]$MinimumVersion, [switch]$Force, [switch]$Confirm, $ErrorAction)
    throw "Install-PackageProvider must not run: NuGet was reported present."
}
function Add-WUServiceManager {
    param([switch]$MicrosoftUpdate, [switch]$Confirm, $ErrorAction)
    $script:ServiceManagerCalls++
}

$script:ScanQueue = New-Object System.Collections.Generic.List[object]
$script:ScanCalls = 0
function Get-WindowsUpdate {
    [CmdletBinding()]
    param([switch]$MicrosoftUpdate, [switch]$AcceptAll)
    $script:ScanCalls++
    if ($script:ScanQueue.Count -eq 0) { throw "The suite ran out of seeded scan results after $script:ScanCalls scan(s)." }
    $next = $script:ScanQueue[0]
    $script:ScanQueue.RemoveAt(0)
    if ($next -is [string] -and $next -eq 'THROW') { throw "Access denied while searching for updates." }
    return @($next)
}

# Tripwire. The install runs inside a Start-Job script block that this suite never executes, so
# reaching this function means a real Windows Update install was attempted from a test.
$script:RealInstallAttempts = 0
function Install-WindowsUpdate {
    [CmdletBinding()]
    param()
    $script:RealInstallAttempts++
    throw "Install-WindowsUpdate was invoked for real by the test suite."
}

$script:JobStateQueue = New-Object System.Collections.Generic.List[string]
$script:JobOutput = @()
$script:JobErrorText = ""
$script:GetJobCalls = 0
$script:SleepCalls = 0
$script:StopJobCalls = 0
$script:RemoveJobCalls = 0
$script:StartJobCalls = 0
$script:StatusWrites = 0
$script:StatusClears = 0
$script:JobState = 'Completed'

function Start-Job {
    param([string]$Name, [scriptblock]$ScriptBlock)
    $script:StartJobCalls++
    return [pscustomobject]@{ Id = 4242; Name = $Name; State = $script:JobState }
}
function Get-Job {
    param([int]$Id)
    $script:GetJobCalls++
    if ($script:JobStateQueue.Count -gt 0) {
        $script:JobState = $script:JobStateQueue[0]
        $script:JobStateQueue.RemoveAt(0)
    }
    return [pscustomobject]@{ Id = $Id; State = $script:JobState }
}
function Stop-Job {
    param($Job, $ErrorAction)
    $script:StopJobCalls++
}
function Receive-Job {
    [CmdletBinding()]
    param($Job)
    if (-not [string]::IsNullOrWhiteSpace($script:JobErrorText)) { Write-Error $script:JobErrorText }
    return $script:JobOutput
}
function Remove-Job {
    param($Job, [switch]$Force, $ErrorAction)
    $script:RemoveJobCalls++
}
# Bounded: a regression that stops re-reading job state would poll forever, so the stub converts
# that hang into a failure instead of letting the suite sit there.
function Start-Sleep {
    param([int]$Seconds, [int]$Milliseconds)
    $script:SleepCalls++
    if ($script:SleepCalls -gt 25) { throw "The Windows Update poll loop did not terminate; job state is not being re-read." }
}
$script:StartProcessTargets = New-Object System.Collections.Generic.List[string]
function Start-Process {
    param([string]$FilePath)
    $script:StartProcessTargets.Add([string]$FilePath) | Out-Null
}

function New-UpdateConfig {
    param([bool]$Enabled = $true, [bool]$UseModule = $true, [int]$MaxPasses = 4, [int]$JobTimeoutMinutes = 120)
    return [pscustomobject]@{
        windowsUpdate = [pscustomobject]@{
            enabled                  = $Enabled
            usePSWindowsUpdateModule = $UseModule
            autoReboot               = $false
            maxPasses                = $MaxPasses
            jobTimeoutMinutes        = $JobTimeoutMinutes
        }
    }
}

function Reset-UpdateState {
    param([string[]]$Scans = @(), [string]$JobState = 'Completed', [object[]]$Output = @(), [string]$JobError = "")
    $script:Log.Clear()
    $script:PolicyWrites.Clear()
    $script:InstallModuleCalls.Clear()
    $script:PolicyDuringInstall.Clear()
    $script:ImportedModules.Clear()
    $script:StartProcessTargets.Clear()
    $script:ScanQueue.Clear()
    $script:JobStateQueue.Clear()
    $script:ScanCalls = 0
    $script:GetJobCalls = 0
    $script:SleepCalls = 0
    $script:StopJobCalls = 0
    $script:RemoveJobCalls = 0
    $script:StartJobCalls = 0
    $script:StatusWrites = 0
    $script:StatusClears = 0
    $script:ServiceManagerCalls = 0
    $script:RepositoryPolicy = 'Untrusted'
    $script:RepositoryLookupFails = $false
    $script:InstallModuleFails = $false
    $script:AvailableModules = @('PSWindowsUpdate')
    $script:RebootRequired = $false
    $script:PendingReboot = $null
    $script:SkipReason = $null
    $script:JobState = $JobState
    $script:JobOutput = $Output
    $script:JobErrorText = $JobError
    $Global:Config = New-UpdateConfig
}

# One detected update, used wherever a pass has to reach the install stage.
$oneUpdate = @([pscustomobject]@{ Title = 'KB5000001 Cumulative Update' })

$previousConfig = $Global:Config
$suiteClock = [System.Diagnostics.Stopwatch]::StartNew()
try {
    # =========================================================================================
    # 1. PSGallery trust is temporary, and the restore is in a finally.
    # =========================================================================================
    # ---- 1a. Untrusted -> Trusted for the action -> restored afterwards. ----
    Reset-UpdateState
    $trustSeen = $null
    $returned = Invoke-WithPSGalleryTrust { $script:TrustProbe = $script:RepositoryPolicy; 'action-result' }
    $trustSeen = $script:TrustProbe
    Assert-Equal 'Trusted' $trustSeen "The wrapped action must run while PSGallery is trusted."
    Assert-Equal 'action-result' $returned "Invoke-WithPSGalleryTrust must return the wrapped action's output."
    Assert-Equal 'Trusted,Untrusted' ($script:PolicyWrites -join ',') "The policy must be raised to Trusted and then put back to the original value."
    Assert-Equal 'Untrusted' $script:RepositoryPolicy "PSGallery must be left exactly as it was found."

    # ---- 1b. THE FINALLY CONTRACT. A throwing action must still restore the policy, and the
    #          exception must not be swallowed. This is what the old
    #          `finally[\s\S]{0,500}Set-PSRepository` grep could only guess at: that regex matched
    #          any finally block anywhere within 500 characters of any Set-PSRepository call. ----
    Reset-UpdateState
    $null = Assert-Throws { Invoke-WithPSGalleryTrust { throw "module install exploded" } } 'module install exploded' `
        "A failure inside the trusted block must propagate to the caller."
    Assert-Equal 'Trusted,Untrusted' ($script:PolicyWrites -join ',') "PSGallery trust must be restored on the failure path, not only on success."
    Assert-Equal 'Untrusted' $script:RepositoryPolicy "A failed install must not leave PSGallery permanently trusted."

    # ---- 1c. An already-trusted gallery is the operator's own setting; do not churn it. ----
    Reset-UpdateState
    $script:RepositoryPolicy = 'Trusted'
    Invoke-WithPSGalleryTrust { $null = 1 }
    Assert-Equal 0 $script:PolicyWrites.Count "An already-trusted PSGallery must not be rewritten."
    Assert-Equal 'Trusted' $script:RepositoryPolicy "An already-trusted PSGallery must stay trusted."

    # ---- 1d. If the repository cannot even be read, nothing is changed. ----
    Reset-UpdateState
    $script:RepositoryLookupFails = $true
    $null = Assert-Throws { Invoke-WithPSGalleryTrust { $null = 1 } } 'Unable to find repository' `
        "An unreadable PSGallery must fail loudly."
    Assert-Equal 0 $script:PolicyWrites.Count "A failed repository lookup must not write any policy."

    # =========================================================================================
    # 2. The module install really goes through the trust wrapper.
    # =========================================================================================
    # ---- 2a. Missing module -> installed under temporary trust -> policy restored. ----
    Reset-UpdateState
    $script:AvailableModules = @()
    Initialize-WindowsUpdateEnvironment
    Assert-Equal 1 $script:InstallModuleCalls.Count "A missing PSWindowsUpdate must be installed."
    Assert-Equal 'Trusted' ($script:PolicyDuringInstall -join ',') "Install-Module must run while PSGallery is trusted."
    Assert-Equal 'Untrusted' $script:RepositoryPolicy "Environment setup must not leave PSGallery trusted."
    Assert-Equal 'PSWindowsUpdate' ($script:ImportedModules -join ',') "The module must be imported after installation."
    Assert-Equal 1 $script:ServiceManagerCalls "The Microsoft Update service manager must be registered."

    # ---- 2b. Already present -> no install, and no trust window opened at all. ----
    Reset-UpdateState
    Initialize-WindowsUpdateEnvironment
    Assert-Equal 0 $script:InstallModuleCalls.Count "An already-available module must not be reinstalled."
    Assert-Equal 0 $script:PolicyWrites.Count "No install means no reason to touch the PSGallery policy."

    # ---- 2c. A failing install still restores the policy and still fails the step. ----
    Reset-UpdateState
    $script:AvailableModules = @()
    $script:InstallModuleFails = $true
    $null = Assert-Throws { Initialize-WindowsUpdateEnvironment } 'PSGallery is unreachable' `
        "A failed module install must fail the setup step."
    Assert-Equal 'Untrusted' $script:RepositoryPolicy "A failed module install must still restore the PSGallery policy."
    Assert-Equal 0 $script:ImportedModules.Count "A module that failed to install must not be reported as imported."

    # =========================================================================================
    # 3. A scan failure is not the same thing as "no updates".
    # =========================================================================================
    # A catch that swallowed the scan error and fell through to the empty-set branch would report
    # a fully patched machine to an operator whose machine was never scanned.
    Reset-UpdateState -Scans @('THROW')
    $script:ScanQueue.Add('THROW') | Out-Null
    $message = Assert-Throws { Invoke-WindowsUpdatePass -PassNumber 1 } 'scan failed on pass 1' `
        "A scan that throws must fail the pass."
    Assert-True ($message -match 'Access denied') "The pass failure must carry the underlying scan error."
    Assert-True ((Get-LogText) -notmatch 'no applicable updates') "A failed scan must never be reported as 'no applicable updates'."
    Assert-Equal 0 $script:StartJobCalls "A failed scan must not proceed to an install job."

    # =========================================================================================
    # 4. Zero updates is a clean success.
    # =========================================================================================
    Reset-UpdateState
    $script:ScanQueue.Add(@()) | Out-Null
    Assert-Equal 0 (Invoke-WindowsUpdatePass -PassNumber 1) "A pass with nothing to install must return zero."
    Assert-True ((Get-LogText) -match 'OK Pass 1: no applicable updates') "Zero updates must be reported as a clean pass."
    Assert-Equal 0 $script:StartJobCalls "Zero updates must not start an install job."

    # =========================================================================================
    # 5. The install poll loop re-reads job state and sleeps between polls.
    # =========================================================================================
    # See the DOCUMENTED GAP at the top of this file: the timeout trip itself needs 60 s of real
    # wall time and is not exercised. What is exercised is the loop that leads to it - a version
    # that trusted the stale $wuJob object would never leave this loop.
    Reset-UpdateState
    $script:ScanQueue.Add($oneUpdate) | Out-Null
    $script:JobState = 'Running'
    foreach ($state in @('Running', 'Running', 'Completed')) { $script:JobStateQueue.Add($state) | Out-Null }
    $script:JobOutput = @([pscustomobject]@{ Title = 'KB5000001'; Result = 'Installed' })
    Assert-Equal 1 (Invoke-WindowsUpdatePass -PassNumber 1) "A pass that installs its detected update must return the detected count."
    Assert-Equal 3 $script:GetJobCalls "Every poll must re-read the job state instead of reusing the stale job object."
    Assert-Equal 3 $script:SleepCalls "The poll loop must sleep between polls rather than spinning."
    Assert-True ($script:StatusWrites -ge 3) "Each poll must refresh the in-place progress line."
    Assert-Equal 1 $script:StatusClears "The in-place progress line must be cleared once the job finishes."
    Assert-Equal 1 $script:RemoveJobCalls "The finished job must be removed so it does not leak into the session."
    Assert-Equal 0 $script:StopJobCalls "A job that completed on its own must not be stopped."

    # =========================================================================================
    # 6. Per-update results are inspected; a partial batch is not reported as installed.
    # =========================================================================================
    # ---- 6a. Every result successful -> success. ----
    Reset-UpdateState
    $script:ScanQueue.Add($oneUpdate) | Out-Null
    $script:JobOutput = @(
        [pscustomobject]@{ Title = 'KB5000001'; Result = 'Installed' }
        [pscustomobject]@{ Title = 'KB5000002'; Result = 'Downloaded' }
    )
    Assert-Equal 1 (Invoke-WindowsUpdatePass -PassNumber 2) "A pass whose results all succeeded must return the detected count."
    Assert-True ((Get-LogText) -match 'install command completed') "A fully successful install must be reported as completed."

    # ---- 6b. One failed result -> the pass fails. The job itself reports Completed here: the
    #          only evidence that something went wrong is inside the per-update results, which is
    #          exactly what the `ResultCode|Result` grep could not check. ----
    Reset-UpdateState
    $script:ScanQueue.Add($oneUpdate) | Out-Null
    $script:JobOutput = @(
        [pscustomobject]@{ Title = 'KB5000001'; Result = 'Installed' }
        [pscustomobject]@{ Title = 'KB5000002'; Result = 'Failed' }
    )
    $null = Assert-Throws { Invoke-WindowsUpdatePass -PassNumber 2 } '1 Windows Update result\(s\) did not report success' `
        "A failed per-update result must fail the pass even though the job state is Completed."
    Assert-True ((Get-LogText) -notmatch 'install command completed') "A batch containing a failure must not be reported as completed."
    Assert-Equal 1 $script:RemoveJobCalls "The job must still be cleaned up when the pass fails."

    # ---- 6c. ResultCode is the other shape PSWindowsUpdate emits. ----
    Reset-UpdateState
    $script:ScanQueue.Add($oneUpdate) | Out-Null
    $script:JobOutput = @([pscustomobject]@{ Title = 'KB5000003'; ResultCode = 'FailedInstall' })
    $null = Assert-Throws { Invoke-WindowsUpdatePass -PassNumber 1 } 'did not report success' `
        "A failing ResultCode must be treated the same as a failing Result."

    # ---- 6d. A job that ends in a non-Completed state fails the pass. ----
    Reset-UpdateState
    $script:ScanQueue.Add($oneUpdate) | Out-Null
    $script:JobState = 'Failed'
    $null = Assert-Throws { Invoke-WindowsUpdatePass -PassNumber 1 } 'install job failed with state Failed' `
        "A job that did not complete must fail the pass."

    # ---- 6e. Errors written by the job fail the pass even when its state is Completed. ----
    Reset-UpdateState
    $script:ScanQueue.Add($oneUpdate) | Out-Null
    $script:JobErrorText = 'HRESULT 0x80240034'
    $null = Assert-Throws { Invoke-WindowsUpdatePass -PassNumber 1 } 'install job failed' `
        "Errors emitted by the install job must fail the pass."

    # ---- 6f. A reboot signal is recorded rather than acted on. ----
    Reset-UpdateState
    $script:ScanQueue.Add($oneUpdate) | Out-Null
    $script:JobOutput = @([pscustomobject]@{ Title = 'KB5000001'; Result = 'Installed' })
    $script:RebootRequired = $true
    Assert-Equal 1 (Invoke-WindowsUpdatePass -PassNumber 1) "A pending reboot must not fail the pass."
    Assert-True ($null -ne $script:PendingReboot) "A reboot-required signal must be flagged for the run summary."

    # =========================================================================================
    # 7. Invoke-SystemUpdate: the final success claim requires a successful final scan.
    # =========================================================================================
    # ---- 7a. Converged: pass 1 finds nothing, final scan finds nothing. ----
    Reset-UpdateState
    $script:AvailableModules = @('PSWindowsUpdate')
    $script:ScanQueue.Add(@()) | Out-Null
    $script:ScanQueue.Add(@()) | Out-Null
    Invoke-SystemUpdate
    Assert-True ((Get-LogText) -match 'All applicable Windows Updates installed') "A converged run must report success."
    Assert-Equal 2 $script:ScanCalls "A converged run must scan once per pass plus once to verify."

    # ---- 7b. THE FINAL SCAN FAILING MUST NOT PRODUCE A SUCCESS CLAIM. ----
    Reset-UpdateState
    $script:ScanQueue.Add(@()) | Out-Null
    $script:ScanQueue.Add('THROW') | Out-Null
    $null = Assert-Throws { Invoke-SystemUpdate } 'Final Windows Update verification scan failed' `
        "A final verification scan that throws must fail the step."
    Assert-True ((Get-LogText) -notmatch 'All applicable Windows Updates installed') `
        "An unverified machine must never be reported as fully updated."

    # ---- 7c. Updates still pending after the last pass are surfaced, not glossed over. ----
    Reset-UpdateState
    $Global:Config = New-UpdateConfig -MaxPasses 1
    $script:ScanQueue.Add($oneUpdate) | Out-Null
    $script:JobOutput = @([pscustomobject]@{ Title = 'KB5000001'; Result = 'Installed' })
    $script:ScanQueue.Add(@([pscustomobject]@{ Title = 'KB5000009 Still Pending' })) | Out-Null
    Invoke-SystemUpdate
    $pendingLog = Get-LogText
    Assert-True ($pendingLog -match 'still pending after 1 passes') "Remaining updates must be reported."
    Assert-True ($pendingLog -match 'KB5000009') "Each remaining update must be named."
    Assert-True ($pendingLog -notmatch 'All applicable Windows Updates installed') `
        "A machine with pending updates must not be reported as fully updated."

    # ---- 7d. Disabled / module-disabled paths never scan. ----
    Reset-UpdateState
    $Global:Config = New-UpdateConfig -Enabled $false
    Invoke-SystemUpdate
    Assert-Equal 0 $script:ScanCalls "A disabled Windows Update section must not scan."
    Assert-Equal 'disabled in config' $script:SkipReason "A disabled section must record why it was skipped."

    Reset-UpdateState
    $Global:Config = New-UpdateConfig -UseModule $false
    Invoke-SystemUpdate
    Assert-Equal 0 $script:ScanCalls "With PSWindowsUpdate disabled the script must not scan itself."
    Assert-Equal 'ms-settings:windowsupdate' ($script:StartProcessTargets -join ',') "With PSWindowsUpdate disabled the operator must be sent to the Settings page."

    # ---- Nothing in this suite may have reached a real install. ----
    Assert-Equal 0 $script:RealInstallAttempts "No test may invoke the real Install-WindowsUpdate."

    # =========================================================================================
    # The wall-clock timeout actually trips, stops the job, and reports the budget it exceeded.
    # =========================================================================================
    # This used to be the file's DOCUMENTED GAP. Config validates jobTimeoutMinutes as whole
    # minutes with a 1-minute floor, so reaching this branch through Invoke-WindowsUpdatePass
    # costs 60 s of real Stopwatch time. The bounded poll is now its own function taking a
    # [double] budget, so the trip is exercised directly in milliseconds. The 1-minute floor is
    # unchanged and still applied by the caller - only the test budget is sub-minute.
    Reset-UpdateState
    $script:JobState = 'Running'
    $stuckJob = [pscustomobject]@{ Id = 4242; State = 'Running' }
    $timedOut = $null
    # Budget 0, not a small non-zero one. Start-Sleep is stubbed here, so a sub-millisecond
    # budget races the stub's own 25-call ceiling and the winner differs per host - it did, and
    # 5.1 hit the ceiling first. Elapsed time is always greater than zero at the first check, so
    # a zero budget reaches this branch deterministically on both hosts. Production cannot pass
    # zero: config validates jobTimeoutMinutes as int 1..1440 and the call site floors it at 1,
    # which the retained source assertion below covers.
    $timeoutClock = [Diagnostics.Stopwatch]::StartNew()
    try { Wait-WindowsUpdateJob -Job $stuckJob -TimeoutMinutes 0 -PassNumber 2 | Out-Null } catch { $timedOut = $_.Exception.Message }
    $timeoutClock.Stop()
    Assert-True ($null -ne $timedOut) `
        "A Windows Update job that never leaves Running must trip its wall-clock budget - without it, one stuck job blocks the whole update step indefinitely."
    Assert-True ($timedOut -match 'timed out after') `
        ("The timeout must say it timed out and name the budget it exceeded. Got: {0}" -f $timedOut)
    Assert-True ($script:StopJobCalls -ge 1) `
        "The job must be STOPPED on timeout, not merely abandoned - an orphaned PSWindowsUpdate job keeps installing after the step reported failure."
    Assert-True ($timeoutClock.Elapsed.TotalSeconds -lt 20) `
        ("The timeout trip must be governed by the budget passed in. Took {0:n1}s." -f $timeoutClock.Elapsed.TotalSeconds)

    # A job that finishes must be returned in its FINAL state, not the stale object handed in.
    Reset-UpdateState
    foreach ($state in @('Running', 'Completed')) { $script:JobStateQueue.Add($state) | Out-Null }
    $finishedJob = Wait-WindowsUpdateJob -Job ([pscustomobject]@{ Id = 4243; State = 'Running' }) -TimeoutMinutes 120 -PassNumber 1
    Assert-Equal 'Completed' ([string]$finishedJob.State) `
        "The poll must return the re-read job; returning the stale input object would make the caller's state check inspect a job that was still Running."

    # ---- One retained source assertion: the behavioural cases above call Wait-WindowsUpdateJob
    #      with a budget of their own, so they cannot prove that PRODUCTION still passes a finite
    #      one from config rather than polling forever. The old `ResultCode|Result` grep is
    #      deliberately NOT retained - it matched unconditionally and therefore asserted nothing. ----
    Assert-True ($source -match 'Wait-WindowsUpdateJob[\s\S]{0,120}-TimeoutMinutes \$WindowsUpdateJobTimeoutMinutes') `
        "The install pass must still pass its configured finite budget to the bounded poll."

    Assert-True ($suiteClock.Elapsed.TotalSeconds -lt 30) ("This suite must stay fast; it took {0:n1}s." -f $suiteClock.Elapsed.TotalSeconds)
    Write-Host ("PASS Windows Update restores PSGallery policy through the finally on both paths, installs the module only under temporary trust, treats a failed scan as a failure rather than 'no updates', inspects per-update results, refuses to claim a fully updated machine without a successful final scan, and trips its wall-clock budget on a stuck job - stopping it rather than abandoning it ({0:n1}s)." -f $suiteClock.Elapsed.TotalSeconds)
} finally {
    $Global:Config = $previousConfig
}
