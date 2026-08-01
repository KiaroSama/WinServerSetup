# Strict configuration import and local override support for WinServerSetup.

function Test-ConfigObject {
    param($Value)
    return $null -ne $Value -and $Value.GetType().FullName -eq 'System.Management.Automation.PSCustomObject'
}

function Merge-ConfigObject {
    param(
        [Parameter(Mandatory)][pscustomobject]$Base,
        [Parameter(Mandatory)][pscustomobject]$Override,
        [string]$Path = ""
    )

    foreach ($overrideProperty in $Override.PSObject.Properties) {
        $propertyPath = if ($Path) { "$Path.$($overrideProperty.Name)" } else { $overrideProperty.Name }
        $baseProperty = $Base.PSObject.Properties[$overrideProperty.Name]
        if ($null -eq $baseProperty) { throw "Unknown config property: $propertyPath" }

        $baseIsObject = Test-ConfigObject $baseProperty.Value
        $overrideIsObject = Test-ConfigObject $overrideProperty.Value
        $baseIsArray = $baseProperty.Value -is [array]
        $overrideIsArray = $overrideProperty.Value -is [array]
        if ($baseIsObject -ne $overrideIsObject -or $baseIsArray -ne $overrideIsArray) {
            throw "Config type mismatch at $propertyPath. Nested objects, arrays, and scalar values cannot replace one another."
        }
        if ($baseIsObject) {
            Merge-ConfigObject -Base $baseProperty.Value -Override $overrideProperty.Value -Path $propertyPath | Out-Null
        } else {
            $baseProperty.Value = $overrideProperty.Value
        }
    }
    return $Base
}

function Assert-PortNumber {
    param($Value, [string]$Path)
    $number = 0
    if (-not [int]::TryParse([string]$Value, [ref]$number) -or $number -lt 1 -or $number -gt 65535) {
        throw "$Path must be an integer between 1 and 65535."
    }
}

function Assert-WinServerSetupConfig {
    param([Parameter(Mandatory)][pscustomobject]$Config)

    foreach ($requiredObject in @('selfRelocate', 'parallel', 'activation', 'windowsUpdate', 'rdp', 'rdpBruteforceBlocker', 'administratorAccount', 'accountLockout', 'cleanup')) {
        if (-not (Test-ConfigObject $Config.$requiredObject)) { throw "$requiredObject must be a JSON object (actual: $($Config.$requiredObject.GetType().FullName))." }
    }
    # H-03: reject a dangerous downloadRoot before full setup begins rather than at cleanup
    # time. Guarded because Config.ps1 is also dot-sourced standalone by its own test suite,
    # where the Maintenance module is not loaded.
    if (Get-Command Assert-DownloadRootAllowed -ErrorAction SilentlyContinue) {
        Assert-DownloadRootAllowed -Path ([string]$Config.downloadRoot) | Out-Null
    }
    Assert-PortNumber $Config.rdp.newPort 'rdp.newPort'
    Assert-PortNumber $Config.rdp.oldPort 'rdp.oldPort'
    if ([int]$Config.parallel.maxParallel -lt 1 -or [int]$Config.parallel.maxParallel -gt 16) { throw "parallel.maxParallel must be between 1 and 16." }
    if ([int]$Config.windowsUpdate.maxPasses -lt 1 -or [int]$Config.windowsUpdate.maxPasses -gt 20) { throw "windowsUpdate.maxPasses must be between 1 and 20." }
    if ([int]$Config.windowsUpdate.jobTimeoutMinutes -lt 1 -or [int]$Config.windowsUpdate.jobTimeoutMinutes -gt 1440) { throw "windowsUpdate.jobTimeoutMinutes must be between 1 and 1440." }
    if ([int]$Config.autoReboot.countdownSeconds -lt 0 -or [int]$Config.autoReboot.countdownSeconds -gt 86400) { throw "autoReboot.countdownSeconds must be between 0 and 86400." }

    $activation = $Config.activation
    if ($activation.enabled) {
        if ([string]::IsNullOrWhiteSpace([string]$activation.productKey) -and [string]::IsNullOrWhiteSpace([string]$activation.kmsServer)) {
            throw "activation.enabled requires productKey or kmsServer in the local override."
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$activation.productKey) -and [string]$activation.productKey -notmatch '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$') {
            throw "activation.productKey has an invalid format."
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$activation.kmsServer) -and [string]$activation.kmsServer -notmatch '^[A-Za-z0-9.-]+(?::\d{1,5})?$') {
            throw "activation.kmsServer must be a host name with an optional port."
        }
    }
    return $Config
}

function Import-WinServerSetupConfig {
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [string]$LocalPath = ""
    )

    if (-not (Test-Path -LiteralPath $BasePath)) { throw "Config file not found: $BasePath" }
    try { $base = Get-Content -LiteralPath $BasePath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "Base config JSON is invalid: $($_.Exception.Message)" }
    if (-not (Test-ConfigObject $base)) { throw "Base config root must be a JSON object." }
    if (-not [string]::IsNullOrWhiteSpace([string]$base.activation.productKey)) {
        throw "Activation product keys are allowed only in the ignored local override."
    }

    if (-not [string]::IsNullOrWhiteSpace($LocalPath) -and (Test-Path -LiteralPath $LocalPath)) {
        try { $local = Get-Content -LiteralPath $LocalPath -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { throw "Local config JSON is invalid: $($_.Exception.Message)" }
        if (-not (Test-ConfigObject $local)) { throw "Local config root must be a JSON object." }
        $base = Merge-ConfigObject -Base $base -Override $local
    }
    return Assert-WinServerSetupConfig $base
}
