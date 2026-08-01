<#
    Behavioral tests for the Windows activation path in WinServerSetup.ps1.

    This file used to consist entirely of four regex matches against the source text. The most
    important of them was a NEGATIVE grep - "no Write-* line mentions $key" - which is exactly the
    kind of assertion source text cannot make: it only proves that one specific spelling of a leak
    is absent from one specific line shape. Interpolating the key into a message built anywhere
    else, or logging the whole argument array, kept every grep green.

    The tests below run the real functions with a recognisable fake product key and capture every
    console/log call, so a leak fails the suite for real. slmgr itself is never invoked: Invoke-Slmgr
    is shadowed, so no licensing state on this machine is read or changed.
#>
# -MainScript targets an alternate copy so these tests can be replayed against a deliberately
# defective build to prove they still fail. CI and local runs use the default.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub signatures mirror production collaborators so parameter binding matches.')]
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
# WinServerSetup.ps1 dot-sources its function library from scripts\; search that whole
# partition so extraction by name keeps working wherever a function lives. $mainScript is
# searched first, so a -MainScript copy still shadows the on-disk original when replaying
# against a deliberately defective build.
$setupSourceNames = @('WinServerSetup.ps1') + @('Console', 'Core', 'Download', 'Rdp', 'Install', 'SystemSettings', 'Maintenance' |
        ForEach-Object { "scripts\{0}.ps1" -f $_ })
$setupSourceFiles = @(@($mainScript) + @($setupSourceNames | ForEach-Object { Join-Path $projectRoot $_ })) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique

# The retained source greps cover the same partition.
$source = ($setupSourceFiles | ForEach-Object { Get-Content -LiteralPath $_ -Raw -Encoding UTF8 }) -join "`r`n"

$setupAsts = @(foreach ($setupFile in $setupSourceFiles) {
        $tokens = $null
        $parseErrors = $null
        $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($setupFile, [ref]$tokens, [ref]$parseErrors)
        Assert-True ($parseErrors.Count -eq 0) "$setupFile must parse before its activation path can be tested."
        $fileAst
    })

function Import-FunctionUnderTest {
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

foreach ($name in @('Invoke-SlmgrChecked', 'Invoke-ActivationIfConfigured')) {
    . ([scriptblock]::Create((Import-FunctionUnderTest $name)))
}

# An obviously fake key in the documented 5x5 shape. Never put a real key in a test.
$fakeKey = 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE'
$fakeKms = 'kms.invalid.test:1688'

# ---- Fake licensing host. Invoke-Slmgr is the ONLY place the real cscript/slmgr.vbs is
#      reached, so shadowing it keeps the whole flow off this machine's licensing state. ----
$script:SlmgrCalls    = New-Object System.Collections.Generic.List[string]
$script:SlmgrExitMap  = @{}
$script:SlmgrDefault  = 0
$script:LoggedLines   = New-Object System.Collections.Generic.List[string]
$script:SkipReasons   = New-Object System.Collections.Generic.List[string]

function Invoke-Slmgr {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $verb = [string]$Arguments[0]
    $script:SlmgrCalls.Add(($Arguments -join ' ')) | Out-Null
    if ($script:SlmgrExitMap.ContainsKey($verb)) { return [int]$script:SlmgrExitMap[$verb] }
    return $script:SlmgrDefault
}

# Every console/log sink the activation path can reach is captured here. The leak assertion is
# only as strong as this list is complete, so ALL of them record, none of them print.
function Write-Info { param([string]$Message) $script:LoggedLines.Add("INFO $Message") | Out-Null }
function Write-Ok { param([string]$Message) $script:LoggedLines.Add("OK $Message") | Out-Null }
function Write-Warn { param([string]$Message) $script:LoggedLines.Add("WARN $Message") | Out-Null }
function Write-Fail { param([string]$Message) $script:LoggedLines.Add("FAIL $Message") | Out-Null }
function Write-StructuredLog {
    param([string]$Level = 'INFO', [string]$Message = '', [string]$Section = '')
    $script:LoggedLines.Add("LOG $Level $Message $Section") | Out-Null
}
function Set-StepSkipped { param([Parameter(Mandatory)][string]$Reason) $script:SkipReasons.Add($Reason) | Out-Null }

function Reset-ActivationTestState {
    param([hashtable]$ExitCodes = @{}, [int]$DefaultExit = 0)
    $script:SlmgrCalls.Clear()
    $script:LoggedLines.Clear()
    $script:SkipReasons.Clear()
    $script:SlmgrExitMap = $ExitCodes
    $script:SlmgrDefault = $DefaultExit
}

function New-ActivationConfig {
    param([bool]$Enabled = $true, [string]$ProductKey = "", [string]$KmsServer = "")
    return [pscustomobject]@{
        activation = [pscustomobject]@{ enabled = $Enabled; productKey = $ProductKey; kmsServer = $KmsServer }
    }
}

$previousConfig = $Global:Config
try {
    # ---- 1. A zero exit code is a success: no throw, and the command really was issued. ----
    Reset-ActivationTestState
    Invoke-SlmgrChecked -Arguments @('/xpr')
    Assert-Equal 1 $script:SlmgrCalls.Count "A checked slmgr call must actually invoke slmgr."
    Assert-Equal '/xpr' $script:SlmgrCalls[0] "The checked wrapper must pass its arguments through unchanged."

    # ---- 2. A nonzero exit code must THROW. Without this, /ipk could fail and the run would
    #         still print "Activation completed". ----
    Reset-ActivationTestState -ExitCodes @{ '/ato' = 31 }
    $slmgrError = $null
    try { Invoke-SlmgrChecked -Arguments @('/ato') } catch { $slmgrError = [string]$_.Exception.Message }
    Assert-True ($null -ne $slmgrError) "A nonzero slmgr exit code must raise a terminating error."
    Assert-True ($slmgrError -match '31') "The failure must report the exit code slmgr returned."
    Assert-True ($slmgrError -match '(?i)licensing|activation') "The failure must identify itself as a licensing failure."

    # ---- 3. NO KEY LEAKAGE. This is the assertion the old negative grep was gesturing at and
    #         could never actually make. The full flow runs with a fake key; every captured
    #         console line and structured-log line is then searched for it. ----
    Reset-ActivationTestState
    $Global:Config = New-ActivationConfig -ProductKey $fakeKey -KmsServer $fakeKms
    Invoke-ActivationIfConfigured

    $captured = ($script:LoggedLines -join "`n")
    Assert-True (-not $captured.Contains($fakeKey)) `
        ("The product key must never reach a console or log sink. Captured: {0}" -f $captured)
    # The 5x5 group shape on its own, in case a future change logs a partially masked key.
    Assert-True ($captured -notmatch '[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}') `
        ("No log line may contain anything shaped like a product key. Captured: {0}" -f $captured)
    Assert-True (($script:SlmgrCalls -join "`n").Contains($fakeKey)) `
        "The key must still reach slmgr itself; a test that proves only that the key is unused proves nothing."

    # ---- 4. The full configured flow issues every licensing step, in order, exactly once. ----
    Assert-Equal 4 $script:SlmgrCalls.Count "A key + KMS configuration must run /ipk, /skms, /ato and /xpr."
    Assert-Equal ("/ipk $fakeKey") $script:SlmgrCalls[0] "The product key must be installed first."
    Assert-Equal ("/skms $fakeKms") $script:SlmgrCalls[1] "The KMS server must be set after the key."
    Assert-Equal '/ato' $script:SlmgrCalls[2] "Activation must be attempted after key and KMS are set."
    Assert-Equal '/xpr' $script:SlmgrCalls[3] "The license status must be queried last."
    Assert-True ($captured -match 'Activation completed') "A fully successful activation must report completion."

    # ---- 5. A failure part-way through must ABORT the remaining steps and must NOT claim
    #         completion. This is the contract the old 'Activation completed...' grep could only
    #         assert the existence of, never the guard around it. ----
    Reset-ActivationTestState -ExitCodes @{ '/ato' = 31 }
    $Global:Config = New-ActivationConfig -ProductKey $fakeKey -KmsServer $fakeKms
    $activationError = $null
    try { Invoke-ActivationIfConfigured } catch { $activationError = [string]$_.Exception.Message }
    Assert-True ($null -ne $activationError) "A failing licensing command must propagate out of the activation step."
    Assert-Equal 3 $script:SlmgrCalls.Count "A failed /ato must stop the flow before /xpr runs."
    Assert-True ((($script:LoggedLines) -join "`n") -notmatch 'Activation completed') `
        "Activation must never report completion after a licensing command failed."
    Assert-True (-not (($script:LoggedLines -join "`n").Contains($fakeKey))) `
        "The failure path must not leak the product key either."

    # ---- 6. Disabled in config: skipped, and nothing is issued to slmgr. ----
    Reset-ActivationTestState
    $Global:Config = New-ActivationConfig -Enabled $false -ProductKey $fakeKey
    Invoke-ActivationIfConfigured
    Assert-Equal 0 $script:SlmgrCalls.Count "Disabled activation must not touch licensing state at all."
    Assert-Equal 1 $script:SkipReasons.Count "Disabled activation must record a skip reason for the summary."

    # ---- 7. Enabled but unconfigured: warn and return, rather than running a bare /ato that
    #         would reach out to whatever KMS the machine already has. ----
    Reset-ActivationTestState
    $Global:Config = New-ActivationConfig -ProductKey "" -KmsServer ""
    Invoke-ActivationIfConfigured
    Assert-Equal 0 $script:SlmgrCalls.Count "Activation with neither a key nor a KMS server must issue no licensing commands."
    Assert-True ((($script:LoggedLines) -join "`n") -match '(?i)no kmsServer or productKey') `
        "An unconfigured activation must say why it did nothing."

    # ---- 8. A KMS-only configuration must not fabricate a /ipk call. ----
    Reset-ActivationTestState
    $Global:Config = New-ActivationConfig -ProductKey "" -KmsServer $fakeKms
    Invoke-ActivationIfConfigured
    Assert-Equal 3 $script:SlmgrCalls.Count "A KMS-only configuration must run /skms, /ato and /xpr."
    Assert-True ((($script:SlmgrCalls) -join ' ') -notmatch '/ipk') "No product key means no /ipk command."

    # ---- Retained source greps: cheap smoke checks over the call sites above. ----
    Assert-True ($source -match 'function\s+Invoke-SlmgrChecked') "Activation must stop when slmgr reports a nonzero exit code."
    Assert-True ($source -notmatch 'Write-(Info|Warn|Ok|StructuredLog)[^\r\n]*\$key') "Activation keys must never be written to console or file logs."
    Assert-True ($source -match 'Invoke-SlmgrChecked -Arguments @\("/ipk", \$key\)') "Product-key installation must use the checked, non-logging slmgr path."
    Assert-True ($source -match 'Activation completed and license status was queried') "Activation must report completion only after all checked commands succeed."

    Write-Host "PASS activation runs against a shadowed slmgr: exit codes are checked, a mid-flow failure aborts before claiming completion, and the product key never reaches any console or log sink."
} finally {
    $Global:Config = $previousConfig
}
