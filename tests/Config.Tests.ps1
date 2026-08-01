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

    # ---- M-06: the local override is under the same exact schema as the tracked config. ----
    # Every case below was silently ACCEPTED before the schema existed. The Boolean ones are
    # the dangerous class: [bool]"false" is $true in PowerShell, so a quoted "false" in the
    # override turned a setting ON instead of failing.
    $rejectCases = @(
        @{ Json    = '{ "rdp": { "enabled": "false" } }'
            Pattern = 'type mismatch at rdp\.enabled'
            Message = 'M-06: the string "false" must be rejected, never coerced to a Boolean.' }
        @{ Json    = '{ "rdp": { "enabled": "0" } }'
            Pattern = 'type mismatch at rdp\.enabled'
            Message = 'M-06: the string "0" must be rejected, never coerced to a Boolean.' }
        @{ Json    = '{ "rdp": { "enabled": 0 } }'
            Pattern = 'type mismatch at rdp\.enabled'
            Message = 'M-06: numeric 0 must be rejected in a Boolean field.' }
        @{ Json    = '{ "rdp": { "enabled": 1 } }'
            Pattern = 'type mismatch at rdp\.enabled'
            Message = 'M-06: numeric 1 must be rejected in a Boolean field.' }
        @{ Json    = '{ "rdp": { "enabled": null } }'
            Pattern = 'type mismatch at rdp\.enabled'
            Message = 'M-06: null must be rejected in a Boolean field.' }
        @{ Json    = '{ "activation": { "kmsServer": null } }'
            Pattern = 'type mismatch at activation\.kmsServer'
            Message = 'M-06: null must be rejected in a string field.' }
        @{ Json    = '{ "rdp": { "newPort": "5901" } }'
            Pattern = 'type mismatch at rdp\.newPort'
            Message = 'M-06: a numeric string must be rejected in an integer field.' }
        @{ Json    = '{ "rdp": { "newPort": 5901.5 } }'
            Pattern = 'rdp\.newPort must be a whole number'
            Message = 'M-06: a fractional number must be rejected in an integer field.' }
        @{ Json    = '{ "unexpectedTopLevelKey": true }'
            Pattern = 'unknown config property: unexpectedTopLevelKey'
            Message = 'M-06: an unknown top-level key must fail loudly until the schema is updated.' }
        @{ Json    = '{ "cleanup": { "unexpectedNestedKey": true } }'
            Pattern = 'unknown config property: cleanup\.unexpectedNestedKey'
            Message = 'M-06: an unknown nested key must fail loudly until the schema is updated.' }
        @{ Json    = '{ "rdpBruteforceBlocker": { "whitelistCIDRs": [ 127 ] } }'
            Pattern = 'type mismatch at rdpBruteforceBlocker\.whitelistCIDRs\[0\]'
            Message = 'M-06: a wrong array element type must be rejected.' }
        @{ Json    = '{ "winget": { "packages": [ { "name": "x", "id": "y", "enabled": "true" } ] } }'
            Pattern = 'type mismatch at winget\.packages\[0\]\.enabled'
            Message = 'M-06: array elements must be validated against the element schema.' }
        @{ Json    = '{ "winget": { "packages": [ { "name": "x", "id": "y" } ] } }'
            Pattern = 'missing required config property: winget\.packages\[0\]\.enabled'
            Message = 'M-06: an array element missing a required key must be rejected.' }
        @{ Json    = '{ "windowsUpdateBandwidth": { "qosNonBestEffortLimit": 5000 } }'
            Pattern = 'qosNonBestEffortLimit must be an integer between 0 and 100'
            Message = 'M-06: an out-of-range integer must be rejected.' }
        @{ Json    = '{ "windowsUpdateBandwidth": { "deliveryOptimizationDownloadMode": 7 } }'
            Pattern = 'deliveryOptimizationDownloadMode must be one of'
            Message = 'M-06: a value outside the allowed enum must be rejected.' }
        @{ Json    = '{ "rdp": { "newPort": 70000 } }'
            Pattern = 'rdp\.newPort must be an integer between 1 and 65535'
            Message = 'M-06: an out-of-range port must be rejected.' }
    )
    foreach ($case in $rejectCases) {
        $case.Json | Set-Content -LiteralPath $localPath -Encoding UTF8
        Assert-Throws { Import-WinServerSetupConfig $basePath $localPath } $case.Pattern $case.Message
    }

    # A required key that silently disappears from the tracked config must fail loudly rather
    # than leave the consuming script reading $null.
    $pruned = Get-Content -LiteralPath $basePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $pruned.cleanup.PSObject.Properties.Remove('cleanUserTemp')
    $prunedPath = Join-Path $testRoot "pruned.config.json"
    $pruned | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $prunedPath -Encoding UTF8
    Assert-Throws { Import-WinServerSetupConfig $prunedPath } 'missing required config property: cleanup\.cleanUserTemp' `
        "M-06: a missing required config key must be rejected."

    # The schema is only correct if the real shipped config still satisfies it.
    $tracked = Import-WinServerSetupConfig -BasePath (Join-Path $projectRoot "WinServerSetup.config.json")
    Assert-Equal 5801 $tracked.rdp.newPort "M-06: the shipped WinServerSetup.config.json must still validate."

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
