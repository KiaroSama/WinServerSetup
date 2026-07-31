param()

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$main = Get-Content -LiteralPath (Join-Path $projectRoot "WinServerSetup.ps1") -Raw -Encoding UTF8
$config = Get-Content -LiteralPath (Join-Path $projectRoot "WinServerSetup.config.json") -Raw -Encoding UTF8 | ConvertFrom-Json

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }

Assert-True ($main -match '\[string\[\]\]\$AllowedHosts') "Download helper must enforce an allowed host/redirect boundary."
Assert-True ($main -match '\[string\[\]\]\$AllowedSignerSubjects') "Executable trust must support an expected publisher allowlist."
Assert-True ($main -match 'TimeoutSec\s+\$TimeoutSeconds') "Network downloads need an explicit timeout."
# Invoke-WebRequest -OutFile emits nothing without -PassThru, and the final-URI property differs
# between Windows PowerShell 5.1 and PowerShell 7, so the resolution is centralised in a helper.
# Actual download behavior is covered by tests/DownloadRuntime.Tests.ps1.
Assert-True ($main -match '-OutFile \$partial -PassThru') "Reading the response requires -PassThru; without it Invoke-WebRequest returns nothing."
Assert-True ($main -match 'Get-WebResponseFinalUri -Response \$response') "Download trust must validate the final redirect URI."
Assert-True ($main -match 'Test-DownloadedFileSignature[\s\S]{0,500}AllowedSignerSubjects') "Authenticode validation must check the signer subject."
Assert-True ($main -match '1641' -and $main -match '3010') "Installer success codes requiring reboot must be recognized."
Assert-True ($main -match 'Test-DirectInstallerInstalled') "Installer success must be verified independently of process exit."

foreach ($installer in @($config.directInstallers | Where-Object enabled)) {
    Assert-True ([bool]$installer.requireValidSignature) "$($installer.name) must require a valid Authenticode signature."
    Assert-True (@($installer.allowedSignerSubjects).Count -gt 0) "$($installer.name) must define an expected signer."
    Assert-True (@($installer.allowedDownloadHosts).Count -gt 0) "$($installer.name) must constrain redirect/download hosts."
}

Write-Host "PASS download redirect, timeout, publisher, installer-code, and post-install verification policy."
