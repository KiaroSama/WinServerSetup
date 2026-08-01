<#
    Regression tests for audit finding H-01: elevated installer cache poisoning.

    Before the fix the download cache defaulted to %TEMP%\WinServerSetup-downloads - writable
    by the interactive user - and a cache hit required only Length >= MinimumBytes whenever the
    spec carried no expectedSha256 and did not set requireValidSignature (the default). An
    unprivileged user could plant an unsigned executable under the expected file name and the
    elevated run would launch it. Proven on a real machine before fixing: the shipped cache root
    granted Modify/FullControl to two non-administrative identities and a 4 KB unsigned file was
    accepted as a valid cache hit.

    Every case here runs in a temporary sandbox. Nothing touches a real system path.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub signatures mirror production collaborators so parameter binding matches.')]
param([string]$MainScript = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$mainScript = if ([string]::IsNullOrWhiteSpace($MainScript)) { Join-Path $projectRoot "WinServerSetup.ps1" } else { $MainScript }

. (Join-Path $PSScriptRoot '_Common.ps1')

$setupSourceNames = @('WinServerSetup.ps1') + @('Console', 'Core', 'Download', 'Rdp', 'Install', 'SystemSettings', 'Maintenance' |
        ForEach-Object { "scripts\{0}.ps1" -f $_ })
$setupSourceFiles = @(@($mainScript) + @($setupSourceNames | ForEach-Object { Join-Path $projectRoot $_ })) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique

$setupAsts = @(foreach ($setupFile in $setupSourceFiles) {
        $tokens = $null
        $parseErrors = $null
        $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($setupFile, [ref]$tokens, [ref]$parseErrors)
        Assert-True ($parseErrors.Count -eq 0) "$setupFile must parse before the trust layer can be tested."
        $fileAst
    })

$script:Warnings = New-Object System.Collections.Generic.List[string]
function Write-Warn { param($Message) $script:Warnings.Add([string]$Message) | Out-Null }
function Write-Ok { param($Message) }
function Write-Info { param($Message) }
function Write-StructuredLog { param($Level, $Message) }

foreach ($name in @('Test-FileSha256', 'Test-SignerSubjectAllowed', 'Test-DownloadedFileSignature',
        'Test-PathContainsReparsePoint', 'Get-UntrustedAclWriter', 'Test-TrustedDirectory',
        'Initialize-TrustedDirectory', 'Get-TrustedFileIdentity', 'Test-ExecutableExtension',
        'Assert-TrustedArtifact')) {
    . ([scriptblock]::Create((Import-FunctionUnderTest $name $setupAsts)))
}

$testRoot = Join-Path $env:TEMP ("WinServerSetup-H01-{0}" -f ([guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

function New-Payload {
    param([string]$Path, [int]$Bytes = 4096)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllBytes($Path, (New-Object byte[] $Bytes))
    return $Path
}

try {
    # ---- H-01.1: an unsigned cached MSI/EXE is rejected even at a valid size. ----
    foreach ($ext in @('.exe', '.msi')) {
        $planted = New-Payload (Join-Path $testRoot "planted$ext")
        Assert-Equal $false (Assert-TrustedArtifact -Path $planted -ExpectedSha256 "" -AllowedSignerSubjects @()) `
            "H-01: an unsigned $ext with no pinned hash must be rejected however large it is."
    }

    # A non-executable payload is not held to the signature bar.
    $archive = New-Payload (Join-Path $testRoot 'payload.zip')
    Assert-Equal $true (Assert-TrustedArtifact -Path $archive -ExpectedSha256 "" -AllowedSignerSubjects @()) `
        "H-01: a non-executable payload must not require an Authenticode signature."

    # ---- H-01.2: a pinned hash is a valid trust anchor; a wrong hash is rejected. ----
    $pinned = New-Payload (Join-Path $testRoot 'pinned.exe')
    $realHash = (Get-FileHash -LiteralPath $pinned -Algorithm SHA256).Hash
    Assert-Equal $true (Assert-TrustedArtifact -Path $pinned -ExpectedSha256 $realHash -AllowedSignerSubjects @()) `
        "H-01: an unsigned executable pinned by sha256 is trusted - the bytes are exactly the chosen ones."
    Assert-Equal $false (Assert-TrustedArtifact -Path $pinned -ExpectedSha256 ('0' * 64) -AllowedSignerSubjects @()) `
        "H-01: a hash mismatch must be rejected."

    # ---- H-01.3: a valid signature from an unapproved signer is rejected. ----
    # Signed system binaries are the only reliably-signed artifacts available offline.
    $signedSystemExe = Join-Path $env:WINDIR 'System32\where.exe'
    if (Test-Path -LiteralPath $signedSystemExe) {
        $sig = Get-AuthenticodeSignature -LiteralPath $signedSystemExe
        if ($sig.Status -eq 'Valid') {
            Assert-Equal $true (Assert-TrustedArtifact -Path $signedSystemExe -ExpectedSha256 "" -AllowedSignerSubjects @()) `
                "H-01: a validly signed executable with no allowlist configured is trusted."
            Assert-Equal $false (Assert-TrustedArtifact -Path $signedSystemExe -ExpectedSha256 "" -AllowedSignerSubjects @('CN=Definitely Not Microsoft')) `
                "H-01: a valid signature from a signer outside the allowlist must be rejected."
            Assert-Equal $true (Assert-TrustedArtifact -Path $signedSystemExe -ExpectedSha256 "" -AllowedSignerSubjects @([string]$sig.SignerCertificate.Subject)) `
                "H-01: the allowlisted signer must still be accepted."
        } else {
            Write-Host "SKIP H-01 signer-allowlist cases: $signedSystemExe reports signature status '$($sig.Status)' on this host."
        }
    } else {
        Write-Host "SKIP H-01 signer-allowlist cases: no signed system binary available."
    }

    # ---- H-01.4: a cache root writable by a non-administrator is detected. ----
    $looseRoot = Join-Path $testRoot 'loose-cache'
    New-Item -ItemType Directory -Path $looseRoot -Force | Out-Null
    $acl = Get-Acl -LiteralPath $looseRoot
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($existing in @($acl.Access)) { $null = $acl.RemoveAccessRule($existing) }
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    (New-Object System.Security.Principal.SecurityIdentifier($sid)),
                    [System.Security.AccessControl.FileSystemRights]::FullControl,
                    ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow)))
    }
    # BUILTIN\Users (S-1-5-32-545) with Modify is exactly the condition that must be caught.
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')),
                [System.Security.AccessControl.FileSystemRights]::Modify,
                ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow)))
    Set-Acl -LiteralPath $looseRoot -AclObject $acl

    $offenders = @(Get-UntrustedAclWriter -Path $looseRoot)
    Assert-True ($offenders.Count -gt 0) "H-01: a cache root granting Modify to Users must be reported as untrusted."
    Assert-True (($offenders -join ' ') -match 'S-1-5-32-545') "H-01: the offending principal must be named by SID. Got: $($offenders -join ' | ')"
    Assert-Equal $false (Test-TrustedDirectory -Path $looseRoot) "H-01: Test-TrustedDirectory must reject a user-writable cache root."

    # ---- H-01.5: hardening produces a directory with no non-administrative writer. ----
    $hardened = Initialize-TrustedDirectory -Path (Join-Path $testRoot 'hardened-cache')
    Assert-Equal 0 (@(Get-UntrustedAclWriter -Path $hardened)).Count `
        "H-01: a hardened cache root must have no non-administrative writer. Got: $((Get-UntrustedAclWriter -Path $hardened) -join ' | ')"
    Assert-Equal $true (Test-TrustedDirectory -Path $hardened) "H-01: the hardened root must be trusted."

    # ---- H-01.6: reparse points are rejected anywhere in the chain. ----
    $realTarget = Join-Path $testRoot 'real-target'
    New-Item -ItemType Directory -Path $realTarget -Force | Out-Null
    $junction = Join-Path $testRoot 'junction-cache'
    $madeJunction = $false
    try {
        $null = New-Item -ItemType Junction -Path $junction -Target $realTarget -ErrorAction Stop
        $madeJunction = $true
    } catch { $madeJunction = $false }

    if ($madeJunction) {
        Assert-Equal $true (Test-PathContainsReparsePoint -Path $junction) "H-01: a junction cache root must be detected."
        $throughJunction = New-Payload (Join-Path $junction 'through-junction.exe')
        Assert-Equal $true (Test-PathContainsReparsePoint -Path $throughJunction) `
            "H-01: a file reached THROUGH a junction must be detected even though the file itself is not a reparse point."
        Assert-Equal $false (Assert-TrustedArtifact -Path $throughJunction -ExpectedSha256 "" -AllowedSignerSubjects @()) `
            "H-01: an artifact reached through a reparse point must be rejected fail-closed."
        # Even a correct pinned hash must not rescue a reparse-point path.
        $throughHash = (Get-FileHash -LiteralPath $throughJunction -Algorithm SHA256).Hash
        Assert-Equal $false (Assert-TrustedArtifact -Path $throughJunction -ExpectedSha256 $throughHash -AllowedSignerSubjects @()) `
            "H-01: a pinned hash must not override reparse-point rejection - the path itself is the untrusted part."
    } else {
        Write-Host "SKIP H-01 reparse-point cases: this host did not permit creating a junction (needs SeCreateSymbolicLink or Developer Mode)."
    }

    # ---- H-01.7: replacement between verification and execution is detectable. ----
    $swapTarget = New-Payload (Join-Path $testRoot 'swap.exe')
    $before = Get-TrustedFileIdentity -Path $swapTarget
    [System.IO.File]::WriteAllBytes($swapTarget, (New-Object byte[] 8192))
    $after = Get-TrustedFileIdentity -Path $swapTarget
    Assert-True ($before.Sha256 -ne $after.Sha256) "H-01: a swapped artifact must produce a different identity hash."
    Assert-True ($before.Length -ne $after.Length) "H-01: a swapped artifact must produce a different identity length."

    Write-Host "PASS H-01 installer cache trust: unsigned executables rejected without a trust anchor, unapproved signers rejected, user-writable cache roots detected, hardening verified, reparse points refused fail-closed, and artifact replacement detectable."
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
