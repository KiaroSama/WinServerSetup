<#
    Behavioral regression tests for full-setup outcome reporting in WinServerSetup.ps1.

    Pre-fix defects:
      O1  Invoke-RecordedSetupStep's catch ran `return $null`, which WRITES $null to the output
          stream. Invoke-FullSetup calls it as a bare statement ~24 times, so every failed step
          appended a $null to the function's output and its `return 1` became the last element of
          an array. `exit (@($null,1))` evaluates to 0 - verified on both hosts - so a setup with
          failed steps reported success to the caller and to CI.
      O2  RunStats.SkippedTasks was declared, displayed in the final summary and written to the
          structured log, but nothing ever added to it. Config-disabled steps returned early and
          were recorded as Completed, so a run that skipped most of its work looked fully done.
#>
param([string]$MainScript = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$mainScript = if ([string]::IsNullOrWhiteSpace($MainScript)) { Join-Path $projectRoot "WinServerSetup.ps1" } else { $MainScript }

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw ("{0} Expected={1}; Actual={2}" -f $Message, $Expected, $Actual) }
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($mainScript, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) "WinServerSetup.ps1 must parse before its outcome reporting can be tested."

function Get-FunctionText {
    param([string]$Name)
    $definition = $ast.FindAll({
            param($node)
            ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq $Name)
        }, $true) | Select-Object -First 1
    if ($null -eq $definition) { throw "WinServerSetup.ps1 must define $Name." }
    return $definition.Extent.Text
}

$harness = @'
$Global:RunStats = [pscustomobject]@{
    StartedTasks   = New-Object System.Collections.Generic.List[string]
    CompletedTasks = New-Object System.Collections.Generic.List[string]
    FailedTasks    = New-Object System.Collections.Generic.List[string]
    SkippedTasks   = New-Object System.Collections.Generic.List[string]
}
$Global:CurrentStepSkipReason = $null
function Write-StructuredLog { param($Level, $Message) }
function Write-Fail { param($Message) }
'@

$stepText = Get-FunctionText 'Invoke-RecordedSetupStep'
$skipText = Get-FunctionText 'Set-StepSkipped'

# ---- O1a: a failing step must emit nothing at all into the output stream. ----
. ([scriptblock]::Create($harness))
. ([scriptblock]::Create($stepText))
. ([scriptblock]::Create($skipText))

$emitted = @(Invoke-RecordedSetupStep -Name "failing" -Action { throw "boom" })
Assert-Equal 0 $emitted.Count `
    "A failed step must emit nothing; emitting `$null corrupts the caller's return value and zeroes the exit code."
Assert-Equal 1 $Global:RunStats.FailedTasks.Count "A failed step must be recorded in FailedTasks."

$emitted = @(Invoke-RecordedSetupStep -Name "clean" -Action { })
Assert-Equal 0 $emitted.Count "A successful non-PassThru step must not emit into the output stream."
Assert-Equal 1 $Global:RunStats.CompletedTasks.Count "A successful step must be recorded in CompletedTasks."

# ---- O2: a config-disabled step is Skipped, not Completed. ----
$null = Invoke-RecordedSetupStep -Name "switched off" -Action { Set-StepSkipped "disabled in config"; return }
Assert-Equal 1 $Global:RunStats.SkippedTasks.Count "A step that reports itself skipped must land in SkippedTasks."
Assert-Equal 1 $Global:RunStats.CompletedTasks.Count "A skipped step must NOT also be counted as Completed."
Assert-True ($Global:RunStats.SkippedTasks[0] -like '*switched off*') "The skip entry must name the step."

# The skip flag must not leak into the next step.
$null = Invoke-RecordedSetupStep -Name "after skip" -Action { }
Assert-Equal 1 $Global:RunStats.SkippedTasks.Count "The skip reason must be cleared between steps."
Assert-Equal 2 $Global:RunStats.CompletedTasks.Count "The step after a skipped one must count as Completed."

# ---- O1b: end-to-end exit-code propagation in the real call shape. ----
# Reproduces Invoke-FullSetup exactly: bare recorded-step statements, then `return 1`, consumed by
# the entry point's exit expression. This is the assertion that fails on the pre-fix source.
$childScript = @"
`$ErrorActionPreference = 'Stop'
$harness
$stepText
$skipText
function Fake-FullSetup {
    Invoke-RecordedSetupStep -Name 'ok'   -Action { }
    Invoke-RecordedSetupStep -Name 'bad'  -Action { throw 'boom' }
    Invoke-RecordedSetupStep -Name 'skip' -Action { Set-StepSkipped 'disabled in config'; return }
    if (`$Global:RunStats.FailedTasks.Count -gt 0) { return 1 }
    return 0
}
`$result = @(Fake-FullSetup)
`$code = if (`$result.Count -gt 0) { `$result[-1] } else { 1 }
exit ([int]`$code)
"@

$childPath = Join-Path $env:TEMP ("WinServerSetup-outcome-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
try {
    Set-Content -LiteralPath $childPath -Value $childScript -Encoding UTF8
    $hostExe = (Get-Process -Id $PID).Path
    & $hostExe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $childPath
    Assert-Equal 1 $LASTEXITCODE `
        "A full setup with a failed step must exit non-zero; a leaked `$null makes `exit` coerce the array to 0."
} finally {
    Remove-Item -LiteralPath $childPath -Force -ErrorAction SilentlyContinue
}

Write-Host "PASS failed steps exit non-zero, emit nothing, and config-disabled steps are recorded as Skipped."
