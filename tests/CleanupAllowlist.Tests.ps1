<#
    Regression tests for audit finding H-03: cleanup denylist replaced with a dedicated-cache
    allowlist.

    The old guard (Test-UnsafeReplaceTarget) rejected only EXACT matches of a drive root or a
    protected root, so C:\Windows\System32 passed, every user profile passed, and a downloadRoot
    typo could aim a recursive delete at almost anything. Deletion now requires a sentinel this
    application wrote, a trusted ACL, no reparse point in the chain, and a non-protected path.

    Every destructive case runs inside a temporary sandbox. Protected system paths are only ever
    passed to the PREDICATES - nothing in this file deletes a real system directory.
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
        Assert-True ($parseErrors.Count -eq 0) "$setupFile must parse before cleanup safety can be tested."
        $fileAst
    })

$script:Failures = New-Object System.Collections.Generic.List[string]
function Write-Fail { param($Message) $script:Failures.Add([string]$Message) | Out-Null }
function Write-Warn { param($Message) }
function Write-Ok { param($Message) }
function Write-Info { param($Message) }
function Write-StructuredLog { param($Level, $Message) }

foreach ($name in @('Get-Sha256Hex', 'Test-PathContainsReparsePoint', 'Get-UntrustedAclWriter', 'Initialize-TrustedDirectory',
        'Get-ProtectedCleanupRoot', 'Test-ProtectedCleanupPath', 'Initialize-CacheSentinel',
        'Test-DedicatedCacheDirectory', 'Assert-DownloadRootAllowed',
        'Remove-DirectoryContentsSafe', 'Remove-CacheContentsSafe', 'Remove-SystemTempContentsSafe')) {
    . ([scriptblock]::Create((Import-FunctionUnderTest $name $setupAsts)))
}

# Production reads $Global:ProjectRoot inside Get-ProtectedCleanupRoot.
$Global:ProjectRoot = $projectRoot
$script:CacheSentinelName = '.winserversetup-cache'

# The cache sandbox must NOT sit under %TEMP%: that is a descendant of %USERPROFILE%, which the
# H-03 rule rejects by design. Production puts the cache under %ProgramData%, so the sandbox goes
# there too. Falls back to %TEMP% only for the predicate-only cases if ProgramData is not writable.
$securityModuleAvailable = $false
try { $securityModuleAvailable = [bool](Get-Command Get-Acl -ErrorAction Stop) } catch { $securityModuleAvailable = $false }

$testRoot = Join-Path $env:ProgramData ("WinServerSetup-H03-{0}" -f ([guid]::NewGuid().ToString("N")))
$cacheCasesEnabled = $securityModuleAvailable
try { New-Item -ItemType Directory -Path $testRoot -Force -ErrorAction Stop | Out-Null }
catch {
    $cacheCasesEnabled = $false
    $testRoot = Join-Path $env:TEMP ("WinServerSetup-H03-{0}" -f ([guid]::NewGuid().ToString("N")))
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    Write-Host "SKIP H-03 cache-deletion cases: %ProgramData% is not writable by this account, so a realistic cache sandbox cannot be created."
}

try {
    # ---- H-03.1: protected paths are refused BEFORE any deletion. ----
    # These are predicate checks only; nothing is deleted.
    $mustReject = @(
        @{ P = $env:SystemDrive; Why = 'the volume root' },
        @{ P = "$env:SystemDrive\"; Why = 'the volume root with a trailing separator' },
        @{ P = $env:SystemRoot; Why = 'the Windows directory' },
        @{ P = (Join-Path $env:SystemRoot 'System32'); Why = 'a descendant of Windows' },
        @{ P = $env:ProgramFiles; Why = 'Program Files' },
        @{ P = (Join-Path $env:ProgramFiles 'SomeVendor'); Why = 'a descendant of Program Files' },
        @{ P = $env:ProgramData; Why = 'the ProgramData root' },
        @{ P = $env:USERPROFILE; Why = 'a user profile root' },
        @{ P = (Join-Path $env:USERPROFILE 'Documents'); Why = 'a descendant of a user profile' },
        @{ P = $projectRoot; Why = 'ProjectRoot itself' }
    )
    foreach ($case in $mustReject) {
        if ([string]::IsNullOrWhiteSpace($case.P)) { continue }
        Assert-Equal $true (Test-ProtectedCleanupPath -Path $case.P) "H-03: must refuse $($case.Why): $($case.P)"
    }

    # The hardened cache location is a ProgramData DESCENDANT and must remain permitted -
    # what protects it is the sentinel and the ACL, not its location.
    Assert-Equal $false (Test-ProtectedCleanupPath -Path (Join-Path $env:ProgramData 'WinServerSetup\cache')) `
        "H-03: the dedicated cache under ProgramData must not be blanket-rejected by location."

  if ($cacheCasesEnabled) {
    # ---- H-03.2a: ACL condition, with the REAL Get-UntrustedAclWriter. ----
    # A sentinel alone is not enough: if a non-administrator can write to the directory, the
    # sentinel itself could have been forged, so deletion must still be refused.
    $sentinelButLoose = Join-Path $testRoot 'sentinel-but-user-writable'
    New-Item -ItemType Directory -Path $sentinelButLoose -Force | Out-Null
    Initialize-CacheSentinel -Path $sentinelButLoose | Out-Null
    Assert-True ((@(Get-UntrustedAclWriter -Path $sentinelButLoose)).Count -gt 0) `
        "H-03: the sandbox must genuinely be user-writable for this case to mean anything."
    Assert-Equal $false (Test-DedicatedCacheDirectory -Path $sentinelButLoose) `
        "H-03: a sentinel in a user-writable directory must NOT qualify it as the dedicated cache."

    # From here the ACL lookup is stubbed so the remaining conditions are isolated - see the
    # explanation at the healthy-cache case below.
    function Get-UntrustedAclWriter { param([string]$Path) return @() }

    # ---- H-03.2: a normal directory without the sentinel is never emptied. ----
    # With the ACL condition stubbed out, refusal here can only come from the missing sentinel.
    $unmarked = Join-Path $testRoot 'not-our-cache'
    New-Item -ItemType Directory -Path $unmarked -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $unmarked 'precious.txt') -Value 'do not delete' -Encoding UTF8
    $script:Failures.Clear()
    $result = Remove-CacheContentsSafe -Path $unmarked
    Assert-Equal $false $result.Succeeded "H-03: a directory without the sentinel must not be cleaned."
    Assert-Equal $true  $result.Unsafe    "H-03: refusing an unmarked directory must be reported as unsafe."
    Assert-Equal 0      $result.Removed   "H-03: nothing may be removed from an unmarked directory."
    Assert-Equal $true  (Test-Path -LiteralPath (Join-Path $unmarked 'precious.txt')) "H-03: the file must still exist."
    Assert-True ($script:Failures.Count -gt 0) "H-03: the refusal must be reported to the operator."

    # ---- H-03.3: a healthy dedicated cache IS emptied, and the sentinel survives. ----
    # Why the ACL lookup is stubbed from H-03.2 onwards: a directory hardened to
    # SYSTEM + Administrators is not even readable by the unelevated process running this suite,
    # so the deletion under test could never run against a realistically-hardened cache. The ACL
    # condition itself is exercised for real in H-03.2a above and, with a directory granting
    # Modify to BUILTIN\Users, in tests\InstallerCacheTrust.Tests.ps1. Stubbing only that lookup
    # keeps the sentinel, reparse-point, protected-path and traversal logic executing for real.
    $cache = Join-Path $testRoot 'cache'
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    Initialize-CacheSentinel -Path $cache | Out-Null
    Assert-Equal $true (Test-DedicatedCacheDirectory -Path $cache) "H-03: a hardened, sentinel-marked cache must be accepted."

    Set-Content -LiteralPath (Join-Path $cache 'installer.exe') -Value 'x' -Encoding UTF8
    New-Item -ItemType Directory -Path (Join-Path $cache 'sub') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $cache 'sub\nested.bin') -Value 'y' -Encoding UTF8

    $result = Remove-CacheContentsSafe -Path $cache
    Assert-Equal $true $result.Succeeded "H-03: a healthy dedicated cache must be cleaned. Failures: $($script:Failures -join ' | ')"
    Assert-Equal 2 $result.Removed "H-03: both top-level entries must be removed."
    Assert-Equal $false (Test-Path -LiteralPath (Join-Path $cache 'installer.exe')) "H-03: cache contents must be gone."
    Assert-Equal $true (Test-Path -LiteralPath (Join-Path $cache $script:CacheSentinelName)) "H-03: the sentinel must survive so the next run still recognises the cache."

    # ---- H-03.4: a junction inside the cache is unlinked, never traversed. ----
    $outside = Join-Path $testRoot 'outside-treasure'
    New-Item -ItemType Directory -Path $outside -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $outside 'keepme.txt') -Value 'must survive' -Encoding UTF8
    $insideJunction = Join-Path $cache 'escape'
    $madeJunction = $false
    try { $null = New-Item -ItemType Junction -Path $insideJunction -Target $outside -ErrorAction Stop; $madeJunction = $true } catch { $madeJunction = $false }

    if ($madeJunction) {
        $result = Remove-CacheContentsSafe -Path $cache
        Assert-Equal $true $result.Succeeded "H-03: cleaning a cache containing a junction must succeed. Failures: $($script:Failures -join ' | ')"
        Assert-Equal $false (Test-Path -LiteralPath $insideJunction) "H-03: the junction itself must be unlinked."
        Assert-Equal $true (Test-Path -LiteralPath (Join-Path $outside 'keepme.txt')) `
            "H-03: traversal must NEVER follow a junction out of the cache - the target's contents must survive."
    } else {
        Write-Host "SKIP H-03 junction-escape case: this host did not permit creating a junction."
    }

    # ---- H-03.5: the cache root itself becoming a reparse point is refused. ----
    $junctionCache = Join-Path $testRoot 'junction-cache'
    if ($madeJunction) {
        $null = New-Item -ItemType Junction -Path $junctionCache -Target $cache -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $junctionCache) {
            Assert-Equal $false (Test-DedicatedCacheDirectory -Path $junctionCache) `
                "H-03: a cache root that is itself a reparse point must be refused even though the sentinel is visible through it."
        }
    }

  }

    # ---- H-03.6: system temp cleanup accepts only the two documented paths. ----
    foreach ($bad in @($testRoot, $env:SystemRoot, (Join-Path $env:SystemRoot 'System32'), $env:USERPROFILE)) {
        if ([string]::IsNullOrWhiteSpace($bad)) { continue }
        $script:Failures.Clear()
        $result = Remove-SystemTempContentsSafe -Path $bad
        Assert-Equal $false $result.Succeeded "H-03: system temp cleanup must refuse a non-allowlisted path: $bad"
        Assert-Equal $true  $result.Unsafe    "H-03: refusing $bad must be flagged unsafe."
        Assert-Equal 0      $result.Removed   "H-03: nothing may be removed from $bad."
    }

    # ---- H-03.7: downloadRoot is validated before setup runs. ----
    Assert-Equal $true (Assert-DownloadRootAllowed -Path "") "H-03: an empty downloadRoot means 'use the hardened default' and is allowed."
    foreach ($bad in @($env:SystemDrive, $env:SystemRoot, (Join-Path $env:SystemRoot 'System32'), $env:USERPROFILE, $projectRoot, 'relative\path')) {
        if ([string]::IsNullOrWhiteSpace($bad)) { continue }
        $rejected = $false
        try { Assert-DownloadRootAllowed -Path $bad | Out-Null } catch { $rejected = $true }
        Assert-Equal $true $rejected "H-03: downloadRoot '$bad' must be rejected during configuration validation."
    }
    Assert-Equal $true (Assert-DownloadRootAllowed -Path (Join-Path $env:ProgramData 'WinServerSetup\cache')) `
        "H-03: the hardened default downloadRoot must pass validation."

    Write-Host "PASS H-03 cleanup allowlist: protected roots and their descendants refused, unmarked directories never emptied, a sentinel-marked cache cleaned with its marker preserved, junctions unlinked instead of traversed, system temp restricted to two exact paths, and downloadRoot validated up front."
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
