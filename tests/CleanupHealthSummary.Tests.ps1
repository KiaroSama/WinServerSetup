param()

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$source = Get-Content -LiteralPath (Join-Path $projectRoot "WinServerSetup.ps1") -Raw -Encoding UTF8

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }

Assert-True ($source -match 'function\s+Restore-ServiceState') "Windows Update cache cleanup must restore original service states in finally."
Assert-True ($source -match 'finally[\s\S]{0,500}Restore-ServiceState') "Service restoration must run even when cleanup fails."
Assert-True ($source -match 'Cleanup failed') "Partial deletion failures must not be reported as clean success."
Assert-True ($source -match 'Enabled\s*=') "Health checks must carry config-aware enablement instead of checking disabled features."
Assert-True ($source -match 'function\s+Test-ScheduledTaskContract') "Health checks must validate task action/principal/trigger contracts."
Assert-True ($source -match 'return \[pscustomobject\]@\{[^}]*Passed') "Health check must return a machine-readable result."
Assert-True ($source -match 'Full setup completed with failures') "Full setup must report partial failure explicitly."
Assert-True ($source -notmatch 'Write-Ok "Full setup completed\."') "Full setup must not print unconditional success."
# The bare `exit (Invoke-FullSetupWithActiveTimer)` form silently returned 0 whenever a step had
# leaked a value into the output stream. The exit code must now be coerced from the last emitted
# value. Actual exit-code behavior is covered by tests/SetupOutcome.Tests.ps1.
Assert-True ($source -match 'Invoke-FullSetupWithActiveTimer') "Noninteractive/full invocation must run the timed full setup."
Assert-True ($source -match 'exit \(\[int\]\$exitCode\)') "Noninteractive/full invocation must coerce a real integer exit code when setup is partial."

Write-Host "PASS cleanup truthfulness, service restoration, config-aware health, and nonzero partial setup status."
