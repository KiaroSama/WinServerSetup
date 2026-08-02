<#
    Behavioral tests for the self-relocation readiness handshake in WinServerSetup.ps1.

    This file used to consist entirely of six regex matches against the source text. Relocation
    ends by DELETING the original project directory, gated only by a token/target handshake with
    the relaunched child. A grep for "Wait-RelocatedChildReady" stays green even if the token
    comparison is inverted - and the failure mode is "the source tree was removed while the
    original process was still using it".

    Write-RelocationReadyMarker and Wait-RelocatedChildReady are filesystem-based, so they run
    here against a real temp directory: no mocking, and stronger evidence than a stub. The
    deferred-cleanup guard is a separate case - see the MIRROR section below.
#>
# -MainScript targets an alternate copy so these tests can be replayed against a deliberately
# defective build to prove they still fail. CI and local runs use the default.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub signatures mirror production collaborators so parameter binding matches.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Start-Process is shadowed deliberately so the relocation copy can be observed without running robocopy.')]
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
$setupSourceFiles = @(Get-SetupSourceFile -ProjectRoot $projectRoot -MainScript $mainScript)
$setupAsts = @(Get-SetupAst -Files $setupSourceFiles -Because 'its relocation path can be tested')
# Raw text of the same partition, for the retained source assertions further down.
$source = ($setupSourceFiles | ForEach-Object { Get-Content -LiteralPath $_ -Raw -Encoding UTF8 }) -join "`r`n"

foreach ($name in @('ConvertTo-CanonicalPath', 'Write-RelocationReadyMarker', 'Wait-RelocatedChildReady')) {
    . ([scriptblock]::Create((Import-FunctionUnderTest $name $setupAsts)))
}

$testRoot = Join-Path $env:TEMP ("WinServerSetup-Relocation-{0}" -f ([guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

function New-TestProjectDirectory {
    param([string]$Path, [switch]$WithoutScript)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    if (-not $WithoutScript) { Set-Content -LiteralPath (Join-Path $Path 'WinServerSetup.ps1') -Value '# placeholder' -Encoding UTF8 }
    return ConvertTo-CanonicalPath $Path
}

try {
    $targetDir = Join-Path $testRoot 'target'
    $markerDir = Join-Path $testRoot 'markers'
    $otherDir = Join-Path $testRoot 'elsewhere'
    New-Item -ItemType Directory -Path $targetDir, $markerDir, $otherDir -Force | Out-Null

    # Write-RelocationReadyMarker stamps the marker with the project root it actually loaded from.
    $Global:ProjectRoot = $targetDir
    # Normalise exactly the way production does. Resolve-Path preserves an 8.3 short spelling
    # while GetFullPath expands it, so mixing the two makes this suite pass on a developer machine
    # with a long profile path and fail on a CI runner whose TEMP is C:\Users\RUNNER~1\...
    $expectedTarget = ConvertTo-CanonicalPath $targetDir
    $otherTarget = ConvertTo-CanonicalPath $otherDir

    # Stand-in for the relaunched child process while it is still alive.
    $liveChild = [pscustomobject]@{ HasExited = $false; ExitCode = 0 }

    # ---- 1. Marker round-trip: the child writes readiness, the parent accepts it. ----
    $markerPath = Join-Path $markerDir 'relocation-ready.json'
    $tokenA = [guid]::NewGuid().ToString('N')
    Write-RelocationReadyMarker -Path $markerPath -Token $tokenA
    Assert-True (Test-Path -LiteralPath $markerPath) "The readiness marker must be written to the requested path."
    $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal $tokenA ([string]$marker.Token) "The marker must carry the token the child was given."
    Assert-Equal $expectedTarget ([string]$marker.TargetPath) "The marker must record the project root the child actually loaded."
    Assert-Equal $true (Wait-RelocatedChildReady -Process $liveChild -Path $markerPath -Token $tokenA -ExpectedTarget $expectedTarget -TimeoutSeconds 2) `
        "A matching token and target must satisfy the handshake."

    # ---- 2. Token mismatch. A marker left by any other run must not unlock source deletion. ----
    $tokenB = [guid]::NewGuid().ToString('N')
    $handshakeError = $null
    try {
        Wait-RelocatedChildReady -Process $liveChild -Path $markerPath -Token $tokenB -ExpectedTarget $expectedTarget -TimeoutSeconds 1 | Out-Null
    } catch {
        $handshakeError = [string]$_.Exception.Message
    }
    Assert-True ($null -ne $handshakeError) "A marker carrying a different token must never satisfy the handshake."
    Assert-True ($handshakeError -match 'did not signal readiness') "A rejected handshake must fail as a readiness timeout."
    Assert-True ($handshakeError -match 'source will be preserved') "The failure must state that the source is preserved."

    # ---- 3. Target mismatch: correct token, but the child loaded from somewhere else. ----
    $handshakeError = $null
    try {
        Wait-RelocatedChildReady -Process $liveChild -Path $markerPath -Token $tokenA -ExpectedTarget $otherTarget -TimeoutSeconds 1 | Out-Null
    } catch {
        $handshakeError = [string]$_.Exception.Message
    }
    Assert-True ($null -ne $handshakeError) "A marker naming a different project root must never satisfy the handshake."

    # ---- 4. Replay protection: the marker file from run 1 is still on disk. A fresh run with a
    #         fresh token must not be unlocked by it. ----
    $tokenC = [guid]::NewGuid().ToString('N')
    $handshakeError = $null
    try {
        Wait-RelocatedChildReady -Process $liveChild -Path $markerPath -Token $tokenC -ExpectedTarget $expectedTarget -TimeoutSeconds 1 | Out-Null
    } catch {
        $handshakeError = [string]$_.Exception.Message
    }
    Assert-True ($null -ne $handshakeError) "A stale marker from an earlier run must not satisfy a new run's handshake."
    Assert-True (Test-Path -LiteralPath $markerPath) "A rejected handshake must leave the marker on disk for diagnosis."

    # ---- 5. A dead child must abort the wait at once instead of burning the whole timeout. ----
    $missingMarker = Join-Path $markerDir 'never-written.json'
    $deadChild = Start-Process -FilePath $env:ComSpec -ArgumentList '/c exit 0' -PassThru -WindowStyle Hidden
    # Touch the handle so ExitCode stays readable after the process exits (needed on 5.1).
    $null = $deadChild.Handle
    Assert-True ($deadChild.WaitForExit(30000)) "The stand-in child must exit inside its bounded wait."
    $deadChild.WaitForExit()    # the bounded overload can leave ExitCode unset on 5.1; this settles it
    Assert-True $deadChild.HasExited "The test's stand-in child process must have exited before the wait starts."

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $handshakeError = $null
    try {
        Wait-RelocatedChildReady -Process $deadChild -Path $missingMarker -Token $tokenA -ExpectedTarget $expectedTarget -TimeoutSeconds 20 | Out-Null
    } catch {
        $handshakeError = [string]$_.Exception.Message
    }
    $stopwatch.Stop()
    Assert-True ($null -ne $handshakeError) "A child that exited without signalling readiness must fail the handshake."
    Assert-True ($handshakeError -match 'before signaling readiness') "A dead child must be reported as such, not as a timeout."
    Assert-True ($stopwatch.Elapsed.TotalSeconds -lt 5) `
        ("A dead child must abort the wait immediately, not wait out the 20 s deadline. Took {0}s." -f [math]::Round($stopwatch.Elapsed.TotalSeconds, 1))

    # =========================================================================================
    # MIRROR - NOT AN IMPORT.
    #
    # The deferred source-deletion guard lives inside a here-string that WinServerSetup.ps1
    # writes out as a standalone cleanup script, so it cannot be AST-extracted, and executing the
    # generated script is out of the question because it calls Remove-Item -Recurse on a real
    # directory. Two things happen instead:
    #
    #   a) the guard's conditions are asserted to still be present in the here-string, and
    #   b) Test-UnsafeRelocationSourceMirror below RE-STATES those conditions and is exercised
    #      against real temp directories, so the rules themselves are proven to reject each
    #      unsafe case.
    #
    # If anyone edits the here-string near WinServerSetup.ps1:915-923, THIS MIRROR MUST BE
    # UPDATED TO MATCH. The fragment assertions in (a) are what will catch that drift.
    # =========================================================================================
    $guardStart = $source.IndexOf('`$unsafe = `$parentStillRunning')
    Assert-True ($guardStart -ge 0) "The deferred cleanup script must still compute an `$unsafe verdict before deleting anything."
    $guardEnd = $source.IndexOf('Refusing to remove unsafe relocation source', $guardStart)
    Assert-True ($guardEnd -gt $guardStart) "The `$unsafe verdict must still be enforced by a throw."
    $guardBlock = $source.Substring($guardStart, $guardEnd - $guardStart)

    $requiredGuardFragments = @(
        '`$parentStillRunning',
        '[string]::Equals(`$src, `$root, [System.StringComparison]::OrdinalIgnoreCase)',
        '[string]::Equals(`$src, `$dst, [System.StringComparison]::OrdinalIgnoreCase)',
        '`$dst.StartsWith(`$src + ''\'', [System.StringComparison]::OrdinalIgnoreCase)',
        '`$src.StartsWith(`$dst + ''\'', [System.StringComparison]::OrdinalIgnoreCase)',
        '-not (Test-Path -LiteralPath (Join-Path `$src ''WinServerSetup.ps1''))',
        '-not (Test-Path -LiteralPath (Join-Path `$dst ''WinServerSetup.ps1''))',
        '[string]`$marker.Token -ne `$ReadinessToken',
        '-not [string]::Equals(`$markerTarget, `$dst, [System.StringComparison]::OrdinalIgnoreCase)'
    )
    foreach ($fragment in $requiredGuardFragments) {
        Assert-True ($guardBlock.Contains($fragment)) `
            ("The cleanup guard no longer contains this condition, so the mirror below is stale: {0}" -f $fragment)
    }

    function Test-UnsafeRelocationSourceMirror {
        param([string]$SourcePath, [string]$TargetPath, [string]$MarkerTarget, [string]$MarkerToken, [string]$ReadinessToken,
            [bool]$ParentStillRunning = $false)
        $src = [System.IO.Path]::GetFullPath($SourcePath).TrimEnd('\')
        $dst = [System.IO.Path]::GetFullPath($TargetPath).TrimEnd('\')
        $root = [System.IO.Path]::GetPathRoot($src).TrimEnd('\')
        $markerTarget = [System.IO.Path]::GetFullPath($MarkerTarget).TrimEnd('\')
        return ($ParentStillRunning -or
            -not $src -or -not $dst -or [string]::Equals($src, $root, [System.StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($src, $dst, [System.StringComparison]::OrdinalIgnoreCase) -or
            $dst.StartsWith($src + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
            $src.StartsWith($dst + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath (Join-Path $src 'WinServerSetup.ps1')) -or
            -not (Test-Path -LiteralPath (Join-Path $dst 'WinServerSetup.ps1')) -or
            $MarkerToken -ne $ReadinessToken -or
            -not [string]::Equals($markerTarget, $dst, [System.StringComparison]::OrdinalIgnoreCase))
    }

    $guardSource = New-TestProjectDirectory (Join-Path $testRoot 'guard-source')
    $guardTarget = New-TestProjectDirectory (Join-Path $testRoot 'guard-target')
    $nestedInSource = New-TestProjectDirectory (Join-Path $guardSource 'nested')
    $nestedInTarget = New-TestProjectDirectory (Join-Path $guardTarget 'nested')
    $noScriptDir = New-TestProjectDirectory (Join-Path $testRoot 'guard-noscript') -WithoutScript
    $guardToken = [guid]::NewGuid().ToString('N')

    Assert-Equal $false (Test-UnsafeRelocationSourceMirror -SourcePath $guardSource -TargetPath $guardTarget -MarkerTarget $guardTarget -MarkerToken $guardToken -ReadinessToken $guardToken) `
        "A fully verified relocation must be allowed to clean up its source."
    Assert-Equal $true (Test-UnsafeRelocationSourceMirror -SourcePath ([System.IO.Path]::GetPathRoot($guardSource)) -TargetPath $guardTarget -MarkerTarget $guardTarget -MarkerToken $guardToken -ReadinessToken $guardToken) `
        "A drive root must never be deletable as a relocation source."
    Assert-Equal $true (Test-UnsafeRelocationSourceMirror -SourcePath $guardSource -TargetPath $guardSource -MarkerTarget $guardSource -MarkerToken $guardToken -ReadinessToken $guardToken) `
        "Source and destination being the same path must abort cleanup."
    Assert-Equal $true (Test-UnsafeRelocationSourceMirror -SourcePath $guardSource -TargetPath $nestedInSource -MarkerTarget $nestedInSource -MarkerToken $guardToken -ReadinessToken $guardToken) `
        "Deleting a source that contains the new destination would destroy the relocated copy."
    Assert-Equal $true (Test-UnsafeRelocationSourceMirror -SourcePath $nestedInTarget -TargetPath $guardTarget -MarkerTarget $guardTarget -MarkerToken $guardToken -ReadinessToken $guardToken) `
        "A source nested inside the destination must not be deleted."
    Assert-Equal $true (Test-UnsafeRelocationSourceMirror -SourcePath $noScriptDir -TargetPath $guardTarget -MarkerTarget $guardTarget -MarkerToken $guardToken -ReadinessToken $guardToken) `
        "A source that is not a WinServerSetup project must never be deleted."
    Assert-Equal $true (Test-UnsafeRelocationSourceMirror -SourcePath $guardSource -TargetPath $noScriptDir -MarkerTarget $noScriptDir -MarkerToken $guardToken -ReadinessToken $guardToken) `
        "Cleanup must not proceed when the destination does not hold a copied project."
    Assert-Equal $true (Test-UnsafeRelocationSourceMirror -SourcePath $guardSource -TargetPath $guardTarget -MarkerTarget $guardTarget -MarkerToken ([guid]::NewGuid().ToString('N')) -ReadinessToken $guardToken) `
        "A marker token that does not match this run must block cleanup."
    Assert-Equal $true (Test-UnsafeRelocationSourceMirror -SourcePath $guardSource -TargetPath $guardTarget -MarkerTarget $otherTarget -MarkerToken $guardToken -ReadinessToken $guardToken) `
        "A marker naming a different target than the one being kept must block cleanup."
    Assert-Equal $true (Test-UnsafeRelocationSourceMirror -SourcePath $guardSource -TargetPath $guardTarget -MarkerTarget $guardTarget -MarkerToken $guardToken -ReadinessToken $guardToken -ParentStillRunning $true) `
        "A parent that outlived its 60s wait must block cleanup. Wait-Process -Timeout raises a NON-terminating error, so under SilentlyContinue the old catch never ran and the source was deleted with the original process still live."

    # =========================================================================================
    # The unsafe pair must be rejected BEFORE the copy, not after it.
    # =========================================================================================
    # The $unsafe guard above is real, but it runs in the deferred cleanup script - which only
    # exists after robocopy /E has already run. A target nested inside the source therefore got
    # copied into itself first and was refused only at cleanup, leaving a duplicated/recursed
    # tree behind and no way to undo it. The same verdict has to gate the copy itself.
    . ([scriptblock]::Create((Import-FunctionUnderTest 'Invoke-SelfRelocateIfNeeded' $setupAsts)))
    function Write-StartupLine { param($State, $Label, $Value, $ValueKind) }
    function Ensure-Directory { param($Path) if (-not (Test-Path -LiteralPath $Path)) { Microsoft.PowerShell.Management\New-Item -ItemType Directory -Path $Path -Force | Out-Null } }
    function Start-Process {
        param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru, $WindowStyle, [switch]$NoNewWindow, $ErrorAction)
        $script:CopyAttempts.Add([string]$FilePath) | Out-Null
        throw "COPY-ATTEMPTED: $FilePath"
    }

    $relocateSource = New-TestProjectDirectory (Join-Path $testRoot 'relocate-src')
    $unsafePairs = @(
        @{ Target = (Join-Path $relocateSource 'inner'); Why = 'a target nested inside the source makes robocopy /E copy the tree into itself' }
        @{ Target = ([System.IO.Path]::GetPathRoot($relocateSource).TrimEnd('\')); Why = 'a drive root as the target would later make the source undeletable and mixes the project into the volume root' }
    )
    $Global:NoRelocate = $false
    foreach ($pair in $unsafePairs) {
        $script:CopyAttempts = New-Object System.Collections.Generic.List[string]
        $Global:ProjectRoot = $relocateSource
        $Global:Config = [pscustomobject]@{
            selfRelocate      = [pscustomobject]@{ enabled = $true }
            targetProjectRoot = [string]$pair.Target
        }
        $rejected = $false
        try { Invoke-SelfRelocateIfNeeded | Out-Null } catch { $rejected = ($_.Exception.Message -notlike 'COPY-ATTEMPTED*') }
        Assert-Equal 0 $script:CopyAttempts.Count `
            ("Relocation must refuse this pair before copying anything: {0}. Attempted: {1}" -f $pair.Why, ($script:CopyAttempts -join ', '))
        Assert-Equal $true $rejected `
            ("An unsafe relocation pair must fail loudly rather than proceed: {0}" -f $pair.Why)
    }

    # The same guard must not reject a legitimate relocation - a rule that refuses everything
    # would pass the two cases above while disabling the feature entirely.
    $script:CopyAttempts = New-Object System.Collections.Generic.List[string]
    $Global:ProjectRoot = $relocateSource
    $Global:Config = [pscustomobject]@{
        selfRelocate      = [pscustomobject]@{ enabled = $true }
        targetProjectRoot = (Join-Path $testRoot 'relocate-dst')
    }
    try { Invoke-SelfRelocateIfNeeded | Out-Null } catch { $null = $_ }
    Assert-Equal 1 $script:CopyAttempts.Count `
        "A sibling target is a legitimate relocation and must still reach the copy - otherwise the guard has simply disabled relocation."

    # =========================================================================================
    # Already installed at the configured target: recognise it and do NOT copy again.
    # =========================================================================================
    # The skip check compared (Resolve-Path $Global:ProjectRoot) against the RAW config string.
    # Resolve-Path PRESERVES whatever spelling it was handed - an 8.3 alias stays short - and the
    # config side was normalised by nothing but TrimEnd('\'), so any spelling of the install
    # directory other than the exact one in the JSON missed the match. The pre-copy guard below
    # does not catch it either: it tests nested and drive-root pairs, and an identical pair is
    # neither. Result: robocopy ran with source and destination naming the same directory.
    $installedDir = New-TestProjectDirectory (Join-Path $testRoot 'relocate-installed')
    $installedShort = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($installedDir).ShortPath

    $sameDirSpellings = @(
        @{ Root = $installedDir; Target = $installedDir.Replace('\', '/'); Why = 'a forward-slash target, which is what writing this path into JSON by hand produces' }
        @{ Root = $installedDir; Target = (Join-Path $installedDir '..\relocate-installed'); Why = 'a target that round-trips through its own parent' }
        @{ Root = $installedDir; Target = ($installedDir + ' '); Why = 'a target carrying a trailing space' }
    )
    # $PSScriptRoot keeps the 8.3 spelling the script was launched with, so this is the real-world
    # case: C:\PROGRA~1\... on one side, the long form in the config on the other. Included only
    # when the volume actually mints aliases, since fsutil 8dot3name can turn that off.
    if ($installedShort -ne $installedDir) {
        $sameDirSpellings += @{ Root = $installedShort; Target = $installedDir; Why = 'launched through an 8.3 short path while the config holds the long form' }
    }

    foreach ($spelling in $sameDirSpellings) {
        # Both sides must really be DIFFERENT strings naming the SAME directory. Without this the
        # case silently degrades into "a path equals itself" and proves nothing.
        Assert-True ([string]$spelling.Root -ne [string]$spelling.Target) `
            ("Fixture check: the two spellings must differ or this case proves nothing: {0}" -f $spelling.Why)
        $script:CopyAttempts = New-Object System.Collections.Generic.List[string]
        $Global:ProjectRoot = [string]$spelling.Root
        $Global:Config = [pscustomobject]@{
            selfRelocate      = [pscustomobject]@{ enabled = $true }
            targetProjectRoot = [string]$spelling.Target
        }
        $relocated = $null
        try { $relocated = Invoke-SelfRelocateIfNeeded } catch { $relocated = "threw: $($_.Exception.Message)" }
        Assert-Equal 0 $script:CopyAttempts.Count `
            ("Already running from the configured target, so nothing may be copied: {0}. Attempted: {1}" -f $spelling.Why, ($script:CopyAttempts -join ', '))
        Assert-Equal $false $relocated `
            ("Already running from the configured target, so relocation must report 'not needed': {0}" -f $spelling.Why)
    }

    # ---- Retained source greps: cheap smoke checks over the parent/child argument contract,
    #      which is exercised only by a real relocation. ----
    Assert-True ($source -match '\[string\]\$RelocationReadyPath') "Relocated child must receive a readiness-marker path."
    Assert-True ($source -match '\[string\]\$RelocationReadyToken') "Relocated child must prove readiness with a per-run token."
    Assert-True ($source -match 'Wait-RelocatedChildReady') "Parent must wait for the relocated child readiness handshake."
    Assert-True ($source -match 'Write-RelocationReadyMarker') "Child must write readiness only after loading the relocated config."
    Assert-True ($source -match 'Refusing to remove unsafe relocation source') "Cleanup must reject root, missing-project, nested, or unverified source paths."
    Assert-True ($source -match 'ReadinessToken') "Cleanup must independently verify the readiness token before deleting the source."

    Write-Host "PASS relocation readiness handshake runs for real, an unsafe source/target pair is refused BEFORE the copy, and the deferred-cleanup guard - including the parent-still-running condition - is covered by a labelled MIRROR (see the MIRROR block) because it lives in a generated here-string."
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
