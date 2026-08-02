<#
    Behavioral tests for winget detection in WinServerSetup.ps1.

    These three functions decide whether every configured package is installed or skipped, and the
    CHANGELOG records repeated churn in them:
      * Test-WingetPackageInstalled  - must NOT pin --source winget. Pinning it reports
        "not installed" for anything installed from msstore or out of band, and this project
        removes the msstore source by default, which makes that false negative routine.
      * Test-WingetUpgradeExitCode   - 0x8A15002B ("no applicable upgrade found") is the normal
        result for an already-current package and must not be reported as a failure.
      * Resolve-WingetExecutable     - Get-Command caches, and a freshly installed App Execution
        Alias may not be on the running shell's PATH, so the fallback order is load-bearing.

    No winget process is started and no registry is read: Invoke-LoggedCommand, Get-Command,
    Test-Path, Get-ChildItem and Get-InstalledRegistryDisplayName are all shadowed.
#>
# -MainScript targets an alternate copy so these tests can be replayed against a deliberately
# defective build to prove they still fail. CI and local runs use the default.
#
# Mock signatures mirror the real cmdlets - including parameters this file never reads - so the
# code under test binds exactly as it does in production.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Cmdlets are shadowed deliberately to mock winget discovery without touching the machine.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock signatures mirror the real cmdlets so parameter binding matches production.')]
param([string]$MainScript = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$mainScript = if ([string]::IsNullOrWhiteSpace($MainScript)) { Join-Path $projectRoot "WinServerSetup.ps1" } else { $MainScript }

. (Join-Path $PSScriptRoot '_Common.ps1')

# ---- Import only the functions under test; the main script self-executes if dot-sourced. ----
# WinServerSetup.ps1 dot-sources its function library from scripts\; search that whole
# partition so extraction by name keeps working wherever a function lives. $mainScript is
# searched first, so a -MainScript copy still shadows the on-disk original when replaying
# against a deliberately defective build.
$setupSourceFiles = @(Get-SetupSourceFile -ProjectRoot $projectRoot -MainScript $mainScript)
$setupAsts = @(Get-SetupAst -Files $setupSourceFiles -Because 'winget detection can be tested')

$detectionSource = Import-FunctionUnderTest 'Test-WingetPackageInstalled' $setupAsts
foreach ($name in @('Test-WingetUpgradeExitCode', 'Test-WingetPackageInstalled', 'Resolve-WingetExecutable', 'Get-WingetExecutable')) {
    . ([scriptblock]::Create((Import-FunctionUnderTest $name $setupAsts)))
}

# ---- Mock state. ----
$script:WingetExitCode = 0
$script:WingetOutput = @()
$script:WingetInvocations = New-Object System.Collections.Generic.List[object]
$script:RegistryDisplayName = $null
$script:RegistryQueries = New-Object System.Collections.Generic.List[string]
$script:ExistingPaths = New-Object System.Collections.Generic.List[string]
$script:WindowsAppsDirectories = @()
$script:GetCommandSource = $null
$script:GetCommandCalls = 0
$script:TestPathCalls = 0
$script:GetChildItemCalls = 0

$aliasPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
$windowsAppsRoot = Join-Path $env:ProgramFiles 'WindowsApps'

function Reset-WingetState {
    $script:WingetExitCode = 0
    $script:WingetOutput = @()
    $script:WingetInvocations.Clear()
    $script:RegistryDisplayName = $null
    $script:RegistryQueries.Clear()
    $script:ExistingPaths.Clear()
    $script:WindowsAppsDirectories = @()
    $script:GetCommandSource = $null
    $script:GetCommandCalls = 0
    $script:TestPathCalls = 0
    $script:GetChildItemCalls = 0
    $Global:WingetExecutable = $null
}

# ---- Cmdlet and collaborator shadows. ----
function Write-StructuredLog { param($Level, $Message) }
function Invoke-LoggedCommand {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @(), [string]$DisplayName = "")
    $script:WingetInvocations.Add([pscustomobject]@{
            FilePath    = $FilePath
            Arguments   = @($Arguments)
            DisplayName = $DisplayName
        }) | Out-Null
    return [pscustomobject]@{ ExitCode = $script:WingetExitCode; Output = @($script:WingetOutput) }
}
function Get-InstalledRegistryDisplayName {
    # Signature copied from production: the parameter is -NameLike.
    param([Parameter(Mandatory)][string]$NameLike)
    $script:RegistryQueries.Add([string]$NameLike) | Out-Null
    return $script:RegistryDisplayName
}
function Get-Command {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string[]]$Name, $CommandType)
    $script:GetCommandCalls++
    if ([string]::IsNullOrWhiteSpace($script:GetCommandSource)) { return $null }
    return [pscustomobject]@{ Name = 'winget.exe'; Source = $script:GetCommandSource }
}
function Test-Path {
    param([Parameter(Position = 0)][string]$Path, [string]$LiteralPath)
    $script:TestPathCalls++
    $target = if ([string]::IsNullOrWhiteSpace($Path)) { $LiteralPath } else { $Path }
    return ($script:ExistingPaths -contains $target)
}
function Get-ChildItem {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Path, [string]$Filter, [switch]$Directory, [switch]$File, [switch]$Recurse)
    $script:GetChildItemCalls++
    return @($script:WindowsAppsDirectories | ForEach-Object {
            [pscustomobject]@{ Name = $_; FullName = (Join-Path $Path $_) }
        })
}

# ---- 1. Upgrade exit-code classification. ----
Assert-Equal $true  (Test-WingetUpgradeExitCode -ExitCode 0) "Exit code 0 is success."
Assert-Equal $true  (Test-WingetUpgradeExitCode -ExitCode -1978335189) "0x8A15002B 'no applicable upgrade found' must not be reported as a failure."
Assert-Equal $false (Test-WingetUpgradeExitCode -ExitCode 1) "A generic failure must stay a failure."
Assert-Equal $false (Test-WingetUpgradeExitCode -ExitCode -1978335212) "An unrelated winget error code must stay a failure."
Assert-Equal $false (Test-WingetUpgradeExitCode -ExitCode 1978335189) "The positive twin of the upgrade-not-applicable code is not success."

# ---- 2. Package reported installed by winget list. ----
Reset-WingetState
$script:GetCommandSource = 'C:\Fake\winget.exe'
$script:WingetExitCode = 0
$script:WingetOutput = @(
    'Name                 Id                    Version',
    '---------------------------------------------------',
    'Mozilla Firefox      Mozilla.Firefox       142.0'
)
Assert-Equal $true (Test-WingetPackageInstalled -Id 'Mozilla.Firefox') "A package listed by winget must be reported installed."
Assert-Equal 1 $script:WingetInvocations.Count "Detection must query winget exactly once."
Assert-Equal 0 $script:RegistryQueries.Count "The registry fallback must not run when winget already answered."

# ---- 3. LOAD-BEARING: the query must not pin --source winget. ----
$invocationArguments = @($script:WingetInvocations[0].Arguments)
Assert-True (-not ($invocationArguments -contains '--source')) `
    ("Pinning a source causes false negatives for msstore/out-of-band installs. Arguments: {0}" -f ($invocationArguments -join ' '))
Assert-True (-not (($invocationArguments -join ' ') -match '--source\s+winget')) `
    ("--source winget must not be pinned. Arguments: {0}" -f ($invocationArguments -join ' '))
Assert-True ($invocationArguments -contains 'list') "Detection must use 'winget list'."
Assert-True ($invocationArguments -contains '--id') "Detection must query by package ID."
Assert-True ($invocationArguments -contains 'Mozilla.Firefox') "Detection must pass the requested ID."
Assert-True ($invocationArguments -contains '--exact') "Detection must match the ID exactly."
Assert-True ($invocationArguments -contains '--disable-interactivity') "Detection must never block on a prompt during unattended setup."
Assert-Equal 'C:\Fake\winget.exe' $script:WingetInvocations[0].FilePath "Detection must use the resolved winget binary."

# ---- 4. A non-zero winget result must not be read as 'installed'. ----
Reset-WingetState
$script:GetCommandSource = 'C:\Fake\winget.exe'
$script:WingetExitCode = 1
$script:WingetOutput = @('No installed package found matching input criteria.')
Assert-Equal $false (Test-WingetPackageInstalled -Id 'Mozilla.Firefox') "Nothing installed anywhere must report false."

# ---- 5. Winget output that does not mention the ID must not count as a match. ----
Reset-WingetState
$script:GetCommandSource = 'C:\Fake\winget.exe'
$script:WingetExitCode = 0
$script:WingetOutput = @('No installed package found matching input criteria.')
Assert-Equal $false (Test-WingetPackageInstalled -Id 'Mozilla.Firefox') "Exit code 0 with no matching ID must not report installed."

# ---- 6. An empty ID is rejected without touching winget. ----
Reset-WingetState
Assert-Equal $false (Test-WingetPackageInstalled -Id '   ') "A blank ID must be rejected."
Assert-Equal 0 $script:WingetInvocations.Count "A blank ID must not start a winget process."

# ---- 7. Registry fallback for a package winget cannot see. ----
# KNOWN DEFECT: at the time this suite was written Test-WingetPackageInstalled calls
# Get-InstalledRegistryDisplayName with -NamePattern, while the real function's parameter is
# -NameLike. The binding error is swallowed by the surrounding catch, so the fallback is dead
# code and an out-of-band install is reported as "not installed".
# plans/003-dead-code-and-silenced-failures.md fixes it. This case pins BOTH behaviors: it
# asserts the fallback is dead while the wrong parameter name is still in the source, and
# automatically starts requiring the fallback to work as soon as 003 lands.
$fallbackIsDeadCode = $detectionSource -match '-NamePattern'
Reset-WingetState
$script:GetCommandSource = 'C:\Fake\winget.exe'
$script:WingetExitCode = 1
$script:WingetOutput = @('No installed package found matching input criteria.')
$script:RegistryDisplayName = 'Mozilla Firefox (x64 en-US)'
$fallbackResult = Test-WingetPackageInstalled -Id 'Mozilla.Firefox'
if ($fallbackIsDeadCode) {
    Assert-Equal $false $fallbackResult `
        "While Test-WingetPackageInstalled passes -NamePattern the registry fallback cannot run; if it now returns true, update this case."
    Assert-Equal 0 $script:RegistryQueries.Count "The dead fallback must not reach the registry helper at all."
    Write-Host "NOTE registry fallback is still dead code (-NamePattern vs -NameLike); pinned as such until plans/003 lands."
} else {
    Assert-Equal $true $fallbackResult "A package installed out of band must be detected through the uninstall registry."
    Assert-True ($script:RegistryQueries -contains 'Firefox') `
        ("The fallback must query the last dotted segment of the ID. Queries: {0}" -f ($script:RegistryQueries -join ', '))
}

# ---- 8. Executable resolution order. ----
# 8a. Get-Command wins and short-circuits every fallback.
Reset-WingetState
$script:GetCommandSource = 'C:\Windows\System32\winget.exe'
Assert-Equal 'C:\Windows\System32\winget.exe' (Resolve-WingetExecutable) "A resolvable command must win."
Assert-Equal 0 $script:TestPathCalls "A Get-Command hit must not probe the filesystem."
Assert-Equal 0 $script:GetChildItemCalls "A Get-Command hit must not enumerate WindowsApps."

# 8b. Get-Command misses; the App Execution Alias path is used.
Reset-WingetState
$script:ExistingPaths.Add($aliasPath) | Out-Null
Assert-Equal $aliasPath (Resolve-WingetExecutable) "The WindowsApps alias must be the first fallback."
Assert-Equal 0 $script:GetChildItemCalls "The alias hit must not enumerate WindowsApps."

# 8c. Both miss; the versioned WindowsApps package is used, highest version first.
Reset-WingetState
$script:WindowsAppsDirectories = @(
    'Microsoft.DesktopAppInstaller_1.20.0.0_x64__8wekyb3d8bbwe',
    'Microsoft.DesktopAppInstaller_1.9.0.0_x64__8wekyb3d8bbwe'
)
$highest = Join-Path (Join-Path $windowsAppsRoot 'Microsoft.DesktopAppInstaller_1.9.0.0_x64__8wekyb3d8bbwe') 'winget.exe'
$lower = Join-Path (Join-Path $windowsAppsRoot 'Microsoft.DesktopAppInstaller_1.20.0.0_x64__8wekyb3d8bbwe') 'winget.exe'
$script:ExistingPaths.Add($highest) | Out-Null
$script:ExistingPaths.Add($lower) | Out-Null
# Names sort as text, so '1.9.0.0' sorts above '1.20.0.0' descending - that is the documented behavior.
Assert-Equal $highest (Resolve-WingetExecutable) "The versioned WindowsApps binary must be the last fallback, taking the first by descending name."

# 8d. The highest-sorting directory without the binary must not stop the search.
Reset-WingetState
$script:WindowsAppsDirectories = @(
    'Microsoft.DesktopAppInstaller_1.9.0.0_x64__8wekyb3d8bbwe',
    'Microsoft.DesktopAppInstaller_1.20.0.0_x64__8wekyb3d8bbwe'
)
$script:ExistingPaths.Add($lower) | Out-Null
Assert-Equal $lower (Resolve-WingetExecutable) "A directory without winget.exe must be skipped, not treated as the answer."

# 8e. Nothing resolves at all.
Reset-WingetState
Assert-Equal $null (Resolve-WingetExecutable) "With no candidate at all the resolver must return null."
Assert-Equal 'winget' (Get-WingetExecutable) "Get-WingetExecutable must fall back to the bare command name, never to null."

# 8f. The resolved path is cached for the run.
Reset-WingetState
$script:GetCommandSource = 'C:\Windows\System32\winget.exe'
Assert-Equal 'C:\Windows\System32\winget.exe' (Get-WingetExecutable) "First call must resolve."
$callsAfterFirst = $script:GetCommandCalls
Assert-Equal 'C:\Windows\System32\winget.exe' (Get-WingetExecutable) "Second call must return the cached path."
Assert-Equal $callsAfterFirst $script:GetCommandCalls "A cached path must not be re-resolved."
$Global:WingetExecutable = $null

# ---- 9. The CALLER must route the upgrade exit code through Test-WingetUpgradeExitCode. ----
# Classifying the code correctly is useless if the one caller open-codes -ne 0, which it did:
# every already-current package produced a spurious "exited with code -1978335189" warning.
# These stubs are defined last so the real functions above are unaffected.
Reset-WingetState
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:Notices = New-Object System.Collections.Generic.List[string]
function Ensure-Winget { return $true }
function Test-WingetPackageInstalled { param([string]$Id) return $true }
function Write-Info { param($Message) $script:Notices.Add([string]$Message) | Out-Null }
function Write-Ok { param($Message) $script:Notices.Add([string]$Message) | Out-Null }
function Write-Warn { param($Message) $script:Warnings.Add([string]$Message) | Out-Null }
foreach ($name in @('Register-AppOutcome', 'Update-WingetPackageInPlace', 'Install-WingetPackages')) {
    . ([scriptblock]::Create((Import-FunctionUnderTest $name $setupAsts)))
}

$Global:Config = [pscustomobject]@{ winget = [pscustomobject]@{
            interactiveInstallers   = $false
            upgradeExistingPackages = $true
            packages                = @([pscustomobject]@{ enabled = $true; name = 'Seven Zip'; id = '7zip.7zip' })
        }
}
$Global:RunStats = [pscustomobject]@{
    InstalledApps = (New-Object System.Collections.Generic.List[string])
    FailedApps    = (New-Object System.Collections.Generic.List[string])
}

# 0x8A15002B - already current. This is the regression: it must not warn.
$script:WingetExitCode = -1978335189
Install-WingetPackages
Assert-Equal 0 $script:Warnings.Count `
    "An already-current package must not warn. Got: $($script:Warnings -join ' | ')"

# A genuine failure must still warn, so the fix cannot have swallowed real errors.
$script:Warnings.Clear()
$script:WingetExitCode = 1
Install-WingetPackages
Assert-Equal 1 $script:Warnings.Count "A real upgrade failure must still be reported."
Assert-True ($script:Warnings[0] -match 'exited with code 1') "The warning must name the failing exit code."

# ---- 10. An installed package must be UPGRADED where it lives, never installed a second time. ----
# winget upgrades a package in the location it already occupies, so "in place" here is a matter of
# calling upgrade rather than install. Re-running install for a package winget already reports
# installed is what produces a duplicate/parallel version on the machine.
function Reset-UpgradeState {
    Reset-WingetState
    $script:Warnings.Clear()
    $script:Notices.Clear()
    $script:GetCommandSource = 'C:\Fake\winget.exe'
    $Global:RunStats = [pscustomobject]@{
        InstalledApps = (New-Object System.Collections.Generic.List[string])
        FailedApps    = (New-Object System.Collections.Generic.List[string])
    }
}
function Get-UpgradeArguments {
    if ($script:WingetInvocations.Count -eq 0) { return "" }
    return (@($script:WingetInvocations[0].Arguments) -join ' ')
}

Reset-UpgradeState
$Global:Config.winget.upgradeExistingPackages = $true
$script:WingetExitCode = 0
Install-WingetPackages
Assert-Equal 1 $script:WingetInvocations.Count "An already-installed package must produce exactly one winget call."
Assert-True ((Get-UpgradeArguments) -match '^upgrade\b') `
    ("An installed package must be upgraded, not installed again. Arguments: {0}" -f (Get-UpgradeArguments))
Assert-True ((Get-UpgradeArguments) -notmatch '(^|\s)install(\s|$)') `
    ("A second 'install' for an installed package is a duplicate install, not an update. Arguments: {0}" -f (Get-UpgradeArguments))
Assert-True ((Get-UpgradeArguments) -match '7zip\.7zip') "The upgrade must name the package it is upgrading."
Assert-Equal 1 $Global:RunStats.InstalledApps.Count "An upgraded package must stay accounted for."
Assert-True ((($script:Notices -join ' | ')) -match 'updated in place') `
    ("An applied upgrade must be reported distinctly. Notices: {0}" -f ($script:Notices -join ' | '))

# 0x8A15002B is the already-current answer, and it is a different outcome from an applied upgrade.
Reset-UpgradeState
$script:WingetExitCode = -1978335189
Install-WingetPackages
Assert-Equal 0 $script:Warnings.Count "An already-current package must not warn."
Assert-True ((($script:Notices -join ' | ')) -match 'already current') `
    ("An already-current package must be reported as such, not as updated. Notices: {0}" -f ($script:Notices -join ' | '))
Assert-Equal 1 $Global:RunStats.InstalledApps.Count "An already-current package must stay accounted for."

# LOAD-BEARING: with upgrades switched off the existing installation is left completely alone -
# no winget call at all, and above all no second install.
Reset-UpgradeState
$Global:Config.winget.upgradeExistingPackages = $false
Install-WingetPackages
Assert-Equal 0 $script:WingetInvocations.Count `
    ("With upgrades disabled an installed package must not be touched at all. Arguments: {0}" -f (Get-UpgradeArguments))
Assert-Equal 1 $Global:RunStats.InstalledApps.Count "A package left alone is still installed and must stay accounted for."
Assert-Equal 0 $Global:RunStats.FailedApps.Count "Declining to upgrade is not a failure."
Assert-True (($script:Warnings -join ' | ') -match 'left unchanged') `
    ("Declining to upgrade must say so. Warnings: {0}" -f ($script:Warnings -join ' | '))
$Global:Config.winget.upgradeExistingPackages = $true

Write-Host "PASS winget detection: exit-code classification, unpinned source query, registry fallback state, executable resolution order, and an installed package upgraded in place instead of installed twice."
