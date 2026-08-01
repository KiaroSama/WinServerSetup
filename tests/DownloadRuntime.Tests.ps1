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

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw ("{0} Expected={1}; Actual={2}" -f $Message, $Expected, $Actual) }
}

# ---- Import only the functions under test; the main script self-executes if dot-sourced. ----
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($mainScript, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) "WinServerSetup.ps1 must parse before its download path can be tested."

function Import-FunctionUnderTest {
    param([string]$Name)
    $definition = $ast.FindAll({
            param($node)
            ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq $Name)
        }, $true) | Select-Object -First 1
    if ($null -eq $definition) { throw "WinServerSetup.ps1 must define $Name." }
    return $definition.Extent.Text
}

foreach ($name in @('Get-WebResponseFinalUri', 'Test-DownloadHostAllowed', 'Test-SignerSubjectAllowed', 'Test-FileSha256', 'Invoke-DownloadFile')) {
    . ([scriptblock]::Create((Import-FunctionUnderTest $name)))
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

    Write-Host "PASS download path completes over a real transport and validates the final redirected URI on this host."
} finally {
    # Stopping the listener aborts the pending GetContext, so the worker loop exits at once.
    try { $listener.Stop() } catch { $null = $_ }
    try { $listener.Close() } catch { $null = $_ }
    try { $null = $worker.EndInvoke($asyncResult) } catch { $null = $_ }
    $worker.Dispose()
    $runspace.Dispose()
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}
