# Conservative local account and lockout-policy operations with JSON recovery records.
#
# Password handling contract for the built-in Administrator rename:
#   * the new password is only ever read from an interactive hidden prompt into a SecureString;
#   * it is never accepted from configuration, a parameter, an environment variable or a
#     command line, and never converted into a managed plaintext string;
#   * it is handed straight to Set-LocalUser and disposed immediately afterwards;
#   * it never reaches a log line, a console write, a recovery record or a process argument.

function Test-ValidLocalAccountName {
    param([AllowEmptyString()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 20 -or $Name -ne $Name.Trim()) { return $false }
    if ($Name.EndsWith('.')) { return $false }
    return $Name -notmatch '["/\\\[\]:;|=,+*?<>@]'
}

function Get-BuiltinAdministratorAccount {
    $account = Get-CimInstance -ClassName Win32_UserAccount -Filter "LocalAccount=True" -ErrorAction Stop |
        Where-Object { [string]$_.SID -match '-500$' } | Select-Object -First 1
    if (-not $account) { throw "The built-in RID-500 local Administrator account was not found." }
    return $account
}

function Get-CurrentUserSid {
    return [string]([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
}

# Win32_UserProfile is the only reliable SID-to-profile mapping; an account that has never
# signed in simply has no entry, which is reported as an empty string rather than an error.
function Get-LocalAccountProfilePath {
    param([Parameter(Mandatory)][string]$Sid)
    $userProfile = Get-CimInstance -ClassName Win32_UserProfile -Filter ("SID='{0}'" -f $Sid) -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($userProfile) { return [string]$userProfile.LocalPath }
    return ''
}

# The well-known SID S-1-5-32-544 keeps this locale-independent. Get-LocalGroupMember is known
# to fail outright on machines whose Administrators group still holds orphaned SIDs, so an
# enumeration error returns $null ("unknown") instead of $false ("not a member") - an unrelated
# Windows bug must not be reported as a lost administrator.
function Test-LocalAdministratorsMembership {
    param([Parameter(Mandatory)][string]$Sid)
    try {
        $members = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)
    } catch {
        Write-Warn ("Could not enumerate the local Administrators group: {0}" -f $_.Exception.Message)
        return $null
    }
    foreach ($member in $members) {
        if ([string]$member.SID -eq $Sid) { return $true }
    }
    return $false
}

function Read-SecurePasswordPrompt {
    param([Parameter(Mandatory)][string]$Prompt)
    return Read-Host -Prompt $Prompt -AsSecureString
}

# Compares two SecureStrings without ever materialising a managed plaintext copy: the BSTRs are
# read byte by byte and zeroed in the finally block. Marshalling the BSTR into a managed string
# instead would create an immutable copy that cannot be cleared and would linger in the heap
# until the garbage collector happened to reclaim it.
function Test-SecureStringMatch {
    param(
        [Parameter(Mandatory)][System.Security.SecureString]$First,
        [Parameter(Mandatory)][System.Security.SecureString]$Second
    )
    if ($First.Length -ne $Second.Length) { return $false }
    $firstPtr = [IntPtr]::Zero
    $secondPtr = [IntPtr]::Zero
    try {
        $firstPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($First)
        $secondPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Second)
        $byteCount = $First.Length * 2
        for ($index = 0; $index -lt $byteCount; $index++) {
            if ([Runtime.InteropServices.Marshal]::ReadByte($firstPtr, $index) -ne [Runtime.InteropServices.Marshal]::ReadByte($secondPtr, $index)) { return $false }
        }
        return $true
    } finally {
        if ($firstPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstPtr) }
        if ($secondPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secondPtr) }
    }
}

# Two hidden prompts. Returns the accepted SecureString; the caller owns and disposes it.
function Read-ConfirmedAdministratorPassword {
    $first = $null
    $second = $null
    $accepted = $false
    try {
        $first = Read-SecurePasswordPrompt -Prompt 'New password for the built-in Administrator account'
        $second = Read-SecurePasswordPrompt -Prompt 'Confirm the new password'
        if (-not $first -or $first.Length -eq 0) { throw "The new Administrator password must not be empty." }
        if (-not $second -or -not (Test-SecureStringMatch -First $first -Second $second)) {
            throw "The two password entries did not match; no account change was made."
        }
        $accepted = $true
        return $first
    } finally {
        if ($second) { $second.Dispose() }
        if (-not $accepted -and $first) { $first.Dispose() }
    }
}

function Write-AccountSecurityBackup {
    param([string]$Kind, [Parameter(Mandatory)]$Data)
    $root = if ($Global:ProjectRoot) { $Global:ProjectRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    $directory = Join-Path $root 'backups'
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    # The stamp is second-granular, so two records written in the same second would land on the
    # same path and the earlier recovery record would be lost. Suffix until the name is free -
    # the same idiom scripts\Run-PostRebootSfc.ps1 uses for its timestamped logs.
    $baseName = "account-security-{0}-{1}" -f $Kind, (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $path = Join-Path $directory "$baseName.json"
    $suffix = 1
    while (Test-Path -LiteralPath $path) { $path = Join-Path $directory "$baseName-$suffix.json"; $suffix++ }
    [pscustomobject]@{ Version = 1; Kind = $Kind; CreatedUtc = (Get-Date).ToUniversalTime().ToString('o'); Data = $Data } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Rename-BuiltinAdministratorAccount {
    param([string]$NewName = '')

    $account = Get-BuiltinAdministratorAccount
    $originalName = [string]$account.Name
    $sid = [string]$account.SID
    $profilePath = Get-LocalAccountProfilePath -Sid $sid

    # Show exactly what is about to change before anything is touched.
    Write-Info ("Built-in Administrator (before): name='{0}'; enabled={1}; SID={2}; profile='{3}'" -f $originalName, (-not [bool]$account.Disabled), $sid, $profilePath)

    $result = [pscustomobject]@{
        Changed         = $false
        OldName         = $originalName
        NewName         = $originalName
        PasswordUpdated = $false
        Verified        = $false
        RebootRequired  = $false
    }

    # -NoPause/-Full must never block on a prompt - least of all a hidden one.
    $interactive = -not $Global:NoPause

    if ([string]::IsNullOrWhiteSpace($NewName)) {
        if (-not $interactive) {
            Write-Warn "Skipped the Administrator rename: no name is configured and noninteractive mode cannot prompt for one."
            return $result
        }
        $NewName = Read-HostThemed -Prompt 'New name for the built-in Administrator account' -DefaultValue ([string]$Global:Config.administratorAccount.defaultNewName)
    }
    if (-not (Test-ValidLocalAccountName $NewName)) { throw "The requested local account name is invalid or longer than 20 characters." }
    if ([string]::Equals($originalName, $NewName, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Ok "Built-in Administrator already uses the requested name."
        $result.Verified = $true
        return $result
    }
    if (Get-LocalUser -Name $NewName -ErrorAction SilentlyContinue) { throw "A local account named '$NewName' already exists." }

    $backup = $null
    $securePassword = $null
    try {
        # The password is collected only after every name check has passed, and before any
        # mutation, so a mismatch cancels the rename as well.
        if ($interactive) {
            $securePassword = Read-ConfirmedAdministratorPassword
        } else {
            Write-Warn "Skipped the Administrator password change: noninteractive mode must never block on a hidden prompt."
        }

        if ($interactive) {
            $suffix = if ($securePassword) { ' and set the new password' } else { '' }
            $answer = Read-HostThemed -Prompt ("Rename '{0}' to '{1}'{2}? [y/N]" -f $originalName, $NewName, $suffix) -DefaultValue 'N'
            if ($answer -notmatch '^(?i)y(es)?$') {
                Write-Warn "Administrator rename cancelled."
                return $result
            }
        }

        $backup = Write-AccountSecurityBackup -Kind 'administrator-name' -Data ([pscustomobject]@{
            SID           = $sid
            OriginalName  = $originalName
            RequestedName = $NewName
            ProfilePath   = $profilePath
        })
        Rename-LocalUser -SID $sid -NewName $NewName -ErrorAction Stop
        $result.Changed = $true
        $result.NewName = $NewName

        if ($securePassword) {
            try {
                Set-LocalUser -SID $sid -Password $securePassword -ErrorAction Stop
                $result.PasswordUpdated = $true
            } catch {
                # Transactional rollback: the rename is undone so the machine is left exactly as
                # it started. Neither message can contain the password - it was never a string.
                $failure = $_.Exception.Message
                try {
                    Rename-LocalUser -SID $sid -NewName $originalName -ErrorAction Stop
                    $result.Changed = $false
                    $result.NewName = $originalName
                    Write-Warn ("Password update failed; the account name was rolled back to '{0}'. Recovery record: {1}" -f $originalName, $backup)
                } catch {
                    Write-Warn ("Password update failed and the rollback to '{0}' also failed: {1}. Recovery record: {2}" -f $originalName, $_.Exception.Message, $backup)
                }
                throw "Failed to set the new Administrator password: $failure"
            }
        }
    } finally {
        if ($securePassword) { $securePassword.Dispose() }
    }

    $verified = Get-BuiltinAdministratorAccount
    if ([string]$verified.SID -ne $sid -or [string]$verified.SID -notmatch '-500$') { throw "Rename verification failed: the RID-500 SID changed. Recovery record: $backup" }
    if ([string]$verified.Name -ne $NewName) { throw "Rename verification failed: the account is named '$($verified.Name)'. Recovery record: $backup" }
    if ([bool]$verified.Disabled) { throw "Rename verification failed: the renamed account is disabled. Recovery record: $backup" }
    $membership = Test-LocalAdministratorsMembership -Sid $sid
    if ($membership -eq $false) { throw "Rename verification failed: the account is no longer a member of the local Administrators group. Recovery record: $backup" }

    $profileAfter = Get-LocalAccountProfilePath -Sid $sid
    if ($profilePath -and $profileAfter -and $profileAfter -ne $profilePath) {
        Write-Warn ("Profile path changed from '{0}' to '{1}'." -f $profilePath, $profileAfter)
    }

    $result.Verified = ($membership -eq $true)
    # Renaming the account you are signed in as leaves the running session showing the old name.
    $result.RebootRequired = ((Get-CurrentUserSid) -eq $sid)

    Write-Info ("Built-in Administrator (after): name='{0}'; enabled={1}; SID={2}; profile='{3}'" -f ([string]$verified.Name), (-not [bool]$verified.Disabled), $sid, $profileAfter)
    Write-Ok ("Built-in Administrator renamed to '{0}' and verified by SID." -f $NewName)
    if ($result.PasswordUpdated) { Write-Ok "Built-in Administrator password updated." }
    if ($null -eq $membership) { Write-Warn "Administrators group membership could not be verified; check it manually." }
    if ($result.RebootRequired) { Write-Warn "You are signed in as the renamed account; sign out or reboot so the session picks up the new name." }
    Write-Info "Recovery record: $backup"
    return $result
}

function Restore-BuiltinAdministratorName {
    $root = if ($Global:ProjectRoot) { $Global:ProjectRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    $record = Get-ChildItem -LiteralPath (Join-Path $root 'backups') -Filter 'account-security-administrator-name-*.json' -File -ErrorAction Stop | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $record) { throw "No Administrator rename recovery record was found." }
    $backup = Get-Content -LiteralPath $record.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $current = Get-BuiltinAdministratorAccount
    if ([string]$current.SID -ne [string]$backup.Data.SID) { throw "Recovery SID does not match the current RID-500 account." }
    $originalName = [string]$backup.Data.OriginalName
    if (-not (Test-ValidLocalAccountName $originalName)) { throw "Recovery record contains an invalid account name." }
    if ([string]$current.Name -eq $originalName) { Write-Ok "Built-in Administrator name already matches the recovery record."; return }
    if (Get-LocalUser -Name $originalName -ErrorAction SilentlyContinue) { throw "Cannot restore because '$originalName' is already in use." }
    Rename-LocalUser -SID ([string]$current.SID) -NewName $originalName -ErrorAction Stop
    $verified = Get-BuiltinAdministratorAccount
    if ([string]$verified.SID -ne [string]$backup.Data.SID -or [string]$verified.Name -ne $originalName) { throw "Administrator name restoration verification failed." }
    Write-Ok "Built-in Administrator name restored to '$originalName'."
}

function Invoke-SeceditChecked {
    param([Parameter(Mandatory)][string[]]$Arguments)
    & secedit.exe @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Local security policy command failed with exit code $LASTEXITCODE." }
}

function Export-LocalLockoutPolicy {
    $temporaryPath = Join-Path $env:TEMP ("WinServerSetup-policy-{0}.inf" -f [guid]::NewGuid().ToString('N'))
    try {
        Invoke-SeceditChecked @('/export', '/cfg', $temporaryPath, '/areas', 'SECURITYPOLICY', '/quiet')
        $text = Get-Content -LiteralPath $temporaryPath -Raw -Encoding Unicode
        $values = [ordered]@{}
        foreach ($key in @('LockoutBadCount', 'ResetLockoutCount', 'LockoutDuration')) {
            $match = [regex]::Match($text, "(?m)^$key\s*=\s*(-?\d+)\s*$")
            # Windows drops the duration and reset window from the export once the threshold is
            # 0, because they no longer apply. Only the threshold itself is required.
            $values[$key] = if ($match.Success) { [int]$match.Groups[1].Value } else { $null }
        }
        if ($null -eq $values['LockoutBadCount']) { throw "Exported local policy did not contain LockoutBadCount." }
        return [pscustomobject]$values
    } finally { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
}

# $ResetLockoutCount and $LockoutDuration are deliberately untyped so $null means "leave this
# value alone" - the key is then simply not written to the INF.
function Set-LocalLockoutPolicyValues {
    param([Parameter(Mandatory)][int]$LockoutBadCount, $ResetLockoutCount, $LockoutDuration)
    $id = [guid]::NewGuid().ToString('N')
    $inf = Join-Path $env:TEMP "WinServerSetup-policy-$id.inf"
    $database = Join-Path $env:TEMP "WinServerSetup-policy-$id.sdb"
    try {
        $lines = @(
            '[Unicode]', 'Unicode=yes', '[Version]', 'signature="$CHICAGO$"', 'Revision=1',
            '[System Access]', "LockoutBadCount = $LockoutBadCount"
        )
        if ($null -ne $ResetLockoutCount) { $lines += ("ResetLockoutCount = {0}" -f [int]$ResetLockoutCount) }
        if ($null -ne $LockoutDuration) { $lines += ("LockoutDuration = {0}" -f [int]$LockoutDuration) }
        $lines | Set-Content -LiteralPath $inf -Encoding Unicode
        Invoke-SeceditChecked @('/configure', '/db', $database, '/cfg', $inf, '/areas', 'SECURITYPOLICY', '/quiet')
    } finally {
        Remove-Item -LiteralPath $inf -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $database -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$database.jfm" -Force -ErrorAction SilentlyContinue
    }
}

# gpupdate blocks indefinitely when a domain controller is slow or unreachable, so it runs as a
# bounded child process and the whole tree is terminated on expiry.
function Invoke-BoundedGpupdate {
    param([int]$TimeoutSeconds = 120)
    $process = Start-Process -FilePath 'gpupdate.exe' -ArgumentList '/target:computer', '/force' -WindowStyle Hidden -PassThru -ErrorAction Stop
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            # taskkill /T kills the tree on both hosts; Process.Kill($true) does not exist on
            # the .NET Framework that Windows PowerShell 5.1 runs on.
            & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null
            throw "Group Policy refresh did not complete within $TimeoutSeconds seconds and was terminated."
        }
        if ($process.ExitCode -ne 0) { throw "Group Policy refresh failed with exit code $($process.ExitCode)." }
    } finally {
        $process.Dispose()
    }
}

function Disable-LocalAccountLockoutPolicy {
    param([switch]$ConfirmDomainImpact, [switch]$RunGpupdate)
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $domainJoined = [bool]$computer.PartOfDomain
    $result = [pscustomobject]@{
        PreviousThreshold = $null
        CurrentThreshold  = $null
        DomainJoined      = $domainJoined
        Changed           = $false
        Verified          = $false
        OverrideWarning   = $null
    }

    if ($domainJoined) {
        $result.OverrideWarning = "This machine is domain-joined; domain Group Policy can override the machine-local lockout policy at the next refresh."
        Write-Warn $result.OverrideWarning
        if (-not $ConfirmDomainImpact) {
            if ($Global:NoPause) {
                Write-Warn "Local lockout policy change skipped: noninteractive mode cannot ask for the domain-impact confirmation."
                return $result
            }
            $answer = Read-HostThemed -Prompt 'Change machine-local lockout policy anyway? [y/N]' -DefaultValue 'N'
            if ($answer -notmatch '^(?i)y(es)?$') { Write-Warn "Local lockout policy change cancelled."; return $result }
        }
    }

    $current = Export-LocalLockoutPolicy
    $result.PreviousThreshold = [int]$current.LockoutBadCount
    $result.CurrentThreshold = [int]$current.LockoutBadCount
    if ($result.PreviousThreshold -eq 0) {
        Write-Ok "Machine-local account lockout is already disabled."
        $result.Verified = $true
        return $result
    }

    $backup = Write-AccountSecurityBackup -Kind 'local-lockout' -Data $current
    # Only the threshold is disabled. The lockout duration is passed through unchanged on
    # purpose: a duration of 0 means "stays locked until an administrator unlocks it", which is
    # the opposite of the intent. Once the threshold is 0 the duration and reset window stop
    # applying and Windows may normalise or drop them - the verified goal is threshold = 0, not
    # a particular duration, so secedit reshaping those two values is not treated as a failure.
    Set-LocalLockoutPolicyValues -LockoutBadCount 0 -ResetLockoutCount $current.ResetLockoutCount -LockoutDuration $current.LockoutDuration
    # Refresh policy first, so the read-back below reflects the refreshed effective policy.
    if ($RunGpupdate) { Invoke-BoundedGpupdate }

    $verified = Export-LocalLockoutPolicy
    $result.CurrentThreshold = [int]$verified.LockoutBadCount
    if ($result.CurrentThreshold -ne 0) { throw "Local lockout policy verification failed. Recovery record: $backup" }
    $result.Changed = $true
    $result.Verified = $true
    Write-Ok ("Machine-local account lockout disabled and verified; lockout duration left unchanged at '{0}'." -f $current.LockoutDuration)
    Write-Info "Recovery record: $backup"
    return $result
}

function Restore-LocalAccountLockoutPolicy {
    $root = if ($Global:ProjectRoot) { $Global:ProjectRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    $record = Get-ChildItem -LiteralPath (Join-Path $root 'backups') -Filter 'account-security-local-lockout-*.json' -File -ErrorAction Stop | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $record) { throw "No local lockout recovery record was found." }
    $backup = Get-Content -LiteralPath $record.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Set-LocalLockoutPolicyValues -LockoutBadCount ([int]$backup.Data.LockoutBadCount) -ResetLockoutCount $backup.Data.ResetLockoutCount -LockoutDuration $backup.Data.LockoutDuration
    $verified = Export-LocalLockoutPolicy
    if ([int]$verified.LockoutBadCount -ne [int]$backup.Data.LockoutBadCount) { throw "Local lockout restoration verification failed." }
    Write-Ok "Machine-local account lockout policy restored from $($record.Name)."
}

function Invoke-ConfiguredAccountSecurity {
    $rename = $Global:Config.administratorAccount
    $lockout = $Global:Config.accountLockout
    if ($Global:NoPause -and ($rename.enabled -or $lockout.disableLocalAccountLockout)) {
        Write-Warn "Skipped account-security mutations because -NoPause is set; run the matching menu actions interactively."
        return
    }
    if ($rename.enabled) {
        $proceed = -not $rename.promptDuringFullSetup -or (Read-HostThemed -Prompt 'Rename the built-in Administrator account now? [y/N]' -DefaultValue 'N') -match '^(?i)y(es)?$'
        if ($proceed) { $null = Rename-BuiltinAdministratorAccount -NewName ([string]$rename.defaultNewName) }
    }
    if ($lockout.disableLocalAccountLockout) {
        $proceed = -not $lockout.promptDuringFullSetup -or (Read-HostThemed -Prompt 'Disable machine-local account lockout now? [y/N]' -DefaultValue 'N') -match '^(?i)y(es)?$'
        if ($proceed) { $null = Disable-LocalAccountLockoutPolicy -RunGpupdate:([bool]$lockout.runGpupdate) }
    }
}
