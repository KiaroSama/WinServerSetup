param()

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$main = Get-Content -LiteralPath (Join-Path $projectRoot "WinServerSetup.ps1") -Raw -Encoding UTF8
$sfc = Get-Content -LiteralPath (Join-Path $projectRoot "scripts\Run-PostRebootSfc.ps1") -Raw -Encoding UTF8

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }

Assert-True ($main -notmatch 'RepetitionDuration\s+\(New-TimeSpan -Days 3650\)') "RDP blocker task must not expire after ten years."
Assert-True ($main -match 'Running blocker verification failed with exit code') "Scheduled blocker installation must fail if its verification run fails."
Assert-True ($sfc -match '\[int\]\$MaxAttempts') "Post-reboot SFC needs a bounded retry contract."
Assert-True ($sfc -match '\[int\]\$RetryDelaySeconds') "Post-reboot SFC retries need an explicit delay."
Assert-True ($sfc -match 'Run-PostRebootSfc_.*UTC' -and $sfc -match 'while \(Test-Path -LiteralPath \$path\)') "Each SFC execution must preserve a unique history log."
Assert-True ($sfc -match 'if \(\$succeeded\)[\s\S]{0,500}Unregister-ScheduledTask') "The startup task must unregister only after a successful SFC run."
Assert-True ($sfc -match 'remains registered') "Exhausted SFC retries must retain the task for a later startup."

Write-Host "PASS recurring blocker and post-reboot SFC tasks remain durable, verified, retryable, and historically logged."
