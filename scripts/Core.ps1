# Core.ps1 - admin/config/path helpers, registry and filesystem access, the download
# cache, file trust checks (signature, hash, host allowlist), environment setup, reboot
# state and self-relocation.
#
# Dot-sourced by WinServerSetup.ps1. Contains function definitions only; it reads the
# globals initialized there ($Global:Config, $Global:ProjectRoot, $Global:RunStats) at
# call time, never at load time.

# =============================================================================
# ADMIN / CONFIG / PATH HELPERS
# =============================================================================
function Assert-Admin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Fail "Run this script as Administrator."
        Pause-IfNeeded
        exit 1
    }
}

function Load-Config {
    $configHelpers = Join-Path $Global:ProjectRoot "scripts\Config.ps1"
    if (-not (Test-Path -LiteralPath $configHelpers)) { throw "Config helper not found: $configHelpers" }
    . $configHelpers
    $localConfigPath = Join-Path $Global:ProjectRoot "WinServerSetup.config.local.json"
    $Global:Config = Import-WinServerSetupConfig -BasePath $Global:ConfigPath -LocalPath $localConfigPath
}

function Resolve-RelativePath {
    param([Parameter(Mandatory)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $Global:ProjectRoot $Path
}

function Set-RegistryDefaultValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    (Get-Item -Path $Path).SetValue('', $Value, [Microsoft.Win32.RegistryValueKind]::String)
}

function Set-RegistryValue {
    <#
        Ensures the key exists, then sets a named value. The ensure-then-set pair was
        copy-pasted about a dozen times with inconsistent error handling; this is the
        single definition. -IgnoreErrors reproduces the sites that deliberately wrote
        best-effort values with -ErrorAction SilentlyContinue.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()]$Value,
        [Microsoft.Win32.RegistryValueKind]$Type = [Microsoft.Win32.RegistryValueKind]::DWord,
        [switch]$IgnoreErrors
    )
    # Key creation always fails hard: every converted site inherited $ErrorActionPreference='Stop'
    # for its New-Item. -IgnoreErrors relaxes only the value write, which is the sole place the
    # best-effort sites used -ErrorAction SilentlyContinue.
    $ea = if ($IgnoreErrors) { 'SilentlyContinue' } else { 'Stop' }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -LiteralPath $Path -Name $Name -Type $Type -Value $Value -ErrorAction $ea
}

function Get-RegistryDefaultValue {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return (Get-Item -Path $Path).GetValue('', $null)
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Write-Ok "Created directory: $Path"
    }
}

function Get-DownloadCachePath {
    <#
        H-01: this cache feeds installers that run ELEVATED, so it must not live anywhere an
        unprivileged user can write. It used to default to %TEMP%\WinServerSetup-downloads,
        which on a normal workstation grants the interactive user FullControl - enough to plant
        an executable under an expected file name and have the elevated run launch it.

        The default is now under %ProgramData%, created and hardened to SYSTEM + Administrators
        with inheritance disabled. A configured downloadRoot is honoured but gets the same
        hardening and the same reparse-point rejection.
    #>
    $cfgValue = ''
    if ($Global:Config) { $cfgValue = [string]$Global:Config.downloadRoot }
    if ([string]::IsNullOrWhiteSpace($cfgValue)) {
        $base = $env:ProgramData
        if ([string]::IsNullOrWhiteSpace($base)) { $base = Join-Path $env:SystemDrive 'ProgramData' }
        $cfgValue = Join-Path $base 'WinServerSetup\cache'
    }
    # H-03: mark it as ours BEFORE hardening. Cleanup refuses to delete the contents of any
    # directory that does not carry this sentinel, so a mistyped downloadRoot cannot aim a
    # recursive delete at an unrelated folder. The sentinel is written first because once the
    # DACL is locked to SYSTEM + Administrators only an elevated caller could still write it.
    if (-not (Test-Path -LiteralPath $cfgValue)) { New-Item -ItemType Directory -Path $cfgValue -Force | Out-Null }
    Initialize-CacheSentinel -Path $cfgValue | Out-Null
    return (Initialize-TrustedDirectory -Path $cfgValue)
}

function Get-SafeDownloadCacheFilePath {
    param([Parameter(Mandatory)][string]$FileName)
    $leaf = Split-Path -Leaf $FileName
    if ([string]::IsNullOrWhiteSpace($leaf)) {
        throw "Download file name is empty."
    }
    if (-not [string]::Equals($leaf, $FileName, [System.StringComparison]::Ordinal)) {
        Write-Warn ("Download file name contained path segments; using safe leaf name: {0}" -f $leaf)
    }
    $root = [System.IO.Path]::GetFullPath((Get-DownloadCachePath)).TrimEnd('\')
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $root $leaf))
    if (-not $candidate.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Resolved download path is outside the configured cache: $candidate"
    }
    return $candidate
}

function Test-SignerSubjectAllowed {
    param(
        [Parameter(Mandatory)][string]$Subject,
        [string[]]$AllowedSignerSubjects = @()
    )
    # The single place publisher identity is decided. Matching an entry as a substring of the
    # whole distinguished name meant an allowlist of "Dolphin" also accepted
    # "CN=Dolphin Emulator, O=Anyone", so entries are anchored to a whole CN or O value.
    # An entry containing '=' is treated as a full-DN pin instead.
    # Returns $false for an empty allowlist; the caller decides what "no allowlist" means.
    $allowed = @($AllowedSignerSubjects | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($allowed.Count -eq 0) { return $false }

    $values = New-Object System.Collections.Generic.List[string]
    foreach ($rdn in ($Subject -split ',')) {
        $parts = $rdn -split '=', 2
        if ($parts.Count -ne 2) { continue }
        if ($parts[0].Trim() -notin @('CN', 'O')) { continue }
        $values.Add($parts[1].Trim().Trim('"')) | Out-Null
    }

    foreach ($entry in $allowed) {
        $candidate = ([string]$entry).Trim()
        if ($candidate.Contains('=')) {
            if ([string]::Equals($Subject.Trim(), $candidate, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
            continue
        }
        foreach ($value in $values) {
            if ([string]::Equals($value, $candidate, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    }
    return $false
}

function Test-DownloadedFileSignature {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$AllowedSignerSubjects = @()
    )
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -notin @('.exe', '.msi', '.msix', '.msixbundle', '.appx', '.appxbundle')) {
        Write-StructuredLog -Level SIGNATURE -Message ("Authenticode signature not applicable for file type: {0}" -f $Path)
        return $null
    }
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        if ($sig.Status -eq 'Valid') {
            # An absent JSON property arrives as @($null), whose Count of 1 would otherwise enter
            # the allowlist branch and then match every subject - a silent fail-open.
            $AllowedSignerSubjects = @($AllowedSignerSubjects | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($AllowedSignerSubjects.Count -gt 0) {
                $subject = [string]$sig.SignerCertificate.Subject
                $matched = Test-SignerSubjectAllowed -Subject $subject -AllowedSignerSubjects $AllowedSignerSubjects
                if (-not $matched) {
                    Write-Warn ("Signer is not allowlisted for {0}." -f (Split-Path -Leaf $Path))
                    Write-StructuredLog -Level SIGNATURE -Message ("Rejected signer: {0}; signer={1}" -f $Path, $subject)
                    return $false
                }
            }
            Write-StructuredLog -Level SIGNATURE -Message ("Valid signature: {0}; signer={1}" -f $Path, $sig.SignerCertificate.Subject)
            return $true
        } else {
            Write-Warn ("Downloaded file signature is not valid for {0}: {1}. Installer will remain available, but verify the source if this is unexpected." -f (Split-Path -Leaf $Path), $sig.Status)
            Write-StructuredLog -Level SIGNATURE -Message ("Non-valid signature: {0}; status={1}; message={2}" -f $Path, $sig.Status, $sig.StatusMessage)
            return $false
        }
    } catch {
        Write-Warn ("Could not verify downloaded file signature for {0}: {1}" -f (Split-Path -Leaf $Path), $_.Exception.Message)
        return $false
    }
}

# --------------------------------------------------------------------------- H-01 trust layer
# The download cache feeds installers that run ELEVATED. Before this, the cache defaulted to
# %TEMP%\WinServerSetup-downloads - writable by the interactive user - and a cache hit required
# only Length >= MinimumBytes whenever the spec carried no sha256 and did not set
# requireValidSignature. An unprivileged user could therefore plant an unsigned executable under
# the expected file name and have the elevated run launch it. Proven on this machine before the
# fix: the shipped cache root granted Modify/FullControl to two non-administrative identities and
# a 4 KB unsigned file was accepted as a valid cache hit.

function Get-Sha256Hex {
    <#
        SHA256 without depending on Get-FileHash.

        Get-FileHash lives in Microsoft.PowerShell.Utility and resolves through module
        autoloading, which is not guaranteed in every host environment: under the guarded test
        runner on Windows PowerShell 5.1 it raises CommandNotFoundException even though a direct
        5.1 session resolves it fine. Hashing is on the trust path that decides whether an
        elevated installer runs, so it must not depend on ambient module resolution.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
        finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
}

function Test-PathContainsReparsePoint {
    <#
        Fail closed on any reparse point in the chain: a junction anywhere between the volume
        root and the target lets an attacker who controls one directory redirect the whole path
        somewhere else after validation.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $current = $null
    try { $current = [System.IO.Path]::GetFullPath($Path) } catch { return $true }
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            try {
                $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint) { return $true }
            } catch {
                # Unreadable component: cannot prove it is safe, so treat it as unsafe.
                return $true
            }
        }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) { break }
        $current = $parent
    }
    return $false
}

function Get-UntrustedAclWriter {
    <#
        Returns the identities that can write to $Path but are not SYSTEM, Administrators or
        TrustedInstaller. A non-empty result means the location cannot be trusted to hold an
        artifact that will later be executed elevated.
    #>
    param([Parameter(Mandatory)][string]$Path)
    # Declared INSIDE the function on purpose: the test suites extract a single function by AST
    # and dot-source it, so a module-level $script: variable would be undefined there and every
    # principal - including SYSTEM - would look untrusted.
    # Compared by SID, never by display name: names are localized and renameable.
    $trustedWriterSids = @(
        'S-1-5-18',      # LOCAL SYSTEM
        'S-1-5-32-544',  # BUILTIN\Administrators
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464' # NT SERVICE\TrustedInstaller
    )
    $offenders = New-Object System.Collections.Generic.List[string]
    $acl = $null
    try { $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop } catch { $offenders.Add("<ACL unreadable: $($_.Exception.Message)>") | Out-Null; return $offenders.ToArray() }
    foreach ($ace in $acl.Access) {
        if ($ace.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        $rights = [string]$ace.FileSystemRights
        if ($rights -notmatch 'Write|Modify|FullControl|CreateFiles|Delete|ChangePermissions|TakeOwnership') { continue }
        $sid = $null
        try {
            $sid = if ($ace.IdentityReference -is [System.Security.Principal.SecurityIdentifier]) { $ace.IdentityReference.Value }
                   else { $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value }
        } catch { $sid = $null }
        if ($null -eq $sid) { $offenders.Add([string]$ace.IdentityReference) | Out-Null; continue }
        # CREATOR OWNER is only as trustworthy as the owner, which is checked separately below.
        if ($sid -eq 'S-1-3-0') { continue }
        if ($trustedWriterSids -notcontains $sid) {
            $offenders.Add(("{0} ({1}) : {2}" -f $ace.IdentityReference, $sid, $rights)) | Out-Null
        }
    }
    # Returns a plain array and enumerates on output, so every CALL SITE must wrap it in @() -
    # the project's documented idiom. Returning the List itself via `return ,$offenders` looks
    # safer but breaks `@(...)` at the call site: it wraps the List in a one-element array and
    # Count is then always 1, which would silently disable this gate.
    return $offenders.ToArray()
}

function Test-TrustedDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if (Test-PathContainsReparsePoint -Path $Path) { return $false }
    return ((Get-UntrustedAclWriter -Path $Path).Count -eq 0)
}

function Initialize-TrustedDirectory {
    <#
        Creates or hardens a directory so only SYSTEM and Administrators can write to it:
        inheritance disabled, inherited ACEs dropped, explicit full control for both.
        Deterministic rather than fail-closed, because the cache root is ours to own.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (Test-PathContainsReparsePoint -Path $Path) {
        throw "Refusing to use a cache path that contains a reparse point: $Path"
    }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }

    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)   # protect from inheritance, drop inherited ACEs
    foreach ($existing in @($acl.Access)) { $null = $acl.RemoveAccessRule($existing) }
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            (New-Object System.Security.Principal.SecurityIdentifier($sid)),
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl

    # Taking ownership needs SeRestorePrivilege, which only an elevated run holds. The DACL set
    # above is the enforced boundary; ownership is tightened when we are able to. Do not make
    # this fatal - a non-elevated caller would otherwise be unable to prepare a cache at all.
    try {
        $ownerAcl = Get-Acl -LiteralPath $Path
        $ownerAcl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
        Set-Acl -LiteralPath $Path -AclObject $ownerAcl
    } catch {
        Write-StructuredLog -Level SIGNATURE -Message ("Could not set Administrators as owner of {0} (needs elevation): {1}" -f $Path, $_.Exception.Message)
    }
    return $Path
}

function Get-TrustedFileIdentity {
    # Identity used to detect replacement between validation and execution (TOCTOU).
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return [pscustomobject]@{
        Length = [int64]$item.Length
        Sha256 = (Get-Sha256Hex -Path $Path)
    }
}

function Test-ExecutableExtension {
    param([Parameter(Mandatory)][string]$Path)
    return ([System.IO.Path]::GetExtension($Path).ToLowerInvariant() -in @('.exe', '.msi', '.msix', '.msixbundle', '.appx', '.appxbundle', '.dll', '.ps1', '.cmd', '.bat'))
}

function Assert-TrustedArtifact {
    <#
        THE single validation contract. A fresh download and a cache hit both go through this,
        so there is no cache bypass to forget about.

        For anything executable a TRUST ANCHOR is mandatory: either a pinned SHA256, or a valid
        Authenticode signature whose signer is on that component's allowlist. "No hash configured
        because the URL tracks the latest version" is exactly the case that must NOT downgrade to
        no verification at all - that is the hole H-01 describes.

        Returns $true when the artifact may be used; writes the reason and returns $false
        otherwise. Never throws for an untrusted artifact - the caller evicts and re-downloads.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedSha256 = "",
        [string[]]$AllowedSignerSubjects = @(),
        [switch]$AllowUnsignedNonExecutable
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if (Test-PathContainsReparsePoint -Path $Path) {
        Write-Warn ("Rejected artifact reached through a reparse point: {0}" -f (Split-Path -Leaf $Path))
        Write-StructuredLog -Level SIGNATURE -Message ("Reparse point in path: {0}" -f $Path)
        return $false
    }

    $hashPinned = -not [string]::IsNullOrWhiteSpace($ExpectedSha256)
    if ($hashPinned -and -not (Test-FileSha256 -Path $Path -ExpectedSha256 $ExpectedSha256)) { return $false }

    if (-not (Test-ExecutableExtension -Path $Path)) {
        if ($AllowUnsignedNonExecutable -or $hashPinned) { return $true }
        return $true   # non-executable payloads (archives, json) are covered by the hash when one exists
    }

    # Executable from here down: a trust anchor is required.
    $signatureOk = Test-DownloadedFileSignature -Path $Path -AllowedSignerSubjects $AllowedSignerSubjects
    if ($true -eq $signatureOk) { return $true }
    if ($hashPinned) {
        # Pinned hash already matched above; an unsigned-but-pinned artifact is acceptable
        # because the bytes are exactly the ones the project chose.
        Write-StructuredLog -Level SIGNATURE -Message ("Unsigned executable accepted on pinned hash: {0}" -f $Path)
        return $true
    }
    Write-Warn ("Rejected executable with no trust anchor (no pinned sha256 and no acceptable signature): {0}" -f (Split-Path -Leaf $Path))
    Write-StructuredLog -Level SIGNATURE -Message ("No trust anchor: {0}; signatureResult={1}" -f $Path, $signatureOk)
    return $false
}

function Test-FileSha256 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedSha256 = ""
    )
    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) { return $true }
    try {
        $actual = Get-Sha256Hex -Path $Path
        if ([string]::Equals($actual, $ExpectedSha256.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-StructuredLog -Level HASH -Message ("SHA256 verified: {0}" -f $Path)
            return $true
        }
        Write-Warn ("SHA256 mismatch for {0}. Expected {1}, got {2}." -f (Split-Path -Leaf $Path), $ExpectedSha256, $actual)
        Write-StructuredLog -Level HASH -Message ("SHA256 mismatch: {0}; expected={1}; actual={2}" -f $Path, $ExpectedSha256, $actual)
        return $false
    } catch {
        Write-Warn ("Could not verify SHA256 for {0}: {1}" -f (Split-Path -Leaf $Path), $_.Exception.Message)
        return $false
    }
}

function Initialize-Environment {
    Load-Config

    $logRoot = Resolve-RelativePath ([string]$Global:Config.logRoot)
    Ensure-Directory $logRoot
    Ensure-Directory (Resolve-RelativePath "backups")

    Initialize-StructuredLog -LogDirectory $logRoot

    $portableRoot = [string]$Global:Config.portableRoot
    if (-not [string]::IsNullOrWhiteSpace($portableRoot)) { Ensure-Directory $portableRoot }

    if (-not $Global:TranscriptStarted) {
        $Global:LogFile = Join-Path $logRoot ("WinServerSetup-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
        try {
            Start-Transcript -Path $Global:LogFile -Append -Force | Out-Null
            $Global:TranscriptStarted = $true
            Write-StartupLine -State "VERSION" -Label "Version" -Value $Global:ScriptVersion -ValueKind "StartupValue"
            Write-StartupLine -State "LOG" -Label "Logging to" -Value $Global:LogFile -ValueKind "StartupPath"
            Write-StartupLine -State "LOG" -Label "Structured log" -Value $Global:StructuredLog -ValueKind "StartupPath"
        } catch {
            Write-Warn "Could not start transcript: $($_.Exception.Message)"
        }
    }
}

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Command)
    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Test-TrustedElevationExecutable {
    <#
        L-04. This decides which binary a relaunch starts, and that relaunch inherits the
        current elevated token, so the binary must live where an unprivileged user cannot
        replace it. A valid signature alone is not enough: a byte-copy of the real
        powershell.exe keeps its signature after being dropped into a user-writable directory.

        Run-WinServerSetup.ps1 carries its own copy of this contract on purpose - the launcher
        runs before this module is dot-sourced and cannot call in here. Fail closed.
    #>
    param([string]$Path)
    # Declared inside the function: the test suites extract a single function by AST, so a
    # module-level $script: variable would be undefined there. SIDs, never display names.
    $trustedSids = @(
        'S-1-5-18',      # LOCAL SYSTEM
        'S-1-5-32-544',  # BUILTIN\Administrators
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464' # NT SERVICE\TrustedInstaller
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    # A bare name would be resolved by Start-Process through PATH, which is this whole finding.
    if (-not [System.IO.Path]::IsPathRooted($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if (Test-PathContainsReparsePoint -Path $Path) { return $false }
    # @() at the call site: Get-UntrustedAclWriter returns a plain array and a single-element
    # result unwraps to a scalar on Windows PowerShell 5.1, where .Count would be missing.
    if (@(Get-UntrustedAclWriter -Path $Path).Count -gt 0) { return $false }
    try {
        # The owner is a writer too: it can always rewrite the DACL and then replace the file.
        $ownerSid = (Get-Acl -LiteralPath $Path -ErrorAction Stop).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($trustedSids -notcontains $ownerSid) { return $false }
        return ((Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop).Status -eq 'Valid')
    } catch {
        Write-StructuredLog -Level SIGNATURE -Message ("Rejected an elevation candidate that could not be verified: {0}: {1}" -f $Path, $_.Exception.Message)
        return $false
    }
}

function Get-PreferredPowerShellForRelaunch {
    # L-04. Fixed, administrator-owned locations are asked first and PATH only last, because
    # prepending a directory to PATH is something an unprivileged user can do and this result
    # runs with the elevated token this process already holds. Every candidate, PATH included,
    # still has to pass Test-TrustedElevationExecutable.
    #
    # Two policies differ from the launcher's Get-PreferredPowerShellExe on purpose, and the
    # functions are deliberately not merged: this one prefers the currently running process,
    # and it degrades instead of throwing so a relocation relaunch is never aborted by a
    # resolver. The degraded value is the absolute Windows PowerShell path, not the bare name
    # "powershell.exe" it used to be - Start-Process resolves a bare name through PATH, which
    # would have left the same hijack open on the one path that skips the trust check.
    $candidates = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates.Add((Join-Path $env:ProgramFiles "PowerShell\7\pwsh.exe")) | Out-Null
        $powerShellRoot = Join-Path $env:ProgramFiles "PowerShell"
        if (Test-Path -LiteralPath $powerShellRoot) {
            $installedPwsh = Get-ChildItem -LiteralPath $powerShellRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                ForEach-Object { Join-Path $_.FullName "pwsh.exe" }
            foreach ($candidate in $installedPwsh) {
                $candidates.Add($candidate) | Out-Null
            }
        }
    }

    if (($env:ProgramW6432) -and ($env:ProgramW6432 -ne $env:ProgramFiles)) {
        $candidates.Add((Join-Path $env:ProgramW6432 "PowerShell\7\pwsh.exe")) | Out-Null
    }

    try {
        $currentProcessPath = (Get-Process -Id $PID -ErrorAction Stop).Path
        if ($currentProcessPath) {
            $candidates.Add($currentProcessPath) | Out-Null
        }
    } catch {
        Write-StructuredLog -Level DEBUG -Message ("Could not resolve current PowerShell process path: {0}" -f $_.Exception.Message)
    }

    $systemRoot = if (-not [string]::IsNullOrWhiteSpace($env:WINDIR)) { $env:WINDIR } else { Split-Path -Parent ([Environment]::SystemDirectory) }
    $windowsPowerShell = Join-Path $systemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $candidates.Add($windowsPowerShell) | Out-Null

    foreach ($name in @("pwsh.exe", "powershell.exe")) {
        try {
            $fromPath = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($fromPath -and $fromPath.Source) {
                $candidates.Add($fromPath.Source) | Out-Null
            }
        } catch {
            Write-StructuredLog -Level DEBUG -Message ("Could not resolve {0} from PATH: {1}" -f $name, $_.Exception.Message)
        }
    }

    foreach ($candidate in ($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        if (Test-TrustedElevationExecutable -Path $candidate) {
            return (Get-Item -LiteralPath $candidate).FullName
        }
    }

    Write-StructuredLog -Level SIGNATURE -Message "No trusted PowerShell host could be verified for relaunch; using the absolute Windows PowerShell path."
    return $windowsPowerShell
}

# =============================================================================
# PENDING REBOOT TRACKER
# =============================================================================
function Set-PendingReboot {
    param([string]$Reason = "")
    $Global:RunStats.RebootRequired = $true
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        Write-Warn "Pending reboot flagged: $Reason"
    } else {
        Write-Warn "Pending reboot flagged."
    }
}

function Test-WindowsRebootRequired {
    $signals = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    )
    foreach ($p in $signals) { if (Test-Path $p) { return $true } }
    try {
        $pending = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)
        $ops = @($pending.PendingFileRenameOperations | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($ops.Count -gt 0) { return $true }
    } catch {
        Write-StructuredLog -Level DEBUG -Message ("PendingFileRenameOperations check failed: {0}" -f $_.Exception.Message)
    }
    return $false
}

# =============================================================================
# SELF-RELOCATE
# =============================================================================
# Move the entire project folder to C:\portable\Scripts\WinServerSetup on first
# run. Uses robocopy to preserve everything, then re-launches at the new path
# and exits the current process cleanly.

function Add-RelocationLog {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )

    Add-Content -LiteralPath $Path -Encoding utf8 -Value (
        "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    )
}

function Test-DownloadHostAllowed {
    param([Parameter(Mandatory)][uri]$Uri, [string[]]$AllowedHosts)
    if ($Uri.Scheme -ne 'https') { return $false }
    # An absent JSON property reaches callers as @($null): Count is 1, so the "no restriction"
    # shortcut below would be skipped and $null.StartsWith() would throw.
    $AllowedHosts = @($AllowedHosts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($AllowedHosts.Count -eq 0) { return $true }
    foreach ($allowedHost in $AllowedHosts) {
        if ($allowedHost.StartsWith('*.')) {
            if ($Uri.Host.EndsWith($allowedHost.Substring(1), [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        } elseif ([string]::Equals($Uri.Host, $allowedHost, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-WebResponseFinalUri {
    param([Parameter(Mandatory)]$Response)
    # The final (post-redirect) URI lives on a different property per host: Windows PowerShell
    # 5.1 returns an HttpWebResponse (.ResponseUri), PowerShell 7 an HttpResponseMessage
    # (.RequestMessage.RequestUri). Neither property exists on the other host, so probe both.
    # Note: Invoke-WebRequest -OutFile emits nothing at all unless -PassThru is also passed.
    $base = $Response.BaseResponse
    if ($null -ne $base) {
        $candidate = $base.ResponseUri
        if ($null -eq $candidate) { $candidate = $base.RequestMessage.RequestUri }
        if ($null -ne $candidate) { return [uri]$candidate }
    }
    # Fail closed: an unverifiable redirect target must not be treated as allowed.
    throw "Unable to determine the final download URI; refusing to trust the response."
}

function Write-RelocationReadyMarker {
    param([string]$Path, [string]$Token)
    if ([string]::IsNullOrWhiteSpace($Path) -and [string]::IsNullOrWhiteSpace($Token)) { return }
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Token)) { throw "Relocation readiness path and token must be provided together." }
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [pscustomobject]@{
            Token = $Token
            # Canonical form, so the parent's comparison cannot be defeated by a short-name spelling.
            TargetPath = (ConvertTo-CanonicalPath $Global:ProjectRoot)
            ProcessId = $PID
            ReadyUtc = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-CanonicalPath {
    <#
        Both sides of the readiness comparison must be normalised the SAME way.

        These two do NOT agree, which is the trap: [System.IO.Path]::GetFullPath EXPANDS an 8.3
        short name (C:\...\CANONI~1 -> C:\...\CanonicalLongName) while Resolve-Path PRESERVES
        whatever spelling it was handed. The marker was written with Resolve-Path and read back
        through GetFullPath, so whenever the path was reached by its short name the two strings
        differed, the handshake never matched, it timed out after 30 seconds, and relocation
        reported failure (fail-safe - the source is preserved - but relocation is broken).

        GetFullPath is used on its own here because it is the one that canonicalises: it maps both
        spellings of a directory to the same long form, and it does not require the path to exist,
        which matters because the relocation target may not exist yet.
    #>
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Wait-RelocatedChildReady {
    param($Process, [string]$Path, [string]$Token, [string]$ExpectedTarget, [int]$TimeoutSeconds = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $expectedCanonical = ConvertTo-CanonicalPath $ExpectedTarget
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            try {
                $marker = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
                $actualTarget = ConvertTo-CanonicalPath ([string]$marker.TargetPath)
                if ([string]$marker.Token -eq $Token -and [string]::Equals($actualTarget, $expectedCanonical, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
            } catch { $null = $_ }
        }
        if ($Process.HasExited) { throw "Relocated setup exited with code $($Process.ExitCode) before signaling readiness." }
        Start-Sleep -Milliseconds 100
    }
    throw "Relocated setup did not signal readiness within $TimeoutSeconds seconds; the original source will be preserved."
}

function Invoke-SelfRelocateIfNeeded {
    if ($Global:NoRelocate) {
        Write-StartupLine -State "SKIP" -Label "Self-relocate" -Value "skipped, -NoRelocate switch is set" -ValueKind "StartupDim"
        return $false
    }
    if (-not $Global:Config.selfRelocate -or -not $Global:Config.selfRelocate.enabled) {
        Write-StartupLine -State "SKIP" -Label "Self-relocate" -Value "disabled in config" -ValueKind "StartupDim"
        return $false
    }

    $target = [string]$Global:Config.targetProjectRoot
    if ([string]::IsNullOrWhiteSpace($target)) { $target = "C:\portable\Scripts\WinServerSetup" }

    # ConvertTo-CanonicalPath on BOTH sides. Resolve-Path is deliberately not used here: it
    # PRESERVES whatever spelling it was handed (an 8.3 alias stays short) while the config value
    # arrived normalised by nothing at all, so "already installed at the target" was decided by
    # string spelling rather than by identity. A short-name $PSScriptRoot, a forward-slash or
    # dot-segment config value, or a stray trailing space each missed the match and relocated the
    # install onto itself - and the pre-copy guard below does not catch it, because an identical
    # pair is neither nested nor a drive root.
    $currentFull = ConvertTo-CanonicalPath $Global:ProjectRoot
    $targetFull  = ConvertTo-CanonicalPath $target

    if ([string]::Equals($currentFull, $targetFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-StartupLine -State "SKIP" -Label "Running from" -Value $targetFull -ValueKind "StartupPath"
        return $false
    }

    # The deferred cleanup script refuses a nested or root pair, but it only runs AFTER robocopy
    # has copied - so a target inside the source was copied into itself first and merely left
    # behind as a duplicated, recursed tree. The same verdict has to gate the copy itself.
    $sourceRoot = [System.IO.Path]::GetPathRoot($currentFull).TrimEnd('\')
    $targetRoot = [System.IO.Path]::GetPathRoot($targetFull).TrimEnd('\')
    if ([string]::Equals($currentFull, $sourceRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($targetFull, $targetRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $targetFull.StartsWith($currentFull + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
        $currentFull.StartsWith($targetFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Refusing to relocate: '{0}' and '{1}' are the same tree, one contains the other, or one is a drive root." -f $currentFull, $targetFull)
    }

    Write-StartupLine -State "RUN" -Label "Relocating project to" -Value $targetFull -ValueKind "StartupPath"
    $parent = Split-Path -Parent $targetFull
    Ensure-Directory $parent
    $targetLogDir = Join-Path $targetFull "logs"
    $relocateLog = Join-Path $targetLogDir ("WinServerSetup-relocate-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

    # Copy with robocopy, then schedule removal of the original source after the
    # relaunched target process starts. /E updates/merges without deleting
    # unexpected destination files.
    Write-StartupLine -State "COPY" -Label "Source" -Value $currentFull -ValueKind "StartupPath"
    Write-StartupLine -State "COPY" -Label "Target" -Value $targetFull -ValueKind "StartupPath"
    $robocopyLog = Join-Path $env:TEMP "WinServerSetup-relocate.log"
    $proc = Start-Process robocopy.exe `
        -ArgumentList @("`"$currentFull`"", "`"$targetFull`"", "/E", "/COPY:DAT", "/R:1", "/W:2", "/NFL", "/NDL", "/NJH", "/NJS", "/NC", "/NS", "/LOG:`"$robocopyLog`"") `
        -Wait -PassThru -WindowStyle Hidden
    # robocopy exit codes <=7 are success (8+ are real failures).
    if ($proc.ExitCode -ge 8) {
        throw "robocopy failed with exit code $($proc.ExitCode). See $robocopyLog"
    }
    Write-StartupLine -State "OK" -Label "Copied" -Value ("project files, robocopy exit code {0}." -f $proc.ExitCode) -ValueKind "StartupOk"
    Ensure-Directory $targetLogDir
    @(
        ("[{0}] [INFO] Source: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $currentFull),
        ("[{0}] [INFO] Target: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $targetFull),
        ("[{0}] [INFO] robocopy exit code: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $proc.ExitCode),
        ("[{0}] [INFO] robocopy log: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $robocopyLog)
    ) | Set-Content -LiteralPath $relocateLog -Encoding utf8
    Add-RelocationLog -Path $relocateLog -Level "OK" -Message ("Project files copied. robocopy exit code {0}." -f $proc.ExitCode)

    # Relaunch from the new location and exit this process.
    $newScript = Join-Path $targetFull "WinServerSetup.ps1"
    $readyToken = [guid]::NewGuid().ToString('N')
    $readyPath = Join-Path $targetLogDir ("relocation-ready-{0}.json" -f $readyToken)
    $childArgs = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$newScript`"", "-NoRelocate",
        "-RelocationReadyPath", "`"$readyPath`"", "-RelocationReadyToken", $readyToken
    )
    if ($Global:Full)    { $childArgs += "-Full" }
    if ($Global:NoPause) { $childArgs += "-NoPause" }
    if ($Global:NoColor) { $childArgs += "-NoColor" }
    if ($Global:NoReboot){ $childArgs += "-NoReboot" }

    Write-StartupLine -State "RUN" -Label "Relaunch script" -Value $newScript -ValueKind "StartupPath"
    Add-RelocationLog -Path $relocateLog -Level "RUN" -Message ("Relaunch script: {0}" -f $newScript)
    $relaunchPowerShellExe = Get-PreferredPowerShellForRelaunch
    Write-StartupLine -State "SHELL" -Label "PowerShell host" -Value $relaunchPowerShellExe -ValueKind "StartupPath"
    Add-RelocationLog -Path $relocateLog -Level "SHELL" -Message ("PowerShell host: {0}" -f $relaunchPowerShellExe)
    $relocatedProcess = Start-Process $relaunchPowerShellExe -ArgumentList $childArgs -NoNewWindow -PassThru
    Write-StartupLine -State "RUN" -Label "Relocated setup PID" -Value ([string]$relocatedProcess.Id) -ValueKind "StartupValue"
    Add-RelocationLog -Path $relocateLog -Level "RUN" -Message ("Relocated setup PID: {0}" -f $relocatedProcess.Id)
    Write-StartupLine -State "LOG" -Label "Relocation log" -Value $relocateLog -ValueKind "StartupPath"
    Wait-RelocatedChildReady -Process $relocatedProcess -Path $readyPath -Token $readyToken -ExpectedTarget $targetFull | Out-Null
    Write-StartupLine -State "OK" -Label "Relocated child" -Value "loaded and ready; source cleanup is now eligible." -ValueKind "StartupOk"
    Add-RelocationLog -Path $relocateLog -Level "OK" -Message "Relocated child readiness handshake verified."
    try {
        $cleanupScript = Join-Path $env:TEMP ("WinServerSetup-clean-source-{0}.ps1" -f ([guid]::NewGuid().ToString("N")))
        $parentPid = $PID
        $cleanup = @"
param(
    [Parameter(Mandatory = `$true)][string]`$SourcePath,
    [Parameter(Mandatory = `$true)][string]`$TargetPath,
    [Parameter(Mandatory = `$true)][int]`$ParentProcessId,
    [Parameter(Mandatory = `$true)][string]`$RelocateLog,
    [Parameter(Mandatory = `$true)][string]`$ReadinessPath,
    [Parameter(Mandatory = `$true)][string]`$ReadinessToken
)
`$ErrorActionPreference = 'SilentlyContinue'
# Wait-Process -Timeout raises a NON-terminating error on expiry, and SilentlyContinue swallows
# it - so the catch never ran and this script proceeded to delete the source with the parent
# still live. Liveness is therefore OBSERVED afterwards rather than inferred from an exception,
# and a parent that is still running is one of the unsafe conditions below.
Wait-Process -Id `$ParentProcessId -Timeout 60
`$parentStillRunning = `$null -ne (Get-Process -Id `$ParentProcessId -ErrorAction SilentlyContinue)
try {
    `$src = [System.IO.Path]::GetFullPath(`$SourcePath).TrimEnd('\')
    `$dst = [System.IO.Path]::GetFullPath(`$TargetPath).TrimEnd('\')
    `$root = [System.IO.Path]::GetPathRoot(`$src).TrimEnd('\')
    `$marker = Get-Content -LiteralPath `$ReadinessPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    `$markerTarget = [System.IO.Path]::GetFullPath([string]`$marker.TargetPath).TrimEnd('\')
    # ponytail: pid-only liveness, so a recycled pid keeps the source instead of deleting it.
    # That is the safe direction; capture the parent's StartTime too if it ever matters.
    `$unsafe = `$parentStillRunning -or
        -not `$src -or -not `$dst -or [string]::Equals(`$src, `$root, [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals(`$src, `$dst, [System.StringComparison]::OrdinalIgnoreCase) -or
        `$dst.StartsWith(`$src + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
        `$src.StartsWith(`$dst + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath (Join-Path `$src 'WinServerSetup.ps1')) -or
        -not (Test-Path -LiteralPath (Join-Path `$dst 'WinServerSetup.ps1')) -or
        [string]`$marker.Token -ne `$ReadinessToken -or
        -not [string]::Equals(`$markerTarget, `$dst, [System.StringComparison]::OrdinalIgnoreCase)
    if (`$unsafe) { throw 'Refusing to remove unsafe relocation source because the original process is still running, or path or readiness verification failed.' }
    Remove-Item -LiteralPath `$src -Recurse -Force -ErrorAction Stop
    Remove-Item -LiteralPath `$ReadinessPath -Force -ErrorAction SilentlyContinue
    Add-Content -LiteralPath `$RelocateLog -Encoding utf8 -Value ("[{0}] [OK] Removed original source folder: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), `$src)
} catch {
    Add-Content -LiteralPath `$RelocateLog -Encoding utf8 -Value ("[{0}] [WARN] Could not remove original source folder: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), `$_.Exception.Message)
}
try { Remove-Item -LiteralPath `$MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
"@
        Set-Content -LiteralPath $cleanupScript -Value $cleanup -Encoding utf8 -Force
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$cleanupScript`"",
            "-SourcePath", "`"$currentFull`"", "-TargetPath", "`"$targetFull`"",
            "-ParentProcessId", "$parentPid", "-RelocateLog", "`"$relocateLog`"",
            "-ReadinessPath", "`"$readyPath`"", "-ReadinessToken", $readyToken
        )
        Write-StartupLine -State "CLEAN" -Label "Cleanup" -Value "original source is removed after this process exits." -ValueKind "StartupDim"
        Add-RelocationLog -Path $relocateLog -Level "CLEAN" -Message "Original source cleanup scheduled after this process exits."
    } catch {
        Write-Warn "Could not schedule source cleanup after relocation: $($_.Exception.Message)"
        Add-RelocationLog -Path $relocateLog -Level "WARN" -Message ("Could not schedule source cleanup after relocation: {0}" -f $_.Exception.Message)
    }
    Write-StartupLine -State "CLEAN" -Label "This process" -Value "exits now, setup continues in the relocated copy." -ValueKind "StartupDim"
    Add-RelocationLog -Path $relocateLog -Level "CLEAN" -Message "Original setup process will now exit."
    Write-StartupLine -State "NEXT" -Label "Future runs" -Value $targetFull -ValueKind "StartupPath"
    Add-RelocationLog -Path $relocateLog -Level "NEXT" -Message ("Future runs: {0}" -f $targetFull)
    return $true
}
