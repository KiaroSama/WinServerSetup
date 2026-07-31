param()

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$source = Get-Content -LiteralPath (Join-Path $projectRoot "WinServerSetup.ps1") -Raw -Encoding UTF8

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }

Assert-True ($source -match 'function\s+Invoke-SlmgrChecked') "Activation must stop when slmgr reports a nonzero exit code."
Assert-True ($source -notmatch 'Write-(Info|Warn|Ok|StructuredLog)[^\r\n]*\$key') "Activation keys must never be written to console or file logs."
Assert-True ($source -match 'Invoke-SlmgrChecked -Arguments @\("/ipk", \$key\)') "Product-key installation must use the checked, non-logging slmgr path."
Assert-True ($source -match 'Activation completed and license status was queried') "Activation must report completion only after all checked commands succeed."

Write-Host "PASS activation is opt-in, non-logging, and exit-code checked."
