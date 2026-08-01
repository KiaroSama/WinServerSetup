# -ConfigPath targets an alternate copy of the tracked config so these assertions can be replayed
# against a deliberately weakened copy to prove they still fail. CI and local runs use the default.
param([string]$ConfigPath = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$configPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) { Join-Path $projectRoot "WinServerSetup.config.json" } else { $ConfigPath }
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

. (Join-Path $PSScriptRoot '_Common.ps1')

Assert-True (-not [bool]$config.activation.enabled) "Tracked activation.enabled must default to false."
Assert-True ([string]::IsNullOrWhiteSpace([string]$config.activation.productKey)) "Tracked activation.productKey must be empty."
Assert-True ([string]::IsNullOrWhiteSpace([string]$config.activation.kmsServer)) "Tracked activation.kmsServer must be empty."
Assert-True (-not [bool]$config.runtimes.includeUnsupportedDotNetVersions) "Unsupported .NET runtimes must be opt-in."
Assert-True (-not [bool]$config.customFolders.excludeCompressedFromDefender) "Downloads must not be excluded from Defender by default."
Assert-True (-not [bool]$config.emptyStandbyList.enabled) "Unverified EmptyStandbyList execution must be disabled by default."

$blocker = $config.rdpBruteforceBlocker
Assert-True ([int]$blocker.taskIntervalMinutes -eq 1) "The blocker must run every minute by default."
Assert-True (-not [bool]$blocker.includeNetworkLogonType3) "Generic LogonType 3 detection must be opt-in."
Assert-True (-not [bool]$blocker.blockAllInbound) "Firewall blocks must default to configured RDP ports only."
Assert-True (-not [bool]$blocker.permanentBlock) "Permanent blocker rules must be opt-in."
Assert-True ([int]$blocker.ruleRetentionDays -ge 1) "Managed blocker rules need finite retention."
Assert-True ([int64]$blocker.logMaxBytes -ge 65536) "RDP blocker logs need a bounded rotation threshold."

# L-01: rdpBruteforceBlocker.hidden was shipped in the tracked config and read by nothing - the
# blocker never hid anything, so the key only ever misled operators into thinking it did. It was
# removed rather than implemented; this assertion is what stops it drifting back in.
Assert-True ($blocker.PSObject.Properties.Name -notcontains "hidden") `
    "L-01: rdpBruteforceBlocker.hidden is not read by scripts\Block-RdpBruteforce.ps1 and must not reappear in the tracked config."

# H-04: the per-run resource caps only bound anything if they are actually shipped.
foreach ($cap in @("maxEventsPerRun", "maxOffendersPerRun", "maxManagedRules", "maxStateBytes", "maxRunSeconds")) {
    Assert-True ($blocker.PSObject.Properties.Name -contains $cap) "H-04: the tracked config must ship rdpBruteforceBlocker.$cap."
    Assert-True ([int64]$blocker.$cap -ge 1) "H-04: rdpBruteforceBlocker.$cap must be a positive bound."
}

Assert-True (-not [bool]$config.administratorAccount.enabled) "Administrator rename must be explicit opt-in."
Assert-True (-not [bool]$config.administratorAccount.promptDuringFullSetup) "Administrator rename prompts must default off."
Assert-True ($config.administratorAccount.PSObject.Properties.Name -notcontains "password") "Tracked config must never accept an Administrator password field."
Assert-True (-not [bool]$config.accountLockout.disableLocalAccountLockout) "Machine-wide lockout disable must default off."
Assert-True (-not [bool]$config.accountLockout.promptDuringFullSetup) "Machine-wide lockout prompts must default off."

Write-Host "PASS tracked security defaults are conservative."
