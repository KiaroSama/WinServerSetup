<#
    Behavioral tests for scripts\Run-PostRebootSfc.ps1 - the task that must survive a failed scan.

    This file used to be eight regex matches against source text. The contract that actually
    matters here is negative: after every attempt fails, the scheduled task must STILL BE
    REGISTERED so the next boot retries it. A grep for "if ($succeeded) ... Unregister-ScheduledTask"
    stays green if someone moves the unregister into a finally block - which is precisely the
    change that would silently disarm the retry.

    Run-PostRebootSfc.ps1 has no dot-source guard: it runs its retry loop at file scope and ends in
    `exit 0` / `exit 1`. That is what we want to test, so each case runs it for real inside a small
    generated harness in a CHILD PROCESS of this host. The harness shadows Start-Process (so sfc
    never runs) and Unregister-ScheduledTask (so no real task is touched), then dot-sources the
    script. The child's exit code is the assertion.
#>
# -SfcScript targets an alternate copy so these tests can be replayed against a deliberately
# defective build to prove they still fail. CI and local runs use the default.
param([string]$SfcScript = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
# WinServerSetup.ps1 dot-sources its function library from scripts\; the source assertions
# below cover that whole partition.
$main = (@('WinServerSetup.ps1') + @('Console', 'Core', 'Download', 'Rdp', 'Install', 'SystemSettings', 'Maintenance' |
        ForEach-Object { "scripts\{0}.ps1" -f $_ }) |
    ForEach-Object { Join-Path $projectRoot $_ } |
    Where-Object { Test-Path -LiteralPath $_ } |
    ForEach-Object { Get-Content -LiteralPath $_ -Raw -Encoding UTF8 }) -join "`r`n"
$sfcScript = if ([string]::IsNullOrWhiteSpace($SfcScript)) { Join-Path $projectRoot "scripts\Run-PostRebootSfc.ps1" } else { $SfcScript }
$sfc = Get-Content -LiteralPath $sfcScript -Raw -Encoding UTF8

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw ("{0} Expected={1}; Actual={2}" -f $Message, $Expected, $Actual) }
}

# The script under test must still be a bounded, retryable, self-unregistering contract before any
# of the behavioral cases below mean anything.
Assert-True ($sfc -match '\[int\]\$MaxAttempts') "Post-reboot SFC needs a bounded retry contract."
Assert-True ($sfc -match '\[int\]\$RetryDelaySeconds') "Post-reboot SFC retries need an explicit delay."

$hostExe = (Get-Process -Id $PID).Path
Assert-True (-not [string]::IsNullOrWhiteSpace($hostExe)) "Unable to resolve the current PowerShell host executable."

$testRoot = Join-Path $env:TEMP ("WinServerSetup-Sfc-{0}" -f ([guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

# The harness is deliberately a separate file: Run-PostRebootSfc.ps1 calls `exit`, which would take
# this test process down with it. Everything Windows-touching is shadowed before the dot-source.
# Two traps this harness had to be built around, both verified on 5.1 and 7:
#
#   * `exit N` inside a script that is dot-sourced or invoked with & does NOT become the host
#     process exit code - the outer script simply carries on and exits 0. It DOES set
#     $LASTEXITCODE, so the harness re-raises it explicitly. Without that, every exit-code
#     assertion below would read 0 and pass for the wrong reason.
#   * PowerShell variable names are case-insensitive, so dot-sourcing put a plain $Attempt counter
#     here in the same slot as the script's `for ($attempt = 1; ...)` loop index and silently
#     truncated the retry loop. The call operator gives the script its own scope (mock FUNCTIONS
#     are still inherited), and every harness variable additionally carries a Mock prefix.
$harnessBody = @'
param(
    [string]$MockScriptPath,
    [string]$MockRoot,
    [string]$MockEvidencePath,
    [string]$MockExitCodeList,
    [string]$MockMaxAttempts,
    [string]$MockRetryDelaySeconds,
    [string]$MockUnregisterFails = "0"
)

$ErrorActionPreference = "Stop"
$MockCodes = @([int[]]($MockExitCodeList -split ',' | ForEach-Object { [int]$_ }))
$MockCallCount = 0

function Write-Evidence { param([string]$Line) Add-Content -LiteralPath $MockEvidencePath -Value $Line -Encoding UTF8 }

# sfc /scannow is never executed. The harness returns the scripted exit code for each attempt.
function Start-Process {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [switch]$PassThru,
        [switch]$Wait,
        [string]$WindowStyle,
        [string]$RedirectStandardOutput,
        [string]$RedirectStandardError
    )
    $script:MockCallCount++
    Write-Evidence ("ATTEMPT {0} {1} {2}" -f $script:MockCallCount, $FilePath, ($ArgumentList -join ' '))
    $index = [Math]::Min($script:MockCallCount, $MockCodes.Count) - 1
    return [pscustomobject]@{ ExitCode = $MockCodes[$index] }
}

function Unregister-ScheduledTask {
    param([string]$TaskName, [switch]$Confirm, $ErrorAction)
    Write-Evidence ("UNREGISTER {0}" -f $TaskName)
    if ($MockUnregisterFails -eq "1") { throw "Access is denied." }
}

& $MockScriptPath -ProjectRoot $MockRoot -TaskName 'WinServerSetup Post-Reboot SFC (test)' -MaxAttempts ([int]$MockMaxAttempts) -RetryDelaySeconds ([int]$MockRetryDelaySeconds)
exit ([int]$LASTEXITCODE)
'@

try {
    $harness = Join-Path $testRoot 'harness.ps1'
    Set-Content -LiteralPath $harness -Value $harnessBody -Encoding UTF8

    $runRoot = Join-Path $testRoot 'project'
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null

    $script:RunIndex = 0
    function Invoke-SfcRun {
        param([string]$ExitCodeList, [int]$MaxAttempts = 3, [int]$RetryDelaySeconds = 1, [switch]$UnregisterFails)
        $script:RunIndex++
        $evidence = Join-Path $testRoot ("evidence-{0}.txt" -f $script:RunIndex)
        Set-Content -LiteralPath $evidence -Value @() -Encoding UTF8
        $stdout = Join-Path $testRoot ("stdout-{0}.txt" -f $script:RunIndex)
        $stderr = Join-Path $testRoot ("stderr-{0}.txt" -f $script:RunIndex)

        $arguments = @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f $harness),
            '-MockScriptPath', ('"{0}"' -f $sfcScript),
            '-MockRoot', ('"{0}"' -f $runRoot),
            '-MockEvidencePath', ('"{0}"' -f $evidence),
            '-MockExitCodeList', $ExitCodeList,
            '-MockMaxAttempts', "$MaxAttempts",
            '-MockRetryDelaySeconds', "$RetryDelaySeconds",
            '-MockUnregisterFails', $(if ($UnregisterFails) { '1' } else { '0' })
        )
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $process = Start-Process -FilePath $hostExe -ArgumentList $arguments -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        # Touch the handle so ExitCode stays readable after exit (needed on 5.1).
        $null = $process.Handle
        if (-not $process.WaitForExit(60000)) {
            try { & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null } catch { $null = $_ }
            throw "The post-reboot SFC harness did not finish within 60 s; the retry loop is not bounded."
        }
        $process.WaitForExit()
        $stopwatch.Stop()
        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Evidence = @(Get-Content -LiteralPath $evidence -ErrorAction SilentlyContinue)
            Stderr   = (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue)
            Seconds  = $stopwatch.Elapsed.TotalSeconds
        }
    }

    function Get-SfcLogText {
        param([int]$Index = -1)
        $logs = @(Get-ChildItem -LiteralPath (Join-Path $runRoot 'logs') -Filter 'Run-PostRebootSfc_*.log' -File | Sort-Object CreationTime, Name)
        if ($logs.Count -eq 0) { return "" }
        $target = if ($Index -lt 0) { $logs[-1] } else { $logs[$Index] }
        return (Get-Content -LiteralPath $target.FullName -Raw -Encoding UTF8)
    }

    # ---- 1. First attempt succeeds: unregister exactly once, exit 0. ----
    $run = Invoke-SfcRun -ExitCodeList '0' -MaxAttempts 3
    Assert-Equal 0 $run.ExitCode ("A successful SFC scan must exit 0. stderr: {0}" -f $run.Stderr)
    Assert-Equal 1 (@($run.Evidence | Where-Object { $_ -like 'ATTEMPT*' }).Count) "A scan that succeeds first time must not retry."
    Assert-Equal 1 (@($run.Evidence | Where-Object { $_ -like 'UNREGISTER*' }).Count) `
        "A successful scan must unregister the startup task exactly once."
    Assert-True ((Get-SfcLogText) -match 'SFC scan completed successfully') "A successful run must say so in its log."

    # ---- 2. THE CRITICAL CASE. Every attempt fails, so the task must SURVIVE for the next boot.
    #         Any unregister here disarms the retry silently. ----
    $run = Invoke-SfcRun -ExitCodeList '1,1' -MaxAttempts 2 -RetryDelaySeconds 1
    Assert-Equal 1 $run.ExitCode "Exhausted SFC retries must exit nonzero so the caller can see the failure."
    Assert-Equal 2 (@($run.Evidence | Where-Object { $_ -like 'ATTEMPT*' }).Count) "-MaxAttempts 2 must produce exactly two attempts."
    Assert-Equal 0 (@($run.Evidence | Where-Object { $_ -like 'UNREGISTER*' }).Count) `
        "A run where every attempt failed must NEVER unregister the task; the next boot has to retry it."
    Assert-True ((Get-SfcLogText) -match 'remains registered') "The log must state that the task remains registered for a later startup."

    # ---- 4. ... and that failing run is bounded. With -RetryDelaySeconds 1 the whole thing is a
    #         few seconds; with the 60 s default it would be minutes. ----
    Assert-True ($run.Seconds -lt 10) `
        ("An exhausted retry run must honour -RetryDelaySeconds instead of the 60 s default. Took {0}s." -f [math]::Round($run.Seconds, 1))
    Assert-True ((Get-SfcLogText) -match 'Retrying after 1 seconds') "The configured retry delay must be the one actually applied."

    # ---- 3. Failure then success inside MaxAttempts: retried, then unregistered once, exit 0. ----
    $run = Invoke-SfcRun -ExitCodeList '1,0' -MaxAttempts 3 -RetryDelaySeconds 1
    Assert-Equal 0 $run.ExitCode ("A scan that succeeds on retry must exit 0. stderr: {0}" -f $run.Stderr)
    Assert-Equal 2 (@($run.Evidence | Where-Object { $_ -like 'ATTEMPT*' }).Count) "A recovered run must stop attempting once SFC succeeds."
    Assert-Equal 1 (@($run.Evidence | Where-Object { $_ -like 'UNREGISTER*' }).Count) "A recovered run must unregister the task exactly once."

    # ---- 6. A successful scan whose unregister is refused must still report success. The scan is
    #         what the task exists to do; a leftover task retries harmlessly next boot. ----
    $run = Invoke-SfcRun -ExitCodeList '0' -MaxAttempts 3 -UnregisterFails
    Assert-Equal 0 $run.ExitCode "A successful scan must not be reported as failed just because unregistering was refused."
    Assert-True ((Get-SfcLogText) -match 'task unregister failed') "A refused unregister must be recorded, not swallowed silently."

    # ---- 5. Every execution keeps its own log. Overwriting one file would destroy the history of
    #         the exact failures this task exists to diagnose. ----
    $logs = @(Get-ChildItem -LiteralPath (Join-Path $runRoot 'logs') -Filter 'Run-PostRebootSfc_*.log' -File)
    Assert-Equal $script:RunIndex $logs.Count `
        ("Each execution must preserve its own UTC-stamped log. Runs={0}; logs={1}" -f $script:RunIndex, $logs.Count)
    Assert-Equal $logs.Count (@($logs | Select-Object -ExpandProperty Name -Unique).Count) "Log names must be unique even within the same second."
    foreach ($log in $logs) {
        Assert-True ($log.Name -match '^Run-PostRebootSfc_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_UTC(-\d+)?\.log$') `
            ("Log file names must be UTC-timestamped: {0}" -f $log.Name)
    }
    Assert-True ((Get-SfcLogText -Index 0) -match '\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC\] \[') "Log entries must carry a UTC timestamp and a level."

    # ---- Retained source greps: cheap smoke checks over the registration side in the main script,
    #      which registers real scheduled tasks and is therefore not executed here. ----
    Assert-True ($main -notmatch 'RepetitionDuration\s+\(New-TimeSpan -Days 3650\)') "RDP blocker task must not expire after ten years."
    Assert-True ($main -match 'Running blocker verification failed with exit code') "Scheduled blocker installation must fail if its verification run fails."
    Assert-True ($sfc -match 'while \(Test-Path -LiteralPath \$path\)') "Colliding log names must be resolved rather than overwritten."

    Write-Host "PASS post-reboot SFC really runs: it retries within its bounded delay, unregisters the startup task only after a successful scan, keeps the task registered when every attempt fails, and writes one UTC log per execution."
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
