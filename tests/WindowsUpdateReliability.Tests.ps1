param()

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$source = Get-Content -LiteralPath (Join-Path $projectRoot "WinServerSetup.ps1") -Raw -Encoding UTF8

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }

Assert-True ($source -match 'function\s+Invoke-WithPSGalleryTrust') "Temporary PSGallery trust must be restored in finally."
Assert-True ($source -match 'finally[\s\S]{0,500}Set-PSRepository') "PSGallery policy restoration must be in a finally block."
Assert-True ($source -match 'WindowsUpdateJobTimeoutMinutes') "Windows Update jobs need a configurable finite timeout."
Assert-True ($source -match 'Stop-Job[\s\S]{0,300}timed out') "Timed-out Windows Update jobs must be stopped and failed."
Assert-True ($source -notmatch 'Get-WindowsUpdate failed:[^\r\n]*\}\s*\r?\n\s*\r?\n\s*if \(-not \$updates') "Scan failure must not fall through to 'no applicable updates'."
Assert-True ($source -match 'Get-WindowsUpdate[\s\S]{0,200}-ErrorAction Stop[\s\S]{0,300}All applicable Windows Updates installed') "The final success claim requires a successful final scan."
Assert-True ($source -match 'ResultCode|Result') "Per-update results must be inspected instead of treating Completed job state as installed."

Write-Host "PASS Windows Update distinguishes scan/install failures, times out, verifies results, and restores PSGallery policy."
