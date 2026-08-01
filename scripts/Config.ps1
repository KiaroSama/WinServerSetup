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

<#
    M-06: recursive schema check for one node.

    $Spec is one of three shapes:
      - a hashtable  -> a JSON object; keys ending in '?' are optional, every other key is
                        required, and any key absent from the schema is rejected.
      - a one-element array -> a JSON array; $Spec[0] is the schema of every element.
      - a string     -> a scalar: 'bool', 'string', 'int', 'int:<min>..<max>',
                        or 'int:enum:<a>|<b>|...'.

    Nothing is ever coerced. PowerShell's [bool]"false" is $true and [int]"5901" is 5901, so
    a quoted value in a Boolean or integer slot has to be rejected by type, not converted.
    $null is never a valid value: no field in this config is nullable.

    -AllowPartial validates a local override, where a missing key just means "not overridden".
    It deliberately does not propagate into arrays: a merge replaces an array wholesale rather
    than merging element by element, so every element of an overriding array must be complete.
#>
function Assert-ConfigNode {
    param($Value, $Spec, [string]$Path, [switch]$AllowPartial)

    $actual = if ($null -eq $Value) { 'null' } else { $Value.GetType().FullName }

    if ($Spec -is [hashtable]) {
        if (-not (Test-ConfigObject $Value)) {
            throw ("Config type mismatch at {0}: expected a JSON object, actual {1}." -f $Path, $actual)
        }
        $allowed = @{}
        foreach ($key in $Spec.Keys) {
            $name = ([string]$key).TrimEnd('?')
            $allowed[$name] = $true
            $childPath = if ($Path) { "$Path.$name" } else { $name }
            if ($Value.PSObject.Properties.Name -notcontains $name) {
                if ($AllowPartial -or ([string]$key).EndsWith('?')) { continue }
                throw "Missing required config property: $childPath"
            }
            Assert-ConfigNode -Value $Value.$name -Spec $Spec[$key] -Path $childPath -AllowPartial:$AllowPartial
        }
        foreach ($property in $Value.PSObject.Properties) {
            if (-not $allowed.ContainsKey($property.Name)) {
                $unknownPath = if ($Path) { "$Path.$($property.Name)" } else { $property.Name }
                throw "Unknown config property: $unknownPath"
            }
        }
        return
    }

    if ($Spec -is [array]) {
        if ($Value -isnot [array]) {
            throw ("Config type mismatch at {0}: expected a JSON array, actual {1}." -f $Path, $actual)
        }
        for ($index = 0; $index -lt $Value.Count; $index++) {
            Assert-ConfigNode -Value $Value[$index] -Spec $Spec[0] -Path ("{0}[{1}]" -f $Path, $index)
        }
        return
    }

    $text = [string]$Spec
    if ($text -eq 'bool') {
        if ($Value -isnot [bool]) {
            throw ("Config type mismatch at {0}: expected a JSON boolean literal (true or false), actual {1}." -f $Path, $actual)
        }
        return
    }
    if ($text -eq 'string') {
        if ($Value -isnot [string]) {
            throw ("Config type mismatch at {0}: expected a string, actual {1}." -f $Path, $actual)
        }
        return
    }
    if ($text -ne 'int' -and -not $text.StartsWith('int:')) {
        throw ("Config schema defect: unsupported specification '{0}' at {1}." -f $text, $Path)
    }

    # ConvertFrom-Json yields Int32 on 5.1 and Int64 on 7 for the same literal, and 5901.5 is
    # Decimal on 5.1 but Double on 7, so both integer widths and both fractional types matter.
    if ($Value -is [int] -or $Value -is [long]) {
        $number = [double]$Value
    } elseif ($Value -is [double] -or $Value -is [decimal]) {
        $number = [double]$Value
        if ([math]::Truncate($number) -ne $number) {
            throw ("{0} must be a whole number. Actual: {1}." -f $Path, $Value)
        }
    } else {
        throw ("Config type mismatch at {0}: expected an integer, actual {1}." -f $Path, $actual)
    }

    $constraint = if ($text.Length -gt 4) { $text.Substring(4) } else { "" }
    if ($constraint.StartsWith('enum:')) {
        $choices = $constraint.Substring(5) -split '\|'
        if ($choices -notcontains ([string][long]$number)) {
            throw ("{0} must be one of: {1}. Actual: {2}." -f $Path, ($choices -join ', '), [long]$number)
        }
    } elseif ($constraint) {
        $bounds = $constraint -split '\.\.'
        if ($number -lt [double]$bounds[0] -or $number -gt [double]$bounds[1]) {
            throw ("{0} must be an integer between {1} and {2}. Actual: {3}." -f $Path, $bounds[0], $bounds[1], [long]$number)
        }
    }
}

<#
    M-06: the exact contract for WinServerSetup.config.json and its local override.

    The tracked config and WinServerSetup.config.local.json are checked against this same
    schema, so a value the override may not set is one the tracked config may not set either.
    Adding a key to the JSON without adding it here fails as an unknown property, which is the
    point: the schema cannot silently drift behind the config.

    rdpBruteforceBlocker integers carry no bounds here on purpose - Block-RdpBruteforce.ps1
    owns its own budget ranges, and duplicating them would give two sources of truth.
#>
function Assert-ConfigSchema {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [switch]$AllowPartial
    )

    $schema = @{
        portableRoot      = 'string'
        targetProjectRoot = 'string'
        downloadRoot      = 'string'
        logRoot           = 'string'
        selfRelocate      = @{ enabled = 'bool' }
        parallel          = @{ enabled = 'bool'; maxParallel = 'int:1..16' }
        autoReboot        = @{ enabled = 'bool'; countdownSeconds = 'int:0..86400'; scheduleSfcAfterReboot = 'bool' }
        activation        = @{ enabled = 'bool'; productKey = 'string'; kmsServer = 'string' }
        windowsUpdate     = @{
            enabled = 'bool'; usePSWindowsUpdateModule = 'bool'; autoReboot = 'bool'
            maxPasses = 'int:1..20'; jobTimeoutMinutes = 'int:1..1440'
        }
        appearance        = @{ darkMode = 'bool'; restartExplorer = 'bool'; showFileExtensions = 'bool' }
        filesystem        = @{ enableLongPaths = 'bool' }
        keyboard          = @{ addPersianLayout = 'bool' }
        rdp               = @{
            enabled = 'bool'; newPort = 'int:1..65535'; oldPort = 'int:1..65535'
            blockOldPort = 'bool'; restartRemoteDesktopService = 'bool'; verifyListening = 'bool'
        }
        indexing          = @{ enabled = 'bool' }
        runtimes          = @{
            installDotNetFramework35 = 'bool'; installDotNetDesktopRuntimes = 'bool'
            installVisualCppRuntimes = 'bool'; installLegacyVisualCppRuntimes = 'bool'
            installDotNetFramework4Plus = 'bool'; dotNetFramework481OfflineUrl = 'string'
            dotNetFramework481ExpectedSha256 = 'string'; installDotNetCoreRuntimes = 'bool'
            includeUnsupportedDotNetVersions = 'bool'
        }
        winget            = @{
            installIfMissing = 'bool'; interactiveInstallers = 'bool'
            upgradeExistingPackages = 'bool'; removeMsstoreSource = 'bool'
            packages = @(@{ name = 'string'; id = 'string'; enabled = 'bool' })
        }
        directInstallers  = @(@{
                name = 'string'; enabled = 'bool'; url = 'string'; fileName = 'string'
                silentArgs = 'string'; fallbackInteractive = 'bool'; verifyRegistryName = 'string'
                requireValidSignature = 'bool'
                allowedSignerSubjects = @('string'); allowedDownloadHosts = @('string')
                'enableService?' = 'bool'; 'expectedSha256?' = 'string'
            })
        v2rayN            = @{
            enabled = 'bool'; githubRepo = 'string'; assetNameRegex = 'string'; installDir = 'string'
            finalFolderName = 'string'; exeName = 'string'; preserveUserDataPaths = @('string')
            createDesktopShortcut = 'bool'; createStartMenuShortcut = 'bool'
        }
        defaultApps       = @{ enabled = 'bool'; importXmlIfExists = 'bool'; xmlPath = 'string'; openSettingsAfterInstall = 'bool' }
        sevenZipDefaults  = @{ enabled = 'bool'; installPath = 'string'; removeUserChoice = 'bool'; extensions = @('string') }
        braveExtensions   = @{
            enabled = 'bool'; useForceListPolicy = 'bool'; openInBrave = 'bool'
            items = @(@{ name = 'string'; id = 'string'; url = 'string' })
        }
        taskbar           = @{ unpinEdge = 'bool'; pinBrave = 'bool' }
        quickAccess       = @{ enabled = 'bool'; includeRecycleBin = 'bool'; folders = @('string') }
        startupDisable    = @{ enabled = 'bool'; patterns = @('string') }
        removeAppxPackages = @{ enabled = 'bool'; packages = @('string') }
        removeWindowsCapabilities = @{ enabled = 'bool'; capabilities = @('string') }
        emptyStandbyList  = @{
            enabled = 'bool'; sourceRepo = 'string'; sourceRef = 'string'; expectedSha256 = 'string'
            installDir = 'string'; exeName = 'string'; argument = 'string'; taskName = 'string'
            repeatMinutes = 'int:1..1440'; taskXmlName = 'string'; taskPath = 'string'
        }
        windowsUpdateBandwidth = @{
            enabled = 'bool'; qosNonBestEffortLimit = 'int:0..100'
            deliveryOptimizationDownloadMode = 'int:enum:0|1|2|3|99'
            disableUpdateBandwidthLimits = 'bool'; runGpupdate = 'bool'
        }
        rdpBruteforceBlocker = @{
            enabled = 'bool'; threshold = 'int'; lookbackMinutes = 'int'; taskName = 'string'
            taskIntervalMinutes = 'int'; rulePrefix = 'string'; includeNetworkLogonType3 = 'bool'
            attributionWindowSeconds = 'int'; executionTimeLimitMinutes = 'int'; maxEventsPerRun = 'int'
            maxOffendersPerRun = 'int'; maxManagedRules = 'int'; maxStateBytes = 'int'; maxRunSeconds = 'int'
            blockAllInbound = 'bool'; permanentBlock = 'bool'; ruleRetentionDays = 'int'
            logMaxBytes = 'int'; logRetentionFiles = 'int'; whitelistCIDRs = @('string')
        }
        powershell        = @{
            enabled = 'bool'; githubRepo = 'string'; assetNameRegex = 'string'; expectedSha256 = 'string'
            installLatestFromGitHub = 'bool'; forceInstall = 'bool'; interactiveInstaller = 'bool'
            setPs1DefaultApp = 'bool'; msiArguments = 'string'; silentMsiArguments = 'string'
        }
        windowsTerminal   = @{
            enabled = 'bool'; packageId = 'string'; interactiveInstaller = 'bool'
            setAsDefaultTerminal = 'bool'; setPowerShell7AsDefaultProfile = 'bool'
            openSettingsAfterInstall = 'bool'
        }
        customFolders     = @{
            enabled = 'bool'; portablePath = 'string'; scriptsPath = 'string'
            createCompressedInDownloads = 'bool'; compressedFolderName = 'string'
            excludeCompressedFromDefender = 'bool'
        }
        administratorAccount = @{ enabled = 'bool'; promptDuringFullSetup = 'bool'; defaultNewName = 'string' }
        accountLockout    = @{ disableLocalAccountLockout = 'bool'; promptDuringFullSetup = 'bool'; runGpupdate = 'bool' }
        cleanup           = @{
            enabled = 'bool'; cleanProjectDownloadCache = 'bool'; cleanUserTemp = 'bool'
            cleanWindowsTemp = 'bool'; cleanWindowsUpdateDownloadCache = 'bool'; cleanRecycleBin = 'bool'
        }
    }

    Assert-ConfigNode -Value $Config -Spec $schema -Path "" -AllowPartial:$AllowPartial
}

function Assert-WinServerSetupConfig {
    param([Parameter(Mandatory)][pscustomobject]$Config)

    Assert-ConfigSchema -Config $Config
    # H-03: reject a dangerous downloadRoot before full setup begins rather than at cleanup
    # time. Guarded because Config.ps1 is also dot-sourced standalone by its own test suite,
    # where the Maintenance module is not loaded.
    if (Get-Command Assert-DownloadRootAllowed -ErrorAction SilentlyContinue) {
        Assert-DownloadRootAllowed -Path ([string]$Config.downloadRoot) | Out-Null
    }

    # Cross-field rules the per-field schema cannot express.
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
        # M-06: the override is held to the same schema as the tracked config, and is checked
        # before the merge so a bad override cannot leave $base half-written.
        Assert-ConfigSchema -Config $local -AllowPartial
        $base = Merge-ConfigObject -Base $base -Override $local
    }
    return Assert-WinServerSetupConfig $base
}
