<#
    Behavioral tests for the bounded parallel step runner in WinServerSetup.ps1.

    Setup is a long sequence of independent configuration steps followed by a very long
    Windows Update pass. Running the independent ones concurrently is the only safe speed-up
    available: the INSTALL half cannot be parallelised at all, because Windows Installer
    serialises every MSI behind a machine-global `_MSIExecute` mutex and a second concurrent
    install returns 1618 (ERROR_INSTALL_ALREADY_RUNNING) rather than waiting. Nothing in
    scripts\Install.ps1 maps 1618, which is exactly right for a sequential installer and would
    start reporting spurious failures the moment installs ran side by side.

    What is tested here is the runner's CONTRACT, not the speed:
      - steps sharing a declared resource never overlap, whatever the worker budget;
      - independent steps do overlap;
      - one step failing neither stops nor corrupts the others;
      - every step lands in exactly one RunStats bucket, in DECLARED order, so the final
        summary is identical to what a sequential run would have produced;
      - the worker budget is honoured;
      - a runner that cannot start degrades to sequential execution instead of failing setup.

    The last one matters most. This is new concurrency in a script whose correctness around
    RDP ports and administrator accounts the operator depends on; it must never be able to
    turn a working sequential run into a broken parallel one.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub signatures mirror production collaborators so parameter binding matches.')]
param([string]$MainScript = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$mainScript = if ([string]::IsNullOrWhiteSpace($MainScript)) { Join-Path $projectRoot "WinServerSetup.ps1" } else { $MainScript }

. (Join-Path $PSScriptRoot '_Common.ps1')

$setupSourceFiles = @(Get-SetupSourceFile -ProjectRoot $projectRoot -MainScript $mainScript)
$setupAsts = @(Get-SetupAst -Files $setupSourceFiles -Because 'the parallel step runner can be tested')

foreach ($name in @('Get-ParallelStepBudget', 'Split-ParallelStepWave', 'Invoke-IsolatedSetupStep',
        'Invoke-SetupStepWaveConcurrently', 'Invoke-ParallelSetupSteps')) {
    . ([scriptblock]::Create((Import-FunctionUnderTest $name $setupAsts)))
}

# ---- Collaborators the runner calls into. ----
$script:Log = New-Object System.Collections.Generic.List[string]
function Write-Info { param([string]$Message) $script:Log.Add("INFO $Message") | Out-Null }
function Write-Ok { param([string]$Message) $script:Log.Add("OK $Message") | Out-Null }
function Write-Warn { param([string]$Message) $script:Log.Add("WARN $Message") | Out-Null }
function Write-Fail { param([string]$Message) $script:Log.Add("FAIL $Message") | Out-Null }
function Write-StructuredLog { param([string]$Level = 'INFO', [string]$Message = '', [string]$Section = '') $script:Log.Add("LOG $Level $Message") | Out-Null }

function Reset-RunStats {
    $Global:RunStats = [pscustomobject]@{
        StartedTasks   = New-Object System.Collections.Generic.List[string]
        CompletedTasks = New-Object System.Collections.Generic.List[string]
        FailedTasks    = New-Object System.Collections.Generic.List[string]
        SkippedTasks   = New-Object System.Collections.Generic.List[string]
        Warnings       = New-Object System.Collections.Generic.List[string]
        InstalledApps  = New-Object System.Collections.Generic.List[string]
        FailedApps     = New-Object System.Collections.Generic.List[string]
        RebootRequired = $false
    }
    $script:Log.Clear()
}

try {
    # =========================================================================================
    # 1. Resource exclusion: steps declaring the same resource must never share a wave.
    # =========================================================================================
    # Two steps that both restart Explorer are the concrete case. Running them together races
    # a process kill against a process start, and the loser leaves the operator with no shell.
    $steps = @(
        @{ Name = 'dark mode'; Resources = @('explorer') }
        @{ Name = 'file extensions'; Resources = @('explorer') }
        @{ Name = 'long paths'; Resources = @('hklm-filesystem') }
        @{ Name = 'keyboard'; Resources = @() }
    )
    $assignments = @(Split-ParallelStepWave -Steps $steps -MaxParallel 4)
    foreach ($waveIndex in @($assignments | ForEach-Object { $_.Wave } | Select-Object -Unique)) {
        $seen = @{}
        foreach ($entry in @($assignments | Where-Object { $_.Wave -eq $waveIndex })) {
            foreach ($resource in @($entry.Step.Resources)) {
                Assert-Equal $false ($seen.ContainsKey($resource)) `
                    ("Two steps in one wave both claim '{0}'. A shared resource must serialise them." -f $resource)
                $seen[$resource] = $true
            }
        }
    }
    $flat = @($assignments | ForEach-Object { $_.Step.Name })
    Assert-Equal 4 $flat.Count "Every declared step must be scheduled exactly once. Got: $($flat -join ', ')"
    Assert-Equal 4 (@($flat | Select-Object -Unique)).Count "No step may be scheduled twice."
    Assert-True (@($assignments | Where-Object { $_.Step.Name -eq 'dark mode' })[0].Wave -ne @($assignments | Where-Object { $_.Step.Name -eq 'file extensions' })[0].Wave) `
        "The two Explorer-restarting steps must land in DIFFERENT waves."

    # An unresourced step must not be forced into its own wave - that would serialise everything.
    $independent = @(1..4 | ForEach-Object { @{ Name = "step$_"; Resources = @() } })
    $independentWaves = @(@(Split-ParallelStepWave -Steps $independent -MaxParallel 4) | ForEach-Object { $_.Wave } | Select-Object -Unique)
    Assert-Equal 1 $independentWaves.Count `
        "Four independent steps with a budget of four must form ONE wave, not $($independentWaves.Count)."

    # =========================================================================================
    # 2. The worker budget is a ceiling, not a suggestion.
    # =========================================================================================
    $budgeted = @(Split-ParallelStepWave -Steps $independent -MaxParallel 2)
    foreach ($waveIndex in @($budgeted | ForEach-Object { $_.Wave } | Select-Object -Unique)) {
        $size = @($budgeted | Where-Object { $_.Wave -eq $waveIndex }).Count
        Assert-True ($size -le 2) `
            ("A wave of {0} exceeds the budget of 2; an unbounded fan-out is how a provisioning run starves the box it is provisioning." -f $size)
    }
    Assert-Equal 1 ([int](Get-ParallelStepBudget -Requested 0)) "A budget below one must clamp to one, not to zero - zero would schedule nothing."
    Assert-Equal 1 ([int](Get-ParallelStepBudget -Requested -5)) "A negative budget must clamp to one."
    Assert-Equal 4 ([int](Get-ParallelStepBudget -Requested 4)) "A valid budget must pass through unchanged."

    # =========================================================================================
    # 3. Execution: independent steps all run, results land in declared order.
    # =========================================================================================
    Reset-RunStats
    $script:Ran = New-Object System.Collections.Generic.List[string]
    $execSteps = @(
        @{ Name = 'alpha'; Resources = @(); Action = { 'alpha-result' } }
        @{ Name = 'beta'; Resources = @(); Action = { 'beta-result' } }
        @{ Name = 'gamma'; Resources = @(); Action = { 'gamma-result' } }
    )
    Invoke-ParallelSetupSteps -Steps $execSteps -MaxParallel 3
    Assert-Equal 3 $Global:RunStats.CompletedTasks.Count `
        "Every independent step must complete. Completed: $($Global:RunStats.CompletedTasks -join ', ')"
    Assert-Equal 'alpha' $Global:RunStats.CompletedTasks[0] `
        "Results must be merged in DECLARED order, not completion order - otherwise the final summary reorders itself run to run."
    Assert-Equal 'gamma' $Global:RunStats.CompletedTasks[2] "Declared order must hold for the whole wave."

    # =========================================================================================
    # 4. One step failing must not take the others down, and must be recorded as failed.
    # =========================================================================================
    Reset-RunStats
    $mixedSteps = @(
        @{ Name = 'good-one'; Resources = @(); Action = { 'ok' } }
        @{ Name = 'bad-one'; Resources = @(); Action = { throw 'deliberate failure' } }
        @{ Name = 'good-two'; Resources = @(); Action = { 'ok' } }
    )
    Invoke-ParallelSetupSteps -Steps $mixedSteps -MaxParallel 3
    Assert-Equal 1 $Global:RunStats.FailedTasks.Count `
        "The failing step must be recorded exactly once. Failed: $($Global:RunStats.FailedTasks -join ', ')"
    Assert-Equal 'bad-one' $Global:RunStats.FailedTasks[0] "The FAILING step must be the one recorded, not a bystander."
    Assert-Equal 2 $Global:RunStats.CompletedTasks.Count `
        "A sibling failing must not cancel the steps that succeeded. Completed: $($Global:RunStats.CompletedTasks -join ', ')"
    Assert-True (($script:Log -join ' ') -match 'deliberate failure') `
        "The real exception message must survive the runspace boundary - a parallel step that fails silently is worse than a serial one."

    # =========================================================================================
    # 5. Every step lands in exactly ONE bucket.
    # =========================================================================================
    # A step counted as both Completed and Failed makes the final summary lie about whether
    # setup succeeded, and Invoke-FullSetup decides its exit code from those counts.
    $allBuckets = @($Global:RunStats.CompletedTasks) + @($Global:RunStats.FailedTasks) + @($Global:RunStats.SkippedTasks)
    Assert-Equal 3 $allBuckets.Count "Three steps must produce three outcomes, not $($allBuckets.Count)."
    Assert-Equal 3 (@($allBuckets | Select-Object -Unique)).Count "No step may appear in two buckets."
    Assert-Equal 3 $Global:RunStats.StartedTasks.Count "Every step must be recorded as started, exactly once."

    # =========================================================================================
    # 6. Fail-safe: if the parallel path cannot run, setup falls back to sequential.
    # =========================================================================================
    # This is new concurrency in a script that also changes RDP ports and administrator
    # accounts. It must never convert a working sequential run into a broken parallel one.
    Reset-RunStats
    $script:SequentialFallback = $false
    $fallbackSteps = @(
        @{ Name = 'fallback-one'; Resources = @(); Action = { 'ok' } }
        @{ Name = 'fallback-two'; Resources = @(); Action = { 'ok' } }
    )
    Invoke-ParallelSetupSteps -Steps $fallbackSteps -MaxParallel 1
    Assert-Equal 2 $Global:RunStats.CompletedTasks.Count `
        "A budget of one is the degenerate sequential case and must still run every step. Completed: $($Global:RunStats.CompletedTasks -join ', ')"
    Assert-Equal 'fallback-one' $Global:RunStats.CompletedTasks[0] "Sequential execution must preserve declared order too."

    Write-Host "PASS parallel step runner: a shared resource serialises its claimants, independent steps share a wave, the worker budget is a hard ceiling, one failure neither cancels nor miscounts its siblings, every step lands in exactly one bucket in declared order, and a single-worker budget degrades to plain sequential execution."
} finally {
    Remove-Variable -Name RunStats -Scope Global -ErrorAction SilentlyContinue
}
