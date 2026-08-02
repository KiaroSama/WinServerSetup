# This harness mocks the Windows-only cmdlets by shadowing them with functions. The mock
# signatures mirror the real cmdlets - including parameters this file never reads - so the code
# under test binds exactly as it does in production. Everything below the dot-source runs the
# real implementation against those mocks; only the outermost Windows APIs are replaced.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Cmdlets are shadowed deliberately to mock Windows-only APIs.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock signatures mirror the real cmdlets so parameter binding matches production.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', '', Justification = 'Mock parameter names must match the real cmdlet parameter names.')]
# -ScriptPath targets an alternate copy so these tests can be replayed against a deliberately
# defective build to prove they still fail. CI and local runs use the default.
param([string]$ScriptPath = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$accountScript = if ([string]::IsNullOrWhiteSpace($ScriptPath)) { Join-Path $projectRoot "scripts\AccountSecurity.ps1" } else { $ScriptPath }
if (-not (Test-Path -LiteralPath $accountScript)) { throw "Missing account security implementation: $accountScript" }
$source = Get-Content -LiteralPath $accountScript -Raw -Encoding UTF8

. (Join-Path $PSScriptRoot '_Common.ps1')

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    try { & $Action } catch { return [string]$_.Exception.Message }
    throw $Message
}

# ---------------------------------------------------------------------------
# Static guards that behavioural tests cannot express
# ---------------------------------------------------------------------------
Assert-True ($source -match "-500") "Built-in Administrator discovery must use RID 500, not the current name."
Assert-True ($source -match 'Rename-LocalUser') "Administrator rename must use the local-account API."
# The whole point of the feature is that the EXISTING administrator is renamed. Creating a new
# account (or deleting the old one) would leave the machine's real administrator untouched under
# a name nobody expects, which is the exact defect this file guards against.
Assert-True ($source -notmatch 'New-LocalUser') "The built-in Administrator must be renamed in place, never re-created."
Assert-True ($source -notmatch 'Remove-LocalUser') "The built-in Administrator must be renamed in place, never deleted and replaced."
Assert-True ($source -match 'Write-AccountSecurityBackup') "Account and policy changes need recoverable backups."
Assert-True ($source -match 'secedit\.exe') "Local lockout policy backup/restore must use locale-independent security policy export/import."
Assert-True ($source -match 'PartOfDomain') "Domain-joined machines require a warning boundary."
Assert-True ($source -match 'Restore-LocalAccountLockoutPolicy') "Local lockout policy needs a restoration path."
Assert-True ($source -match 'Read-Host\s+-Prompt\s+\$Prompt\s+-AsSecureString') "The new password must be read through a hidden secure prompt."

# The password must never exist as a managed plaintext string, and must never be sourced from a
# parameter, configuration value or environment variable.
foreach ($forbidden in @('PtrToStringBSTR', 'PtrToStringUni', 'PtrToStringAuto', 'PtrToStringAnsi', 'ConvertFrom-SecureString', 'ConvertTo-SecureString', 'GetNetworkCredential', 'NetworkCredential')) {
    Assert-True ($source -notmatch [regex]::Escape($forbidden)) "SecureString must never be converted to plaintext ($forbidden)."
}
Assert-True ($source -match 'ZeroFreeBSTR') "Any BSTR taken from a SecureString must be zeroed and freed."
Assert-True (([regex]::Matches($source, 'SecureStringToBSTR')).Count -le ([regex]::Matches($source, 'ZeroFreeBSTR')).Count) "Every SecureStringToBSTR needs a matching ZeroFreeBSTR."
Assert-True ($source -notmatch '(?i)\$\w*(Config|env:)\w*\.?\w*[Pp]assword') "The password must never come from configuration or the environment."
Assert-True ($source -notmatch '(?i)param\s*\([^)]*\[string\]\s*\$\w*Password') "The password must never be accepted as a plaintext parameter."

# gpupdate must be bounded and must run before the effective-policy read-back.
Assert-True ($source -notmatch '&\s*gpupdate\.exe') "gpupdate must not run unbounded as a direct external call."
Assert-True ($source -match 'Start-Process[^\r\n]*gpupdate\.exe') "gpupdate must run as a child process so it can be bounded."
Assert-True ($source -match 'WaitForExit\(\s*\$TimeoutSeconds') "gpupdate must be bounded by a wall-clock timeout."
Assert-True ($source -match 'taskkill\.exe[^\r\n]*/T') "An expired gpupdate must have its whole process tree terminated."
Assert-True ($source -match '(?s)Invoke-BoundedGpupdate\s*\}?\s*\r?\n\s*\r?\n?\s*\$verified\s*=\s*Export-LocalLockoutPolicy') "Policy refresh must happen before the verification read-back."

$main = Get-Content -LiteralPath (Join-Path $projectRoot "WinServerSetup.ps1") -Raw -Encoding UTF8
Assert-True ($main -match 'Invoke-ConfiguredAccountSecurity') "Full setup must integrate account-security choices."
Assert-True ($main -match 'Rename built-in Administrator') "Main menu must expose Administrator rename."
Assert-True ($main -match 'Disable local account lockout') "Main menu must expose local lockout control."

$configText = Get-Content -LiteralPath (Join-Path $projectRoot "WinServerSetup.config.json") -Raw -Encoding UTF8
$configJson = $configText | ConvertFrom-Json
foreach ($section in @('administratorAccount', 'accountLockout')) {
    foreach ($property in $configJson.$section.PSObject.Properties) {
        Assert-True ($property.Name -notmatch '(?i)password|secret|credential') "Config section '$section' must never carry a password field ($($property.Name))."
    }
}

. $accountScript

# Captured before the mocks shadow it, so the timeout path of the real implementation is still
# reachable while every other test uses the recording stub. The ScriptBlock has to be taken here
# rather than the FunctionInfo: redefining a function mutates the existing FunctionInfo in place,
# so a captured FunctionInfo would silently resolve to the mock.
$realBoundedGpupdate = (Get-Command Invoke-BoundedGpupdate -CommandType Function).ScriptBlock

$testRoot = Join-Path $env:TEMP ("WinServerSetup-AccountSecurity-{0}" -f ([guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$Global:ProjectRoot = $testRoot
$Global:NoPause = $false
$Global:Config = [pscustomobject]@{
    administratorAccount = [pscustomobject]@{ enabled = $true; promptDuringFullSetup = $false; defaultNewName = 'PromptedAdmin' }
    accountLockout       = [pscustomobject]@{ disableLocalAccountLockout = $true; promptDuringFullSetup = $false; runGpupdate = $false }
}

# The single value that must never surface anywhere observable.
$secretValue = 'Sentinel-Passw0rd-Never-Logged!'

# Built without ConvertTo-SecureString so the test file itself never converts plaintext either
# way through the API the implementation is forbidden to use.
function New-TestSecureString {
    param([string]$Text)
    $secure = New-Object System.Security.SecureString
    foreach ($character in $Text.ToCharArray()) { $secure.AppendChar($character) }
    $secure.MakeReadOnly()
    return $secure
}

$script:LogLines = New-Object System.Collections.Generic.List[string]
$script:HostAnswers = New-Object System.Collections.Generic.Queue[string]
$script:HostPrompts = New-Object System.Collections.Generic.List[string]
$script:SecureAnswers = New-Object System.Collections.Generic.Queue[object]
$script:SecurePromptCount = 0
$script:Accounts = @()
$script:Profiles = @{}
$script:GroupMembers = @()
$script:GroupEnumerationFails = $false
$script:DomainJoined = $false
$script:CurrentSid = 'S-1-5-21-11-22-33-1001'
$script:RenameCalls = New-Object System.Collections.Generic.List[object]
$script:NewUserCalls = New-Object System.Collections.Generic.List[object]
$script:RenameFailFor = @()
$script:SetUserCalls = New-Object System.Collections.Generic.List[object]
$script:SetUserFails = $false
$script:SeceditCalls = New-Object System.Collections.Generic.List[string]
$script:AppliedInfs = New-Object System.Collections.Generic.List[string]
$script:CallOrder = New-Object System.Collections.Generic.List[string]
$script:Policy = @{ LockoutBadCount = 5; ResetLockoutCount = 30; LockoutDuration = 30 }
$script:SeceditConfigureIgnored = $false
$script:GpupdateCalls = 0
$script:TaskkillArgs = @()
$script:ProcessExitsInTime = $true
$script:ProcessExitCode = 0
$script:ProcessDisposed = $false

# --- Console shims (the real ones live in WinServerSetup.ps1) ---------------
function Write-Ok   { param([string]$Message) $script:LogLines.Add("[OK] $Message")   | Out-Null }
function Write-StructuredLog { param([string]$Level = 'INFO', [string]$Message = '', [string]$Section = '') $script:LogLines.Add("[$Level] $Message") | Out-Null }
function Write-Info { param([string]$Message) $script:LogLines.Add("[INFO] $Message") | Out-Null }
function Write-Warn { param([string]$Message) $script:LogLines.Add("[WARN] $Message") | Out-Null }
function Read-HostThemed {
    param([Parameter(Mandatory)][string]$Prompt, [string]$DefaultValue = "")
    $script:HostPrompts.Add($Prompt) | Out-Null
    if ($script:HostAnswers.Count -eq 0) { throw "Unexpected interactive prompt: $Prompt" }
    return $script:HostAnswers.Dequeue()
}
function Read-SecurePasswordPrompt {
    param([Parameter(Mandatory)][string]$Prompt)
    $script:SecurePromptCount++
    if ($script:SecureAnswers.Count -eq 0) { throw "Unexpected secure prompt: $Prompt" }
    return $script:SecureAnswers.Dequeue()
}

# --- Windows API shims ------------------------------------------------------
function Get-CimInstance {
    param([string]$ClassName, [string]$Filter, $ErrorAction)
    switch ($ClassName) {
        'Win32_UserAccount'    { return @($script:Accounts) }
        'Win32_ComputerSystem' { return [pscustomobject]@{ PartOfDomain = $script:DomainJoined } }
        'Win32_UserProfile'    {
            $sid = ([regex]::Match($Filter, "SID='([^']+)'")).Groups[1].Value
            if ($script:Profiles.ContainsKey($sid)) { return @([pscustomobject]@{ SID = $sid; LocalPath = $script:Profiles[$sid] }) }
            return @()
        }
    }
    throw "Unexpected CIM class: $ClassName"
}
function Get-LocalUser {
    param([string]$Name, [string]$SID, $ErrorAction)
    $found = @($script:Accounts | Where-Object { [string]$_.Name -eq $Name })
    if ($found.Count -eq 0) { return $null }
    return $found[0]
}
function Rename-LocalUser {
    param([string]$SID, [string]$Name, [string]$NewName, $ErrorAction)
    $script:RenameCalls.Add([pscustomobject]@{ SID = [string]$SID; NewName = $NewName }) | Out-Null
    if ($script:RenameFailFor -contains $NewName) { throw "Access is denied while renaming to '$NewName'." }
    $target = @($script:Accounts | Where-Object { [string]$_.SID -eq [string]$SID })
    if ($target.Count -eq 0) { throw "No local account with SID $SID." }
    $target[0].Name = $NewName
}
# Shadowed so a regression that creates an account instead of renaming one is recorded here
# rather than executed against the machine running the suite. It throws as well as records: an
# unshadowed New-LocalUser would create a real local account on this host.
function New-LocalUser {
    param([string]$Name, [System.Security.SecureString]$Password, [string]$Description, [switch]$NoPassword, $ErrorAction)
    $script:NewUserCalls.Add([pscustomobject]@{ Name = $Name }) | Out-Null
    throw "The built-in Administrator must be renamed, not re-created ('$Name')."
}
function Set-LocalUser {
    param([string]$SID, [string]$Name, [System.Security.SecureString]$Password, $ErrorAction)
    # Only non-secret metadata is recorded; the SecureString itself is never stringified.
    $script:SetUserCalls.Add([pscustomobject]@{
        SID            = [string]$SID
        PasswordType   = if ($null -ne $Password) { $Password.GetType().FullName } else { '<none>' }
        PasswordLength = if ($null -ne $Password) { $Password.Length } else { -1 }
    }) | Out-Null
    if ($script:SetUserFails) { throw "The password does not meet the password policy requirements." }
}
function Get-LocalGroupMember {
    param([string]$Group, [string]$Name, [string]$SID, [string]$Member, $ErrorAction)
    if ($script:GroupEnumerationFails) { throw "Failed to compare two elements in the array." }
    return @($script:GroupMembers | ForEach-Object { [pscustomobject]@{ SID = $_; Name = $_ } })
}
function Get-CurrentUserSid { return $script:CurrentSid }

# Shadowing only the secedit invocation keeps the real INF writer and the real INF parser under
# test, so the exact key/value lines that reach secedit are observable.
function Invoke-SeceditChecked {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $script:SeceditCalls.Add(($Arguments -join ' ')) | Out-Null
    $configPath = $Arguments[([array]::IndexOf($Arguments, '/cfg') + 1)]
    if ($Arguments -contains '/export') {
        $script:CallOrder.Add('export') | Out-Null
        $lines = @('[Unicode]', 'Unicode=yes', '[System Access]', ("LockoutBadCount = {0}" -f $script:Policy.LockoutBadCount))
        if ($null -ne $script:Policy.ResetLockoutCount) { $lines += ("ResetLockoutCount = {0}" -f $script:Policy.ResetLockoutCount) }
        if ($null -ne $script:Policy.LockoutDuration) { $lines += ("LockoutDuration = {0}" -f $script:Policy.LockoutDuration) }
        $lines | Set-Content -LiteralPath $configPath -Encoding Unicode
        return
    }
    if ($Arguments -contains '/configure') {
        $script:CallOrder.Add('configure') | Out-Null
        $applied = Get-Content -LiteralPath $configPath -Raw -Encoding Unicode
        $script:AppliedInfs.Add($applied) | Out-Null
        if ($script:SeceditConfigureIgnored) { return }
        foreach ($key in @('LockoutBadCount', 'ResetLockoutCount', 'LockoutDuration')) {
            $match = [regex]::Match($applied, "(?m)^$key\s*=\s*(-?\d+)\s*$")
            if ($match.Success) { $script:Policy[$key] = [int]$match.Groups[1].Value }
        }
        return
    }
    throw "Unexpected secedit arguments: $($Arguments -join ' ')"
}
function Invoke-BoundedGpupdate {
    param([int]$TimeoutSeconds = 120)
    $script:GpupdateCalls++
    $script:CallOrder.Add('gpupdate') | Out-Null
}
function Start-Process {
    param([string]$FilePath, [string[]]$ArgumentList, [string]$WindowStyle, [switch]$PassThru, $ErrorAction)
    # Handle mirrors the real Process property the implementation caches so ExitCode stays
    # readable after exit on 5.1; WaitForExit is called both with and without a budget.
    $fake = [pscustomobject]@{ Id = 424242; ExitCode = $script:ProcessExitCode; Handle = [IntPtr]::Zero }
    $fake | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param([int]$Milliseconds = 0) if ($Milliseconds -eq 0) { return } return $script:ProcessExitsInTime }
    $fake | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $script:ProcessDisposed = $true }
    return $fake
}
function taskkill.exe { $script:TaskkillArgs = @($args) }

function Reset-TestState {
    $script:LogLines.Clear()
    $script:HostAnswers.Clear()
    $script:HostPrompts.Clear()
    $script:SecureAnswers.Clear()
    $script:SecurePromptCount = 0
    $script:Accounts = @(
        [pscustomobject]@{ Name = 'Administrator'; SID = 'S-1-5-21-11-22-33-500'; Disabled = $false }
        [pscustomobject]@{ Name = 'Occupied';      SID = 'S-1-5-21-11-22-33-1002'; Disabled = $false }
    )
    $script:Profiles = @{ 'S-1-5-21-11-22-33-500' = 'C:\Users\Administrator' }
    $script:GroupMembers = @('S-1-5-21-11-22-33-500')
    $script:GroupEnumerationFails = $false
    $script:DomainJoined = $false
    $script:CurrentSid = 'S-1-5-21-11-22-33-1001'
    $script:RenameCalls.Clear()
    $script:NewUserCalls.Clear()
    $script:RenameFailFor = @()
    $script:SetUserCalls.Clear()
    $script:SetUserFails = $false
    $script:SeceditCalls.Clear()
    $script:AppliedInfs.Clear()
    $script:CallOrder.Clear()
    $script:Policy = @{ LockoutBadCount = 5; ResetLockoutCount = 30; LockoutDuration = 30 }
    $script:SeceditConfigureIgnored = $false
    $script:GpupdateCalls = 0
    $script:TaskkillArgs = @()
    $script:ProcessExitsInTime = $true
    $script:ProcessExitCode = 0
    $script:ProcessDisposed = $false
    $Global:NoPause = $false
    # Every block starts from a machine that HAS a configured name, so a block asserting the
    # "nothing configured" behaviour has to clear it explicitly and cannot pass by accident.
    $Global:Config.administratorAccount.defaultNewName = 'PromptedAdmin'
    Remove-Item -LiteralPath (Join-Path $testRoot 'backups') -Recurse -Force -ErrorAction SilentlyContinue
}

# $Entry/$ConfirmEntry are the plaintext the test turns into SecureStrings before handing them
# to the mocked prompt; the implementation never sees a string.
function Set-InteractiveRename {
    param([string]$Entry = $secretValue, [string]$ConfirmEntry = $secretValue, [string]$Answer = 'y')
    $script:SecureAnswers.Enqueue((New-TestSecureString $Entry))
    $script:SecureAnswers.Enqueue((New-TestSecureString $ConfirmEntry))
    $script:HostAnswers.Enqueue($Answer)
}

function Get-BackupText {
    $directory = Join-Path $testRoot 'backups'
    if (-not (Test-Path -LiteralPath $directory)) { return '' }
    return ((Get-ChildItem -LiteralPath $directory -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n")
}

try {
    # --- name validation ----------------------------------------------------
    Assert-True (Test-ValidLocalAccountName "ServerAdmin") "Expected valid local account name was rejected."
    foreach ($invalid in @("", "name/with/slash", "name.", "123456789012345678901")) {
        Assert-True (-not (Test-ValidLocalAccountName $invalid)) "Invalid local account name was accepted: $invalid"
    }

    # --- two records in the same second must not overwrite each other --------
    # These are the recovery records for the rename and for the lockout change, so a lost one is
    # exactly the data an operator needs after something went wrong. The filename stamp is
    # second-granular; a frozen clock makes the collision deterministic instead of a race.
    Reset-TestState
    function Get-Date { return [datetime]::new(2026, 1, 2, 3, 4, 5, [DateTimeKind]::Utc) }
    try {
        $firstRecord = Write-AccountSecurityBackup -Kind 'administrator-name' -Data ([pscustomobject]@{ Marker = 'first' })
        $secondRecord = Write-AccountSecurityBackup -Kind 'administrator-name' -Data ([pscustomobject]@{ Marker = 'second' })
    } finally { Remove-Item -LiteralPath Function:\Get-Date -Force }
    Assert-True ($firstRecord -ne $secondRecord) "Two records written in the same second must not share a path. Both were '$firstRecord'."
    Assert-Equal 2 (@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'backups') -File)).Count "Two same-second backups must leave two files on disk."
    $firstData = Get-Content -LiteralPath $firstRecord -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 'first' $firstData.Data.Marker "The earlier recovery record must survive the later write, not be overwritten by it."
    Assert-True ((Split-Path -Leaf $secondRecord) -like 'account-security-administrator-name-*.json') "A suffixed record must still match the pattern the restore path globs for."

    # --- happy path: rename + password, fully verified -----------------------
    Reset-TestState
    Set-InteractiveRename
    $result = Rename-BuiltinAdministratorAccount -NewName 'ServerAdmin'
    Assert-Equal $true $result.Changed "Rename must report a change."
    Assert-Equal 'Administrator' $result.OldName "OldName must be the original RID-500 name."
    Assert-Equal 'ServerAdmin' $result.NewName "NewName must be the requested name."
    Assert-Equal $true $result.PasswordUpdated "PasswordUpdated must be reported."
    Assert-Equal $true $result.Verified "A clean rename must verify."
    Assert-Equal $false $result.RebootRequired "A rename of an account other than the signed-in one needs no reboot."
    Assert-Equal 2 $script:SecurePromptCount "The password needs one entry plus one confirmation, both hidden."
    Assert-Equal 1 $script:RenameCalls.Count "Exactly one rename must be issued."
    Assert-Equal 1 $script:SetUserCalls.Count "The password must be applied exactly once."
    Assert-Equal 'S-1-5-21-11-22-33-500' $script:SetUserCalls[0].SID "The password must be applied by SID, not by name."
    Assert-Equal 'System.Security.SecureString' $script:SetUserCalls[0].PasswordType "The password must reach Set-LocalUser as a SecureString."
    Assert-Equal $secretValue.Length $script:SetUserCalls[0].PasswordLength "The full password must reach Set-LocalUser."
    $logText = $script:LogLines -join "`n"
    Assert-True ($logText -match "name='Administrator'; enabled=True; SID=S-1-5-21-11-22-33-500; profile='C:\\Users\\Administrator'") "The pre-change state (name, enabled, SID, profile) must be displayed."
    Assert-True ($logText -match "name='ServerAdmin'; enabled=True; SID=S-1-5-21-11-22-33-500; profile='C:\\Users\\Administrator'") "SID and profile mapping must be shown to be preserved after the rename."
    Assert-True (($script:HostPrompts -join "`n") -match "Rename 'Administrator' to 'ServerAdmin' and set the new password") "An explicit confirmation must precede the change."

    # --- the password must not leak anywhere observable ----------------------
    $observable = @($logText, (Get-BackupText), ($script:SeceditCalls -join "`n"), (($script:SetUserCalls | ConvertTo-Json -Depth 4)), (($script:RenameCalls | ConvertTo-Json -Depth 4)), (($result | ConvertTo-Json -Depth 4))) -join "`n"
    Assert-True ($observable -notmatch [regex]::Escape($secretValue)) "The password value must never appear in logs, backups, arguments or results."
    Assert-True ((Get-BackupText) -notmatch '(?i)password') "Recovery records must not even mention a password field."

    # --- the existing account is RENAMED, never replaced by a new one --------
    # Requirement: "rename exactly the current administrator account, do not create a new user."
    # A rename must leave the account population unchanged, move the ORIGINAL name off the
    # machine, and land the new name on the same SID that carried the old one.
    Reset-TestState
    Set-InteractiveRename
    $result = Rename-BuiltinAdministratorAccount -NewName 'ServerAdmin'
    Assert-Equal 0 $script:NewUserCalls.Count "The administrator must be renamed in place; creating an account is the defect this guards."
    Assert-Equal 2 (@($script:Accounts)).Count "A rename must not add an account to the machine."
    Assert-Equal 1 (@($script:Accounts | Where-Object { [string]$_.SID -eq 'S-1-5-21-11-22-33-500' })).Count "The RID-500 account must still be the only one with that SID."
    Assert-Equal 'ServerAdmin' ([string](@($script:Accounts | Where-Object { [string]$_.SID -eq 'S-1-5-21-11-22-33-500' })[0].Name)) "The SAME RID-500 SID must carry the new name after the rename."
    Assert-Equal 0 (@($script:Accounts | Where-Object { [string]$_.Name -eq 'Administrator' })).Count "The original name must be gone, not left behind on a second account."
    Assert-Equal 'S-1-5-21-11-22-33-500' $script:RenameCalls[0].SID "The rename must be issued against the RID-500 SID, never a display name."
    Assert-Equal $true $result.Verified "A rename of the real RID-500 account must verify."

    # --- the target is the RID-500 SID, not anything that merely ends in -500 -
    Assert-True (Test-BuiltinAdministratorSid 'S-1-5-21-11-22-33-500') "The machine's RID-500 SID must be recognised as the built-in Administrator."
    foreach ($notAdmin in @('S-1-5-21-11-22-33-1500', 'S-1-5-21-11-22-33-1000', 'S-1-5-21-11-22-33-501', 'S-1-5-32-544', 'S-1-5-80-1-2-3-4-500', '', 'Administrator')) {
        Assert-True (-not (Test-BuiltinAdministratorSid $notAdmin)) "A SID that is not the machine's RID-500 account must never be the rename target: '$notAdmin'"
    }

    # Listed FIRST so a suffix-only match plus Select-Object -First 1 would pick the wrong
    # principal, and made a group member so it would sail through verification unnoticed.
    Reset-TestState
    $script:Accounts = @([pscustomobject]@{ Name = 'Decoy'; SID = 'S-1-5-80-1-2-3-4-500'; Disabled = $false }) + $script:Accounts
    $script:GroupMembers = @('S-1-5-21-11-22-33-500', 'S-1-5-80-1-2-3-4-500')
    Set-InteractiveRename
    $null = Rename-BuiltinAdministratorAccount -NewName 'ServerAdmin'
    Assert-Equal 'Decoy' ([string]$script:Accounts[0].Name) "A principal whose SID merely ends in -500 must never be the account that gets renamed."
    Assert-Equal 'ServerAdmin' ([string](@($script:Accounts | Where-Object { [string]$_.SID -eq 'S-1-5-21-11-22-33-500' })[0].Name)) "The machine's RID-500 account must be the one renamed."
    Assert-Equal 'S-1-5-21-11-22-33-500' $script:RenameCalls[0].SID "The rename must target the RID-500 SID even when another principal sorts ahead of it."

    # --- reboot signal when renaming the signed-in account -------------------
    Reset-TestState
    $script:CurrentSid = 'S-1-5-21-11-22-33-500'
    Set-InteractiveRename
    $result = Rename-BuiltinAdministratorAccount -NewName 'ServerAdmin'
    Assert-Equal $true $result.RebootRequired "Renaming the signed-in account must flag a reboot."

    # --- idempotent: already renamed ----------------------------------------
    Reset-TestState
    $script:Accounts[0].Name = 'ServerAdmin'
    $result = Rename-BuiltinAdministratorAccount -NewName 'ServerAdmin'
    Assert-Equal $false $result.Changed "An already-renamed account must not report a change."
    Assert-Equal 'ServerAdmin' $result.NewName "The reported name must stay the current one."
    Assert-Equal $true $result.Verified "An already-correct name is verified."
    Assert-Equal 0 $script:RenameCalls.Count "An already-renamed account must not be renamed again."
    Assert-Equal 0 $script:SecurePromptCount "An idempotent run must not prompt for a password."

    # --- invalid name rejected ----------------------------------------------
    Reset-TestState
    $message = Assert-Throws { Rename-BuiltinAdministratorAccount -NewName 'bad/name' } "An invalid account name must be rejected."
    Assert-True ($message -match 'invalid or longer than 20') "Invalid names must fail with a clear reason. Got: $message"
    Assert-Equal 0 $script:RenameCalls.Count "An invalid name must not reach Rename-LocalUser."
    Assert-Equal 0 $script:SecurePromptCount "An invalid name must be rejected before any password prompt."

    # --- collision rejected --------------------------------------------------
    Reset-TestState
    $message = Assert-Throws { Rename-BuiltinAdministratorAccount -NewName 'Occupied' } "A colliding account name must be rejected."
    Assert-True ($message -match "already exists") "Collisions must fail with a clear reason. Got: $message"
    Assert-Equal 0 $script:RenameCalls.Count "A colliding name must not reach Rename-LocalUser."
    Assert-Equal 0 $script:SecurePromptCount "A colliding name must be rejected before any password prompt."

    # --- password mismatch: rejected, nothing renamed ------------------------
    Reset-TestState
    $script:SecureAnswers.Enqueue((New-TestSecureString $secretValue))
    $script:SecureAnswers.Enqueue((New-TestSecureString 'Different-Value!'))
    $message = Assert-Throws { Rename-BuiltinAdministratorAccount -NewName 'ServerAdmin' } "Mismatched password entries must be rejected."
    Assert-True ($message -match 'did not match') "A mismatch must be reported as such. Got: $message"
    Assert-Equal 0 $script:RenameCalls.Count "A password mismatch must not rename the account."
    Assert-Equal 0 $script:SetUserCalls.Count "A password mismatch must not touch the password."
    Assert-Equal 'Administrator' $script:Accounts[0].Name "The account name must be untouched after a mismatch."
    Assert-True ((($script:LogLines -join "`n") + $message) -notmatch [regex]::Escape($secretValue)) "A rejected password must not be echoed."

    # --- empty password rejected --------------------------------------------
    Reset-TestState
    $script:SecureAnswers.Enqueue((New-TestSecureString ''))
    $script:SecureAnswers.Enqueue((New-TestSecureString ''))
    $message = Assert-Throws { Rename-BuiltinAdministratorAccount -NewName 'ServerAdmin' } "An empty password must be rejected."
    Assert-True ($message -match 'must not be empty') "Empty passwords must be reported as such. Got: $message"
    Assert-Equal 0 $script:RenameCalls.Count "An empty password must not rename the account."

    # --- declined confirmation ----------------------------------------------
    Reset-TestState
    Set-InteractiveRename -Answer 'n'
    $result = Rename-BuiltinAdministratorAccount -NewName 'ServerAdmin'
    Assert-Equal $false $result.Changed "A declined confirmation must not change anything."
    Assert-Equal 0 $script:RenameCalls.Count "A declined confirmation must not rename the account."

    # --- rename failure surfaces --------------------------------------------
    Reset-TestState
    $script:RenameFailFor = @('ServerAdmin')
    Set-InteractiveRename
    $message = Assert-Throws { Rename-BuiltinAdministratorAccount -NewName 'ServerAdmin' } "A failing rename must surface."
    Assert-True ($message -match 'Access is denied') "The underlying rename failure must be reported. Got: $message"
    Assert-Equal 0 $script:SetUserCalls.Count "A failed rename must not apply the password."
    Assert-Equal 'Administrator' $script:Accounts[0].Name "A failed rename must leave the name alone."

    # --- password failure rolls the rename back ------------------------------
    Reset-TestState
    $script:SetUserFails = $true
    Set-InteractiveRename
    $message = Assert-Throws { Rename-BuiltinAdministratorAccount -NewName 'ServerAdmin' } "A failing password update must surface."
    Assert-True ($message -match 'Failed to set the new Administrator password') "The password failure must be reported. Got: $message"
    Assert-Equal 'Administrator' $script:Accounts[0].Name "A failed password update must roll the rename back."
    Assert-Equal 2 $script:RenameCalls.Count "Rollback must issue a second rename."
    Assert-Equal 'ServerAdmin' $script:RenameCalls[0].NewName "The first rename must be the requested one."
    Assert-Equal 'Administrator' $script:RenameCalls[1].NewName "The rollback must restore the original name."
    $rollbackLogs = $script:LogLines -join "`n"
    Assert-True ($rollbackLogs -match "rolled back to 'Administrator'") "The rollback result must be logged."
    Assert-True ((($rollbackLogs) + $message + (Get-BackupText)) -notmatch [regex]::Escape($secretValue)) "Rollback diagnostics must not expose the password."

    # --- rollback failure is reported, not swallowed --------------------------
    Reset-TestState
    $script:SetUserFails = $true
    $script:RenameFailFor = @('Administrator')
    Set-InteractiveRename
    $message = Assert-Throws { Rename-BuiltinAdministratorAccount -NewName 'ServerAdmin' } "A failing password update must surface even when rollback fails."
    Assert-True (($script:LogLines -join "`n") -match 'rollback to .Administrator. also failed') "A failed rollback must be reported. Logs: $($script:LogLines -join ' | ')"

    # --- lost Administrators membership fails verification -------------------
    Reset-TestState
    $script:GroupMembers = @('S-1-5-21-11-22-33-1002')
    Set-InteractiveRename
    $message = Assert-Throws { Rename-BuiltinAdministratorAccount -NewName 'ServerAdmin' } "Losing Administrators membership must fail verification."
    Assert-True ($message -match 'local Administrators group') "Membership loss must be named. Got: $message"

    # --- unverifiable membership warns instead of failing --------------------
    Reset-TestState
    $script:GroupEnumerationFails = $true
    Set-InteractiveRename
    $result = Rename-BuiltinAdministratorAccount -NewName 'ServerAdmin'
    Assert-Equal $true $result.Changed "An unrelated group-enumeration bug must not undo a good rename."
    Assert-Equal $false $result.Verified "Unverifiable membership must not be reported as verified."
    Assert-True (($script:LogLines -join "`n") -match 'could not be verified') "Unverifiable membership must be warned about."

    # --- noninteractive never blocks on a hidden prompt ----------------------
    Reset-TestState
    $Global:NoPause = $true
    $result = Rename-BuiltinAdministratorAccount -NewName 'ServerAdmin'
    Assert-Equal 0 $script:SecurePromptCount "Noninteractive mode must never open a secure prompt."
    Assert-Equal 0 $script:HostPrompts.Count "Noninteractive mode must never open any prompt."
    Assert-Equal $false $result.PasswordUpdated "Noninteractive mode must report the password as not updated."
    Assert-Equal $true $result.Changed "An explicitly supplied name may still be applied noninteractively."
    Assert-True (($script:LogLines -join "`n") -match 'Skipped the Administrator password change') "The skipped password must be reported explicitly."

    Reset-TestState
    $Global:NoPause = $true
    $Global:Config.administratorAccount.defaultNewName = ''
    $result = Rename-BuiltinAdministratorAccount
    Assert-Equal $false $result.Changed "Noninteractive mode without a configured name must skip."
    Assert-Equal 0 $script:HostPrompts.Count "Noninteractive mode must not prompt for a name."
    Assert-True (($script:LogLines -join "`n") -match 'Skipped the Administrator rename') "The skipped rename must be reported explicitly."

    # --- noninteractive WITH a configured name falls back to it and says so ---
    # There is no console to ask, so the configured value is the only remaining source. It must
    # still be applied - silently skipping would leave a provisioning run half-done - and the
    # substitution has to be visible in the log rather than looking like an operator decision.
    Reset-TestState
    $Global:NoPause = $true
    $Global:Config.administratorAccount.defaultNewName = 'ConfiguredAdmin'
    $result = Rename-BuiltinAdministratorAccount
    Assert-Equal $true $result.Changed "Noninteractive mode must fall back to the configured name instead of skipping the rename."
    Assert-Equal 'ConfiguredAdmin' $result.NewName "The configured name must be the one applied."
    Assert-Equal 'ConfiguredAdmin' ([string]$script:Accounts[0].Name) "The RID-500 account must actually carry the configured name."
    Assert-Equal 0 $script:HostPrompts.Count "The noninteractive fallback must not open a prompt."
    Assert-Equal 0 $script:SecurePromptCount "The noninteractive fallback must not open a secure prompt."
    Assert-True (($script:LogLines -join "`n") -match "configured name 'ConfiguredAdmin'") "Falling back to configuration must be logged, not silent."

    # --- full setup ASKS for the name; configuration only supplies the default -
    # The reported defect: a configured defaultNewName was handed straight to the rename, so a
    # full setup renamed the administrator without ever asking. The operator's answer must win,
    # and the prompt must happen even when a name is configured.
    Reset-TestState
    $Global:Config.administratorAccount.defaultNewName = 'ConfiguredAdmin'
    $script:HostAnswers.Enqueue('ChosenByOperator')
    Set-InteractiveRename
    Invoke-ConfiguredAccountSecurity
    Assert-True (($script:HostPrompts -join "`n") -match 'New name for the built-in Administrator account') "Full setup must ASK for the new Administrator name instead of taking it silently from configuration."
    Assert-Equal 1 $script:RenameCalls.Count "Exactly one rename must be issued."
    Assert-Equal 'S-1-5-21-11-22-33-500' $script:RenameCalls[0].SID "The rename must target the RID-500 SID."
    Assert-Equal 'ChosenByOperator' $script:RenameCalls[0].NewName "The operator's answer must be the applied name, not the configured one."
    Assert-Equal 'ChosenByOperator' ([string]$script:Accounts[0].Name) "The RID-500 account must carry the name the operator typed."
    Assert-Equal 0 $script:NewUserCalls.Count "Full setup must rename the existing administrator, never create one."

    # --- lockout: threshold to 0, duration untouched -------------------------
    Reset-TestState
    $result = Disable-LocalAccountLockoutPolicy
    Assert-Equal 5 $result.PreviousThreshold "The previous threshold must be reported."
    Assert-Equal 0 $result.CurrentThreshold "The threshold must end at 0."
    Assert-Equal $false $result.DomainJoined "A workgroup machine must not be reported as domain-joined."
    Assert-Equal $true $result.Changed "A real threshold change must be reported."
    Assert-Equal $true $result.Verified "A verified change must be reported."
    Assert-Equal $null $result.OverrideWarning "A workgroup machine needs no override warning."
    Assert-Equal 1 $script:AppliedInfs.Count "Exactly one policy write must be issued."
    $applied = $script:AppliedInfs[0]
    Assert-True ($applied -match '(?m)^LockoutBadCount = 0\s*$') "The applied policy must set the threshold to 0."
    Assert-True ($applied -match '(?m)^LockoutDuration = 30\s*$') "The applied policy must pass the existing lockout duration through unchanged."
    Assert-True ($applied -match '(?m)^ResetLockoutCount = 30\s*$') "The applied policy must pass the existing reset window through unchanged."
    Assert-True ($applied -notmatch '(?m)^LockoutDuration = 0\s*$') "The lockout duration must never be forced to 0."
    Assert-Equal 30 $script:Policy.LockoutDuration "The machine's lockout duration must be left as it was."
    Assert-Equal 30 $script:Policy.ResetLockoutCount "The machine's reset window must be left as it was."

    # --- lockout: already disabled, and Windows omits the duration keys ------
    Reset-TestState
    $script:Policy = @{ LockoutBadCount = 0; ResetLockoutCount = $null; LockoutDuration = $null }
    $result = Disable-LocalAccountLockoutPolicy
    Assert-Equal 0 $result.PreviousThreshold "An already-disabled threshold must be reported as 0."
    Assert-Equal $false $result.Changed "An already-disabled policy must not report a change."
    Assert-Equal $true $result.Verified "An already-disabled policy is verified."
    Assert-Equal 0 $script:AppliedInfs.Count "An already-disabled policy must not be rewritten."

    # --- lockout: the recovery record restores the original values -----------
    Reset-TestState
    $null = Disable-LocalAccountLockoutPolicy
    Assert-Equal 0 $script:Policy.LockoutBadCount "The threshold must be disabled before restoring."
    $script:Policy = @{ LockoutBadCount = 0; ResetLockoutCount = 99; LockoutDuration = 99 }
    Restore-LocalAccountLockoutPolicy
    Assert-Equal 5 $script:Policy.LockoutBadCount "Restore must put the original threshold back."
    Assert-Equal 30 $script:Policy.LockoutDuration "Restore must put the original lockout duration back."
    Assert-Equal 30 $script:Policy.ResetLockoutCount "Restore must put the original reset window back."

    # A record captured while Windows omitted the duration keys must not restore them as 0.
    Reset-TestState
    $script:Policy = @{ LockoutBadCount = 3; ResetLockoutCount = $null; LockoutDuration = $null }
    $null = Disable-LocalAccountLockoutPolicy
    $script:Policy = @{ LockoutBadCount = 0; ResetLockoutCount = 99; LockoutDuration = 99 }
    Restore-LocalAccountLockoutPolicy
    Assert-Equal 3 $script:Policy.LockoutBadCount "Restore must put the original threshold back."
    Assert-Equal 99 $script:Policy.LockoutDuration "An absent recorded duration must be left alone, not written as 0."
    Assert-True ($script:AppliedInfs[-1] -notmatch 'LockoutDuration') "An absent recorded duration must not be written to the policy file at all."

    # --- lockout: verification mismatch fails --------------------------------
    Reset-TestState
    $script:SeceditConfigureIgnored = $true
    $message = Assert-Throws { Disable-LocalAccountLockoutPolicy } "A policy that did not take effect must fail verification."
    Assert-True ($message -match 'verification failed') "Verification failure must be named. Got: $message"
    Assert-True ($message -match 'Recovery record') "Verification failure must point at the recovery record. Got: $message"

    # --- lockout: domain-joined warning and declined change ------------------
    Reset-TestState
    $script:DomainJoined = $true
    $script:HostAnswers.Enqueue('n')
    $result = Disable-LocalAccountLockoutPolicy
    Assert-Equal $true $result.DomainJoined "A domain-joined machine must be reported as such."
    Assert-True ($null -ne $result.OverrideWarning) "A domain-joined machine must carry an override warning."
    Assert-True ($result.OverrideWarning -match 'Group Policy can override') "The override warning must explain the risk."
    Assert-Equal $false $result.Changed "A declined domain-impact prompt must change nothing."
    Assert-Equal 0 $script:AppliedInfs.Count "A declined domain-impact prompt must not write policy."

    Reset-TestState
    $script:DomainJoined = $true
    $result = Disable-LocalAccountLockoutPolicy -ConfirmDomainImpact
    Assert-Equal $true $result.Changed "An explicitly confirmed domain-impact change must proceed."
    Assert-True ($null -ne $result.OverrideWarning) "The override warning must survive an explicit confirmation."
    Assert-Equal 0 $script:HostPrompts.Count "-ConfirmDomainImpact must not prompt."

    Reset-TestState
    $script:DomainJoined = $true
    $Global:NoPause = $true
    $result = Disable-LocalAccountLockoutPolicy
    Assert-Equal $false $result.Changed "Noninteractive mode must not silently override domain policy."
    Assert-Equal 0 $script:HostPrompts.Count "Noninteractive mode must not open the domain-impact prompt."

    # --- gpupdate runs before the verification read-back ---------------------
    Reset-TestState
    $result = Disable-LocalAccountLockoutPolicy -RunGpupdate
    Assert-Equal 1 $script:GpupdateCalls "gpupdate must run when requested."
    Assert-Equal 'export,configure,gpupdate,export' ($script:CallOrder -join ',') "Policy refresh must happen between the write and the verification read-back."
    Assert-Equal $true $result.Verified "The verified read-back must follow the refresh."

    Reset-TestState
    $null = Disable-LocalAccountLockoutPolicy
    Assert-Equal 0 $script:GpupdateCalls "gpupdate must not run unless requested."

    # --- bounded gpupdate: expiry kills the tree and fails --------------------
    Reset-TestState
    $script:ProcessExitsInTime = $false
    $message = Assert-Throws { & $realBoundedGpupdate -TimeoutSeconds 1 } "An expired gpupdate must fail rather than block."
    Assert-True ($message -match 'did not complete within 1 seconds') "The timeout must be reported. Got: $message"
    Assert-True (($script:TaskkillArgs -join ' ') -match '/PID 424242') "The expired process must be targeted by PID."
    Assert-True (($script:TaskkillArgs -join ' ') -match '/T') "The whole process tree must be terminated."
    Assert-Equal $true $script:ProcessDisposed "The process handle must be released."

    Reset-TestState
    $script:ProcessExitCode = 1
    $message = Assert-Throws { & $realBoundedGpupdate } "A failing gpupdate must surface its exit code."
    Assert-True ($message -match 'exit code 1') "The gpupdate exit code must be reported. Got: $message"

    Reset-TestState
    & $realBoundedGpupdate
    Assert-Equal $true $script:ProcessDisposed "A successful gpupdate must still release the process handle."

    Write-Host "PASS RID-500 rename-never-create with an operator-chosen name, confirmed hidden password, transactional rollback, leak-free logging, preserved lockout duration and bounded pre-verification policy refresh."
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
