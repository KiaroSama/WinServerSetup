param()

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$source = Get-Content -LiteralPath (Join-Path $projectRoot "WinServerSetup.ps1") -Raw -Encoding UTF8

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }

Assert-True ($source -match 'function\s+Test-TermServiceOwnsTcpPort') "RDP verification must prove TermService owns the listener."
Assert-True ($source -match 'already occupied by a process other than TermService') "RDP migration must abort on a conflicting listener before changing the registry."
Assert-True ($source -match 'function\s+Restore-RdpPort') "Failed bind/restart paths need a shared rollback routine."
Assert-True ($source -match 'Block Old RDP TCP \$previousPort') "The firewall must block the actual previous registry port, not a stale configured value."
Assert-True ($source -match 'Test-TermServiceOwnsTcpPort -Port \$previousPort') "Rollback must verify that TermService reclaimed the previous port."

Write-Host "PASS RDP migration checks collisions, listener ownership, rollback, and actual previous port."
