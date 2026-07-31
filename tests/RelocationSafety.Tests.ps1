param()

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$source = Get-Content -LiteralPath (Join-Path $projectRoot "WinServerSetup.ps1") -Raw -Encoding UTF8

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }

Assert-True ($source -match '\[string\]\$RelocationReadyPath') "Relocated child must receive a readiness-marker path."
Assert-True ($source -match '\[string\]\$RelocationReadyToken') "Relocated child must prove readiness with a per-run token."
Assert-True ($source -match 'Wait-RelocatedChildReady') "Parent must wait for the relocated child readiness handshake."
Assert-True ($source -match 'Write-RelocationReadyMarker') "Child must write readiness only after loading the relocated config."
Assert-True ($source -match 'Refusing to remove unsafe relocation source') "Cleanup must reject root, missing-project, nested, or unverified source paths."
Assert-True ($source -match 'ReadinessToken') "Cleanup must independently verify the readiness token before deleting the source."

Write-Host "PASS relocation requires a verified child-readiness handshake before guarded source cleanup."
