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
$setupSourceFiles = @(Get-SetupSourceFile -ProjectRoot $projectRoot -MainScript $mainScript)
$setupAsts = @(Get-SetupAst -Files $setupSourceFiles -Because 'its install path can be tested')
# Raw text of the same partition, for the retained source assertions further down.
$main = ($setupSourceFiles | ForEach-Object { Get-Content -LiteralPath $_ -Raw -Encoding UTF8 }) -join "`r`n"

foreach ($name in @('Resolve-InstallerExitCode', 'Test-DirectInstallerInstalled', 'Resolve-InstallDirectory',
        'Register-AppOutcome', 'Complete-DirectInstall', 'Install-DirectInstaller')) {
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
# Captured rather than discarded: the outcome an operator reads ("installed", "updated in place",
# "left unchanged") is the report this project makes about an application, so it is asserted.
$script:Messages = New-Object System.Collections.Generic.List[string]
function Write-Info { param($Message) $script:Messages.Add("INFO $Message") | Out-Null }
function Write-Ok { param($Message) $script:Messages.Add("OK $Message") | Out-Null }
function Write-Warn { param($Message) $script:Messages.Add("WARN $Message") | Out-Null }
function Write-StructuredLog { param($Level, $Message) }
function Get-Messages { return ($script:Messages -join ' | ') }

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

# The uninstall-key record, with the location the application already occupies. $null models
# "not installed yet"; a record whose InstallLocation is empty models an application whose
# location cannot be resolved from the registry at all.
$script:ExistingRecord = $null
$script:RecordAfterInstall = $null
function Get-InstalledAppRecord {
    param([Parameter(Mandatory)][string]$NameLike)
    if ($script:ExistingRecord) { return $script:ExistingRecord }
    return
}
function New-AppRecord {
    param([string]$Location)
    return [pscustomobject]@{ DisplayName = 'Fixture App 1.0'; DisplayVersion = '1.0'; InstallLocation = $Location }
}

function Invoke-SilentExeInstall {
    param($Path, $Arguments, $TimeoutSeconds)
    $script:InstallerRan = $true
    $script:RegistryDisplayName = $script:RegistryAfterInstall
    $script:ExistingRecord = $script:RecordAfterInstall
    return $script:InstallerExitCode
}

function Invoke-FixtureInstall {
    param([int]$ExitCode, [string]$RegistryDisplayName, $ExistingRecord = $null, $RecordAfterInstall = $null)
    $script:InstallerExitCode = $ExitCode
    $script:RegistryAfterInstall = $RegistryDisplayName
    $script:RegistryDisplayName = $null
    $script:ExistingRecord = $ExistingRecord
    # An installer normally leaves the application registered where it already was, so the
    # post-install record defaults to the pre-install one. A case that passes a different record
    # models an update that relocated the application instead of updating it in place.
    $script:RecordAfterInstall = if ($null -ne $RecordAfterInstall) { $RecordAfterInstall } else { $ExistingRecord }
    $script:InstallerRan = $false
    $script:Messages.Clear()
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

# =============================================================================================
# 3b. CHECK THEN UPDATE: an application that is already installed is updated WHERE IT LIVES.
#
# Before this, an already-installed direct installer was reported installed and skipped outright,
# so it was never updated at all. Detecting it is only half the job: the update has to be aimed
# at the directory the operator already has, and an update that lands somewhere else is a second
# copy of the application, not an update.
#
# GetFullPath is applied to the fixture root as well as to the production result. $env:TEMP is an
# 8.3 short path on some machines and GetFullPath expands it, so comparing an unexpanded fixture
# path against an expanded result would fail for a reason that has nothing to do with the code.
# =============================================================================================
$locationRoot = [System.IO.Path]::GetFullPath((Join-Path $env:TEMP ("WinServerSetup-Location-{0}" -f ([guid]::NewGuid().ToString('N')))))
$appDir = Join-Path $locationRoot 'App'
$otherDir = Join-Path $locationRoot 'Other'
try {
    New-Item -ItemType Directory -Path $appDir -Force | Out-Null
    New-Item -ItemType Directory -Path $otherDir -Force | Out-Null
    $appExe = Join-Path $appDir 'app.exe'
    $uninstExe = Join-Path $otherDir 'unins000.exe'
    Set-Content -LiteralPath $appExe -Value 'fixture' -Encoding ascii
    Set-Content -LiteralPath $uninstExe -Value 'fixture' -Encoding ascii

    # ---- 3b.1 Resolving the location an application already occupies. ----
    # The fixture guard matters: both fallbacks below derive a directory, and if they derived it
    # from the same place the cases could not tell them apart and would pass vacuously.
    Assert-True ($appDir -ne $otherDir) "Fixture guard: the DisplayIcon and UninstallString candidates must resolve to DIFFERENT directories."
    Assert-Equal $appDir (Resolve-InstallDirectory -Candidates @($appDir)) `
        "InstallLocation is the direct answer when the installer wrote one."
    Assert-Equal $appDir (Resolve-InstallDirectory -Candidates @('', ('"{0}",0' -f $appExe))) `
        "With no InstallLocation, DisplayIcon's directory is the evidence - its icon index must be stripped."
    Assert-Equal $otherDir (Resolve-InstallDirectory -Candidates @('', '', ('"{0}" /SILENT' -f $uninstExe))) `
        "With neither, UninstallString's directory is the last evidence - its arguments must be stripped."
    Assert-Equal $otherDir (Resolve-InstallDirectory -Candidates @((Join-Path $uninstExe 'nope'), $otherDir)) `
        "A candidate that does not exist must not stop a later candidate that does."
    Assert-Equal "" (Resolve-InstallDirectory -Candidates @('', $null, (Join-Path $locationRoot 'Missing\deeper\gone.exe'))) `
        "A location that resolves nowhere must be reported as unknown, never guessed."
    Assert-Equal "" (Resolve-InstallDirectory -Candidates @()) "No candidate at all must be reported as unknown."
    # LOAD-BEARING, and found on a real machine rather than in a fixture: every MSI records
    # UninstallString as "MsiExec.exe /X{GUID}", which is a RELATIVE path once the arguments come
    # off. GetFullPath resolves it against the current directory, so this returned the folder the
    # setup happened to be running from - a directory that exists and is completely unrelated.
    # PowerShell 7-x64 resolved to the project folder before this was fixed.
    Assert-Equal "" (Resolve-InstallDirectory -Candidates @('MsiExec.exe /X{6BB1DE85-6C58-4B23-9E00-BEC5E9C1EF39}')) `
        "A relative candidate must never resolve against the current directory."
    Assert-Equal "" (Resolve-InstallDirectory -Candidates @('unins000.exe')) `
        "A bare file name is not evidence of an install location."
    # ... and the rejection must not be a blanket one: a rooted path still resolves.
    Assert-Equal $appDir (Resolve-InstallDirectory -Candidates @('MsiExec.exe /X{GUID}', $appDir)) `
        "A rooted candidate after a rejected relative one must still resolve."

    # ---- 3b.2 LOAD-BEARING: already installed means UPDATE IN PLACE, not skip. ----
    $stats = Invoke-FixtureInstall -ExitCode 0 -RegistryDisplayName 'Fixture App 1.0' -ExistingRecord (New-AppRecord -Location $appDir)
    Assert-True $script:InstallerRan `
        ("An already-installed application must actually be updated; skipping it leaves it on its old version forever. Messages: {0}" -f (Get-Messages))
    Assert-Equal 1 $stats.InstalledApps.Count ("An updated application must stay accounted for. Messages: {0}" -f (Get-Messages))
    Assert-Equal 0 $stats.FailedApps.Count ("A verified in-place update must not be recorded as failed. Messages: {0}" -f (Get-Messages))
    Assert-True ((Get-Messages) -match [regex]::Escape("updated in place - $appDir")) `
        ("The update must be reported distinctly from a fresh install, and must name the existing location. Messages: {0}" -f (Get-Messages))
    Assert-True ((Get-Messages) -notmatch 'installed and verified') `
        ("An update must not be reported as a fresh install. Messages: {0}" -f (Get-Messages))

    # ---- 3b.3 LOAD-BEARING: an update that did not stay put is a duplicate, not an update. ----
    $stats = Invoke-FixtureInstall -ExitCode 0 -RegistryDisplayName 'Fixture App 1.0' `
        -ExistingRecord (New-AppRecord -Location $appDir) -RecordAfterInstall (New-AppRecord -Location $otherDir)
    Assert-Equal 0 $stats.InstalledApps.Count `
        ("An application that moved to a different directory was not updated in place and must not be reported as installed. Messages: {0}" -f (Get-Messages))
    Assert-Equal 1 $stats.FailedApps.Count ("A relocated update must be recorded as failed. Messages: {0}" -f (Get-Messages))
    Assert-True ((Get-Messages) -match [regex]::Escape($appDir) -and (Get-Messages) -match [regex]::Escape($otherDir)) `
        ("The relocation report must name both the old and the new location. Messages: {0}" -f (Get-Messages))

    # ---- 3b.3b An update that FAILS must not fail the run: the application is still installed. ----
    # Turning "we could not update it" into a failed app would exit 1 over a transient installer
    # error for software that is present and working. M-08 is about a component that is genuinely
    # ABSENT, and the case below that has nothing installed still fails.
    $stats = Invoke-FixtureInstall -ExitCode 1603 -RegistryDisplayName 'Fixture App 1.0' -ExistingRecord (New-AppRecord -Location $appDir)
    Assert-Equal 0 $stats.FailedApps.Count `
        ("A failed update of an application that is already installed must not fail the run. Messages: {0}" -f (Get-Messages))
    Assert-Equal 1 $stats.InstalledApps.Count `
        ("An application whose update failed is still installed and must stay accounted for. Messages: {0}" -f (Get-Messages))
    Assert-True ((Get-Messages) -match 'left unchanged') `
        ("A failed update must still be reported. Messages: {0}" -f (Get-Messages))
    # The same installer failure with nothing installed yet must still fail the run.
    $stats = Invoke-FixtureInstall -ExitCode 1603 -RegistryDisplayName 'Fixture App 1.0'
    Assert-Equal 1 $stats.FailedApps.Count `
        ("M-08: an application that is NOT on the machine and whose install failed must still fail the run. Messages: {0}" -f (Get-Messages))

    # ---- 3b.4 An unresolvable location means LEAVE IT ALONE, never install a second copy. ----
    $stats = Invoke-FixtureInstall -ExitCode 0 -RegistryDisplayName 'Fixture App 1.0' -ExistingRecord (New-AppRecord -Location '')
    Assert-True (-not $script:InstallerRan) `
        ("With no resolvable install location the installer must not run: it would install a second copy at the default path. Messages: {0}" -f (Get-Messages))
    Assert-Equal 1 $stats.InstalledApps.Count `
        ("An application left untouched is still installed and must stay accounted for. Messages: {0}" -f (Get-Messages))
    Assert-Equal 0 $stats.FailedApps.Count `
        ("Declining to update is not a failed run. Messages: {0}" -f (Get-Messages))
    Assert-True ((Get-Messages) -match 'left unchanged') `
        ("An update that could not be attempted must say so. Messages: {0}" -f (Get-Messages))
} finally {
    Remove-Item -LiteralPath $locationRoot -Recurse -Force -ErrorAction SilentlyContinue
}

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

Write-Host "PASS installer exit-code rule, independent registry verification, install-location resolution, update-in-place with its relocation guard, and per-installer download trust contracts."
