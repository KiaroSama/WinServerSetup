<#
    Behavioral tests for Brave ExtensionInstallForcelist reconciliation.

    Sync-BraveForceListPolicy decides which admin-managed policy values it is allowed to DELETE.
    Get that wrong in one direction and an extension stays force-installed forever (the bug the
    ownership record was added to fix); get it wrong in the other direction and the tool silently
    deletes a policy value some other administrator placed there.

    Nothing here touches the real registry. Get-Item / Get-ItemProperty / Set-ItemProperty /
    Remove-ItemProperty / New-Item / Test-Path are shadowed over an in-memory hashtable, and every
    shadow asserts the path it was handed starts with 'HKLM:\' so a redirected call is a loud
    failure rather than a machine mutation.
#>
# -MainScript targets an alternate copy so these tests can be replayed against a deliberately
# defective build to prove they still fail. CI and local runs use the default.
#
# Mock signatures mirror the real cmdlets - including parameters this file never reads - so the
# code under test binds exactly as it does in production.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Cmdlets are shadowed deliberately to model the registry in memory.')]
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
$setupSourceNames = @('WinServerSetup.ps1') + @('Console', 'Core', 'Download', 'Rdp', 'Install', 'SystemSettings', 'Maintenance' |
        ForEach-Object { "scripts\{0}.ps1" -f $_ })
$setupSourceFiles = @(@($mainScript) + @($setupSourceNames | ForEach-Object { Join-Path $projectRoot $_ })) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique

$setupAsts = @(foreach ($setupFile in $setupSourceFiles) {
        $tokens = $null
        $parseErrors = $null
        $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($setupFile, [ref]$tokens, [ref]$parseErrors)
        Assert-True ($parseErrors.Count -eq 0) "$setupFile must parse before its Brave policy path can be tested."
        $fileAst
    })

foreach ($name in @('Test-ChromeExtensionId', 'Sync-BraveForceListPolicy')) {
    . ([scriptblock]::Create((Import-FunctionUnderTest $name $setupAsts)))
}

# ---- The in-memory registry: path -> (value name -> value data). ----
$policyPath = "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave\ExtensionInstallForcelist"
$ownershipPath = "HKLM:\SOFTWARE\WinServerSetup"
$ownershipName = "BraveManagedExtensionIds"
$updateUrl = "https://clients2.google.com/service/update2/crx"

$script:Registry = @{}
$script:ValueTypes = @{}
$script:Warnings = New-Object System.Collections.Generic.List[string]

function Assert-RegistryPath {
    param([string]$Path)
    # The suite must never reach a real hive or the filesystem, whatever the code under test does.
    if ([string]::IsNullOrWhiteSpace($Path) -or -not $Path.StartsWith('HKLM:\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "SAFETY: the Brave policy path must stay inside the in-memory HKLM model, got '$Path'."
    }
}

function Reset-Registry {
    param([hashtable]$PolicyValues = @{}, [string[]]$ManagedIds = $null)
    $script:Registry = @{}
    $script:ValueTypes = @{}
    $script:Warnings.Clear()
    if ($PolicyValues.Count -gt 0) {
        $values = @{}
        foreach ($key in $PolicyValues.Keys) { $values[[string]$key] = $PolicyValues[$key] }
        $script:Registry[$policyPath] = $values
    }
    if ($null -ne $ManagedIds) {
        $script:Registry[$ownershipPath] = @{ $ownershipName = [string[]]$ManagedIds }
    }
}

function Get-PolicyValues { if ($script:Registry.ContainsKey($policyPath)) { return $script:Registry[$policyPath] } return @{} }
function Get-ManagedIds {
    if (-not $script:Registry.ContainsKey($ownershipPath)) { return @() }
    return @($script:Registry[$ownershipPath][$ownershipName])
}
function Get-SlotFor {
    param([string]$Id)
    $values = Get-PolicyValues
    foreach ($key in $values.Keys) { if (([string]$values[$key]) -like ("{0};*" -f $Id)) { return [string]$key } }
    return $null
}

# ---- Registry cmdlet shadows. ----
function Test-Path {
    param([Parameter(Mandatory, Position = 0)][string]$Path, [string]$LiteralPath)
    $target = if ([string]::IsNullOrWhiteSpace($Path)) { $LiteralPath } else { $Path }
    Assert-RegistryPath $target
    return $script:Registry.ContainsKey($target)
}
function New-Item {
    param([Parameter(Mandatory, Position = 0)][string]$Path, [string]$ItemType, [switch]$Force)
    Assert-RegistryPath $Path
    if (-not $script:Registry.ContainsKey($Path)) { $script:Registry[$Path] = @{} }
    return [pscustomobject]@{ PSPath = $Path }
}
function Get-Item {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    Assert-RegistryPath $Path
    $names = @()
    if ($script:Registry.ContainsKey($Path)) { $names = @($script:Registry[$Path].Keys | ForEach-Object { [string]$_ }) }
    $key = New-Object psobject
    Add-Member -InputObject $key -MemberType ScriptMethod -Name GetValueNames -Value { $names }.GetNewClosure()
    return $key
}
function Get-ItemProperty {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Path, [string]$Name)
    Assert-RegistryPath $Path
    if (-not $script:Registry.ContainsKey($Path)) { return $null }
    $values = $script:Registry[$Path]
    if (-not $values.ContainsKey($Name)) { return $null }
    $result = New-Object psobject
    Add-Member -InputObject $result -MemberType NoteProperty -Name $Name -Value $values[$Name]
    return $result
}
function Set-ItemProperty {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Path, [Parameter(Mandatory)][string]$Name, [string]$Type, $Value)
    Assert-RegistryPath $Path
    if (-not $script:Registry.ContainsKey($Path)) { $script:Registry[$Path] = @{} }
    $script:Registry[$Path][$Name] = $Value
    $script:ValueTypes[("{0}|{1}" -f $Path, $Name)] = $Type
}
function Remove-ItemProperty {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Path, [Parameter(Mandatory)][string]$Name)
    Assert-RegistryPath $Path
    if (-not $script:Registry.ContainsKey($Path) -or -not $script:Registry[$Path].ContainsKey($Name)) {
        throw "Registry value '$Name' does not exist under $Path."
    }
    $script:Registry[$Path].Remove($Name)
}

# ---- Console collaborators. ----
function Write-Ok { param($Message) }
function Write-Info { param($Message) }
function Write-Warn { param($Message) $script:Warnings.Add([string]$Message) | Out-Null }

function New-ExtensionItem {
    param([string]$Name, [string]$Id)
    return [pscustomobject]@{ name = $Name; id = $Id }
}

$idA = 'a' * 32
$idB = 'b' * 32
$idOther = 'c' * 32

# ---- 1. Extension ID validation, directly. ----
Assert-Equal $true  (Test-ChromeExtensionId ('p' * 32)) "A 32-character a-p ID must be accepted."
Assert-Equal $false (Test-ChromeExtensionId ('a' * 31)) "A 31-character ID must be rejected."
Assert-Equal $false (Test-ChromeExtensionId ('a' * 33)) "A 33-character ID must be rejected."
Assert-Equal $false (Test-ChromeExtensionId (('a' * 31) + 'z')) "'z' is outside the a-p alphabet and must be rejected."
Assert-Equal $false (Test-ChromeExtensionId (('a' * 31) + '1')) "A digit must be rejected."
Assert-Equal $false (Test-ChromeExtensionId ('A' * 32)) "The match is case-sensitive; uppercase must be rejected."
Assert-Equal $false (Test-ChromeExtensionId '') "An empty ID must be rejected."

# ---- 2. Fresh install: both extensions applied, nothing removed, ownership recorded. ----
Reset-Registry
$result = Sync-BraveForceListPolicy -Items @((New-ExtensionItem 'A' $idA), (New-ExtensionItem 'B' $idB))
Assert-Equal 2 $result.Applied "Both configured extensions must be applied on a fresh machine."
Assert-Equal 0 $result.Removed "A fresh machine has nothing to remove."
Assert-Equal 0 $result.Unmanaged "A fresh machine has no other administrator's values."
Assert-Equal 2 (Get-PolicyValues).Count "Exactly two force-list values must exist."
Assert-Equal ("{0};{1}" -f $idA, $updateUrl) ([string](Get-PolicyValues)['1']) "Slot 1 must carry the first extension with the update URL."
Assert-Equal ("{0};{1}" -f $idB, $updateUrl) ([string](Get-PolicyValues)['2']) "Slot 2 must carry the second extension."
Assert-Equal "$idA,$idB" ((Get-ManagedIds) -join ',') "Ownership must record exactly the IDs this project wrote."
Assert-Equal 'MultiString' $script:ValueTypes[("{0}|{1}" -f $ownershipPath, $ownershipName)] "The ownership record must be a MultiString."

# ---- 3. Idempotent re-run: same slots, nothing removed, nothing duplicated. ----
$slotABefore = Get-SlotFor $idA
$slotBBefore = Get-SlotFor $idB
$result = Sync-BraveForceListPolicy -Items @((New-ExtensionItem 'A' $idA), (New-ExtensionItem 'B' $idB))
Assert-Equal 2 $result.Applied "A re-run must still report both extensions applied."
Assert-Equal 0 $result.Removed "A re-run with unchanged config must remove nothing."
Assert-Equal 2 (Get-PolicyValues).Count "A re-run must not allocate duplicate slots."
Assert-Equal $slotABefore (Get-SlotFor $idA) "An extension must keep the slot it already occupies."
Assert-Equal $slotBBefore (Get-SlotFor $idB) "An extension must keep the slot it already occupies."

# ---- 4. Dropped from config: this project's own stale value is removed. ----
$result = Sync-BraveForceListPolicy -Items @((New-ExtensionItem 'A' $idA))
Assert-Equal 1 $result.Applied "Only the still-configured extension is applied."
Assert-Equal 1 $result.Removed "The extension dropped from config must be removed from the policy."
Assert-Equal 1 (Get-PolicyValues).Count "Only one force-list value must remain."
Assert-True ($null -eq (Get-SlotFor $idB)) "The dropped extension must no longer be force-installed."
Assert-Equal $slotABefore (Get-SlotFor $idA) "The surviving extension must keep its slot."
Assert-Equal "$idA" ((Get-ManagedIds) -join ',') "Ownership must shrink to the surviving extension."

# ---- 5. LOAD-BEARING: a value this project never wrote is never deleted. ----
# Slot 5 belongs to another administrator - it is absent from the ownership record. Dropping
# everything from config must clear only this project's own value and leave slot 5 untouched.
Reset-Registry -PolicyValues @{
    '1' = ("{0};{1}" -f $idA, $updateUrl)
    '5' = ("{0};{1}" -f $idOther, $updateUrl)
} -ManagedIds @($idA)
$result = Sync-BraveForceListPolicy -Items @()
Assert-Equal 0 $result.Applied "Nothing is configured, so nothing is applied."
Assert-Equal 1 $result.Removed "Only this project's own value may be removed."
Assert-Equal 1 $result.Unmanaged "The other administrator's value must be reported as unmanaged."
Assert-True ((Get-PolicyValues).ContainsKey('5')) "Another administrator's policy value must never be deleted."
Assert-Equal ("{0};{1}" -f $idOther, $updateUrl) ([string](Get-PolicyValues)['5']) "The other administrator's value must be byte-for-byte unchanged."
Assert-True (-not (Get-PolicyValues).ContainsKey('1')) "This project's dropped value must be gone."
Assert-Equal 0 (Get-ManagedIds).Count "Ownership must now record nothing."

# ---- 6. Slot allocation must not overwrite an occupied unmanaged slot. ----
Reset-Registry -PolicyValues @{ '1' = ("{0};{1}" -f $idOther, $updateUrl) }
$result = Sync-BraveForceListPolicy -Items @((New-ExtensionItem 'A' $idA))
Assert-Equal 1 $result.Applied "The configured extension must be applied."
Assert-Equal 0 $result.Removed "An unowned value must not be removed."
Assert-Equal ("{0};{1}" -f $idOther, $updateUrl) ([string](Get-PolicyValues)['1']) "Slot 1 was occupied and must not be overwritten."
Assert-Equal '2' (Get-SlotFor $idA) "A new extension must take the lowest FREE slot."
Assert-Equal 2 (Get-PolicyValues).Count "Both values must coexist."

# ---- 7. An invalid extension ID is skipped with a warning and never written. ----
Reset-Registry
$result = Sync-BraveForceListPolicy -Items @(
    (New-ExtensionItem 'Valid' $idA),
    (New-ExtensionItem 'Bogus' 'not-a-real-extension-id')
)
Assert-Equal 1 $result.Applied "Only the valid extension may be applied."
Assert-Equal 1 (Get-PolicyValues).Count "The invalid ID must not produce a policy value."
Assert-True (($script:Warnings -join "`n") -match 'Bogus') "Skipping an invalid extension must warn, naming the extension."
Assert-True (($script:Warnings -join "`n") -match 'not-a-real-extension-id') "The warning must name the rejected ID."
Assert-Equal "$idA" ((Get-ManagedIds) -join ',') "Ownership must record only the valid extension."

# ---- 8. Duplicate IDs in config collapse to a single slot. ----
Reset-Registry
$result = Sync-BraveForceListPolicy -Items @(
    (New-ExtensionItem 'A' $idA),
    (New-ExtensionItem 'A again' $idA)
)
Assert-Equal 1 $result.Applied "A duplicate ID must be applied once."
Assert-Equal 1 (Get-PolicyValues).Count "A duplicate ID must not consume two slots."

Write-Host "PASS Brave force-list reconciliation: ownership rules, slot reuse, stale removal, ID validation."
