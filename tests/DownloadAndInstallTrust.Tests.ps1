<#
    Installer trust tests for WinServerSetup.ps1.

    These used to be source greps for strings like "1641". A grep proves a literal exists
    somewhere in a 4000-line file; it does not prove the rule is applied at the site that
    matters. The PowerShell 7 MSI path was the proof: it accepted only 0 and 3010, so a
    successful 1641 install was reported as a failure - while a grep for "1641" still
    passed, because other call sites contained the string.

    So the rule itself is now exercised through Resolve-InstallerExitCode, and the
    install/verify decision is exercised by driving Install-DirectInstaller with stubbed
    collaborators. Download transport, host allowlisting and signer-subject matching are
    covered behaviorally by tests/DownloadRuntime.Tests.ps1 and are not duplicated here.
#>
# -MainScript targets an alternate copy so these tests can be replayed against a deliberately
# defective build to prove they still fail. CI and local runs use the default.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub signatures mirror production collaborators so parameter binding matches.')]
param([string]$MainScript = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$mainScript = if ([string]::IsNullOrWhiteSpace($MainScript)) { Join-Path $projectRoot "WinServerSetup.ps1" } else { $MainScript }
$config = Get-Content -LiteralPath (Join-Path $projectRoot "WinServerSetup.config.json") -Raw -Encoding UTF8 | ConvertFrom-Json

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
. (Join-Path $PSScriptRoot '_Common.ps1')

# ---- Import only the functions under test; the main script self-executes if dot-sourced. ----
# WinServerSetup.ps1 dot-sources its function library from scripts\; search that whole
# partition so extraction by name keeps working wherever a function lives. $mainScript is
# searched first, so a -MainScript copy still shadows the on-disk original when replaying
# against a deliberately defective build.
$setupSourceNames = @('WinServerSetup.ps1') + @('Console', 'Core', 'Download', 'Rdp', 'Install', 'SystemSettings', 'Maintenance' |
        ForEach-Object { "scripts\{0}.ps1" -f $_ })
$setupSourceFiles = @(@($mainScript) + @($setupSourceNames | ForEach-Object { Join-Path $projectRoot $_ })) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique

# The remaining source assertions cover the same partition.
$main = ($setupSourceFiles | ForEach-Object { Get-Content -LiteralPath $_ -Raw -Encoding UTF8 }) -join "`r`n"

$setupAsts = @(foreach ($setupFile in $setupSourceFiles) {
        $tokens = $null
        $parseErrors = $null
        $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($setupFile, [ref]$tokens, [ref]$parseErrors)
        Assert-True ($parseErrors.Count -eq 0) "$setupFile must parse before its install path can be tested."
        $fileAst
    })

foreach ($name in @('Resolve-InstallerExitCode', 'Test-DirectInstallerInstalled', 'Install-DirectInstaller')) {
    . ([scriptblock]::Create((Import-FunctionUnderTest $name $setupAsts)))
}

# ---- 1. The installer exit-code rule, in one place. ----
# 0 = success, 3010 = success + reboot required, 1641 = success + reboot already initiated.
# Everything else is a failure. 1641 is the row the PowerShell 7 MSI path used to get wrong.
$exitCodeTable = @(
    @{ Code = 0;    Succeeded = $true;  RebootPending = $false }
    @{ Code = 3010; Succeeded = $true;  RebootPending = $true  }
    @{ Code = 1641; Succeeded = $true;  RebootPending = $true  }
    @{ Code = 1603; Succeeded = $false; RebootPending = $false }
    @{ Code = 1;    Succeeded = $false; RebootPending = $false }
)
foreach ($row in $exitCodeTable) {
    $actual = Resolve-InstallerExitCode -ExitCode $row.Code
    Assert-Equal $row.Code          $actual.ExitCode      "Exit code $($row.Code) must be echoed back unchanged."
    Assert-Equal $row.Succeeded     $actual.Succeeded     "Exit code $($row.Code) Succeeded is wrong."
    Assert-Equal $row.RebootPending $actual.RebootPending "Exit code $($row.Code) RebootPending is wrong."
}

# The rule must be pure: no reboot flag is set, no state is written, so every installer can
# consult it without side effects.
$script:PendingReboots = New-Object System.Collections.Generic.List[string]
function Set-PendingReboot { param($Reason) $script:PendingReboots.Add([string]$Reason) | Out-Null }
$null = Resolve-InstallerExitCode -ExitCode 3010
Assert-Equal 0 $script:PendingReboots.Count "Resolve-InstallerExitCode must not set the pending-reboot flag itself."

# Supplement to the table above: the PowerShell 7 MSI path must route through the helper
# rather than re-deriving the rule (that is how it lost 1641 in the first place).
Assert-True ($main -match '\$msiResult = Resolve-InstallerExitCode -ExitCode \$proc\.ExitCode') `
    "The PowerShell 7 MSI path must use the shared exit-code helper."
Assert-True ($main -notmatch '\$proc\.ExitCode -eq 0 -or \$proc\.ExitCode -eq 3010') `
    "The PowerShell 7 MSI path must no longer open-code an exit-code set that omits 1641."

# ---- 2. An installer with no verification contract is never reported as installed. ----
function Write-Info { param($Message) }
function Write-Ok { param($Message) }
function Write-Warn { param($Message) }
function Write-StructuredLog { param($Level, $Message) }

# Stands in for the uninstall-registry scan. It reports whatever the fixture says is
# currently registered, so "not installed yet" and "registered after the installer ran"
# are both expressible.
$script:RegistryDisplayName = $null
function Get-InstalledRegistryDisplayName { param($NameLike) if ($script:RegistryDisplayName) { return [string]$script:RegistryDisplayName } return }

foreach ($blank in @('', '   ', $null)) {
    Assert-Equal $false (Test-DirectInstallerInstalled -Name 'Fixture App' -RegistryName $blank) `
        "An installer with a blank verifyRegistryName has no verification contract and must never be reported installed."
}
# ... and the check is not trivially always-false.
$script:RegistryDisplayName = 'Fixture App 1.0'
Assert-Equal $true (Test-DirectInstallerInstalled -Name 'Fixture App' -RegistryName 'Fixture App') `
    "A real registry match must verify the install."

# ---- 3. A success exit code alone must not count as an installed app. ----
# Many installers exit 0 after doing nothing (wrong architecture, silent switch ignored,
# elevation refused). The registry check is the independent evidence, so it decides.
function Get-SafeDownloadCacheFilePath { param($FileName) return (Join-Path $env:TEMP $FileName) }
function Invoke-DownloadFile {
    param($Url, $Destination, $ExpectedSha256, $RequireValidSignature, $AllowedHosts, $AllowedSignerSubjects, $RetryCount, $TimeoutSeconds)
    return $true
}
# Running the installer is what puts the app in the uninstall registry - the fixture must
# model that order. Seeding the registry up front instead makes Install-DirectInstaller take
# its "already installed" shortcut and return before installing anything, which silently
# turns every assertion below into a test of the shortcut.
$script:InstallerExitCode = 0
$script:InstallerRan = $false
$script:RegistryAfterInstall = $null
function Invoke-SilentExeInstall {
    param($Path, $Arguments, $TimeoutSeconds)
    $script:InstallerRan = $true
    $script:RegistryDisplayName = $script:RegistryAfterInstall
    return $script:InstallerExitCode
}

function Invoke-FixtureInstall {
    param([int]$ExitCode, [string]$RegistryDisplayName)
    $script:InstallerExitCode = $ExitCode
    $script:RegistryAfterInstall = $RegistryDisplayName
    $script:RegistryDisplayName = $null
    $script:InstallerRan = $false
    $script:PendingReboots.Clear()
    $Global:RunStats = [pscustomobject]@{
        InstalledApps = (New-Object System.Collections.Generic.List[string])
        FailedApps    = (New-Object System.Collections.Generic.List[string])
    }
    Install-DirectInstaller -Spec ([pscustomobject]@{
            enabled            = $true
            name               = 'Fixture App'
            url                = 'https://fixture.invalid/app.exe'
            fileName           = 'fixture-app.exe'
            silentArgs         = '/S'
            verifyRegistryName = 'Fixture App'
        })
    return $Global:RunStats
}

$stats = Invoke-FixtureInstall -ExitCode 0 -RegistryDisplayName $null
Assert-True $script:InstallerRan "The fixture must actually reach the installer, not the already-installed shortcut."
Assert-Equal 0 $stats.InstalledApps.Count `
    ("Exit code 0 without registry evidence must not be counted as installed. Got: {0}" -f ($stats.InstalledApps -join ', '))
Assert-Equal 1 $stats.FailedApps.Count "An unverified install must be recorded as failed."
Assert-Equal 'Fixture App' $stats.FailedApps[0] "The failed app must be recorded under its configured name."

# The same path with real registry evidence must succeed, so the assertion above is not
# passing because the install path is simply broken.
$stats = Invoke-FixtureInstall -ExitCode 0 -RegistryDisplayName 'Fixture App 1.0'
Assert-True $script:InstallerRan "The fixture must actually reach the installer, not the already-installed shortcut."
Assert-Equal 1 $stats.InstalledApps.Count "A verified install must be counted as installed."
Assert-Equal 0 $stats.FailedApps.Count "A verified install must not be counted as failed."

# 1641 is a success code: verified, counted as installed, and flagged for reboot.
$stats = Invoke-FixtureInstall -ExitCode 1641 -RegistryDisplayName 'Fixture App 1.0'
Assert-Equal 1 $stats.InstalledApps.Count "Exit code 1641 is a successful install, not a failure."
Assert-Equal 1 $script:PendingReboots.Count "Exit code 1641 must record a pending reboot."

# 1603 is a fatal MSI error: never installed, always failed.
$stats = Invoke-FixtureInstall -ExitCode 1603 -RegistryDisplayName 'Fixture App 1.0'
Assert-Equal 0 $stats.InstalledApps.Count "A fatal installer exit code must not be counted as installed even if the registry name matches."
Assert-Equal 1 $stats.FailedApps.Count "A fatal installer exit code must be recorded as failed."

# ---- 4. Trust wiring with no behavioral home elsewhere. ----
# DownloadRuntime.Tests.ps1 drives the transport with the signature check stubbed out, so
# these two remain source assertions: they only confirm the parameters are still threaded
# through, not that they behave.
Assert-True ($main -match 'TimeoutSec\s+\$TimeoutSeconds') "Network downloads need an explicit timeout."
Assert-True ($main -match 'Test-DownloadedFileSignature[\s\S]{0,500}AllowedSignerSubjects') "Authenticode validation must check the signer subject."

# ---- 5. Every shipped installer declares its own trust contract. ----
foreach ($installer in @($config.directInstallers | Where-Object enabled)) {
    Assert-True ([bool]$installer.requireValidSignature) "$($installer.name) must require a valid Authenticode signature."
    Assert-True (@($installer.allowedSignerSubjects).Count -gt 0) "$($installer.name) must define an expected signer."
    Assert-True (@($installer.allowedDownloadHosts).Count -gt 0) "$($installer.name) must constrain redirect/download hosts."
}

Write-Host "PASS installer exit-code rule, independent registry verification, and per-installer download trust contracts."
