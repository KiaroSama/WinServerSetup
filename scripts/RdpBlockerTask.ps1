# RdpBlockerTask.ps1 - installing and health-checking the RDP brute-force blocker SYSTEM
# scheduled task: trusted-principal and path-ownership validation, staging into the directory
# this project owns, the ACL-hardened trust manifest, and the registration contract re-proved at
# health time.
#
# Split out of Rdp.ps1, which kept the port migration itself. The blocker runs as SYSTEM every few
# minutes, so anything it executes or reads is a privilege-escalation primitive if a
# non-administrator can replace it - which is why this is its own module rather than a section.
# Dot-sourced by WinServerSetup.ps1; function definitions only, globals read at call time.


# ------------------------------------------------------ H-02 / L-02 / M-04 task trust contract
# The blocker runs as SYSTEM every few minutes. Anything it executes or reads is therefore a
# privilege-escalation primitive if a non-administrator can replace it, and "a task with that
# name exists" is not evidence that the control still does its job. The functions below validate
# every target before registration, record the exact contract in an ACL-hardened manifest, and
# re-prove that contract - including the target hash and an over-long active run - at health time.

function Get-TrustedPrincipalSid {
    # Declared inside each consumer rather than at module scope: the suites AST-extract a single
    # function, so a module-level $script: table would be undefined there.
    return @(
        'S-1-5-18',      # LOCAL SYSTEM
        'S-1-5-32-544',  # BUILTIN\Administrators
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464' # NT SERVICE\TrustedInstaller
    )
}

function Get-PathOwnerSid {
    <#
        The owner of an object always holds READ_CONTROL and WRITE_DAC implicitly, whatever the
        DACL says. A user-owned file with a perfect DACL is therefore NOT safe: the owner can
        rewrite that DACL at any moment and replace content this project later executes as
        SYSTEM. Returns $null when the owner cannot be read, which callers must treat as unsafe.
    #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        $owner = (Get-Acl -LiteralPath $Path).GetOwner([System.Security.Principal.SecurityIdentifier])
        if ($null -eq $owner) { return $null }
        return [string]$owner.Value
    } catch { return $null }
}

function Get-ReplaceCapableUntrustedPrincipal {
    <#
        Which non-administrative principals can REPLACE this component - delete it, swap it, or
        rewrite its DACL and then do either.

        Deliberately narrower than Get-UntrustedAclWriter. %ProgramData% grants BUILTIN\Users
        plain `Write`, which for a directory means CreateFiles/CreateDirectories only: a user may
        add a new sibling there but cannot delete or replace an existing subdirectory. Treating
        that as disqualifying would make every ProgramData-based task location fail, so the test
        is for delete/ownership rights specifically.

        Tested as a BITMASK, never as a substring of FileSystemRights.ToString(). The enum prints
        composite values by their composite name: Modify renders as "Modify, Synchronize" and
        contains no "Delete" substring at all, yet Modify includes DELETE and is therefore fully
        replace-capable. Measured on this machine, the shipped checkout carries three ACEs of
        exactly that shape, and a string test silently cleared every one of them.

        Inherit-only ACEs are ignored: by definition they do not grant access to this object.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $trusted = Get-TrustedPrincipalSid
    $replaceMask = [int]([System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership)
    $offenders = New-Object System.Collections.Generic.List[string]
    $acl = $null
    try { $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop }
    catch { $offenders.Add("<ACL unreadable: $($_.Exception.Message)>") | Out-Null; return $offenders.ToArray() }

    foreach ($ace in $acl.Access) {
        if ($ace.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        if (($ace.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -eq [System.Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
        $rights = [string]$ace.FileSystemRights
        if (([int]$ace.FileSystemRights -band $replaceMask) -eq 0) { continue }
        $sid = $null
        try {
            $sid = if ($ace.IdentityReference -is [System.Security.Principal.SecurityIdentifier]) { $ace.IdentityReference.Value }
                   else { $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value }
        } catch { $sid = $null }
        if ($null -eq $sid) { $offenders.Add([string]$ace.IdentityReference) | Out-Null; continue }
        if ($sid -eq 'S-1-3-0') { continue }   # CREATOR OWNER - covered by the owner check
        if ($trusted -notcontains $sid) {
            $offenders.Add(("{0} ({1}) : {2}" -f $ace.IdentityReference, $sid, $rights)) | Out-Null
        }
    }
    return $offenders.ToArray()
}

function Test-TrustedTaskTargetPath {
    <#
        A SYSTEM task target is trusted only when nothing outside the administrative set can
        change it OR the chain that leads to it.

        Three conditions, each closing a different hole:
          - no reparse point anywhere in the chain;
          - no non-administrative writer on the target itself (DACL);
          - a trusted OWNER on the target, and on every parent component, plus no
            non-administrative principal able to REPLACE any of those components.

        The owner condition is the one this originally missed. An owner keeps WRITE_DAC
        implicitly, so a user-owned target with an otherwise perfect DACL can have that DACL
        rewritten and its content swapped before SYSTEM next runs it.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    $result = [pscustomobject]@{ Path = $Path; Trusted = $false; Reason = '' }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        $result.Reason = 'the path does not exist'
        return $result
    }
    if (Test-PathContainsReparsePoint -Path $Path) {
        $result.Reason = 'a reparse point exists in the parent or target chain'
        return $result
    }
    $writers = @(Get-UntrustedAclWriter -Path $Path)
    if ($writers.Count -gt 0) {
        $result.Reason = ('writable by non-administrative principal(s): {0}' -f ($writers -join ', '))
        return $result
    }

    $trusted = Get-TrustedPrincipalSid
    $current = ''
    try { $current = [System.IO.Path]::GetFullPath($Path) } catch { $result.Reason = 'the path cannot be canonicalized'; return $result }

    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $ownerSid = Get-PathOwnerSid -Path $current
        if ($null -eq $ownerSid) {
            $result.Reason = ('the owner of {0} cannot be read' -f $current)
            return $result
        }
        if ($trusted -notcontains $ownerSid) {
            $result.Reason = ('{0} is owned by {1}, which is outside SYSTEM/Administrators/TrustedInstaller; an owner keeps WRITE_DAC and can re-open the path' -f $current, $ownerSid)
            return $result
        }
        $replacers = @(Get-ReplaceCapableUntrustedPrincipal -Path $current)
        if ($replacers.Count -gt 0) {
            $result.Reason = ('{0} can be replaced by non-administrative principal(s): {1}' -f $current, ($replacers -join ', '))
            return $result
        }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) { break }
        $current = $parent
    }

    $result.Trusted = $true
    return $result
}

function Initialize-TrustedTaskAcl {
    <#
        Deterministic hardening for a SYSTEM task target: inheritance disabled, inherited ACEs
        dropped, full control for SYSTEM and Administrators, read+execute for BUILTIN\Users.

        Fail-closed alone is not usable here: a directory freshly created under %ProgramData%
        inherits "BUILTIN\Users: Write" from its parent, so the staging root is writable the
        moment it is created and every install would abort. Users keep read+execute so the
        blocker's own log directory stays readable without elevation, but nobody outside the
        administrative set can write a file that SYSTEM later executes, nor delete and replace
        its directory.
    #>
    param([Parameter(Mandatory)][string]$Path)
    # Never harden through a link: Set-Acl would follow it and rewrite the target's DACL.
    if (Test-PathContainsReparsePoint -Path $Path) { throw "Refusing to harden a path that contains a reparse point: $Path" }
    $isContainer = Test-Path -LiteralPath $Path -PathType Container
    $administrators = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')

    # OWNERSHIP FIRST, and it is not optional here unlike the download cache: a user-owned target
    # keeps WRITE_DAC implicitly, so the DACL written below could be undone by that user before
    # SYSTEM next executes the file. Doing it first also means a refusal changes nothing - the
    # reverse order writes a restrictive DACL and only then discovers it cannot finish, having
    # meanwhile removed the very rights it needs to retry.
    try {
        $ownerAcl = if ($isContainer) { New-Object System.Security.AccessControl.DirectorySecurity }
                    else { New-Object System.Security.AccessControl.FileSecurity }
        $ownerAcl.SetOwner($administrators)
        Set-Acl -LiteralPath $Path -AclObject $ownerAcl
    } catch {
        throw ("Could not take ownership of the SYSTEM task target {0}: {1}. Registration is refused because the current owner keeps WRITE_DAC and could re-open the path." -f $Path, $_.Exception.Message)
    }

    # A FRESH descriptor, never one from Get-Acl. Set-Acl writes back every section its argument
    # carries, and a descriptor from Get-Acl carries the SACL - so the round trip demands
    # SeSecurityPrivilege that this operation does not otherwise need. A fresh, protected
    # descriptor also arrives with no rules at all, so there is nothing to strip first.
    $inheritance = if ($isContainer) {
        [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else {
        [System.Security.AccessControl.InheritanceFlags]::None
    }
    $acl = if ($isContainer) { New-Object System.Security.AccessControl.DirectorySecurity }
           else { New-Object System.Security.AccessControl.FileSecurity }
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($grant in @(
            @{ Sid = 'S-1-5-18';     Rights = 'FullControl' },      # LOCAL SYSTEM
            @{ Sid = 'S-1-5-32-544'; Rights = 'FullControl' },      # BUILTIN\Administrators
            @{ Sid = 'S-1-5-32-545'; Rights = 'ReadAndExecute' })) {  # BUILTIN\Users
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    (New-Object System.Security.Principal.SecurityIdentifier($grant.Sid)),
                    [System.Security.AccessControl.FileSystemRights]$grant.Rights,
                    $inheritance,
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow)))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl

    # Re-read rather than trust the write: an owner that did not actually change is the same hole.
    $ownerSid = Get-PathOwnerSid -Path $Path
    if ($ownerSid -ne $administrators.Value) {
        throw ("Ownership of the SYSTEM task target {0} did not change (owner is still {1}); registration is refused." -f $Path, $ownerSid)
    }
    return $Path
}

function Assert-TrustedTaskTarget {
    <#
        H-02: validate every path a SYSTEM task executes or reads, plus the directories that
        could be used to replace them. -Harden repairs a writable directory or file once and
        re-validates; anything still untrusted afterwards - and every reparse point - fails
        closed rather than being registered.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Path,
        [switch]$Harden
    )
    foreach ($target in $Path) {
        $state = Test-TrustedTaskTargetPath -Path $target
        # An untrusted OWNER is repairable by the same hardening pass (it takes ownership), so it
        # is offered to -Harden alongside a writable DACL. A reparse point never is.
        if (-not $state.Trusted -and $Harden -and ($state.Reason -like 'writable by*' -or $state.Reason -like '*is owned by*' -or $state.Reason -like '*can be replaced by*')) {
            Write-Warn ("Hardening SYSTEM task target {0}: {1}" -f $target, $state.Reason)
            Initialize-TrustedTaskAcl -Path $target | Out-Null
            $state = Test-TrustedTaskTargetPath -Path $target
        }
        if (-not $state.Trusted) {
            throw ("Refusing to register a SYSTEM scheduled task: {0} is not a trusted target ({1})." -f $target, $state.Reason)
        }
        Write-StructuredLog -Level TASK -Message ("Trusted SYSTEM task target verified: {0}" -f $target)
    }
    return $true
}

# --------------------------------------------------------------- FU-01 SYSTEM task staging area
# A SYSTEM task must not be registered against a file in the project checkout. Measured on a real
# machine, the shipped checkout was owned by the interactive user and granted FullControl to
# BUILTIN\Users plus Modify/DeleteSubdirectoriesAndFiles to six further non-administrative SIDs.
# An owner keeps WRITE_DAC whatever the DACL says, so hardening that directory in place could be
# undone by its owner before SYSTEM next ran the file - and it also locked the non-elevated
# launcher out of its own log directory. Everything a SYSTEM task executes or reads is therefore
# COPIED into a directory this project creates, owns and hardens, and only the copy is registered,
# validated and health-checked.

function Get-TaskStagingRoot {
    <#
        %ProgramData%\WinServerSetup\tasks, hardened together with its parent.

        The parent matters as much as the directory itself: a principal able to replace
        %ProgramData%\WinServerSetup could substitute the whole hardened `tasks` directory with
        one of its own. Above that, C:\ProgramData is owned by SYSTEM and grants BUILTIN\Users
        only `Write` - CreateFiles/CreateDirectories, which cannot delete or replace an existing
        subdirectory - and C:\ is owned by TrustedInstaller, so the chain terminates safely.
    #>
    $base = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($base)) { $base = Join-Path $env:SystemDrive 'ProgramData' }
    $root = ''
    foreach ($dir in @((Join-Path $base 'WinServerSetup'), (Join-Path $base 'WinServerSetup\tasks'))) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # Throws rather than returning if ownership cannot be taken or does not stick.
        $root = Initialize-TrustedTaskAcl -Path $dir
    }
    return (ConvertTo-CanonicalPath $root)
}

function Copy-TaskTargetToStaging {
    <#
        Stages one file a SYSTEM task will execute, then returns the canonical path of the COPY.

        The source is deliberately not ACL-validated. On a normal machine the checkout is
        user-writable, and the elevated run is already executing that same checkout, so refusing
        there would abort every install without closing anything. What this closes is the
        persistent target a SYSTEM task keeps re-executing every few minutes.
    #>
    param(
        [Parameter(Mandatory)][string]$StagingRoot,
        [Parameter(Mandatory)][string]$SourcePath
    )
    $destination = Join-Path $StagingRoot (Split-Path -Leaf $SourcePath)
    Copy-Item -LiteralPath $SourcePath -Destination $destination -Force -ErrorAction Stop
    return (ConvertTo-CanonicalPath $destination)
}

function Resolve-StagedBlockerStatePath {
    <#
        The one place the staged task's state path is decided, resolved to an absolute canonical
        path at registration time.

        A configured rdpBruteforceBlocker.statePath is honoured as-is when it is already rooted.
        An empty or relative one resolves against the STAGING root's parent - the directory the
        staged blocker will itself compute as its project root - so the path recorded here is the
        path the task actually writes.
    #>
    param([Parameter(Mandatory)][string]$StagingRoot)

    $configured = ''
    if ($Global:Config -and $Global:Config.rdpBruteforceBlocker) {
        $configured = [string]$Global:Config.rdpBruteforceBlocker.statePath
    }
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        if (-not [System.IO.Path]::IsPathRooted($configured)) {
            throw "rdpBruteforceBlocker.statePath must be an absolute path when set; got '$configured'."
        }
        return (ConvertTo-CanonicalPath $configured)
    }

    # Staging root is <...>\WinServerSetup\tasks; the staged blocker's Resolve-ProjectRoot returns
    # its parent, so that is where its default state directory lives.
    $stagedProjectRoot = Split-Path -Parent (ConvertTo-CanonicalPath $StagingRoot)
    if ([string]::IsNullOrWhiteSpace($stagedProjectRoot)) {
        throw "Could not derive the staged project root from staging root '$StagingRoot'."
    }
    return (ConvertTo-CanonicalPath (Join-Path $stagedProjectRoot 'state\rdp-blocker-state.json'))
}

function Save-StagedTaskConfig {
    <#
        Writes the EFFECTIVE blocker configuration next to the staged script.

        Effective, not a copy of the tracked file: $Global:Config already carries the ignored
        local override, which the task never saw before - it read the tracked config directly, so
        an override silently did not apply to the scheduled control.

        Only the two sections Block-RdpBruteforce.ps1 actually consumes are written. The staged
        file is readable by BUILTIN\Users, and the merged configuration can carry an activation
        product key from the local override; an allowlist keeps that key out of a location every
        user can read. A section the blocker needs and does not find makes it throw, so this
        fails closed rather than silently.
    #>
    param(
        [Parameter(Mandatory)][string]$StagingRoot,
        [Parameter(Mandatory)][string]$FileName
    )
    $destination = Join-Path $StagingRoot $FileName

    # The staged blocker derives its own default state path from where IT lives, not from the
    # checkout: Resolve-ProjectRoot returns the parent of scripts\, which for a staged copy is
    # %ProgramData%\WinServerSetup. An empty statePath therefore meant the task wrote its state
    # and its deadline marker under %ProgramData%, while anything reasoning from
    # $Global:ProjectRoot looked under the checkout - two different files, and a health check that
    # could report healthy while a real deadline marker still stood.
    #
    # Resolving it to an ABSOLUTE path here removes the ambiguity for good: the staged config
    # states exactly one location, and every consumer reads that instead of recomputing a default
    # from whichever root it happens to know about. -Force so this both overwrites an existing
    # statePath and adds one when the source config omits it - the omitted case being precisely
    # the default that produced the mismatch.
    $blockerSettings = $Global:Config.rdpBruteforceBlocker | Select-Object -Property *
    $blockerSettings | Add-Member -NotePropertyName 'statePath' `
        -NotePropertyValue (Resolve-StagedBlockerStatePath -StagingRoot $StagingRoot) -Force

    $effective = [pscustomobject]@{
        rdp                  = $Global:Config.rdp
        rdpBruteforceBlocker = $blockerSettings
    }
    Set-Content -LiteralPath $destination -Value ($effective | ConvertTo-Json -Depth 10) -Encoding UTF8
    return (ConvertTo-CanonicalPath $destination)
}

function Get-BlockerDeadlineMarkerPath {
    <#
        FU-04: where the blocker's deadline guard records that a run was killed mid-pass.

        Read from the trust manifest recorded at registration, NOT recomputed here. Recomputing
        was the defect: the health check runs from the checkout, so an empty statePath resolved
        against $Global:ProjectRoot, while the STAGED task resolves against
        %ProgramData%\WinServerSetup. Two different files - and a health check watching a file
        nobody writes reports healthy while a real deadline marker still stands.

        Returns '' when no manifest exists or the recorded path fails validation. The caller
        already treats a missing manifest as unverifiable and fails the contract, so an empty
        result here never silently means "healthy".
    #>
    param([Parameter(Mandatory)][string]$TaskName)

    $manifest = Get-TaskTrustManifest -TaskName $TaskName
    if ($null -eq $manifest) { return '' }

    $statePath = [string]$manifest.StatePath
    if ([string]::IsNullOrWhiteSpace($statePath)) { return '' }

    # A manifest is only as good as what it says. A relative or non-canonical path would make
    # this watch something other than the recorded contract, so it is rejected rather than used.
    if (-not [System.IO.Path]::IsPathRooted($statePath)) { return '' }
    if ($statePath -ne (ConvertTo-CanonicalPath $statePath)) { return '' }

    return ("{0}.deadline" -f $statePath)
}

function Get-TaskTrustManifestRoot {
    # The manifest records what the health check trusts, so it must not itself be writable by a
    # non-administrator. It lives beside the download cache and gets the same hardening.
    $base = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($base)) { $base = Join-Path $env:SystemDrive 'ProgramData' }
    return (Initialize-TrustedDirectory -Path (Join-Path $base 'WinServerSetup\trust'))
}

function Get-TaskTrustManifestPath {
    param([Parameter(Mandatory)][string]$TaskName)
    $safeName = $TaskName -replace '[^A-Za-z0-9 ._-]', '_'
    return (Join-Path (Get-TaskTrustManifestRoot) ("{0}.json" -f $safeName))
}

function Save-TaskTrustManifest {
    param([Parameter(Mandatory)][string]$TaskName, [Parameter(Mandatory)]$Contract)
    $path = Get-TaskTrustManifestPath -TaskName $TaskName
    $Contract | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Get-TaskTrustManifest {
    param([Parameter(Mandatory)][string]$TaskName)
    $path = Get-TaskTrustManifestPath -TaskName $TaskName
    $state = Test-TrustedTaskTargetPath -Path $path
    if (-not $state.Trusted) {
        Write-StructuredLog -Level HEALTH -Message ("Task trust manifest is unusable ({0}): {1}" -f $state.Reason, $path)
        return
    }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch {
        Write-StructuredLog -Level HEALTH -Message ("Task trust manifest could not be parsed: {0}" -f $_.Exception.Message)
        return
    }
}

function ConvertFrom-ScheduledTaskDuration {
    <#
        Task Scheduler reports durations as ISO-8601, and the same value has several spellings
        ('PT5M', 'PT300S', 'PT0H5M0S'). Normalising through XmlConvert means the health check
        compares durations rather than strings. Absent or unparseable input returns nothing,
        which every caller reads as "no limit is set".
    #>
    param([AllowEmptyString()][string]$Duration)
    if ([string]::IsNullOrWhiteSpace($Duration)) { return }
    try { return [System.Xml.XmlConvert]::ToTimeSpan($Duration.Trim()) } catch { return }
}

function ConvertFrom-ScheduledTaskArgument {
    <#
        L-02: splits a task action argument string into its -Switch/value pairs, honouring
        quoting. A substring match is not a contract - '-Foo "C:\cfg.json"' contains the config
        path but never passes it to the blocker, and would have been reported as healthy.
    #>
    param([AllowEmptyString()][string]$Arguments)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($Arguments)) { return $map }
    $tokens = @([regex]::Matches($Arguments, '"[^"]*"|\S+') | ForEach-Object { $_.Value })
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $switchName = $tokens[$i]
        if ($switchName[0] -ne '-') { continue }
        $value = ''
        if (($i + 1) -lt $tokens.Count -and $tokens[$i + 1][0] -ne '-') {
            $value = $tokens[$i + 1].Trim('"')
            $i++
        }
        $map[$switchName.ToLowerInvariant()] = $value
    }
    return $map
}

function Test-BlockerTaskArgumentContract {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Arguments,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ConfigPath
    )
    $map = ConvertFrom-ScheduledTaskArgument -Arguments $Arguments
    foreach ($required in @('-noprofile', '-noninteractive')) {
        if (-not $map.ContainsKey($required)) { return $false }
    }
    if ([string]$map['-executionpolicy'] -ne 'Bypass') { return $false }
    try {
        if (-not [string]::Equals((ConvertTo-CanonicalPath ([string]$map['-file'])), (ConvertTo-CanonicalPath $ScriptPath), [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        if (-not [string]::Equals((ConvertTo-CanonicalPath ([string]$map['-configpath'])), (ConvertTo-CanonicalPath $ConfigPath), [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    } catch { return $false }
    return $true
}

function Get-BlockerExecutionTimeLimitMinutes {
    <#
        M-04: Task Scheduler's default ExecutionTimeLimit is PT72H. Combined with
        MultipleInstances=IgnoreNew, a single run that hangs suppresses every later trigger for
        three days while the task still looks registered and enabled.
    #>
    param([int]$ConfiguredMinutes = 0, [int]$IntervalMinutes = 5)
    $minutes = if ($ConfiguredMinutes -ge 1) { $ConfiguredMinutes } else { 5 }
    # Bounded relative to the repetition interval, because IgnoreNew means a run that outlives
    # its window skips triggers. Five windows is the ceiling, so the shipped 1-minute interval
    # allows the shipped 5-minute limit and nothing longer.
    $maximum = [Math]::Max(5, 5 * [Math]::Max(1, $IntervalMinutes))
    if ($minutes -gt $maximum) { $minutes = $maximum }
    return $minutes
}

function New-BlockerTaskArgument {
    # Always the CURRENT resolved config path, so post-relocate runs use the new path -- item 36.
    param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][string]$ConfigPath)
    return ('-WindowStyle Hidden -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $ScriptPath, $ConfigPath)
}

function Test-RdpBlockerTaskHealth {
    <#
        L-02 and M-04. The blocker is a security control, so the health check re-proves the whole
        contract recorded at registration: trusted executable, exact script path, exact canonical
        config path, argument shape, SYSTEM principal at the highest run level, trigger and
        repetition interval, ExecutionTimeLimit, MultipleInstances, the ACL and hash of every
        target, and that no active run has outlived its limit.
    #>
    param([Parameter(Mandatory)][string]$TaskName)
    $manifest = Get-TaskTrustManifest -TaskName $TaskName
    if ($null -eq $manifest) {
        Write-StructuredLog -Level HEALTH -Message ("No usable trust manifest for task {0}; re-run the RDP blocker step to register it." -f $TaskName)
        return $false
    }
    $task = $null
    $info = $null
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
    } catch {
        Write-StructuredLog -Level HEALTH -Message ("Task {0} could not be read: {1}" -f $TaskName, $_.Exception.Message)
        return $false
    }

    $reasons = New-Object System.Collections.Generic.List[string]
    $action = @($task.Actions)[0]
    $systemPowerShell = Join-Path $env:windir "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not [string]::Equals([string]$action.Execute, [string]$manifest.Execute, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$action.Execute, $systemPowerShell, [System.StringComparison]::OrdinalIgnoreCase)) {
        $reasons.Add(("the action executable is '{0}', not the registered system PowerShell" -f $action.Execute)) | Out-Null
    }
    if (-not (Test-BlockerTaskArgumentContract -Arguments ([string]$action.Arguments) -ScriptPath ([string]$manifest.ScriptPath) -ConfigPath ([string]$manifest.ConfigPath))) {
        $reasons.Add("the action arguments do not match the registered -File/-ConfigPath contract") | Out-Null
    }
    if ([string]$task.Principal.UserId -ne 'SYSTEM') { $reasons.Add(("the principal is '{0}', not SYSTEM" -f $task.Principal.UserId)) | Out-Null }
    if ([string]$task.Principal.RunLevel -ne 'Highest') { $reasons.Add(("the run level is '{0}', not Highest" -f $task.Principal.RunLevel)) | Out-Null }

    $trigger = @($task.Triggers)[0]
    if ($null -eq $trigger) {
        $reasons.Add("the task has no trigger and can never run") | Out-Null
    } else {
        $interval = ConvertFrom-ScheduledTaskDuration -Duration ([string]$trigger.Repetition.Interval)
        if ($null -eq $interval -or [int]$interval.TotalMinutes -ne [int]$manifest.IntervalMinutes) {
            $reasons.Add(("the trigger repetition is '{0}', not the registered {1} minute(s)" -f $trigger.Repetition.Interval, $manifest.IntervalMinutes)) | Out-Null
        }
    }

    $limit = ConvertFrom-ScheduledTaskDuration -Duration ([string]$task.Settings.ExecutionTimeLimit)
    if ($null -eq $limit -or $limit.TotalMinutes -le 0 -or [int]$limit.TotalMinutes -ne [int]$manifest.ExecutionTimeLimitMinutes) {
        $reasons.Add(("ExecutionTimeLimit is '{0}', not the registered {1} minute(s)" -f $task.Settings.ExecutionTimeLimit, $manifest.ExecutionTimeLimitMinutes)) | Out-Null
    }
    if ([string]$task.Settings.MultipleInstances -ne 'IgnoreNew') {
        $reasons.Add(("MultipleInstances is '{0}', not IgnoreNew" -f $task.Settings.MultipleInstances)) | Out-Null
    }

    foreach ($target in @([string]$manifest.ScriptPath, [string]$manifest.ConfigPath)) {
        $state = Test-TrustedTaskTargetPath -Path $target
        if (-not $state.Trusted) { $reasons.Add(("task target {0} is not trusted ({1})" -f $target, $state.Reason)) | Out-Null }
    }
    try {
        if (-not [string]::Equals((Get-Sha256Hex -Path ([string]$manifest.ScriptPath)), [string]$manifest.ScriptSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            $reasons.Add("the blocker script has changed since it was registered") | Out-Null
        }
    } catch {
        $reasons.Add(("the blocker script could not be hashed: {0}" -f $_.Exception.Message)) | Out-Null
    }

    # M-04: IgnoreNew is only safe while an over-long ACTIVE run counts as a failure. Without
    # this, a hung instance quietly suppresses every later trigger and the task still looks fine.
    if ([string]$task.State -eq 'Running' -and $null -ne $limit -and $null -ne $info.LastRunTime -and
        ((Get-Date) - [datetime]$info.LastRunTime) -gt $limit) {
        $reasons.Add(("a run started at {0} has outlived its {1} limit; end that instance and re-run the RDP blocker step" -f $info.LastRunTime, $task.Settings.ExecutionTimeLimit)) | Out-Null
    }
    if ([string]$task.State -eq 'Disabled') { $reasons.Add("the task is disabled") | Out-Null }

    # FU-04: a run killed by its own deadline guard leaves a marker beside the state file. Task
    # Scheduler cannot describe that outcome on its own - the process was ended from inside, so
    # LastTaskResult only carries the exit code - and the marker outlives the run, so it is the
    # durable evidence that this control stopped mid-pass. Only a later run that completes
    # successfully removes it.
    # The recorded path must also agree with the staged config this task was registered against;
    # a manifest naming a state file outside the staged tree is not describing this task.
    $markerPath = Get-BlockerDeadlineMarkerPath -TaskName $TaskName
    if ([string]::IsNullOrWhiteSpace($markerPath)) {
        $reasons.Add("the trust manifest records no usable absolute state path, so a deadline kill could not be detected") | Out-Null
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$manifest.ConfigPath)) {
        $stagedRoot = Split-Path -Parent (Split-Path -Parent ([string]$manifest.ConfigPath))
        $stateRoot = Split-Path -Parent (Split-Path -Parent $markerPath)
        if (-not [string]::Equals($stagedRoot, $stateRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $reasons.Add(("the recorded state path {0} does not sit under the staged task tree {1}" -f $markerPath, $stagedRoot)) | Out-Null
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($markerPath) -and (Test-Path -LiteralPath $markerPath)) {
        $detail = ''
        try { $detail = (Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop).Trim() } catch { $detail = '<marker unreadable>' }
        $reasons.Add(("a previous run was ended by its deadline guard and no later run has completed since: {0}" -f $detail)) | Out-Null
    }
    # 0 = success, 267011 (0x00041303) = has not yet run, 267009 (0x00041301) = currently running.
    $lastResult = [int]$info.LastTaskResult
    if ($lastResult -notin @(0, 267011, 267009)) { $reasons.Add(("the last run result was {0}" -f $lastResult)) | Out-Null }
    if (-not $info.NextRunTime -and [string]$task.State -ne 'Running') { $reasons.Add("no next run is scheduled") | Out-Null }

    if ($reasons.Count -gt 0) {
        foreach ($reason in $reasons) { Write-StructuredLog -Level HEALTH -Message ("RDP blocker task {0}: {1}" -f $TaskName, $reason) }
        Write-Warn ("RDP blocker task contract failed - {0}. Re-run the RDP brute-force blocker step to repair it." -f ($reasons -join '; '))
        return $false
    }
    return $true
}

function Install-RdpBruteforceBlocker {
    $s = $Global:Config.rdpBruteforceBlocker
    if (-not $s.enabled) { Set-StepSkipped "disabled in config"; return }
    $sourceScript = Join-Path $Global:ProjectRoot "scripts\Block-RdpBruteforce.ps1"
    if (-not (Test-Path -LiteralPath $sourceScript)) { throw "Blocker script not found: $sourceScript" }

    # M-01: the blocker writes every block rule on rdp.newPort. Registering while the machine
    # actually serves RDP on a different port produces a control that looks healthy and filters
    # nothing, so config, registry and the live listener must agree before anything is created.
    # Checked BEFORE anything is staged, so a refusal leaves no files behind.
    $rdpPort = Assert-RdpPortAgreement

    $psExe = Join-Path $env:windir "System32\WindowsPowerShell\v1.0\powershell.exe"
    # FU-01: the task executes the staged COPY, never the checkout, so the file SYSTEM runs every
    # few minutes cannot be replaced by whoever can write the project directory.
    $stagingRoot = Get-TaskStagingRoot
    $scriptPath = Copy-TaskTargetToStaging -StagingRoot $stagingRoot -SourcePath $sourceScript
    $configPath = Save-StagedTaskConfig -StagingRoot $stagingRoot -FileName 'Block-RdpBruteforce.config.json'
    # FU-04: resolved AFTER staging, from the staging root, so it names the file the staged task
    # actually writes rather than a default recomputed from the checkout.
    $stagedStatePath = Resolve-StagedBlockerStatePath -StagingRoot $stagingRoot
    # H-02 / FU-01: every path this SYSTEM task executes or reads. Each one is re-validated for
    # reparse points, a non-administrative writer, a trusted OWNER and no replace-capable
    # principal on any parent - independently of the hardening that just ran.
    Assert-TrustedTaskTarget -Harden -Path @($psExe, $stagingRoot, $scriptPath, $configPath) | Out-Null

    $taskName = [string]$s.taskName
    $interval = [int]$s.taskIntervalMinutes; if ($interval -lt 1) { $interval = 5 }
    $limitMinutes = Get-BlockerExecutionTimeLimitMinutes -ConfiguredMinutes ([int]$s.executionTimeLimitMinutes) -IntervalMinutes $interval
    $arguments = New-BlockerTaskArgument -ScriptPath $scriptPath -ConfigPath $configPath

    $action    = New-ScheduledTaskAction    -Execute $psExe -Argument $arguments
    $trigger   = New-ScheduledTaskTrigger   -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes $interval)
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    # M-04: the explicit ExecutionTimeLimit is what makes MultipleInstances=IgnoreNew safe.
    $settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden `
        -ExecutionTimeLimit (New-TimeSpan -Minutes $limitMinutes)

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Ok ("Scheduled task registered: {0}  (hidden, highest privileges, RDP port {1}, {2} min run limit)" -f $taskName, $rdpPort, $limitMinutes)
    Write-Info ("Task argument: {0}" -f $arguments)

    # L-02: record the contract the health check has to re-prove later, including the hash of the
    # exact file SYSTEM will execute.
    Save-TaskTrustManifest -TaskName $taskName -Contract ([pscustomobject]@{
            TaskName                  = $taskName
            Execute                   = $psExe
            Arguments                 = $arguments
            ScriptPath                = $scriptPath
            ConfigPath                = $configPath
            ScriptSha256              = (Get-Sha256Hex -Path $scriptPath)
            # FU-04: the absolute state path the STAGED task writes. Recorded rather than
            # recomputed later, because the health check runs from the checkout and would
            # otherwise derive a different default and watch a file nobody writes.
            StatePath                 = $stagedStatePath
            IntervalMinutes           = $interval
            ExecutionTimeLimitMinutes = $limitMinutes
            RdpPort                   = $rdpPort
            RegisteredUtc             = (Get-Date).ToUniversalTime().ToString('o')
        }) | Out-Null

    if (-not (Test-RdpBlockerTaskHealth -TaskName $taskName)) {
        throw "RDP blocker task '$taskName' did not satisfy its own registration contract immediately after being registered."
    }
    Write-Ok "RDP blocker task verified against its recorded trust contract."

    Invoke-BlockerVerificationRun -PowerShellExe $psExe -ScriptPath $scriptPath -ConfigPath $configPath
}

function Invoke-BlockerVerificationRun {
    # Extracted from Install-RdpBruteforceBlocker so the installer can be exercised in tests
    # without launching the real blocker against the live event log and firewall.
    param(
        [Parameter(Mandatory)][string]$PowerShellExe,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ConfigPath
    )
    Write-Info "Running blocker once now for verification..."
    & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -ConfigPath $ConfigPath
    if ($LASTEXITCODE -ne 0) { throw "Running blocker verification failed with exit code $LASTEXITCODE." }
    Write-Ok "RDP blocker verification run completed successfully."
}
