<#
    M-08 regression suite: a requested runtime that fails to install must reach the FINAL EXIT CODE.

    Pre-fix defects, each pinned by a case below:
      M-08.a  Install-WingetRuntimePackage is the single funnel for every .NET Desktop, .NET Core
              and Visual C++ runtime, and it only ever wrote a warning. A non-zero winget exit
              code, an exception, and an install that could not be found afterwards all left
              RunStats untouched, so Invoke-FullSetup returned 0 and the process exited 0.
      M-08.b  Ensure-Winget returning $false made Install-WingetPackages,
              Install-DotNetDesktopRuntimes, Install-DotNetCoreRuntimes and
              Install-VisualCppRuntimes return silently. A run that installed nothing at all
              reported success.
      M-08.c  Install-DotNetFramework4Plus returned silently when the download failed, swallowed
              installer exceptions, and never re-read the NDP v4 release value - so an installer
              that exited 0 without installing anything was accepted on its own claim.
      M-08.d  Install-DotNetFramework35 warned and continued when the feature state could not be
              verified at all.
      M-08.e  Install-DotNetAspNetCoreRuntimes warned when the config requested a component the
              project refuses to install, and the run still succeeded.
      M-08.f  Install-WingetPackages, Install-LatestPowerShellFromGitHub and
              Install-WindowsTerminal each had at least one warning-only failure path for a
              component the shipped config explicitly requests.

    Nothing here downloads, runs an installer, or invokes winget or a Windows feature cmdlet.
    scripts\Download.ps1 and scripts\Install.ps1 are dot-sourced (both are definition-only
    modules by their own header contract) and every collaborator that would touch the network,
    the registry, a Windows feature or a process is redefined AFTERWARDS, so the later definition
    wins. Enable-WindowsOptionalFeature is replaced by a stub that throws, so a regression that
    routes around the shadows fails the suite instead of servicing the host.

    Fixture state lives in the $Global:M08 hashtable rather than in $script: variables because
    the stubs are built from a here-string: PSScriptAnalyzer cannot see reads inside a string and
    would report every switch as assigned-and-never-used.
#>
# -InstallScript targets an alternate copy so these tests can be replayed against a deliberately
# defective build to prove they still fail. CI and local runs use the default.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Start-Process, Get-Command and Invoke-RestMethod are shadowed deliberately so no installer, feature cmdlet or network call can run from a test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub signatures mirror production collaborators so parameter binding matches.')]
param([string]$InstallScript = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$installModule = if ([string]::IsNullOrWhiteSpace($InstallScript)) { Join-Path $projectRoot "scripts\Install.ps1" } else { $InstallScript }
$downloadModule = Join-Path $projectRoot "scripts\Download.ps1"
$consoleModule = Join-Path $projectRoot "scripts\Console.ps1"

. (Join-Path $PSScriptRoot '_Common.ps1')

# Invoke-RecordedSetupStep is extracted rather than dot-sourced: Console.ps1 also defines the
# themed writers, and those need the colour table that only WinServerSetup.ps1 initializes.
$tokens = $null
$parseErrors = $null
$consoleAst = [System.Management.Automation.Language.Parser]::ParseFile($consoleModule, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) "M-08: scripts\Console.ps1 must parse before the exit-code path can be tested."
$recordedStepText = Import-FunctionUnderTest 'Invoke-RecordedSetupStep' @($consoleAst)

$Global:M08Modules = @{ Download = $downloadModule; Install = $installModule }

# ---------------------------------------------------------------------------------------------
# Shared harness. Dot-sourced in-process below and embedded verbatim into the end-to-end child
# script, so both prove the same production functions against the same collaborators.
# ---------------------------------------------------------------------------------------------
$harness = @'
. $Global:M08Modules.Download
. $Global:M08Modules.Install

function Reset-RuntimeRun {
    $Global:M08 = @{
        Messages            = New-Object System.Collections.Generic.List[string]
        PendingReboots      = New-Object System.Collections.Generic.List[string]
        InstalledIds        = New-Object System.Collections.Generic.List[string]
        WingetAvailable     = $true
        WingetExitCode      = 0
        WingetRegisters     = $true
        WingetThrows        = $false
        DownloadSucceeds    = $true
        MsiExitCode         = 0
        ReleaseValue        = 0
        ReleaseAfterInstall = 533320
        Framework35State    = $true
        PowerShell7Path     = 'C:\Program Files\PowerShell\7\pwsh.exe'
        TerminalPresent     = $true
        GitHubThrows        = $false
    }
    $Global:RunStats = [pscustomobject]@{
        StartedTasks   = New-Object System.Collections.Generic.List[string]
        CompletedTasks = New-Object System.Collections.Generic.List[string]
        FailedTasks    = New-Object System.Collections.Generic.List[string]
        SkippedTasks   = New-Object System.Collections.Generic.List[string]
        Warnings       = New-Object System.Collections.Generic.List[string]
        InstalledApps  = New-Object System.Collections.Generic.List[string]
        FailedApps     = New-Object System.Collections.Generic.List[string]
        RebootRequired = $false
    }
    $Global:CurrentStepSkipReason = $null
}

function Set-RuntimeConfig {
    param([hashtable]$Runtimes = @{})
    $values = @{
        installDotNetFramework35         = $false
        installDotNetFramework4Plus      = $false
        installDotNetDesktopRuntimes     = $false
        installDotNetCoreRuntimes        = $false
        installDotNetAspNetCoreRuntimes  = $false
        installVisualCppRuntimes         = $false
        installLegacyVisualCppRuntimes   = $false
        includeUnsupportedDotNetVersions = $false
        dotNetFramework481OfflineUrl     = 'https://go.microsoft.com/fwlink/?linkid=2203305'
        dotNetFramework481ExpectedSha256 = ''
    }
    foreach ($key in @($Runtimes.Keys)) { $values[$key] = $Runtimes[$key] }
    $Global:Config = [pscustomobject]@{ runtimes = [pscustomobject]$values }
}

function Get-M08Report {
    return ("failed=[{0}] installed=[{1}] messages=[{2}]" -f `
        ($Global:RunStats.FailedApps -join ', '), ($Global:RunStats.InstalledApps -join ', '), ($Global:M08.Messages -join ' | '))
}

# ---- Console and run-state collaborators. ----
function Write-Info { param($Message) $Global:M08.Messages.Add("INFO $Message") | Out-Null }
function Write-Ok { param($Message) $Global:M08.Messages.Add("OK $Message") | Out-Null }
function Write-Warn { param($Message) $Global:M08.Messages.Add("WARN $Message") | Out-Null }
function Write-Fail { param($Message) $Global:M08.Messages.Add("FAIL $Message") | Out-Null }
function Write-StructuredLog { param($Level, $Message) }
function Write-Section { param($Message) }
function Set-StepSkipped { param($Reason) $Global:M08.Messages.Add("SKIP $Reason") | Out-Null }
function Set-PendingReboot { param($Reason) $Global:M08.PendingReboots.Add([string]$Reason) | Out-Null }

# ---- winget boundary. ----
function Ensure-Winget { return $Global:M08.WingetAvailable }
function Get-WingetExecutable { return 'C:\Fake\winget.exe' }
function Test-WingetPackageInstalled {
    param([Parameter(Mandatory)][string]$Id)
    return ($Global:M08.InstalledIds -contains $Id)
}
function Invoke-LoggedCommand {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @(), [string]$DisplayName = "")
    if ($Global:M08.WingetThrows) { throw "Simulated winget transport failure." }
    $arguments = @($Arguments)
    if ($Global:M08.WingetExitCode -eq 0 -and $Global:M08.WingetRegisters -and ($arguments -contains 'install')) {
        $index = [array]::IndexOf($arguments, '--id')
        if ($index -ge 0 -and ($index + 1) -lt $arguments.Count) {
            $Global:M08.InstalledIds.Add([string]$arguments[$index + 1]) | Out-Null
        }
    }
    return [pscustomobject]@{ ExitCode = $Global:M08.WingetExitCode; Output = @() }
}

# ---- Download boundary. ----
function Get-SafeDownloadCacheFilePath {
    param([Parameter(Mandatory)][string]$FileName)
    return (Join-Path $env:TEMP (Split-Path -Leaf $FileName))
}
function Invoke-DownloadFile {
    param($Url, $Destination, $RetryCount, $MinimumBytes, $ExpectedSha256, $RequireValidSignature, $AllowedHosts, $AllowedSignerSubjects, $TimeoutSeconds)
    return $Global:M08.DownloadSucceeds
}
function Invoke-RestMethod {
    param($Uri, [switch]$UseBasicParsing, $TimeoutSec, $Headers)
    if ($Global:M08.GitHubThrows) { throw "Simulated GitHub release query failure." }
    return [pscustomobject]@{
        tag_name = 'v7.5.0'
        assets   = @([pscustomobject]@{
                name                 = 'PowerShell-7.5.0-win-x64.msi'
                browser_download_url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.5.0/PowerShell-7.5.0-win-x64.msi'
            })
    }
}

# ---- Independent verification sources. ----
function Get-DotNetFrameworkReleaseValue { return [int]$Global:M08.ReleaseValue }
function Test-DotNetFramework35Enabled { return $Global:M08.Framework35State }
function Get-PowerShellCoreVersion { return $null }
function Get-PowerShell7ExePath { return $Global:M08.PowerShell7Path }
function Test-WindowsTerminalInstalled { return $Global:M08.TerminalPresent }
function Set-WindowsTerminalAsDefault { }
function Set-WindowsTerminalPowerShell7Default { }

# ---- Nothing may start a process or service a Windows feature. ----
function Start-Process {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$FilePath,
        $ArgumentList,
        [switch]$Wait,
        [switch]$PassThru,
        $WindowStyle,
        [switch]$NoNewWindow
    )
    # Running the installer is what raises the NDP v4 release value on a real machine, so the
    # fixture models that order: the value only moves when the installer actually ran.
    $Global:M08.ReleaseValue = $Global:M08.ReleaseAfterInstall
    return [pscustomobject]@{ ExitCode = $Global:M08.MsiExitCode }
}
function Get-Command {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string[]]$Name, $CommandType)
    if (@($Name) -contains 'Install-WindowsFeature') { return [pscustomobject]@{ Name = 'Install-WindowsFeature' } }
    return $null
}
function Install-WindowsFeature {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name)
    return [pscustomobject]@{ RestartNeeded = 'No' }
}
function Enable-WindowsOptionalFeature {
    [CmdletBinding()]
    param([switch]$Online, [string]$FeatureName, [switch]$All, [switch]$NoRestart)
    throw "SAFETY: a test must never service a real Windows optional feature."
}
'@

. ([scriptblock]::Create($harness))

# =============================================================================================
# 1. Install-WingetRuntimePackage - the verification contract every winget runtime funnels into.
# =============================================================================================
Reset-RuntimeRun
Install-WingetRuntimePackage -Name '.NET Runtime 9 x64' -Id 'Microsoft.DotNet.Runtime.9'
Assert-Equal 1 $Global:RunStats.InstalledApps.Count ("M-08: a runtime that installs and is detectable afterwards must be recorded as installed. {0}" -f (Get-M08Report))
Assert-Equal 0 $Global:RunStats.FailedApps.Count ("M-08: a verified runtime install must not be recorded as failed. {0}" -f (Get-M08Report))

Reset-RuntimeRun
$Global:M08.WingetExitCode = 1
Install-WingetRuntimePackage -Name '.NET Runtime 9 x64' -Id 'Microsoft.DotNet.Runtime.9'
Assert-Equal 1 $Global:RunStats.FailedApps.Count ("M-08: a non-zero winget exit code for a requested runtime must be recorded as a failed app, not only warned about. {0}" -f (Get-M08Report))
Assert-Equal '.NET Runtime 9 x64' $Global:RunStats.FailedApps[0] "M-08: the failed runtime must be recorded under its configured name."
Assert-Equal 0 $Global:RunStats.InstalledApps.Count "M-08: a failed runtime must not also be reported as installed."

Reset-RuntimeRun
$Global:M08.WingetRegisters = $false
Install-WingetRuntimePackage -Name '.NET Runtime 9 x64' -Id 'Microsoft.DotNet.Runtime.9'
Assert-Equal 0 $Global:RunStats.InstalledApps.Count ("M-08: winget exit code 0 is the installer's own claim and must not count as installed. {0}" -f (Get-M08Report))
Assert-Equal 1 $Global:RunStats.FailedApps.Count ("M-08: a runtime that is not detectable after a successful install must be recorded as failed. {0}" -f (Get-M08Report))

Reset-RuntimeRun
$Global:M08.WingetThrows = $true
Install-WingetRuntimePackage -Name '.NET Runtime 9 x64' -Id 'Microsoft.DotNet.Runtime.9'
Assert-Equal 1 $Global:RunStats.FailedApps.Count ("M-08: an exception while installing a requested runtime must be recorded as failed. {0}" -f (Get-M08Report))

# An already-present runtime is still accounted for, so it can never look unattempted.
Reset-RuntimeRun
$Global:M08.InstalledIds.Add('Microsoft.DotNet.Runtime.9') | Out-Null
Install-WingetRuntimePackage -Name '.NET Runtime 9 x64' -Id 'Microsoft.DotNet.Runtime.9'
Assert-Equal 1 $Global:RunStats.InstalledApps.Count ("M-08: an already-installed runtime must still be recorded as installed. {0}" -f (Get-M08Report))

# =============================================================================================
# 2. WinGet unavailable must fail every requested runtime, never skip them silently.
# =============================================================================================
$unavailableCases = @(
    @{ Function = 'Install-DotNetDesktopRuntimes'; Flag = 'installDotNetDesktopRuntimes'; Expected = 3 }
    @{ Function = 'Install-DotNetCoreRuntimes';    Flag = 'installDotNetCoreRuntimes';    Expected = 3 }
    @{ Function = 'Install-VisualCppRuntimes';     Flag = 'installVisualCppRuntimes';     Expected = 2 }
)
foreach ($case in $unavailableCases) {
    Reset-RuntimeRun
    Set-RuntimeConfig @{ $case.Flag = $true }
    $Global:M08.WingetAvailable = $false
    & $case.Function
    Assert-Equal $case.Expected $Global:RunStats.FailedApps.Count `
        ("M-08: with WinGet unavailable every runtime requested by {0} must be recorded as failed, not silently skipped. {1}" -f $case.Function, (Get-M08Report))
    Assert-Equal 0 $Global:RunStats.InstalledApps.Count `
        ("M-08: {0} must not report anything installed when WinGet is unavailable. {1}" -f $case.Function, (Get-M08Report))
}

# The same functions must still install and verify the whole requested set when winget works.
Reset-RuntimeRun
Set-RuntimeConfig @{ installDotNetDesktopRuntimes = $true }
Install-DotNetDesktopRuntimes
Assert-Equal 3 $Global:RunStats.InstalledApps.Count ("M-08: every requested .NET Desktop runtime must be verified and recorded. {0}" -f (Get-M08Report))
Assert-Equal 0 $Global:RunStats.FailedApps.Count ("M-08: a healthy runtime pass must record no failures. {0}" -f (Get-M08Report))

# The unsupported-versions opt-in widens the requested set, and all of it must be verified.
Reset-RuntimeRun
Set-RuntimeConfig @{ installDotNetCoreRuntimes = $true; includeUnsupportedDotNetVersions = $true }
Install-DotNetCoreRuntimes
Assert-Equal 6 $Global:RunStats.InstalledApps.Count ("M-08: opting into unsupported .NET versions must verify all six requested runtimes. {0}" -f (Get-M08Report))

# =============================================================================================
# 3. .NET Framework 4.8.1 - download, installer and post-install verification.
# =============================================================================================
Reset-RuntimeRun
Set-RuntimeConfig @{ installDotNetFramework4Plus = $true }
$Global:M08.DownloadSucceeds = $false
Install-DotNetFramework4Plus
Assert-Equal 1 $Global:RunStats.FailedApps.Count ("M-08: a .NET Framework 4.8.1 download failure must be recorded as failed, not returned from silently. {0}" -f (Get-M08Report))
Assert-Equal '.NET Framework 4.8.1' $Global:RunStats.FailedApps[0] "M-08: the failed .NET Framework download must be recorded under its runtime name."

Reset-RuntimeRun
Set-RuntimeConfig @{ installDotNetFramework4Plus = $true }
$Global:M08.MsiExitCode = 1603
$Global:M08.ReleaseAfterInstall = 0
Install-DotNetFramework4Plus
Assert-Equal 1 $Global:RunStats.FailedApps.Count ("M-08: a fatal .NET Framework 4.8.1 installer exit code must be recorded as failed. {0}" -f (Get-M08Report))

Reset-RuntimeRun
Set-RuntimeConfig @{ installDotNetFramework4Plus = $true }
$Global:M08.ReleaseAfterInstall = 0
Install-DotNetFramework4Plus
Assert-Equal 0 $Global:RunStats.InstalledApps.Count ("M-08: installer exit code 0 without a raised NDP v4 release value must not count as installed. {0}" -f (Get-M08Report))
Assert-Equal 1 $Global:RunStats.FailedApps.Count ("M-08: a .NET Framework 4.8.1 install that cannot be independently verified must be recorded as failed. {0}" -f (Get-M08Report))

Reset-RuntimeRun
Set-RuntimeConfig @{ installDotNetFramework4Plus = $true }
Install-DotNetFramework4Plus
Assert-Equal 1 $Global:RunStats.InstalledApps.Count ("M-08: a verified .NET Framework 4.8.1 install must be recorded as installed. {0}" -f (Get-M08Report))
Assert-Equal 0 $Global:RunStats.FailedApps.Count ("M-08: a verified .NET Framework 4.8.1 install must not be recorded as failed. {0}" -f (Get-M08Report))

# 3010 is a success whose registry evidence only settles after the tracked restart.
Reset-RuntimeRun
Set-RuntimeConfig @{ installDotNetFramework4Plus = $true }
$Global:M08.MsiExitCode = 3010
$Global:M08.ReleaseAfterInstall = 0
Install-DotNetFramework4Plus
Assert-Equal 1 $Global:RunStats.InstalledApps.Count ("M-08: a 3010 install is a success whose verification is deferred to the tracked reboot. {0}" -f (Get-M08Report))
Assert-Equal 1 $Global:M08.PendingReboots.Count "M-08: installer exit code 3010 must flag the pending reboot."

# An already-current machine is still accounted for.
Reset-RuntimeRun
Set-RuntimeConfig @{ installDotNetFramework4Plus = $true }
$Global:M08.ReleaseValue = 533320
Install-DotNetFramework4Plus
Assert-Equal 1 $Global:RunStats.InstalledApps.Count ("M-08: an already-current .NET Framework 4.8.1 must be recorded as installed. {0}" -f (Get-M08Report))

# =============================================================================================
# 4. .NET Framework 3.5 - the feature state is the verification contract.
# =============================================================================================
Reset-RuntimeRun
Set-RuntimeConfig @{ installDotNetFramework35 = $true }
$Global:M08.Framework35State = $null
Install-DotNetFramework35
Assert-Equal 1 $Global:RunStats.FailedApps.Count ("M-08: a .NET Framework 3.5 install whose state cannot be verified at all must be recorded as failed. {0}" -f (Get-M08Report))

Reset-RuntimeRun
Set-RuntimeConfig @{ installDotNetFramework35 = $true }
$Global:M08.Framework35State = $false
Install-DotNetFramework35
Assert-Equal 1 $Global:RunStats.FailedApps.Count ("M-08: .NET Framework 3.5 that does not report enabled after install must be recorded as failed. {0}" -f (Get-M08Report))

Reset-RuntimeRun
Set-RuntimeConfig @{ installDotNetFramework35 = $true }
Install-DotNetFramework35
Assert-Equal 1 $Global:RunStats.InstalledApps.Count ("M-08: an enabled .NET Framework 3.5 feature must be recorded as installed. {0}" -f (Get-M08Report))
Assert-Equal 0 $Global:RunStats.FailedApps.Count ("M-08: an enabled .NET Framework 3.5 feature must not be recorded as failed. {0}" -f (Get-M08Report))

# =============================================================================================
# 5. ASP.NET Core - refused by project policy, and therefore NOT marked optional.
# =============================================================================================
$shippedConfig = Get-Content -LiteralPath (Join-Path $projectRoot "WinServerSetup.config.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (-not [bool]$shippedConfig.runtimes.installDotNetAspNetCoreRuntimes) `
    "M-08: the shipped config must not request ASP.NET Core; it is refused by project policy (item 31), not silently optional."

Reset-RuntimeRun
Set-RuntimeConfig @{ installDotNetAspNetCoreRuntimes = $true }
Install-DotNetAspNetCoreRuntimes
Assert-Equal 1 $Global:RunStats.FailedApps.Count ("M-08: a component the config requests but project policy refuses must fail the run, not just warn. {0}" -f (Get-M08Report))

Reset-RuntimeRun
Set-RuntimeConfig @{}
Install-DotNetAspNetCoreRuntimes
Assert-Equal 0 $Global:RunStats.FailedApps.Count ("M-08: the policy no-op must not fail a run that never requested ASP.NET Core. {0}" -f (Get-M08Report))

# =============================================================================================
# 6. Install-WingetPackages - the same contract for requested applications.
# =============================================================================================
function Set-WingetPackageConfig {
    param([object[]]$Packages)
    $Global:Config = [pscustomobject]@{
        winget = [pscustomobject]@{
            interactiveInstallers   = $false
            upgradeExistingPackages = $false
            packages                = @($Packages)
        }
    }
}
$samplePackages = @(
    [pscustomobject]@{ enabled = $true;  name = '7-Zip';    id = '7zip.7zip' }
    [pscustomobject]@{ enabled = $false; name = 'Disabled'; id = 'Vendor.Disabled' }
)

Reset-RuntimeRun
Set-WingetPackageConfig -Packages $samplePackages
$Global:M08.WingetAvailable = $false
Install-WingetPackages
Assert-Equal 1 $Global:RunStats.FailedApps.Count ("M-08: with WinGet unavailable every enabled package must be recorded as failed, not silently skipped. {0}" -f (Get-M08Report))
Assert-Equal '7-Zip' $Global:RunStats.FailedApps[0] "M-08: a package that could not be attempted must be recorded under its configured name."

Reset-RuntimeRun
Set-WingetPackageConfig -Packages $samplePackages
$Global:M08.WingetRegisters = $false
Install-WingetPackages
Assert-Equal 0 $Global:RunStats.InstalledApps.Count ("M-08: a package that reports success but is not detectable afterwards must not count as installed. {0}" -f (Get-M08Report))
Assert-Equal 1 $Global:RunStats.FailedApps.Count ("M-08: a package that reports success but is not detectable afterwards must be recorded as failed. {0}" -f (Get-M08Report))

Reset-RuntimeRun
Set-WingetPackageConfig -Packages @([pscustomobject]@{ enabled = $true; name = 'Broken Entry'; id = '' })
Install-WingetPackages
Assert-Equal 1 $Global:RunStats.FailedApps.Count ("M-08: an enabled package with no id can never be installed and must be recorded as failed. {0}" -f (Get-M08Report))

Reset-RuntimeRun
Set-WingetPackageConfig -Packages $samplePackages
Install-WingetPackages
Assert-Equal 1 $Global:RunStats.InstalledApps.Count ("M-08: a verified package install must still be recorded as installed. {0}" -f (Get-M08Report))
Assert-Equal 0 $Global:RunStats.FailedApps.Count ("M-08: a verified package install must not be recorded as failed. {0}" -f (Get-M08Report))

# =============================================================================================
# 7. PowerShell 7 and Windows Terminal are requested by the shipped config too.
# =============================================================================================
$powerShellConfig = [pscustomobject]@{
    powershell = [pscustomobject]@{
        enabled                 = $true
        installLatestFromGitHub = $true
        githubRepo              = 'PowerShell/PowerShell'
        assetNameRegex          = '^PowerShell-.*-win-x64\.msi$'
        expectedSha256          = ''
        forceInstall            = $false
        interactiveInstaller    = $false
        msiArguments            = ''
        silentMsiArguments      = ''
    }
}

Reset-RuntimeRun
$Global:Config = $powerShellConfig
$Global:M08.DownloadSucceeds = $false
Install-LatestPowerShellFromGitHub
Assert-Equal 1 $Global:RunStats.FailedApps.Count ("M-08: a PowerShell 7 download failure must be recorded as failed, not returned from silently. {0}" -f (Get-M08Report))

Reset-RuntimeRun
$Global:Config = $powerShellConfig
$Global:M08.PowerShell7Path = $null
Install-LatestPowerShellFromGitHub
Assert-Equal 1 $Global:RunStats.FailedApps.Count ("M-08: a PowerShell 7 install that leaves no pwsh.exe must be recorded as failed. {0}" -f (Get-M08Report))

Reset-RuntimeRun
$Global:Config = $powerShellConfig
Install-LatestPowerShellFromGitHub
Assert-Equal 1 $Global:RunStats.InstalledApps.Count ("M-08: a verified PowerShell 7 install must be recorded as installed. {0}" -f (Get-M08Report))
Assert-Equal 0 $Global:RunStats.FailedApps.Count ("M-08: a verified PowerShell 7 install must not be recorded as failed. {0}" -f (Get-M08Report))

$terminalConfig = [pscustomobject]@{
    windowsTerminal = [pscustomobject]@{
        enabled                        = $true
        packageId                      = 'Microsoft.WindowsTerminal'
        interactiveInstaller           = $false
        setAsDefaultTerminal           = $false
        setPowerShell7AsDefaultProfile  = $false
    }
}

Reset-RuntimeRun
$Global:Config = $terminalConfig
$Global:M08.TerminalPresent = $false
Install-WindowsTerminal
Assert-Equal 1 $Global:RunStats.FailedApps.Count ("M-08: Windows Terminal that is not present after its install must be recorded as failed. {0}" -f (Get-M08Report))

Reset-RuntimeRun
$Global:Config = $terminalConfig
$Global:M08.WingetExitCode = 1
Install-WindowsTerminal
Assert-Equal 1 $Global:RunStats.FailedApps.Count ("M-08: a non-zero Windows Terminal install exit code must be recorded as failed. {0}" -f (Get-M08Report))

Reset-RuntimeRun
$Global:Config = $terminalConfig
Install-WindowsTerminal
Assert-Equal 1 $Global:RunStats.InstalledApps.Count ("M-08: a verified Windows Terminal install must be recorded as installed. {0}" -f (Get-M08Report))
Assert-Equal 0 $Global:RunStats.FailedApps.Count ("M-08: a verified Windows Terminal install must not be recorded as failed. {0}" -f (Get-M08Report))

# =============================================================================================
# 8. END TO END: every failure class must reach the process exit code.
#
# The child reproduces Invoke-FullSetup's real shape - a bare Invoke-RecordedSetupStep statement,
# then `return 1` when FailedTasks or FailedApps is non-empty - consumed by the entry point's
# `exit ([int]$exitCode)` expression. These are the assertions that fail on the pre-fix source.
# =============================================================================================
$childTemplate = @'
param(
    [Parameter(Mandatory)][string]$Scenario,
    [Parameter(Mandatory)][string]$DownloadModule,
    [Parameter(Mandatory)][string]$InstallModule
)
$ErrorActionPreference = 'Stop'
$Global:M08Modules = @{ Download = $DownloadModule; Install = $InstallModule }
__HARNESS__
__RECORDED_STEP__

Reset-RuntimeRun
Set-RuntimeConfig @{
    installDotNetFramework35     = $true
    installDotNetFramework4Plus  = $true
    installDotNetDesktopRuntimes = $true
}
switch ($Scenario) {
    'Success'                { }
    'WingetUnavailable'      { $Global:M08.WingetAvailable = $false }
    'WingetFailure'          { $Global:M08.WingetExitCode = 1 }
    'VerificationFailure'    { $Global:M08.WingetRegisters = $false }
    'DotNetDownloadFailure'  { $Global:M08.DownloadSucceeds = $false }
    'DotNetInstallerFailure' { $Global:M08.MsiExitCode = 1603; $Global:M08.ReleaseAfterInstall = 0 }
    default { throw "Unknown M-08 scenario: $Scenario" }
}

function Invoke-FakeFullSetup {
    Invoke-RecordedSetupStep -Name 'Install runtimes' -Action { Install-Runtimes }
    if ($Global:RunStats.FailedTasks.Count -gt 0 -or $Global:RunStats.FailedApps.Count -gt 0) { return 1 }
    return 0
}
$setupResult = @(Invoke-FakeFullSetup)
$exitCode = if ($setupResult.Count -gt 0) { $setupResult[-1] } else { 1 }
Write-Host ("M08 scenario={0} failedApps=[{1}]" -f $Scenario, ($Global:RunStats.FailedApps -join ', '))
exit ([int]$exitCode)
'@

# String.Replace, never -replace: in a replacement string `$_` expands to the ENTIRE input, and
# both the harness and the extracted function are full of $ tokens.
$childScript = $childTemplate.Replace('__HARNESS__', $harness).Replace('__RECORDED_STEP__', $recordedStepText)
$childPath = Join-Path $env:TEMP ("WinServerSetup-M08-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
$hostExe = (Get-Process -Id $PID).Path

$endToEndCases = @(
    @{ Scenario = 'Success';                ExpectedExitCode = 0; Why = 'a healthy runtime pass must still exit 0, so the failing cases below are not passing by accident' }
    @{ Scenario = 'DotNetDownloadFailure';  ExpectedExitCode = 1; Why = 'a .NET download failure must reach the final exit code' }
    @{ Scenario = 'DotNetInstallerFailure'; ExpectedExitCode = 1; Why = 'a .NET installer failure must reach the final exit code' }
    @{ Scenario = 'WingetFailure';          ExpectedExitCode = 1; Why = 'a winget failure must reach the final exit code' }
    @{ Scenario = 'VerificationFailure';    ExpectedExitCode = 1; Why = 'a post-install verification failure must reach the final exit code' }
    @{ Scenario = 'WingetUnavailable';      ExpectedExitCode = 1; Why = 'runtimes that could not even be attempted must reach the final exit code' }
)

try {
    Set-Content -LiteralPath $childPath -Value $childScript -Encoding UTF8
    foreach ($case in $endToEndCases) {
        & $hostExe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $childPath `
            -Scenario $case.Scenario -DownloadModule $downloadModule -InstallModule $installModule | Out-Null
        Assert-Equal $case.ExpectedExitCode $LASTEXITCODE `
            ("M-08 [{0}]: {1}." -f $case.Scenario, $case.Why)
    }
} finally {
    Remove-Item -LiteralPath $childPath -Force -ErrorAction SilentlyContinue
    $Global:Config = $null
    $Global:M08 = $null
    $Global:M08Modules = $null
}

Write-Host "PASS M-08 runtime install outcomes: every requested runtime is independently verified, and download, installer, winget, unavailable-winget and verification failures all reach the final exit code."
