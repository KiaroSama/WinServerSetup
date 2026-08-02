<#
    Regression tests for follow-up security finding FU-01 (High): SYSTEM scheduled task targets
    were validated by DACL alone.

    Two holes, both reproduced here against the pre-fix behaviour:

      * The OWNER was never read. An owner holds READ_CONTROL and WRITE_DAC implicitly, whatever
        the DACL says, so a user-owned file with an otherwise perfect DACL is not safe at all -
        its owner can rewrite that DACL and swap the content before SYSTEM next executes it.
      * Only the target itself was inspected. A principal able to DELETE or replace any parent
        directory can substitute the whole hardened directory, ACL and all, without ever needing
        a right on the target.

    Both are now checked on the target and on every path component up to the volume root, which
    is also what makes %ProgramData%\WinServerSetup\tasks a defensible home for a SYSTEM task:
    C:\ProgramData grants BUILTIN\Users only `Write` - CreateFiles/CreateDirectories, which
    cannot delete or replace an existing subdirectory - and C:\ is owned by TrustedInstaller.

    Nothing here asserts on what the TEST PROCESS is allowed to do. Every case reads back the
    owner and DACL that were actually written, so an elevated CI runner and a non-elevated
    developer shell reach the same verdict.
#>
# -MainScript targets an alternate copy so these tests can be replayed against a deliberately
# defective build to prove they still fail. Import-FunctionUnderTest returns the FIRST definition
# it finds and this file heads the list, so a file holding one re-broken function is enough to
# mutate - the working tree is never touched.
param([string]$MainScript = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$mainScript = if ([string]::IsNullOrWhiteSpace($MainScript)) { Join-Path $projectRoot "WinServerSetup.ps1" } else { $MainScript }

. (Join-Path $PSScriptRoot '_Common.ps1')

$setupSourceFiles = @(Get-SetupSourceFile -ProjectRoot $projectRoot -MainScript $mainScript)
$setupAsts = @(Get-SetupAst -Files $setupSourceFiles -Because 'task target ownership can be tested')

foreach ($name in @('Test-PathContainsReparsePoint', 'Get-UntrustedAclWriter', 'Get-TrustedPrincipalSid',
        'Get-PathOwnerSid', 'Get-ReplaceCapableUntrustedPrincipal', 'Test-TrustedTaskTargetPath')) {
    . ([scriptblock]::Create((Import-FunctionUnderTest $name $setupAsts)))
}

# Microsoft.PowerShell.Security supplies Get-Acl / Set-Acl through module autoloading, which the
# guarded runner's Windows PowerShell 5.1 child cannot always perform. Skipping loudly is the only
# honest option there; the other host covers these cases. Production fails closed in the same
# situation - Get-PathOwnerSid returns $null, which Test-TrustedTaskTargetPath treats as unsafe.
$aclAvailable = $false
try {
    $aclAvailable = [bool](Get-Command Get-Acl -ErrorAction Stop) -and [bool](Get-Command Set-Acl -ErrorAction Stop)
} catch { $aclAvailable = $false }

# GetFullPath, never a bare Join-Path: GitHub Actions windows-latest exposes %TEMP% as the 8.3
# path C:\Users\RUNNER~1\AppData\Local\Temp, while the code under test canonicalises every
# component it walks. Comparing a short spelling against a long one has broken CI here before.
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $env:TEMP ("WinServerSetup-FU01-{0}" -f ([guid]::NewGuid().ToString("N")))))
$script:CreatedPaths = New-Object System.Collections.Generic.List[string]

function New-SandboxDirectory {
    param([string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $script:CreatedPaths.Add($Path) | Out-Null
    return $Path
}

function New-SandboxFile {
    param([string]$Path)
    Set-Content -LiteralPath $Path -Value '# staged SYSTEM task target' -Encoding UTF8
    $script:CreatedPaths.Add($Path) | Out-Null
    return $Path
}

function New-SandboxSecurityObject {
    <#
        A FRESH DirectorySecurity/FileSecurity, never one returned by Get-Acl.

        Measured on both hosts: Set-Acl writes back every section the object carries, and an
        object from Get-Acl carries the SACL, so persisting it needs SeSecurityPrivilege - which
        a non-elevated shell does not hold. A fresh descriptor carries only the sections this
        function actually sets, so the same code works elevated and not.
    #>
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Container) { return (New-Object System.Security.AccessControl.DirectorySecurity) }
    return (New-Object System.Security.AccessControl.FileSecurity)
}

function Set-SandboxOwner {
    <#
        Always called BEFORE Set-SandboxDacl. Writing the owner needs WRITE_OWNER, and an owner
        holds only READ_CONTROL and WRITE_DAC implicitly - so once the task-grade DACL has dropped
        every inherited ACE there is no WRITE_OWNER left. The reverse order fails on an elevated
        host, where the object starts out owned by Administrators and really has to be changed.
    #>
    param([string]$Path, [string]$Sid)
    $acl = New-SandboxSecurityObject -Path $Path
    $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier($Sid)))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Set-SandboxDacl {
    <#
        Writes the DACL a correctly hardened SYSTEM task target carries - inheritance off,
        inherited ACEs dropped, full control for SYSTEM and Administrators, read+execute for
        BUILTIN\Users - plus any extra ACE a case needs, in ONE write.

        One write is not a style choice. Once this DACL is in place a non-elevated process holds
        no explicit right on the path, and a second Set-Acl against it is impossible for the same
        SeSecurityPrivilege reason described above. Every ACE a case wants must go in here.
    #>
    param([string]$Path, [hashtable[]]$AlsoGrant = @())
    $inheritance = if (Test-Path -LiteralPath $Path -PathType Container) {
        [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else {
        [System.Security.AccessControl.InheritanceFlags]::None
    }
    $acl = New-SandboxSecurityObject -Path $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($grant in (@(
                @{ Sid = 'S-1-5-18';     Rights = [System.Security.AccessControl.FileSystemRights]::FullControl },
                @{ Sid = 'S-1-5-32-544'; Rights = [System.Security.AccessControl.FileSystemRights]::FullControl },
                @{ Sid = 'S-1-5-32-545'; Rights = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute }) + $AlsoGrant)) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    (New-Object System.Security.Principal.SecurityIdentifier([string]$grant.Sid)),
                    ([System.Security.AccessControl.FileSystemRights]$grant.Rights),
                    $inheritance,
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow)))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

try {
    if (-not $aclAvailable) {
        Write-Host "SKIP FU-01 every case: Microsoft.PowerShell.Security could not be loaded in this host, so an owner or DACL can be neither written nor read here. The other host covers them."
        Write-Host "PASS FU-01 task target ownership (skipped in this host: no Get-Acl/Set-Acl)."
        return
    }

    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    $trustedSids = @(Get-TrustedPrincipalSid)
    Assert-True ($trustedSids -contains 'S-1-5-18' -and $trustedSids -contains 'S-1-5-32-544') `
        "FU-01: the trusted principal set must contain SYSTEM and Administrators, or every case below is meaningless."

    # ---- Positive control. Without it the negative cases could all pass for the trivial reason
    #      that the walk rejects everything. System PowerShell is owned by TrustedInstaller and is
    #      the exact executable both SYSTEM tasks are registered against. ----
    $systemPowerShell = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $control = Test-TrustedTaskTargetPath -Path $systemPowerShell
    Assert-Equal $true $control.Trusted `
        ("FU-01: the owner and parent walk must still ACCEPT a genuine system binary, or every rejection below proves nothing. Reason: {0}" -f $control.Reason)

    $currentUserSid = [string]([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    if ($trustedSids -contains $currentUserSid) {
        Write-Host "SKIP FU-01.1 and FU-01.2: this host runs as $currentUserSid, which IS a trusted principal, so it cannot plant an untrusted owner."
    } else {
        # =====================================================================================
        # FU-01.1  A USER-OWNED DIRECTORY WITH AN OTHERWISE PERFECT DACL.
        # Pre-fix this returned Trusted=$true: only the DACL was read, and the DACL is spotless.
        # The owner keeps WRITE_DAC implicitly and can undo that DACL at any moment.
        # =====================================================================================
        $ownedDir = New-SandboxDirectory (Join-Path $testRoot 'user-owned-dir')
        Set-SandboxOwner -Path $ownedDir -Sid $currentUserSid
        Set-SandboxDacl -Path $ownedDir

        # Preconditions. Without these the rejection could come from the DACL rather than the
        # owner, and the case would prove nothing about FU-01.
        Assert-Equal 0 (@(Get-UntrustedAclWriter -Path $ownedDir).Count) `
            ("FU-01: the DACL of the user-owned directory must be spotless, or this case tests the wrong thing. Got: {0}" -f ((Get-UntrustedAclWriter -Path $ownedDir) -join ' | '))
        Assert-Equal $currentUserSid (Get-PathOwnerSid -Path $ownedDir) `
            "FU-01: the sandbox owner must really be the untrusted current user before the verdict is meaningful."

        $state = Test-TrustedTaskTargetPath -Path $ownedDir
        Assert-Equal $false $state.Trusted `
            "FU-01: a SYSTEM task target owned by a non-administrative principal must be refused however clean its DACL is - the owner keeps WRITE_DAC and can rewrite that DACL before SYSTEM next runs the file."
        Assert-True ($state.Reason -match [regex]::Escape($currentUserSid)) `
            ("FU-01: the refusal must name the untrusted owner. Got: {0}" -f $state.Reason)
        Assert-True ($state.Reason -match 'WRITE_DAC') `
            ("FU-01: the refusal must explain WHY an owner is disqualifying, or it reads as an ACL error. Got: {0}" -f $state.Reason)

        # ---- FU-01.2  The same hole on a FILE, which is what a task action actually executes. ----
        $ownedFile = New-SandboxFile (Join-Path $testRoot 'user-owned-target.ps1')
        Set-SandboxOwner -Path $ownedFile -Sid $currentUserSid
        Set-SandboxDacl -Path $ownedFile

        Assert-Equal 0 (@(Get-UntrustedAclWriter -Path $ownedFile).Count) `
            "FU-01: the user-owned FILE must also carry a spotless DACL before its verdict means anything."
        Assert-Equal $false (Test-TrustedTaskTargetPath -Path $ownedFile).Trusted `
            "FU-01: a user-owned script file is exactly the privilege-escalation primitive this check exists for and must be refused."
    }

    # =========================================================================================
    # FU-01.3 / FU-01.4  A REPLACE-CAPABLE PARENT.
    #
    # The target below is hardened correctly AND has a trusted owner, so nothing about the target
    # itself is wrong. A principal that can delete its parent directory replaces the whole thing,
    # ACL and all, and SYSTEM then executes whatever took its place.
    #
    # Get-PathOwnerSid is shadowed from here on so these two cases isolate the parent dimension:
    # a sandbox directory under %TEMP% is owned by whoever created it, and on a non-elevated host
    # that is the interactive user, which would short-circuit the walk on FU-01.1's condition
    # instead. The real owner check is proven above, against real owners.
    # =========================================================================================
    # $Path is bound and discarded on purpose: the signature must match the real function so the
    # walk binds identically, but every component answers "SYSTEM" here.
    function Get-PathOwnerSid { param([string]$Path) $null = $Path; return 'S-1-5-18' }

    $usersSid = 'S-1-5-32-545'
    foreach ($case in @(
            @{ Id = 'FU-01.3'; Folder = 'parent-fullcontrol'; Rights = [System.Security.AccessControl.FileSystemRights]::FullControl
               Why = 'FullControl on the parent is unambiguous delete-and-replace capability' },
            @{ Id = 'FU-01.4'; Folder = 'parent-modify'; Rights = [System.Security.AccessControl.FileSystemRights]::Modify
               Why = 'Modify includes DELETE, yet FileSystemRights renders it as the composite name "Modify, Synchronize" - a substring test for "Delete" clears it where a bitmask test does not' })) {

        # Strict order. The child is created while the parent is still permissive, because a
        # task-grade parent leaves a non-elevated process nothing but read+execute. The child's
        # DACL is protected, so neither the parent's hardening nor the planted ACE inherits into
        # it - which the preconditions below verify rather than assume.
        #
        # The parent also grants the CURRENT USER full control. That is a cleanup affordance, not
        # part of the case: without DELETE_CHILD on the parent a non-elevated run cannot remove
        # the hardened child afterwards and leaves an undeletable directory behind. It is
        # harmless here because this parent is the deliberately-bad one, and the assertions
        # require the planted BUILTIN\Users SID by name rather than a particular offender count.
        $parent = New-SandboxDirectory (Join-Path $testRoot $case.Folder)
        $target = New-SandboxFile (Join-Path $parent 'staged-target.ps1')
        Set-SandboxDacl -Path $target
        Set-SandboxDacl -Path $parent -AlsoGrant @(
            @{ Sid = $usersSid; Rights = $case.Rights },
            @{ Sid = $currentUserSid; Rights = [System.Security.AccessControl.FileSystemRights]::FullControl })

        # Preconditions: the TARGET is beyond reproach, so the only possible complaint is the parent.
        Assert-Equal 0 (@(Get-UntrustedAclWriter -Path $target).Count) `
            ("{0}: the staged target's own DACL must be spotless, or this case does not test the parent. Got: {1}" -f $case.Id, ((Get-UntrustedAclWriter -Path $target) -join ' | '))
        Assert-Equal 0 (@(Get-ReplaceCapableUntrustedPrincipal -Path $target).Count) `
            ("{0}: the staged target must not itself be replace-capable, or this case does not test the parent." -f $case.Id)
        Assert-True ((@(Get-ReplaceCapableUntrustedPrincipal -Path $parent) -join ' | ') -match [regex]::Escape($usersSid)) `
            ("{0}: the planted parent ACE must be recognised as replace-capable - {1}." -f $case.Id, $case.Why)

        $state = Test-TrustedTaskTargetPath -Path $target
        Assert-Equal $false $state.Trusted `
            ("{0}: a SYSTEM task target whose PARENT can be deleted and replaced by a non-administrative principal must be refused; the target's own ACL is irrelevant once the directory holding it can be swapped." -f $case.Id)
        Assert-True ($state.Reason -match [regex]::Escape($parent)) `
            ("{0}: the refusal must name the parent component that can be replaced. Got: {1}" -f $case.Id, $state.Reason)
        Assert-True ($state.Reason -match [regex]::Escape($usersSid)) `
            ("{0}: the refusal must name the principal that can replace it. Got: {1}" -f $case.Id, $state.Reason)
    }

    # =========================================================================================
    # FU-01.5  The property that makes %ProgramData%\WinServerSetup\tasks usable at all.
    #
    # C:\ProgramData grants BUILTIN\Users plain `Write`, which for a directory is
    # CreateFiles/CreateDirectories: a user may add a new sibling but cannot delete or replace an
    # existing subdirectory. Widening the replace-capability test to any write-class right would
    # make every ProgramData-based task location fail closed and leave nowhere to put a SYSTEM
    # task at all - so that boundary is pinned here rather than left to a comment.
    # =========================================================================================
    $programData = if ([string]::IsNullOrWhiteSpace($env:ProgramData)) { Join-Path $env:SystemDrive 'ProgramData' } else { $env:ProgramData }
    $programDataReplacers = @(Get-ReplaceCapableUntrustedPrincipal -Path $programData)
    Assert-Equal 0 $programDataReplacers.Count `
        ("FU-01: %ProgramData% must pass the REPLACE-capability test - BUILTIN\Users holds Write there, which creates but cannot replace - or the staging root can never be trusted. Got: {0}" -f ($programDataReplacers -join ' | '))
    Assert-True (@(Get-UntrustedAclWriter -Path $programData).Count -gt 0) `
        "FU-01: %ProgramData% is expected to be WRITABLE by Users; if it were not, the case above would pass for the wrong reason and prove nothing about the narrower test."

    Write-Host "PASS FU-01 task target ownership: a user-owned file or directory is refused however clean its DACL, a replace-capable parent (FullControl and bare Modify alike) is refused, a genuine system binary is still accepted, and %ProgramData% stays usable as the staging root."
} finally {
    # A hardened sandbox path grants a non-elevated process read+execute and nothing more, and
    # Set-Acl cannot relax it afterwards (SeSecurityPrivilege, measured on both hosts). What DOES
    # work is deleting it through the parent's DELETE_CHILD, which %TEMP% grants - so each path
    # is removed directly, deepest first (children are strictly longer than their parents).
    # Failures here must never mask the assertion that actually failed.
    foreach ($path in @($script:CreatedPaths.ToArray() | Sort-Object -Property Length -Descending)) {
        try {
            if (Test-Path -LiteralPath $path -PathType Container) { [System.IO.Directory]::Delete($path, $false) }
            elseif (Test-Path -LiteralPath $path) { [System.IO.File]::Delete($path) }
        } catch { $null = $_ }
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) {
        Write-Host ("WARNING FU-01 sandbox survived cleanup and must be removed by hand: {0}" -f $testRoot)
    }
}
