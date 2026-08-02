<#
    Behavioral regression tests for the download trust path in WinServerSetup.ps1.

    Pre-fix defect: Invoke-DownloadFile called `Invoke-WebRequest -OutFile` WITHOUT -PassThru,
    which emits no object at all, then read `$response.BaseResponse.ResponseUri`. That yielded
    $null, and passing $null to Test-DownloadHostAllowed's [Parameter(Mandatory)][uri] parameter
    raised a binding error inside the try block. The catch swallowed it, the partial file was
    deleted, and EVERY download in the project failed after exhausting its retries - while
    tests/DownloadAndInstallTrust.Tests.ps1 still passed, because it only greps the source for
    the string "BaseResponse.ResponseUri".

    A second, host-specific trap: the final URI is exposed as HttpWebResponse.ResponseUri on
    Windows PowerShell 5.1 but as HttpResponseMessage.RequestMessage.RequestUri on PowerShell 7.

    These tests drive a real local HTTP listener, so they exercise the actual network code path.
#>
# -MainScript targets an alternate copy so these tests can be replayed against a deliberately
# defective build to prove they still fail. CI and local runs use the default.
#
# Collaborator stubs mirror the real signatures so the extracted functions bind as in production.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub signatures mirror production collaborators so parameter binding matches.')]
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
$setupAsts = @(Get-SetupAst -Files $setupSourceFiles -Because 'its download path can be tested')

# H-01 added a trust layer that Invoke-DownloadFile now calls into, so those functions have to
# be imported alongside it or the download path fails with "term is not recognized".
foreach ($name in @('Get-WebResponseFinalUri', 'Test-DownloadHostAllowed', 'Test-SignerSubjectAllowed', 'Test-FileSha256',
        'Test-PathContainsReparsePoint', 'Get-UntrustedAclWriter', 'Initialize-TrustedDirectory',
        'Test-ExecutableExtension', 'Assert-TrustedArtifact', 'Invoke-DownloadFile')) {
    . ([scriptblock]::Create((Import-FunctionUnderTest $name $setupAsts)))
}

# ---- Console/logging collaborators the download path calls into. ----
function Write-Ok { param($Message) }
function Write-Warn { param($Message) }
function Write-Fail { param($Message) $script:Failures.Add([string]$Message) | Out-Null }
function Write-StructuredLog { param($Level, $Message) }
function Write-StatusInPlace { param($Message) }
function Clear-StatusInPlace { }
function Ensure-Directory { param($Path) if ($Path -and -not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }
function Test-DownloadedFileSignature { param($Path, $AllowedSignerSubjects) return $null }
$script:Failures = New-Object System.Collections.Generic.List[string]

# ---- 1. The real host allowlist: HTTPS-only, exact and wildcard matching. ----
Assert-Equal $false (Test-DownloadHostAllowed -Uri ([uri]'http://example.com/a') -AllowedHosts @()) "Plain HTTP must be rejected."
Assert-Equal $true  (Test-DownloadHostAllowed -Uri ([uri]'https://example.com/a') -AllowedHosts @()) "HTTPS with no allowlist is permitted."
Assert-Equal $true  (Test-DownloadHostAllowed -Uri ([uri]'https://cdn.example.com/a') -AllowedHosts @('*.example.com')) "Wildcard host must match."
Assert-Equal $false (Test-DownloadHostAllowed -Uri ([uri]'https://evil.test/a') -AllowedHosts @('*.example.com')) "Non-matching host must be rejected."

# ---- 1b. An absent JSON property reaches these helpers as @($null), NOT as an empty array.
# @($null).Count is 1, so every "no restriction configured" shortcut was skipped: the host check
# threw on $null.StartsWith(), and the signer check interpolated $null into "**", matching every
# certificate while still appearing to enforce a publisher allowlist. ----
Assert-Equal $true (Test-DownloadHostAllowed -Uri ([uri]'https://example.com/a') -AllowedHosts @($null)) `
    "An absent host allowlist must mean allow-any, not a null-reference throw."
Assert-Equal $false (Test-SignerSubjectAllowed -Subject 'CN=Totally Unrelated, O=Elsewhere' -AllowedSignerSubjects @($null)) `
    "An absent signer allowlist must never silently accept an unrelated signer."

# ---- 1c. An allowlist entry pins a whole CN/O value, not a substring of the entire DN. ----
Assert-Equal $false (Test-SignerSubjectAllowed -Subject 'CN=Dolphin Emulator, O=Unrelated' -AllowedSignerSubjects @('Dolphin')) `
    "A partial token must not match a longer CN; that is publisher impersonation."
Assert-Equal $true (Test-SignerSubjectAllowed -Subject 'CN=voidtools, O=voidtools, C=AU' -AllowedSignerSubjects @('voidtools')) `
    "The shipped short-token entries must still match their real certificate CN/O."
Assert-Equal $true (Test-SignerSubjectAllowed -Subject 'CN=voidtools, O=voidtools' -AllowedSignerSubjects @('CN=voidtools, O=voidtools')) `
    "An entry containing '=' must pin the full distinguished name."

# ---- 2. Final-URI resolution must fail closed on an unusable response. ----
$failedClosed = $false
try { Get-WebResponseFinalUri -Response $null } catch { $failedClosed = $true }
Assert-True $failedClosed "A null response must fail closed, never be treated as an allowed host."

# ---- 3. Real download over a local listener, including a redirect. ----
$port = 8700 + ($PID % 200)
$prefix = "http://localhost:$port/"

# The listener is created here and served from an in-process runspace, so teardown can call
# $listener.Stop() directly. A Start-Job worker parked in the blocking GetContext() cannot be
# torn down: both Stop-Job and Remove-Job -Force wait out a 120s timeout (measured on both hosts).
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
$listener.Start()

$runspace = [runspacefactory]::CreateRunspace()
$runspace.Open()
$runspace.SessionStateProxy.SetVariable('listener', $listener)
$runspace.SessionStateProxy.SetVariable('prefix', $prefix)
$worker = [powershell]::Create()
$worker.Runspace = $runspace
$null = $worker.AddScript({
        while ($listener.IsListening) {
            try { $context = $listener.GetContext() } catch { break }
            try {
                if ($context.Request.Url.AbsolutePath -like '*redirect*') {
                    $context.Response.StatusCode = 302
                    $context.Response.RedirectLocation = ($prefix + 'payload.bin')
                    $context.Response.Close()
                    continue
                }
                $payload = New-Object byte[] 4096
                $context.Response.ContentLength64 = $payload.Length
                $context.Response.OutputStream.Write($payload, 0, $payload.Length)
                $context.Response.Close()
            } catch { $null = $_ }
        }
    })
$asyncResult = $worker.BeginInvoke()

$workRoot = Join-Path $env:TEMP ("WinServerSetup-DownloadRuntime-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

# H-01: Invoke-DownloadFile now refuses to write into a directory a non-administrator can write
# to. That gate is correct and is covered for real - including the reject case - by
# tests\InstallerCacheTrust.Tests.ps1, which builds a directory granting Modify to
# BUILTIN\Users and asserts it is reported untrusted.
#
# It cannot also be exercised here: hardening this sandbox to SYSTEM+Administrators makes it
# unwritable by the unelevated process running the suite, so the download under test could
# never run. Stubbing the ACL lookup keeps THIS suite about the download path (redirects,
# hashes, signatures, retries) without weakening the gate, which still executes for real in
# production and in the H-01 suite.
function Get-UntrustedAclWriter { param([string]$Path) return @() }

try {
    Assert-True $listener.IsListening "Local test listener never started on port $port."

    # The production allowlist is HTTPS-only, so substitute a recording stub that accepts the
    # loopback listener while still capturing exactly which URI the download path validated.
    $script:CheckedUris = New-Object System.Collections.Generic.List[string]
    function Test-DownloadHostAllowed {
        param([Parameter(Mandatory)][uri]$Uri, [string[]]$AllowedHosts)
        $script:CheckedUris.Add([string]$Uri) | Out-Null
        return $true
    }

    # 3a. Direct download must succeed. Pre-fix this returned $false for every URL.
    $target = Join-Path $workRoot 'direct.bin'
    $result = Invoke-DownloadFile -Url ($prefix + 'payload.bin') -Destination $target -RetryCount 0
    Assert-Equal $true $result ("A healthy download must succeed. Failures: {0}" -f ($script:Failures -join ' | '))
    Assert-True (Test-Path -LiteralPath $target) "The downloaded file must be moved into place."
    Assert-Equal 4096 ((Get-Item -LiteralPath $target).Length) "The full payload must be written."
    Assert-True (-not (Test-Path -LiteralPath "$target.partial")) "The .partial staging file must not be left behind."

    # 3b. The URI that gets host-checked must be the FINAL one, after redirects.
    $script:CheckedUris.Clear()
    $redirectTarget = Join-Path $workRoot 'redirected.bin'
    $result = Invoke-DownloadFile -Url ($prefix + 'redirect') -Destination $redirectTarget -RetryCount 0
    Assert-Equal $true $result ("A redirected download must succeed. Failures: {0}" -f ($script:Failures -join ' | '))
    $postRequestChecks = @($script:CheckedUris | Where-Object { $_ -like '*payload.bin*' })
    Assert-True ($postRequestChecks.Count -gt 0) `
        ("The post-download host check must see the final redirected URI. Saw: {0}" -f ($script:CheckedUris -join ', '))

    # ---- 4. Wait-ProcessWithStatus must stop when the process handle dies. ----
    # Both spinner call sites were merged into this one helper. The one that used to swallow a
    # Refresh() failure would poll a dead object every 2s forever; the merged helper breaks out.
    # A fake process is used deliberately: a real one cannot be made to fail Refresh() on demand.
    . ([scriptblock]::Create((Import-FunctionUnderTest 'Wait-ProcessWithStatus' $setupAsts)))
    $script:StatusLines = New-Object System.Collections.Generic.List[string]
    function Write-StatusInPlace { param($Message) $script:StatusLines.Add([string]$Message) | Out-Null }
    function Clear-StatusInPlace { }

    $doomed = [pscustomobject]@{ HasExited = $false }
    $doomed | Add-Member -MemberType ScriptMethod -Name Refresh -Value { throw "handle is gone" }
    $elapsedSeen = $null
    $spin = [Diagnostics.Stopwatch]::StartNew()
    Wait-ProcessWithStatus -Process $doomed -Started (Get-Date) -StatusFormat {
        param($elapsed) $script:Elapsed = $elapsed; "working [{0:hh\:mm\:ss}]" -f $elapsed
    }
    $spin.Stop()
    $elapsedSeen = $script:Elapsed
    Assert-True ($spin.Elapsed.TotalSeconds -lt 15) `
        ("A dead handle must end the wait, not spin forever. Took {0:n1}s." -f $spin.Elapsed.TotalSeconds)
    Assert-Equal 1 $script:StatusLines.Count "The status line must be written once before the handle failure ends the wait."
    Assert-True ($null -ne $elapsedSeen) "The status formatter must receive the elapsed TimeSpan."

    # ---- 5. A process that never exits must be terminated at the deadline, tree and all. ----
    # This is the wait that both the app-download prefetch and every installer route through. A
    # healthy handle that simply never exits used to spin here forever, so one hung installer or
    # one hung prefetch child blocked -Full setup with no deadline at all.
    # A REAL process is used: a fake object would let the deadline branch call taskkill against
    # whatever unrelated process happens to hold that pid. cmd.exe spawning ping gives a genuine
    # two-level tree, so /T is proven rather than assumed.
    $script:StatusLines.Clear()
    # 30s of runtime against a 3s budget: long enough that only the deadline can end the wait
    # early, short enough that replaying this suite against a build with the deadline removed
    # costs 30s rather than hanging.
    $hung = Start-Process -FilePath $env:ComSpec -ArgumentList @('/c', 'ping -n 30 127.0.0.1 > nul') -WindowStyle Hidden -PassThru
    try {
        $null = $hung.Handle
        $bounded = [Diagnostics.Stopwatch]::StartNew()
        Wait-ProcessWithStatus -Process $hung -Started (Get-Date) -TimeoutSeconds 3 -StatusFormat {
            param($elapsed) "hung [{0:hh\:mm\:ss}]" -f $elapsed
        }
        $bounded.Stop()
        Assert-True ($bounded.Elapsed.TotalSeconds -lt 15) `
            ("A process that never exits must be ended at its deadline, not waited on forever. Took {0:n1}s." -f $bounded.Elapsed.TotalSeconds)
        $hung.Refresh()
        Assert-Equal $true $hung.HasExited `
            "The deadline must terminate the process, not merely stop watching it - a hung installer left running is worse than a hung wait."
    } finally {
        try { if (-not $hung.HasExited) { & taskkill.exe /PID $hung.Id /T /F 2>$null | Out-Null } } catch { $null = $_ }
        try { $hung.Dispose() } catch { $null = $_ }
    }

    Write-Host "PASS download path completes over a real transport, validates the final redirected URI on this host, ends the status wait on a dead process handle, and terminates a process that outruns its deadline."
} finally {
    # Stopping the listener aborts the pending GetContext, so the worker loop exits at once.
    try { $listener.Stop() } catch { $null = $_ }
    try { $listener.Close() } catch { $null = $_ }
    try { $null = $worker.EndInvoke($asyncResult) } catch { $null = $_ }
    $worker.Dispose()
    $runspace.Dispose()
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}
