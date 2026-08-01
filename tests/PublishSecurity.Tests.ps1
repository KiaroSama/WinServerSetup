<#
    Behavioral regression tests for Publish-ToGitHub.ps1.

    Pre-fix defect 1: Invoke-GitChecked ran `$output = @(& git @Arguments 2>&1)` while
    $ErrorActionPreference was 'Stop'. On Windows PowerShell 5.1 that combination turns the
    FIRST native stderr line into a terminating RemoteException even when the process exits 0.
    `git push` writes "Enumerating objects: ..." and "To https://..." to stderr on SUCCESS, so
    a completed publish was reported as a failure and the exit-code check never ran at all.
    PowerShell 7 does not convert native stderr this way, so a 5.1-only run is required.

    Pre-fix defect 2: the secret scan only read the working-tree .\WinServerSetup.config.json.
    `git add --all` can stage a config that check never looked at, so a real activation key
    could be committed and pushed. The scan now inspects the git INDEX.

    These tests drive real processes: a native stderr-emitting shim on PATH for the exit-code
    contract, and a throwaway git repository under $env:TEMP for the staged-secret scan. The
    real repository is never touched.
#>
# -PublishScript targets an alternate copy so these tests can be replayed against a
# deliberately defective build to prove they still fail. CI and local runs use the default.
param([string]$PublishScript = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$publishPath = if ([string]::IsNullOrWhiteSpace($PublishScript)) { Join-Path $projectRoot "Publish-ToGitHub.ps1" } else { $PublishScript }

. (Join-Path $PSScriptRoot '_Common.ps1')

# ---- Import only the functions under test; the script self-executes if dot-sourced. ----
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($publishPath, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) "Publish-ToGitHub.ps1 must parse before its git path can be tested."

function Import-FunctionUnderTest {
    param([string]$Name)
    $definition = $ast.FindAll({
            param($node)
            ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq $Name)
        }, $true) | Select-Object -First 1
    if ($null -eq $definition) { throw "Publish-ToGitHub.ps1 must define $Name." }
    return $definition.Extent.Text
}

foreach ($name in @('Invoke-GitChecked', 'Assert-NoStagedSecrets')) {
    . ([scriptblock]::Create((Import-FunctionUnderTest $name $setupAsts)))
}

$source = Get-Content -LiteralPath $publishPath -Raw -Encoding UTF8
$workRoot = Join-Path $env:TEMP ("WinServerSetup-Publish-{0}" -f [guid]::NewGuid().ToString('N'))
$shimDir = Join-Path $workRoot 'shim'
$repoDir = Join-Path $workRoot 'repo'
New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
$originalPath = $env:PATH

try {
    # ================================================================================
    # 1. Exit code is the ONLY success signal, even when the command writes to stderr.
    #    A real native process is required: a PowerShell stub would never reproduce the
    #    5.1 stderr-to-RemoteException conversion this guards against.
    # ================================================================================
    Set-Content -LiteralPath (Join-Path $shimDir 'git.cmd') -Encoding ASCII -Value @(
        '@echo off'
        'echo Enumerating objects: 12, done. 1>&2'
        'echo To https://github.com/example/repo.git 1>&2'
        'exit /b %WSS_TEST_GIT_EXIT%'
    )
    # Shim tests run before any real git call so command resolution cannot be served from a
    # cache populated with the real git.exe.
    $env:PATH = $shimDir + [System.IO.Path]::PathSeparator + $originalPath
    Assert-True ((Get-Command git).Source -eq (Join-Path $shimDir 'git.cmd')) "The stderr shim must be the resolved 'git' for this phase."

    # 1a. Exit 0 with stderr output must NOT throw. This is the reported bug.
    $env:WSS_TEST_GIT_EXIT = '0'
    $caught = $null
    try { Invoke-GitChecked -Arguments @('push', '-u', 'origin', 'main') } catch { $caught = $_ }
    Assert-True ($null -eq $caught) `
    ("A successful push that writes progress to stderr must not be reported as a failure. Got: {0}" -f $caught)

    # 1b. The stderr text must still be captured, not silently discarded.
    $captured = @(Invoke-GitChecked -Arguments @('push') -CaptureOutput | ForEach-Object { [string]$_ })
    Assert-True (($captured -join "`n") -match 'Enumerating objects') "Native stderr must still be captured for diagnostics."

    # 1c. The pre-existing contract: a non-zero exit MUST still throw, and name the code.
    $env:WSS_TEST_GIT_EXIT = '3'
    $caught = $null
    try { Invoke-GitChecked -Arguments @('push', '-u', 'origin', 'main') } catch { $caught = $_ }
    Assert-True ($null -ne $caught) "A non-zero git exit code must throw."
    Assert-True ($caught.Exception.Message -match 'exit code 3') `
    ("The failure must report the real exit code. Got: {0}" -f $caught.Exception.Message)

    # 1d. A non-zero exit must surface the command output as diagnostic detail.
    Assert-True ($caught.Exception.Message -match 'Enumerating objects') "A failure must include the captured command output."

    $env:PATH = $originalPath
    Remove-Item -LiteralPath 'Env:\WSS_TEST_GIT_EXIT' -ErrorAction SilentlyContinue

    # ================================================================================
    # 2. The secret scan must inspect what is STAGED, in a throwaway repository.
    # ================================================================================
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git is required on PATH to verify the staged-secret scan."
    }
    Push-Location $repoDir
    try {
        Invoke-GitChecked -Arguments @('init', '-b', 'main') | Out-Null
        $configPath = Join-Path $repoDir 'WinServerSetup.config.json'

        # 2a. A clean staged config must pass.
        Set-Content -LiteralPath $configPath -Encoding UTF8 -Value '{ "activation": { "productKey": "" } }'
        Invoke-GitChecked -Arguments @('add', '--all') | Out-Null
        $caught = $null
        try { Assert-NoStagedSecrets } catch { $caught = $_ }
        Assert-True ($null -eq $caught) ("An empty activation.productKey must publish cleanly. Got: {0}" -f $caught)

        # 2b. A staged config carrying a real key must stop publication. The working-tree check
        #     alone never saw this, because `git add --all` is what put it into the index.
        Set-Content -LiteralPath $configPath -Encoding UTF8 -Value '{ "activation": { "productKey": "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE" } }'
        Invoke-GitChecked -Arguments @('add', '--all') | Out-Null
        $caught = $null
        try { Assert-NoStagedSecrets } catch { $caught = $_ }
        Assert-True ($null -ne $caught) "A staged non-empty activation.productKey must stop publication."
        Assert-True ($caught.Exception.Message -match 'activation\.productKey') `
        ("The rejection must name the offending field. Got: {0}" -f $caught.Exception.Message)
        Assert-True ($caught.Exception.Message -notmatch 'AAAAA') "The rejection must not echo the key itself."

        # 2c. The scan must reach a config staged under a subfolder, not just the root name.
        Invoke-GitChecked -Arguments @('rm', '--cached', '-f', 'WinServerSetup.config.json') | Out-Null
        Remove-Item -LiteralPath $configPath -Force
        $nested = Join-Path $repoDir 'nested'
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $nested 'WinServerSetup.config.json') -Encoding UTF8 `
            -Value '{ "activation": { "productKey": "REAL-KEY-VALUE" } }'
        Invoke-GitChecked -Arguments @('add', '--all') | Out-Null
        $caught = $null
        try { Assert-NoStagedSecrets } catch { $caught = $_ }
        Assert-True ($null -ne $caught) "A staged key in a subfolder must stop publication too."
        Invoke-GitChecked -Arguments @('rm', '--cached', '-r', '-f', 'nested') | Out-Null
        Remove-Item -LiteralPath $nested -Recurse -Force

        # 2d. The ignored local override must never be publishable, key or not.
        Set-Content -LiteralPath (Join-Path $repoDir 'WinServerSetup.config.local.json') -Encoding UTF8 `
            -Value '{ "activation": { "productKey": "" } }'
        Invoke-GitChecked -Arguments @('add', '--all', '--force') | Out-Null
        $caught = $null
        try { Assert-NoStagedSecrets } catch { $caught = $_ }
        Assert-True ($null -ne $caught) "A staged WinServerSetup.config.local.json must stop publication."
        Assert-True ($caught.Exception.Message -match 'local override') `
        ("The rejection must explain the local override. Got: {0}" -f $caught.Exception.Message)

        # 2e. Malformed staged JSON must stop publication instead of being skipped.
        Invoke-GitChecked -Arguments @('rm', '--cached', '-f', 'WinServerSetup.config.local.json') | Out-Null
        Remove-Item -LiteralPath (Join-Path $repoDir 'WinServerSetup.config.local.json') -Force
        Set-Content -LiteralPath $configPath -Encoding UTF8 -Value '{ "activation": { '
        Invoke-GitChecked -Arguments @('add', '--all') | Out-Null
        $caught = $null
        try { Assert-NoStagedSecrets } catch { $caught = $_ }
        Assert-True ($null -ne $caught) "Malformed staged JSON must stop publication."
        Assert-True ($caught.Exception.Message -match 'Config JSON validation failed') `
        ("Malformed staged JSON must report a validation failure. Got: {0}" -f $caught.Exception.Message)
    } finally {
        Pop-Location
    }

    # ================================================================================
    # 3. Source contracts that cannot be proven by execution.
    # ================================================================================
    # The scan is wired in after staging, so `git add --all` can never outrun it.
    Assert-True ($source -match '"add",\s*"--all"[\s\S]{0,200}Assert-NoStagedSecrets') `
        "The staged-secret scan must run immediately after 'git add --all'."
    # Proving a bypass is ABSENT cannot be done by executing the happy path.
    Assert-True ($source -notmatch 'productKey[\s\S]{0,400}-not\s+\$Force') "-Force must never bypass activation-key rejection."
    Assert-True ($source -notmatch 'git\s+symbolic-ref') "Publishing must not rewrite HEAD with symbolic-ref."

    Write-Host "PASS publish helper survives native stderr, checks exit codes, and rejects staged secrets on this host."
} finally {
    $env:PATH = $originalPath
    Remove-Item -LiteralPath 'Env:\WSS_TEST_GIT_EXIT' -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}
