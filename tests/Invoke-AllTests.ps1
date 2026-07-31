<#
.SYNOPSIS
    Discovers and runs every tests\*.Tests.ps1 file in the current PowerShell host.

.DESCRIPTION
    Each test file runs in its own child process of the *current* host, so the same
    command validates Windows PowerShell 5.1 and PowerShell 7 simply by being invoked
    from each host. Suites are discovered from disk rather than hardcoded, so a newly
    added test file can never be silently skipped by CI.

    Every child gets a bounded wall timeout; a child that exceeds it is killed together
    with its process tree and reported as TIMEOUT (never as success).

.PARAMETER TimeoutSeconds
    Per-test wall timeout. A test that exceeds it fails the run.

.PARAMETER Filter
    Optional wildcard filter on the test file name, e.g. 'Rdp*'.
#>
[CmdletBinding()]
param(
    [ValidateRange(10, 1800)][int]$TimeoutSeconds = 180,
    [string]$Filter = '*.Tests.ps1'
)

$ErrorActionPreference = 'Stop'
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent $testRoot

# Re-invoke the host this script is already running under, so the caller picks 5.1 vs 7.
$hostExe = (Get-Process -Id $PID).Path
if ([string]::IsNullOrWhiteSpace($hostExe)) { throw "Unable to resolve the current PowerShell host executable." }

$suites = @(Get-ChildItem -LiteralPath $testRoot -Filter $Filter -File | Sort-Object Name)
if ($suites.Count -eq 0) { throw "No test suites discovered under $testRoot (filter: $Filter)." }

$results = New-Object System.Collections.Generic.List[object]
foreach ($suite in $suites) {
    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = $null
    try {
        $process = Start-Process -FilePath $hostExe `
            -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $suite.FullName)) `
            -WorkingDirectory $projectRoot -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

        # Touch the handle so the process object caches it. Without this, Start-Process -PassThru
        # can report an unreliable ExitCode once the process has already exited (seen on 5.1).
        $null = $process.Handle

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            # Kill the whole owned tree so a hung child cannot outlive the run.
            & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null
            $stopwatch.Stop()
            $results.Add([pscustomobject]@{
                Suite   = $suite.Name
                Result  = 'TIMEOUT'
                Code    = 'n/a'
                Seconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
                Detail  = "exceeded ${TimeoutSeconds}s wall timeout"
            })
            continue
        }
        # The bounded WaitForExit(ms) overload can leave ExitCode unpopulated on Windows
        # PowerShell 5.1; the parameterless call returns immediately here and settles it.
        $process.WaitForExit()
        $stopwatch.Stop()

        $stdout = Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
        $exitCode = if ($null -eq $process.ExitCode) { -1 } else { [int]$process.ExitCode }

        if ($exitCode -eq 0) {
            $detail = @($stdout -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
        } else {
            $combined = @($stderr, $stdout) -join "`n"
            $detail = @($combined -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -First 4) -join ' | '
        }

        $results.Add([pscustomobject]@{
            Suite   = $suite.Name
            Result  = if ($exitCode -eq 0) { 'PASS' } else { 'FAIL' }
            Code    = $exitCode
            Seconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
            Detail  = ($detail -join ' ')
        })
    } finally {
        if ($process -and -not $process.HasExited) { try { & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null } catch { $null = $_ } }
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

$results | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host

$failures = @($results | Where-Object { $_.Result -ne 'PASS' })
Write-Host ("HOST=PowerShell {0}  SUITES={1}  FAILED={2}" -f $PSVersionTable.PSVersion, $results.Count, $failures.Count)
foreach ($failure in $failures) {
    Write-Host ("::error file=tests/{0}::{1} ({2})" -f $failure.Suite, $failure.Result, $failure.Detail)
}
if ($failures.Count -gt 0) { exit 1 }
exit 0
