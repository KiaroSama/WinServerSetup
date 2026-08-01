param()

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot "scripts\Block-RdpBruteforce.ps1")

. (Join-Path $PSScriptRoot '_Common.ps1')

Assert-True (Test-IPv4InCidr "192.0.2.42" "192.0.2.0/24") "Expected IPv4 address to match its /24 network."
Assert-True (-not (Test-IPv4InCidr "192.0.3.42" "192.0.2.0/24")) "Unexpected IPv4 CIDR match."
Assert-True (-not (Test-ValidIPv4 "999.0.0.1")) "Invalid octets must be rejected."
Assert-True (-not (Test-ValidIPv4Cidr "192.0.2.0/33")) "Invalid CIDR prefix must be rejected."
Assert-True (-not (Test-ValidIPv4Cidr "2001:db8::/32")) "The documented blocker scope is IPv4 only."

$summary = Format-RdpOffenderSummary ([pscustomobject]@{
    Count = 2
    LogonTypes = @("10")
    TargetUserNames = @("renamed-admin")
})
Assert-True ($summary -match "renamed-admin") "Offender summary must retain the actual target username."

Write-Host "PASS RDP blocker IPv4/CIDR validation and diagnostic summary."
