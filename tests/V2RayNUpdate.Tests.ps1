<#
    Behavioral tests for the v2rayN install/update path in WinServerSetup.ps1.

    Install-V2RayN is the only routine in this project that DELETES user data as part of a normal,
    successful run: it empties the install folder and restores a preserved subset. A regression
    there destroys a user's saved proxy configuration silently, with no error and no exit code.

    These tests run the real function against a real filesystem confined to $env:TEMP - stronger
    evidence than mocking the filesystem away. Only two boundaries are stubbed:
      * Invoke-RestMethod  - the GitHub release query (no network).
      * Invoke-DownloadFile - the download (delivers a zip fixture built at test time).
    Remove-Item and Move-Item are shadowed by guards that REFUSE any path outside this suite's
    temp root, so a defect that widens the delete blast radius fails the suite instead of the host.
#>
# -MainScript targets an alternate copy so these tests can be replayed against a deliberately
# defective build to prove they still fail. CI and local runs use the default.
#
# Mock signatures mirror the real cmdlets - including parameters this file never reads - so the
# code under test binds exactly as it does in production.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Remove-Item and Move-Item are shadowed to confine destructive operations to the test root.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock signatures mirror the real cmdlets so parameter binding matches production.')]
param([string]$MainScript = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$mainScript = if ([string]::IsNullOrWhiteSpace($MainScript)) { Join-Path $projectRoot "WinServerSetup.ps1" } else { $MainScript }

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw ("{0} Expected={1}; Actual={2}" -f $Message, $Expected, $Actual) }
}

# ---- Import only the functions under test; the main script self-executes if dot-sourced. ----
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($mainScript, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) "WinServerSetup.ps1 must parse before its v2rayN path can be tested."

function Import-FunctionUnderTest {
    param([string]$Name)
    $definition = $ast.FindAll({
            param($node)
            ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq $Name)
        }, $true) | Select-Object -First 1
    if ($null -eq $definition) { throw "WinServerSetup.ps1 must define $Name." }
    return $definition.Extent.Text
}

foreach ($name in @('Test-UnsafeReplaceTarget', 'Install-V2RayN')) {
    . ([scriptblock]::Create((Import-FunctionUnderTest $name)))
}

$script:TestRoot = Join-Path $env:TEMP ("WinServerSetup-V2RayN-{0}" -f ([guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null

$script:CacheDir = Join-Path $script:TestRoot "cache"
New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null

$script:Messages = New-Object System.Collections.Generic.List[string]
$script:DownloadSucceeds = $true
$script:FailPayloadMove = $false
$script:FixtureZip = $null
$script:SkipReasons = New-Object System.Collections.Generic.List[string]

function Assert-UnderTestRoot {
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [System.IO.Path]::GetFullPath($script:TestRoot).TrimEnd('\')
    if (-not ($full -eq $root -or $full.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "SAFETY: refused a destructive operation outside the suite temp root: $full"
    }
}

# ---- Destructive-cmdlet guards. Every delete/move must stay inside the suite's temp root. ----
function Remove-Item {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)][object[]]$InputObject,
        [string[]]$LiteralPath,
        [string[]]$Path,
        [switch]$Recurse,
        [switch]$Force
    )
    process {
        $targets = New-Object System.Collections.Generic.List[string]
        foreach ($item in @($LiteralPath)) { if ($item) { $targets.Add([string]$item) | Out-Null } }
        foreach ($item in @($Path)) { if ($item) { $targets.Add([string]$item) | Out-Null } }
        foreach ($item in @($InputObject)) { if ($item) { $targets.Add([string]$item.FullName) | Out-Null } }
        foreach ($target in $targets) {
            Assert-UnderTestRoot $target
            Microsoft.PowerShell.Management\Remove-Item -LiteralPath $target -Recurse:$Recurse -Force:$Force -ErrorAction SilentlyContinue
        }
    }
}

function Move-Item {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)][object[]]$InputObject,
        [string]$LiteralPath,
        [string]$Path,
        [string]$Destination,
        [switch]$Force
    )
    process {
        Assert-UnderTestRoot $Destination
        if ($InputObject) {
            # The payload move is the only pipeline-fed call; failing it exercises the
            # "update died after user data was set aside" recovery path.
            if ($script:FailPayloadMove) { throw "Simulated payload move failure." }
            foreach ($item in @($InputObject)) {
                Assert-UnderTestRoot ([string]$item.FullName)
                Microsoft.PowerShell.Management\Move-Item -LiteralPath ([string]$item.FullName) -Destination $Destination -Force:$Force
            }
            return
        }
        $source = if ([string]::IsNullOrWhiteSpace($LiteralPath)) { $Path } else { $LiteralPath }
        Assert-UnderTestRoot $source
        Microsoft.PowerShell.Management\Move-Item -LiteralPath $source -Destination $Destination -Force:$Force
    }
}

# ---- Collaborators from WinServerSetup.ps1 that the v2rayN path calls into. ----
function Write-Info { param($Message) $script:Messages.Add("INFO $Message") | Out-Null }
function Write-Ok { param($Message) $script:Messages.Add("OK $Message") | Out-Null }
function Write-Warn { param($Message) $script:Messages.Add("WARN $Message") | Out-Null }
function Set-StepSkipped { param($Reason) $script:SkipReasons.Add([string]$Reason) | Out-Null }
function New-Shortcut { param($TargetPath, $ShortcutPath, $WorkingDirectory, $Description) }
function Get-DownloadCachePath { return $script:CacheDir }
function Get-SafeDownloadCacheFilePath {
    param([Parameter(Mandatory)][string]$FileName)
    return (Join-Path $script:CacheDir (Split-Path -Leaf $FileName))
}
function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (Test-Path -LiteralPath $Path) { return }
    Assert-UnderTestRoot $Path
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

# ---- Network boundary stubs. ----
function Invoke-RestMethod {
    param($Uri, [switch]$UseBasicParsing, $TimeoutSec, $Headers)
    return [pscustomobject]@{
        tag_name = 'v7.0.0'
        assets   = @([pscustomobject]@{
                name                 = 'v2rayN-windows-64.zip'
                browser_download_url = 'https://github.com/2dust/v2rayN/releases/download/v7.0.0/v2rayN-windows-64.zip'
            })
    }
}
function Invoke-DownloadFile {
    param($Url, $Destination, $ExpectedSha256, $AllowedHosts, $RetryCount)
    if (-not $script:DownloadSucceeds) { return $false }
    Assert-UnderTestRoot $Destination
    Copy-Item -LiteralPath $script:FixtureZip -Destination $Destination -Force
    return $true
}

# ---- Test helpers. ----
function New-PayloadZip {
    param([Parameter(Mandatory)][hashtable]$Files, [Parameter(Mandatory)][string]$Name)
    $stage = Join-Path $script:TestRoot ("fixture-{0}" -f ([guid]::NewGuid().ToString("N").Substring(0, 8)))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($relative in $Files.Keys) {
        $full = Join-Path $stage $relative
        $parent = Split-Path -Parent $full
        if (-not [System.IO.Directory]::Exists($parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [System.IO.File]::WriteAllText($full, [string]$Files[$relative], [System.Text.UTF8Encoding]::new($false))
    }
    $zip = Join-Path $script:TestRoot ("{0}.zip" -f $Name)
    if ([System.IO.File]::Exists($zip)) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
    Remove-Item -LiteralPath $stage -Recurse -Force
    return $zip
}

function New-InstallRoot {
    param([string]$Name)
    $path = Join-Path $script:TestRoot $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Set-V2RayNConfig {
    param(
        [string]$InstallDir,
        [string]$FinalFolderName = 'V2rayN',
        [string[]]$Preserve = @('guiNDB.db', 'guiConfigs', 'config.json')
    )
    $Global:Config = [pscustomobject]@{
        v2rayN = [pscustomobject]@{
            enabled                 = $true
            githubRepo              = '2dust/v2rayN'
            assetNameRegex          = '^v2rayN-windows-64\.zip$'
            installDir              = $InstallDir
            finalFolderName         = $FinalFolderName
            exeName                 = 'v2rayN.exe'
            preserveUserDataPaths   = $Preserve
            createDesktopShortcut   = $false
            createStartMenuShortcut = $false
        }
    }
}

function Write-TestFile {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not [System.IO.Directory]::Exists($parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Get-Text { param([string]$Path) return [System.IO.File]::ReadAllText($Path) }
function Test-Exists { param([string]$Path) return ([System.IO.File]::Exists($Path) -or [System.IO.Directory]::Exists($Path)) }
function Get-StageLeftovers { return @([System.IO.Directory]::GetDirectories($script:CacheDir, 'v2rayN-stage-*')) }
function Get-KeepLeftovers { return @([System.IO.Directory]::GetDirectories($script:CacheDir, 'v2rayN-keep-*')) }
function Reset-Run {
    $script:Messages.Clear()
    $script:DownloadSucceeds = $true
    $script:FailPayloadMove = $false
}
function Get-Messages { return ($script:Messages -join " | ") }

try {
    # ---- 1. The unsafe-target predicate itself. ----
    Assert-Equal $true  (Test-UnsafeReplaceTarget -Path 'C:\') "A drive root must be refused."
    Assert-Equal $true  (Test-UnsafeReplaceTarget -Path $env:SystemRoot) "The Windows directory must be refused."
    Assert-Equal $true  (Test-UnsafeReplaceTarget -Path $env:ProgramFiles) "Program Files must be refused."
    Assert-Equal $false (Test-UnsafeReplaceTarget -Path (Join-Path $script:TestRoot 'app\V2rayN')) "An ordinary application folder must be allowed."

    # ---- 2. Fresh install: the payload lands in the install folder. ----
    Reset-Run
    $script:FixtureZip = New-PayloadZip -Name 'flat' -Files @{
        'v2rayN.exe' = 'new-exe'
        'core.dll'   = 'new-core'
    }
    $installRoot = New-InstallRoot 'fresh'
    Set-V2RayNConfig -InstallDir $installRoot
    Install-V2RayN
    $finalDir = Join-Path $installRoot 'V2rayN'
    Assert-True (Test-Exists (Join-Path $finalDir 'v2rayN.exe')) ("The executable must be installed. Messages: {0}" -f (Get-Messages))
    Assert-Equal 'new-exe' (Get-Text (Join-Path $finalDir 'v2rayN.exe')) "The installed executable must be the downloaded payload."
    Assert-True (Test-Exists (Join-Path $finalDir 'core.dll')) "The rest of the payload must be installed too."
    Assert-Equal 0 @(Get-StageLeftovers).Count "Staging must be cleaned after a successful install."

    # ---- 3. LOAD-BEARING: an upgrade preserves user data and drops obsolete binaries. ----
    Reset-Run
    $installRoot = New-InstallRoot 'upgrade'
    $finalDir = Join-Path $installRoot 'V2rayN'
    Write-TestFile (Join-Path $finalDir 'guiNDB.db') 'user-database-v1'
    Write-TestFile (Join-Path $finalDir 'guiConfigs\sub.txt') 'user-subscription-v1'
    Write-TestFile (Join-Path $finalDir 'oldbinary.dll') 'obsolete-binary'
    Write-TestFile (Join-Path $finalDir 'v2rayN.exe') 'old-exe'
    Set-V2RayNConfig -InstallDir $installRoot
    Install-V2RayN
    Assert-True (Test-Exists (Join-Path $finalDir 'guiNDB.db')) ("User data must survive an upgrade. Messages: {0}" -f (Get-Messages))
    Assert-Equal 'user-database-v1' (Get-Text (Join-Path $finalDir 'guiNDB.db')) "Preserved user data must keep its original contents."
    Assert-True (Test-Exists (Join-Path $finalDir 'guiConfigs\sub.txt')) "A preserved DIRECTORY must survive with its contents."
    Assert-Equal 'user-subscription-v1' (Get-Text (Join-Path $finalDir 'guiConfigs\sub.txt')) "Preserved directory contents must be unchanged."
    Assert-True (-not (Test-Exists (Join-Path $finalDir 'oldbinary.dll'))) "An obsolete binary from an earlier release must NOT linger after an upgrade."
    Assert-Equal 'new-exe' (Get-Text (Join-Path $finalDir 'v2rayN.exe')) "The executable must be replaced by the new payload."
    Assert-Equal 0 @(Get-StageLeftovers).Count "Staging must be cleaned after an upgrade."
    Assert-Equal 0 @(Get-KeepLeftovers).Count "The preserve directory must be cleaned once its contents are restored."

    # ---- 4. The payload is located by the executable, not by the first top-level directory. ----
    Reset-Run
    $script:FixtureZip = New-PayloadZip -Name 'nested' -Files @{
        'aaa-first\readme.txt'        = 'decoy-that-sorts-first'
        'zz-payload\bin\v2rayN.exe'   = 'nested-exe'
        'zz-payload\bin\helper.dll'   = 'nested-helper'
    }
    $installRoot = New-InstallRoot 'nested'
    Set-V2RayNConfig -InstallDir $installRoot
    Install-V2RayN
    $finalDir = Join-Path $installRoot 'V2rayN'
    Assert-Equal 'nested-exe' (Get-Text (Join-Path $finalDir 'v2rayN.exe')) ("The exe must come from the folder that actually contains it. Messages: {0}" -f (Get-Messages))
    Assert-True (Test-Exists (Join-Path $finalDir 'helper.dll')) "The payload folder's siblings must be installed alongside the exe."
    Assert-True (-not (Test-Exists (Join-Path $finalDir 'readme.txt'))) "The alphabetically first top-level folder must not be treated as the payload."
    Assert-True (-not (Test-Exists (Join-Path $finalDir 'aaa-first'))) "The decoy folder must not be installed."

    # ---- 5. A stale executable already in the install folder is never selected. ----
    Reset-Run
    $script:FixtureZip = New-PayloadZip -Name 'flat2' -Files @{
        'v2rayN.exe' = 'new-exe'
        'core.dll'   = 'new-core'
    }
    $installRoot = New-InstallRoot 'stale'
    $finalDir = Join-Path $installRoot 'V2rayN'
    Write-TestFile (Join-Path $finalDir 'old\deep\v2rayN.exe') 'stale-exe'
    Write-TestFile (Join-Path $finalDir 'guiNDB.db') 'keep-me'
    Set-V2RayNConfig -InstallDir $installRoot
    Install-V2RayN
    Assert-Equal 'new-exe' (Get-Text (Join-Path $finalDir 'v2rayN.exe')) ("The resolved exe must be the new payload, not a stale copy. Messages: {0}" -f (Get-Messages))
    Assert-True (-not (Test-Exists (Join-Path $finalDir 'old'))) "The stale tree must be removed by the payload replacement."
    Assert-Equal 'keep-me' (Get-Text (Join-Path $finalDir 'guiNDB.db')) "User data must still be preserved when a stale exe was present."

    # ---- 6. Staging is cleaned on the failure path too. ----
    Reset-Run
    $script:DownloadSucceeds = $false
    $installRoot = New-InstallRoot 'faileddownload'
    Set-V2RayNConfig -InstallDir $installRoot
    Install-V2RayN
    Assert-True ((Get-Messages) -match 'download failed') ("A failed download must be reported. Messages: {0}" -f (Get-Messages))
    Assert-Equal 0 @(Get-StageLeftovers).Count "Staging must be cleaned after a failed download."
    Assert-True (-not (Test-Exists (Join-Path $installRoot 'V2rayN\v2rayN.exe'))) "A failed download must not install anything."

    # ---- 7. An unsafe install target is refused before anything is deleted. ----
    # finalDir resolves to the string 'C:\'. The guard must reject it; no delete may run.
    Reset-Run
    Set-V2RayNConfig -InstallDir 'C:' -FinalFolderName '\'
    Install-V2RayN
    Assert-True ((Get-Messages) -match 'Refusing to replace an unsafe install path') `
        ("A drive-root install target must be refused. Messages: {0}" -f (Get-Messages))
    Assert-Equal 0 @(Get-StageLeftovers).Count "Staging must be cleaned after the unsafe-target refusal."

    # ---- 8. A failure after preservation leaves the user's data recoverable, and says where. ----
    Reset-Run
    $installRoot = New-InstallRoot 'recovery'
    $finalDir = Join-Path $installRoot 'V2rayN'
    Write-TestFile (Join-Path $finalDir 'guiNDB.db') 'irreplaceable-user-data'
    Write-TestFile (Join-Path $finalDir 'v2rayN.exe') 'old-exe'
    Set-V2RayNConfig -InstallDir $installRoot
    $script:FailPayloadMove = $true
    Install-V2RayN
    $script:FailPayloadMove = $false
    $recoveryMessage = @($script:Messages | Where-Object { $_ -match 'left for manual recovery at' }) | Select-Object -First 1
    Assert-True ($null -ne $recoveryMessage) ("A mid-update failure must tell the user where their data went. Messages: {0}" -f (Get-Messages))
    $keepDirs = @(Get-KeepLeftovers)
    Assert-Equal 1 $keepDirs.Count "The preserve directory must be left in place for recovery."
    Assert-True ($recoveryMessage -match [regex]::Escape($keepDirs[0])) "The warning must name the actual preserve directory."
    Assert-Equal 'irreplaceable-user-data' (Get-Text (Join-Path $keepDirs[0] 'guiNDB.db')) "The preserved user data must be intact and recoverable."
    Assert-Equal 0 @(Get-StageLeftovers).Count "Staging must be cleaned even when the payload move fails."
    Remove-Item -LiteralPath $keepDirs[0] -Recurse -Force

    # ---- 9. Disabled in config is a skip, not an install. ----
    Reset-Run
    $installRoot = New-InstallRoot 'disabled'
    Set-V2RayNConfig -InstallDir $installRoot
    $Global:Config.v2rayN.enabled = $false
    $script:SkipReasons.Clear()
    Install-V2RayN
    Assert-Equal 1 $script:SkipReasons.Count "A disabled v2rayN step must be recorded as skipped."
    Assert-True (-not (Test-Exists (Join-Path $installRoot 'V2rayN'))) "A disabled step must not create the install folder."

    Write-Host "PASS v2rayN update preserves user data, drops stale binaries, resolves the payload by executable, and cleans staging on every path."
} finally {
    $Global:Config = $null
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}
