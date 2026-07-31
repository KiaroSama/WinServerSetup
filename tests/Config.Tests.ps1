param()

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$configScript = Join-Path $projectRoot "scripts\Config.ps1"
if (-not (Test-Path -LiteralPath $configScript)) { throw "Missing centralized config loader: $configScript" }
. $configScript

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message Expected=$Expected; Actual=$Actual" }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)
    try { & $Action; throw "Expected failure was not raised. $Message" }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "$Message Unexpected error: $($_.Exception.Message)" }
    }
}

$testRoot = Join-Path $env:TEMP ("WinServerSetup-Config-{0}" -f [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    $basePath = Join-Path $testRoot "WinServerSetup.config.json"
    $localPath = Join-Path $testRoot "WinServerSetup.config.local.json"
    Copy-Item -LiteralPath (Join-Path $projectRoot "WinServerSetup.config.json") -Destination $basePath
    @'
{
  "activation": {
    "enabled": true,
    "productKey": "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE",
    "kmsServer": "kms.example.test"
  },
  "rdp": { "newPort": 5901 }
}
'@ | Set-Content -LiteralPath $localPath -Encoding UTF8

    $config = Import-WinServerSetupConfig -BasePath $basePath -LocalPath $localPath
    Assert-Equal 5901 $config.rdp.newPort "Local override did not replace the RDP port."
    Assert-Equal 3389 $config.rdp.oldPort "Local override destroyed sibling defaults."
    Assert-Equal $true $config.activation.enabled "Local activation override was not applied."

    '{ "rdp": { "unexpectedNestedKey": true } }' | Set-Content -LiteralPath $localPath -Encoding UTF8
    Assert-Throws { Import-WinServerSetupConfig $basePath $localPath } 'unknown config property.*rdp.unexpectedNestedKey' "Unknown nested properties must be rejected."

    '{ "rdp": { "newPort": { "value": 5901 } } }' | Set-Content -LiteralPath $localPath -Encoding UTF8
    Assert-Throws { Import-WinServerSetupConfig $basePath $localPath } 'type mismatch.*rdp.newPort' "Nested objects must not replace scalar settings."

    '{ "rdp": { "newPort": 70000 } }' | Set-Content -LiteralPath $localPath -Encoding UTF8
    Assert-Throws { Import-WinServerSetupConfig $basePath $localPath } 'rdp.newPort' "Out-of-range RDP ports must fail centralized validation."

    $unsafeBase = Get-Content -LiteralPath $basePath -Raw | ConvertFrom-Json
    $unsafeBase.activation.enabled = $true
    $unsafeBase.activation.productKey = "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE"
    $unsafeBase | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $basePath -Encoding UTF8
    Remove-Item -LiteralPath $localPath -Force
    Assert-Throws { Import-WinServerSetupConfig $basePath $localPath } 'local override' "Tracked/base config must not carry an activation key."

    Write-Host "PASS centralized config validation, strict nesting, and local override merge."
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
