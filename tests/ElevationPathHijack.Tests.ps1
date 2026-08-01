<#
    Regression tests for audit finding L-04: PATH-based elevation executable hijacking.

    Get-PreferredPowerShellExe and Get-WindowsTerminalExe (launcher) and
    Get-PreferredPowerShellForRelaunch (scripts\Core.ps1) each hand a path to
    Start-Process -Verb RunAs, or to a relaunch that inherits an already elevated token, so
    whatever they pick runs with full administrative rights.

    Before the fix all three consulted PATH first through
    `Get-Command <name> -CommandType Application` and accepted the first candidate that merely
    passed Test-Path. Prepending a directory to PATH is something an unprivileged user can do
    for their own session, so the attacker - not the machine - chose the elevated image. Proven
    on this machine before fixing: a 16-byte file named pwsh.exe in %TEMP% and a byte-copy of
    the real System32 powershell.exe were both selected once their directory led PATH, and the
    copy even kept a Valid Authenticode signature while sitting in a directory the interactive
    user owns.

    Safety: decoys live in a temporary directory, only the in-process $env:PATH is changed and
    it is restored in finally, the real machine PATH is never touched, and no planted binary is
    ever executed - every assertion is about the path a resolver RETURNS.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub signatures mirror production collaborators so parameter binding matches.')]
param([string]$MainScript = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$mainScript = if ([string]::IsNullOrWhiteSpace($MainScript)) { Join-Path $projectRoot "WinServerSetup.ps1" } else { $MainScript }
$launcherScript = Join-Path $projectRoot "Run-WinServerSetup.ps1"

. (Join-Path $PSScriptRoot '_Common.ps1')

function Get-ParsedAst {
    param([Parameter(Mandatory)][string]$Path)
    $tokens = $null
    $parseErrors = $null
    $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "$Path must parse before its elevation resolver can be tested."
    return $fileAst
}

$launcherAsts = @(Get-ParsedAst -Path $launcherScript)
$coreAsts = @(@($mainScript, (Join-Path $projectRoot 'scripts\Core.ps1')) |
        Where-Object { Test-Path -LiteralPath $_ } |
        ForEach-Object { Get-ParsedAst -Path $_ })

function Write-LauncherLog { param([string]$Level, [string]$Message) }
function Write-StructuredLog { param($Level, $Message) }

# Microsoft.PowerShell.Security supplies Get-Acl and Get-AuthenticodeSignature through module
# autoloading, and the guarded test runner's Windows PowerShell 5.1 child cannot always load it.
# The resolvers fail closed in exactly that situation, so the "a decoy is never selected" half of
# every case still holds; only the "and the trusted binary is selected instead" half is skipped.
$securityModuleAvailable = $false
try {
    $securityModuleAvailable = [bool](Get-Command Get-Acl -ErrorAction Stop) -and
                               [bool](Get-Command Get-AuthenticodeSignature -ErrorAction Stop)
} catch { $securityModuleAvailable = $false }
if (-not $securityModuleAvailable) {
    Write-Host "SKIP L-04 positive-selection cases: Microsoft.PowerShell.Security could not be loaded in this host, so an ACL or signature cannot be read here."
}

$attackDir = Join-Path $env:TEMP ("WinServerSetup-L04-{0}" -f ([guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Path $attackDir -Force | Out-Null
$realWindowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$originalPath = $env:PATH

$trustedRoots = @(
    (Join-Path $env:WINDIR 'System32\WindowsPowerShell'),
    (Join-Path $env:ProgramFiles 'PowerShell')
) + @(if ($env:ProgramW6432) { Join-Path $env:ProgramW6432 'PowerShell' })

function Test-UnderTrustedRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return (@($trustedRoots | Where-Object { $Path -like ("{0}\*" -f $_) }).Count -gt 0)
}

try {
    # The decoys. A byte-copy of the real System32 powershell.exe keeps a Valid Authenticode
    # signature, so signature alone cannot save this: the location is the untrusted part.
    [System.IO.File]::WriteAllBytes((Join-Path $attackDir 'pwsh.exe'), (New-Object byte[] 16))
    [System.IO.File]::WriteAllBytes((Join-Path $attackDir 'wt.exe'), (New-Object byte[] 16))
    Copy-Item -LiteralPath $realWindowsPowerShell -Destination (Join-Path $attackDir 'powershell.exe') -Force
    $signedDecoy = Join-Path $attackDir 'powershell.exe'

    # =========================================================================
    # Launcher: Run-WinServerSetup.ps1 runs before scripts\Core.ps1 is dot-sourced,
    # so it carries its own copy of the trust check.
    # =========================================================================
    foreach ($name in @('Test-TrustedElevationExecutable', 'Get-PreferredPowerShellExe', 'Get-WindowsTerminalExe')) {
        . ([scriptblock]::Create((Import-FunctionUnderTest $name $launcherAsts)))
    }

    try {
        # ---- L-04.1: a user-writable directory is untrusted even with a valid signature. ----
        Assert-Equal $false (Test-TrustedElevationExecutable -Path $signedDecoy) `
            "L-04: a validly signed executable copied into a user-writable directory must be rejected for elevation."
        Assert-Equal $false (Test-TrustedElevationExecutable -Path (Join-Path $attackDir 'pwsh.exe')) `
            "L-04: an unsigned decoy in a user-writable directory must be rejected for elevation."
        Assert-Equal $false (Test-TrustedElevationExecutable -Path $attackDir) `
            "L-04: a directory is not a regular file and must never be selected for elevation."
        Assert-Equal $false (Test-TrustedElevationExecutable -Path (Join-Path $attackDir 'does-not-exist.exe')) `
            "L-04: a missing candidate must be rejected for elevation."

        if ($securityModuleAvailable) {
            Assert-Equal $true (Test-TrustedElevationExecutable -Path $realWindowsPowerShell) `
                "L-04: the System32 Windows PowerShell binary must pass the elevation trust check."
        }

        # ---- L-04.2: a reparse point anywhere in the chain is refused. ----
        $junction = Join-Path $attackDir 'junction'
        $madeJunction = $false
        try {
            $null = New-Item -ItemType Junction -Path $junction -Target (Split-Path -Parent $realWindowsPowerShell) -ErrorAction Stop
            $madeJunction = $true
        } catch { $madeJunction = $false }
        if ($madeJunction) {
            Assert-Equal $false (Test-TrustedElevationExecutable -Path (Join-Path $junction 'powershell.exe')) `
                "L-04: a trusted binary reached THROUGH a junction must be rejected - the redirect is attacker-controlled."
        } else {
            Write-Host "SKIP L-04 reparse-point case: this host did not permit creating a junction (needs SeCreateSymbolicLink or Developer Mode)."
        }

        # ---- L-04.3: a poisoned PATH never wins the launcher's elevated host. ----
        $env:PATH = $attackDir + ';' + $originalPath
        $resolvedLauncher = $null
        $launcherError = $null
        try { $resolvedLauncher = Get-PreferredPowerShellExe } catch { $launcherError = $_ }

        Assert-True `
            (($null -eq $resolvedLauncher) -or -not ($resolvedLauncher.StartsWith($attackDir, [System.StringComparison]::OrdinalIgnoreCase))) `
            ("L-04: the launcher must never elevate a PowerShell binary supplied through PATH. Resolved: {0}" -f $resolvedLauncher)

        if ($securityModuleAvailable) {
            Assert-True ($null -eq $launcherError) `
                ("L-04: the launcher must still find a trusted PowerShell host under a poisoned PATH. Error: {0}" -f $launcherError)
            Assert-True (Test-UnderTrustedRoot -Path $resolvedLauncher) `
                ("L-04: the launcher must elevate a binary from a fixed trusted location. Resolved: {0}" -f $resolvedLauncher)
        } else {
            # Fail closed: with no way to read an ACL or a signature the launcher must throw,
            # never downgrade to the first thing PATH happens to offer.
            Assert-True ($null -ne $launcherError) `
                "L-04: with no way to verify a candidate the launcher must fail closed instead of trusting PATH."
        }

        # ---- L-04.4: a poisoned PATH never wins the elevated Windows Terminal host. ----
        $resolvedTerminal = Get-WindowsTerminalExe
        Assert-True `
            (($null -eq $resolvedTerminal) -or -not ($resolvedTerminal.StartsWith($attackDir, [System.StringComparison]::OrdinalIgnoreCase))) `
            ("L-04: the launcher must never elevate a wt.exe supplied through PATH. Resolved: {0}" -f $resolvedTerminal)

        # The per-user app-execution alias is a 0-byte reparse point in a directory the
        # interactive user owns, which is exactly the shape this finding is about.
        $terminalAlias = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe' } else { $null }
        if ($terminalAlias -and (Test-Path -LiteralPath $terminalAlias)) {
            Assert-Equal $false (Test-TrustedElevationExecutable -Path $terminalAlias) `
                "L-04: the per-user Windows Terminal app-execution alias must not be trusted for an elevated launch."
            Assert-True `
                (($null -eq $resolvedTerminal) -or -not ([string]::Equals($resolvedTerminal, $terminalAlias, [System.StringComparison]::OrdinalIgnoreCase))) `
                ("L-04: the launcher must not elevate the per-user Windows Terminal alias. Resolved: {0}" -f $resolvedTerminal)
        }
        if ($resolvedTerminal) {
            Assert-Equal $true (Test-TrustedElevationExecutable -Path $resolvedTerminal) `
                ("L-04: a Windows Terminal path offered for elevation must itself pass the trust check. Resolved: {0}" -f $resolvedTerminal)
        }
    } finally {
        $env:PATH = $originalPath
        foreach ($name in @('Test-TrustedElevationExecutable', 'Get-PreferredPowerShellExe', 'Get-WindowsTerminalExe')) {
            Remove-Item -LiteralPath ("Function:\{0}" -f $name) -ErrorAction SilentlyContinue
        }
    }

    # =========================================================================
    # scripts\Core.ps1: same trust contract, different documented policy - this resolver
    # prefers the current process and degrades instead of throwing.
    # =========================================================================
    foreach ($name in @('Test-PathContainsReparsePoint', 'Get-UntrustedAclWriter', 'Test-TrustedElevationExecutable', 'Get-PreferredPowerShellForRelaunch')) {
        . ([scriptblock]::Create((Import-FunctionUnderTest $name $coreAsts)))
    }

    try {
        Assert-Equal $false (Test-TrustedElevationExecutable -Path $signedDecoy) `
            "L-04: the relaunch resolver must reject a validly signed executable in a user-writable directory."

        $env:PATH = $attackDir + ';' + $originalPath
        $resolvedRelaunch = Get-PreferredPowerShellForRelaunch

        Assert-True `
            (-not $resolvedRelaunch.StartsWith($attackDir, [System.StringComparison]::OrdinalIgnoreCase)) `
            ("L-04: the relaunch resolver must never hand a PATH-supplied binary to an elevated relaunch. Resolved: {0}" -f $resolvedRelaunch)

        # A bare name such as "powershell.exe" is resolved by Start-Process through PATH, which
        # is the same hijack by another route, so even the never-throw fallback must be rooted.
        Assert-Equal $true ([System.IO.Path]::IsPathRooted($resolvedRelaunch)) `
            ("L-04: the relaunch resolver must return a rooted path, never a name PATH would resolve. Resolved: {0}" -f $resolvedRelaunch)

        if ($securityModuleAvailable) {
            Assert-True (Test-UnderTrustedRoot -Path $resolvedRelaunch) `
                ("L-04: the relaunch resolver must pick a binary from a fixed trusted location. Resolved: {0}" -f $resolvedRelaunch)
        }
    } finally {
        $env:PATH = $originalPath
        foreach ($name in @('Test-PathContainsReparsePoint', 'Get-UntrustedAclWriter', 'Test-TrustedElevationExecutable', 'Get-PreferredPowerShellForRelaunch')) {
            Remove-Item -LiteralPath ("Function:\{0}" -f $name) -ErrorAction SilentlyContinue
        }
    }

    # The two resolvers are deliberately NOT merged: the launcher throws when nothing is
    # trusted, scripts\Core.ps1 degrades, and only scripts\Core.ps1 prefers the current process.
    $launcherText = Get-Content -LiteralPath $launcherScript -Raw -Encoding UTF8
    $coreText = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\Core.ps1') -Raw -Encoding UTF8
    Assert-True ($launcherText -match '(?s)function\s+Get-PreferredPowerShellExe.*?throw\s') `
        "L-04: the launcher policy is to throw when no trusted PowerShell host is available."
    Assert-True ($coreText -match '(?s)function\s+Get-PreferredPowerShellForRelaunch.*?Get-Process\s+-Id\s+\$PID') `
        "L-04: only the relaunch resolver prefers the current PowerShell process."

    Write-Host "PASS L-04 elevation resolvers: PATH decoys are never elevated, a validly signed copy in a user-writable directory is rejected, reparse points and the per-user Windows Terminal alias are refused, and both resolvers keep their own throw/degrade policy."
} finally {
    $env:PATH = $originalPath
    Remove-Item -LiteralPath $attackDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Get-ParsedAst, Function:\Test-UnderTrustedRoot -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Write-LauncherLog, Function:\Write-StructuredLog -ErrorAction SilentlyContinue
}
