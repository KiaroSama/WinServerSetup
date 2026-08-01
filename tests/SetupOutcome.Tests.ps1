<#
    Behavioral regression tests for full-setup outcome reporting in WinServerSetup.ps1.

    Pre-fix defects:
      O1  Invoke-RecordedSetupStep's catch ran `return $null`, which WRITES $null to the output
          stream. Invoke-FullSetup calls it as a bare statement ~24 times, so every failed step
          appended a $null to the function's output and its `return 1` became the last element of
          an array. `exit (@($null,1))` evaluates to 0 - verified on both hosts - so a setup with
          failed steps reported success to the caller and to CI.
      O2  RunStats.SkippedTasks was declared, displayed in the final summary and written to the
          structured log, but nothing ever added to it. Config-disabled steps returned early and
          were recorded as Completed, so a run that skipped most of its work looked fully done.
      O3  Get-InstalledRegistryDisplayName used `return` inside a ForEach-Object block, which
          exits only that iteration. The match leaked into the pipeline, the scan continued
          across all three hives, and the closing `return $null` appended a $null - so a hit was
          @("App Name", $null) and a miss was @($null), never an empty result.
      O4  Disable-StartupEntry deleted with -ErrorAction SilentlyContinue, then logged success and
          counted the entry unconditionally. A run where every delete failed still returned $true.

    Cmdlets are shadowed inside `& { ... }` blocks so the mocks stay local to the case under test
    and cannot affect the rest of this file.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Cmdlets are shadowed deliberately to drive the functions under test without touching the registry or disk.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock signatures mirror the real cmdlets so parameter binding matches production.')]
param([string]$MainScript = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$mainScript = if ([string]::IsNullOrWhiteSpace($MainScript)) { Join-Path $projectRoot "WinServerSetup.ps1" } else { $MainScript }

. (Join-Path $PSScriptRoot '_Common.ps1')

# WinServerSetup.ps1 dot-sources its function library from scripts\; search that whole partition
# so extraction by name keeps working wherever a function lives. $mainScript is searched first,
# so a -MainScript copy still shadows the on-disk original when replaying a defective build.
$setupSourceNames = @('WinServerSetup.ps1') + @('Console', 'Core', 'Download', 'Rdp', 'Install', 'SystemSettings', 'Maintenance' |
        ForEach-Object { "scripts\{0}.ps1" -f $_ })
$setupSourceFiles = @(@($mainScript) + @($setupSourceNames | ForEach-Object { Join-Path $projectRoot $_ })) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique

$setupAsts = @(foreach ($setupFile in $setupSourceFiles) {
        $tokens = $null
        $parseErrors = $null
        $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($setupFile, [ref]$tokens, [ref]$parseErrors)
        Assert-True ($parseErrors.Count -eq 0) "$setupFile must parse before outcome reporting can be tested."
        $fileAst
    })

function Get-FunctionText {
    param([string]$Name)
    foreach ($fileAst in $setupAsts) {
        $definition = $fileAst.FindAll({
                param($node)
                ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq $Name)
            }, $true) | Select-Object -First 1
        if ($null -ne $definition) { return $definition.Extent.Text }
    }
    throw "WinServerSetup.ps1 or its scripts\ modules must define $Name."
}

$harness = @'
$Global:RunStats = [pscustomobject]@{
    StartedTasks   = New-Object System.Collections.Generic.List[string]
    CompletedTasks = New-Object System.Collections.Generic.List[string]
    FailedTasks    = New-Object System.Collections.Generic.List[string]
    SkippedTasks   = New-Object System.Collections.Generic.List[string]
}
$Global:CurrentStepSkipReason = $null
function Write-StructuredLog { param($Level, $Message) }
function Write-Fail { param($Message) }
'@

$stepText = Get-FunctionText 'Invoke-RecordedSetupStep'
$skipText = Get-FunctionText 'Set-StepSkipped'

# ---- O1a: a failing step must emit nothing at all into the output stream. ----
. ([scriptblock]::Create($harness))
. ([scriptblock]::Create($stepText))
. ([scriptblock]::Create($skipText))

$emitted = @(Invoke-RecordedSetupStep -Name "failing" -Action { throw "boom" })
Assert-Equal 0 $emitted.Count `
    "A failed step must emit nothing; emitting `$null corrupts the caller's return value and zeroes the exit code."
Assert-Equal 1 $Global:RunStats.FailedTasks.Count "A failed step must be recorded in FailedTasks."

$emitted = @(Invoke-RecordedSetupStep -Name "clean" -Action { })
Assert-Equal 0 $emitted.Count "A successful non-PassThru step must not emit into the output stream."
Assert-Equal 1 $Global:RunStats.CompletedTasks.Count "A successful step must be recorded in CompletedTasks."

# ---- O2: a config-disabled step is Skipped, not Completed. ----
$null = Invoke-RecordedSetupStep -Name "switched off" -Action { Set-StepSkipped "disabled in config"; return }
Assert-Equal 1 $Global:RunStats.SkippedTasks.Count "A step that reports itself skipped must land in SkippedTasks."
Assert-Equal 1 $Global:RunStats.CompletedTasks.Count "A skipped step must NOT also be counted as Completed."
Assert-True ($Global:RunStats.SkippedTasks[0] -like '*switched off*') "The skip entry must name the step."

# The skip flag must not leak into the next step.
$null = Invoke-RecordedSetupStep -Name "after skip" -Action { }
Assert-Equal 1 $Global:RunStats.SkippedTasks.Count "The skip reason must be cleared between steps."
Assert-Equal 2 $Global:RunStats.CompletedTasks.Count "The step after a skipped one must count as Completed."

# ---- O1b: end-to-end exit-code propagation in the real call shape. ----
# Reproduces Invoke-FullSetup exactly: bare recorded-step statements, then `return 1`, consumed by
# the entry point's exit expression. This is the assertion that fails on the pre-fix source.
$childScript = @"
`$ErrorActionPreference = 'Stop'
$harness
$stepText
$skipText
function Fake-FullSetup {
    Invoke-RecordedSetupStep -Name 'ok'   -Action { }
    Invoke-RecordedSetupStep -Name 'bad'  -Action { throw 'boom' }
    Invoke-RecordedSetupStep -Name 'skip' -Action { Set-StepSkipped 'disabled in config'; return }
    if (`$Global:RunStats.FailedTasks.Count -gt 0) { return 1 }
    return 0
}
`$result = @(Fake-FullSetup)
`$code = if (`$result.Count -gt 0) { `$result[-1] } else { 1 }
exit ([int]`$code)
"@

$childPath = Join-Path $env:TEMP ("WinServerSetup-outcome-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
try {
    Set-Content -LiteralPath $childPath -Value $childScript -Encoding UTF8
    $hostExe = (Get-Process -Id $PID).Path
    & $hostExe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $childPath
    Assert-Equal 1 $LASTEXITCODE `
        "A full setup with a failed step must exit non-zero; a leaked `$null makes `exit` coerce the array to 0."
} finally {
    Remove-Item -LiteralPath $childPath -Force -ErrorAction SilentlyContinue
}

# ---- O3: Get-InstalledRegistryDisplayName must yield one scalar, or nothing at all. ----
# The fake hives key on the root path; each "subkey" carries its display name as its PSPath so the
# Get-ItemProperty shadow can hand it straight back.
$script:FakeHives = @{
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"              = @('Contoso Widget 3.1', 'Contoso Widget Helper')
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"  = @('Contoso Widget (x86)')
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"              = @('Contoso Widget (user)')
}
$script:HivesRead = New-Object System.Collections.Generic.List[string]
$registryText = Get-FunctionText 'Get-InstalledRegistryDisplayName'

& {
    function Get-ChildItem {
        [CmdletBinding()]
        param([Parameter(Position = 0)][string]$Path)
        $script:HivesRead.Add($Path) | Out-Null
        return @($script:FakeHives[$Path] | ForEach-Object { [pscustomobject]@{ PSPath = $_ } })
    }
    function Get-ItemProperty {
        [CmdletBinding()]
        param([Parameter(Position = 0)][string]$Path)
        return [pscustomobject]@{ DisplayName = $Path }
    }
    . ([scriptblock]::Create($registryText))

    $miss = @(Get-InstalledRegistryDisplayName -NameLike 'ZzzDefinitelyNotInstalledZzz')
    Assert-Equal 0 $miss.Count `
        "A miss must emit nothing; `$null in the output stream is what corrupts a caller's return value."
    Assert-Equal 3 $script:HivesRead.Count "A miss must look in all three uninstall hives."

    $script:HivesRead.Clear()
    $hit = @(Get-InstalledRegistryDisplayName -NameLike 'Contoso Widget')
    Assert-Equal 1 $hit.Count "A hit must be a single value, not the match plus a trailing `$null."
    Assert-Equal 'Contoso Widget 3.1' $hit[0] "The first match must be returned verbatim, with no array join."
    Assert-True ($hit[0] -is [string]) "The contract is a scalar string, not an object array."
    Assert-Equal 1 $script:HivesRead.Count "The scan must stop at the first match instead of walking every remaining hive."
}

# ---- O4: Disable-StartupEntry must not count a removal that failed. ----
$script:StartupLog = New-Object System.Collections.Generic.List[string]
$script:RemovalThrows = $true
$script:RunEntryName = 'MyStartupApp'
$script:RunEntryValue = 'C:\Tools\MyStartupApp.exe'
$script:FakeShortcuts = @()
$startupText = Get-FunctionText 'Disable-StartupEntry'

& {
    function Write-Ok { param([string]$Message) $script:StartupLog.Add("OK $Message") | Out-Null }
    function Write-Warn { param([string]$Message) $script:StartupLog.Add("WARN $Message") | Out-Null }
    function Write-Info { param([string]$Message) $script:StartupLog.Add("INFO $Message") | Out-Null }
    function Test-Path {
        [CmdletBinding()]
        param([Parameter(Position = 0)][string]$Path)
        return $true
    }
    function Get-ItemProperty {
        [CmdletBinding()]
        param([Parameter(Position = 0)][string]$Path)
        return [pscustomobject]@{ $script:RunEntryName = $script:RunEntryValue }
    }
    function Remove-ItemProperty {
        [CmdletBinding()]
        param([string]$Path, [string]$Name)
        if ($script:RemovalThrows) { throw "Requested registry access is not allowed." }
    }
    function Get-ChildItem {
        [CmdletBinding()]
        param([Parameter(Position = 0)][string]$Path, [string]$Filter)
        return @($script:FakeShortcuts)
    }
    function Remove-Item {
        [CmdletBinding()]
        param([Parameter(Position = 0)][string]$Path, [switch]$Force)
        if ($script:RemovalThrows) { throw "Access to the path is denied." }
    }
    . ([scriptblock]::Create($startupText))

    # O4a: every registry delete fails.
    $failed = Disable-StartupEntry -Pattern 'MyStartupApp'
    $failedLog = $script:StartupLog -join "`n"
    Assert-Equal $false $failed "A run where every removal failed must not report that something was removed."
    Assert-True ($failedLog -notmatch 'OK Removed startup entry') "A failed removal must not print a success line."
    Assert-True ($failedLog -match 'WARN Could not remove startup entry.*MyStartupApp') "A failed removal must be reported with the entry name."

    # O4b: the success path still counts.
    $script:StartupLog.Clear()
    $script:RemovalThrows = $false
    $removed = Disable-StartupEntry -Pattern 'MyStartupApp'
    $removedLog = $script:StartupLog -join "`n"
    Assert-Equal $true $removed "A removal that succeeds must still be reported as a removal."
    Assert-True ($removedLog -match 'OK Removed startup entry.*MyStartupApp') "A successful removal must print the success line."

    # O4c: the startup-folder shortcut path has the same contract. Registry finds nothing here, so
    # only the shortcut deletion decides the result.
    $script:StartupLog.Clear()
    $script:RemovalThrows = $true
    $script:RunEntryName = 'Unrelated'
    $script:RunEntryValue = 'C:\Tools\Unrelated.exe'
    $script:FakeShortcuts = @([pscustomobject]@{ Name = 'MyStartupApp.lnk'; FullName = 'C:\FakeStartup\MyStartupApp.lnk' })
    $shortcutFailed = Disable-StartupEntry -Pattern 'MyStartupApp'
    $shortcutLog = $script:StartupLog -join "`n"
    Assert-Equal $false $shortcutFailed "A shortcut delete that failed must not be counted as a removal."
    Assert-True ($shortcutLog -notmatch 'OK Removed startup shortcut') "A failed shortcut delete must not print a success line."
    Assert-True ($shortcutLog -match 'WARN Could not remove startup shortcut.*MyStartupApp\.lnk') "A failed shortcut delete must name the shortcut."
}

Write-Host "PASS failed steps exit non-zero and emit nothing, config-disabled steps are Skipped, registry lookup returns a scalar, and failed startup removals are not counted."
