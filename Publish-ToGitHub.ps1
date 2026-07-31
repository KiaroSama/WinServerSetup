# Publish-ToGitHub.ps1
# Bootstraps a clean git repository for this project and pushes it to GitHub.
# Run from the project root (the folder that contains WinServerSetup.ps1).
#
# Examples:
#   .\Publish-ToGitHub.ps1 -RepoUrl https://github.com/KiaroSama/WinServerSetup.git
#   .\Publish-ToGitHub.ps1 -RepoUrl https://github.com/KiaroSama/WinServerSetup.git -Force
#   .\Publish-ToGitHub.ps1 -CreateWithGhCli -RepoName WinServerSetup -Visibility public

[CmdletBinding()]
param(
    [string]$RepoUrl,
    [string]$Branch = "main",
    [string]$CommitMessage = "Initial public release of WinServerSetup",
    [switch]$Force,
    [switch]$CreateWithGhCli,
    [string]$RepoName = "WinServerSetup",
    [ValidateSet("public", "private", "internal")]
    [string]$Visibility = "public"
)

$ErrorActionPreference = "Stop"

function Write-Step  { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok    { param([string]$m) Write-Host "[OK] $m"  -ForegroundColor Green }
function Write-Warn2 { param([string]$m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Fail2 { param([string]$m) Write-Host "[ERROR] $m" -ForegroundColor Red }

function Assert-Tool {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name is not installed or not in PATH. Install it and try again."
    }
}

function Invoke-GitChecked {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$CaptureOutput
    )
    # Windows PowerShell 5.1 turns the FIRST native stderr line captured by 2>&1 into a
    # terminating RemoteException while 'Stop' is in effect - even when the process exits 0.
    # `git push` writes its progress ("Enumerating objects...", "To https://...") to stderr on
    # SUCCESS, so that combination reported every successful publish as a failure and skipped
    # the exit-code check entirely. This assignment is function-scoped and reverts on return;
    # the exit code stays the only success signal.
    $ErrorActionPreference = 'Continue'
    $output = @(& git @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $detail = ($output | ForEach-Object { [string]$_ }) -join "`n"
        throw "git $($Arguments[0]) failed with exit code $exitCode. $detail"
    }
    if ($CaptureOutput) { return $output }
    if ($output.Count -gt 0) { $output | Out-Host }
}

# Scans the git INDEX - what a push actually publishes - rather than the working tree.
# `git add --all` can stage a config the working-tree check never looked at (a differently
# named copy, a subfolder, or a local override that escaped .gitignore). -Force is deliberately
# not consulted here: no flag may bypass an activation-key rejection.
function Assert-NoStagedSecrets {
    $staged = @(Invoke-GitChecked -Arguments @("ls-files", "--cached") -CaptureOutput |
        ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    foreach ($path in $staged) {
        $leaf = Split-Path -Leaf $path
        if ($leaf -like "WinServerSetup.config.local.json") {
            throw "The local override '$path' is staged. It is meant to stay untracked - run 'git rm --cached -- $path' before publishing."
        }
        if ($leaf -notlike "WinServerSetup.config*.json") { continue }
        $blob = ((Invoke-GitChecked -Arguments @("show", ":$path") -CaptureOutput) | ForEach-Object { [string]$_ }) -join "`n"
        try {
            $stagedConfig = $blob | ConvertFrom-Json
        } catch {
            throw "Config JSON validation failed before publishing: staged '$path' is not valid JSON. $($_.Exception.Message)"
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$stagedConfig.activation.productKey)) {
            throw "Staged file '$path' contains a non-empty activation.productKey. Move it to the ignored local override and unstage the file before publishing."
        }
    }
}

function Get-ProjectRoot {
    if ($PSScriptRoot) { return $PSScriptRoot }
    return (Get-Location).Path
}

function Test-GitHubRemoteUrl {
    param([Parameter(Mandatory)][string]$Url)
    return (
        $Url -match '^https://github\.com/[^/]+/[^/]+(\.git)?$' -or
        $Url -match '^git@github\.com:[^/]+/[^/]+(\.git)?$'
    )
}

$projectRoot = Get-ProjectRoot
Push-Location $projectRoot
try {
    Assert-Tool -Name "git"

    if ($CreateWithGhCli) {
        Assert-Tool -Name "gh"
    }

    Write-Step "Project root: $projectRoot"

    if (-not (Test-Path ".\WinServerSetup.ps1")) {
        throw "WinServerSetup.ps1 was not found in the current folder. Run this script from the project root."
    }

    if (-not (Test-Path ".\.gitignore")) {
        Write-Warn2 ".gitignore was not found. Files inside logs/, backups/ and apps/installers/ may be committed."
    }

    # Refuse to commit a config that still has a productKey filled in.
    if (Test-Path ".\WinServerSetup.config.json") {
        try {
            $cfg = Get-Content ".\WinServerSetup.config.json" -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            throw "Config JSON validation failed before publishing: $($_.Exception.Message)"
        }
        $key = [string]$cfg.activation.productKey
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            throw "WinServerSetup.config.json contains a non-empty activation.productKey. Move it to the ignored local override before publishing."
        }
    }

    # 1. Initialize repository if needed.
    if (-not (Test-Path ".\.git")) {
        Write-Step "Initializing new git repository on branch '$Branch'."
        Invoke-GitChecked -Arguments @("init", "-b", $Branch) | Out-Null
    } else {
        Write-Step "Git repository already exists. Reusing it."
    }

    # 2. Stage and commit without rewriting the current branch of an existing repository.
    Write-Step "Staging files."
    Invoke-GitChecked -Arguments @("add", "--all") | Out-Null
    Assert-NoStagedSecrets
    $pendingChanges = ((Invoke-GitChecked -Arguments @("status", "--porcelain") -CaptureOutput) -join "`n").Trim()

    if ([string]::IsNullOrEmpty($pendingChanges)) {
        Write-Warn2 "No changes to commit. Skipping commit step."
    } else {
        Write-Step "Creating commit: $CommitMessage"
        Invoke-GitChecked -Arguments @("commit", "-m", $CommitMessage) | Out-Null
        Write-Ok "Commit created."
    }

    # 4. Create remote with gh if requested.
    if ($CreateWithGhCli) {
        Write-Step "Creating GitHub repository '$RepoName' ($Visibility) with gh CLI."
        $ghArgs = @("repo", "create", $RepoName, "--source=.", "--remote=origin", "--push", "--$Visibility")
        & gh @ghArgs
        if ($LASTEXITCODE -ne 0) { throw "gh repo create failed with exit code $LASTEXITCODE." }
        Write-Ok "Repository created and pushed via gh CLI."
        return
    }

    # 5. Set or update the 'origin' remote.
    if ([string]::IsNullOrWhiteSpace($RepoUrl)) {
        Write-Warn2 "No -RepoUrl provided. Skipping remote configuration and push."
        Write-Host ""
        Write-Host "To finish manually:" -ForegroundColor Yellow
        Write-Host "  git remote add origin https://github.com/KiaroSama/$RepoName.git"
        Write-Host "  git branch -M $Branch"
        Write-Host "  git push -u origin $Branch"
        return
    }

    if (-not (Test-GitHubRemoteUrl -Url $RepoUrl) -and -not $Force) {
        throw "RepoUrl is not a GitHub remote. Pass -Force only if you intentionally want to push elsewhere: $RepoUrl"
    }

    $remotes = @(Invoke-GitChecked -Arguments @("remote") -CaptureOutput)
    if ($remotes -contains "origin") {
        $currentOrigin = ((Invoke-GitChecked -Arguments @("remote", "get-url", "origin") -CaptureOutput) -join "").Trim()
        if ($currentOrigin -and -not (Test-GitHubRemoteUrl -Url $currentOrigin) -and -not $Force) {
            throw "Existing origin is not a GitHub remote. Pass -Force to overwrite it intentionally: $currentOrigin"
        }
        if ($Force) {
            Write-Step "Updating existing 'origin' remote to $RepoUrl."
            Invoke-GitChecked -Arguments @("remote", "set-url", "origin", $RepoUrl) | Out-Null
        } else {
            Write-Warn2 "Remote 'origin' already exists. Pass -Force to overwrite its URL."
        }
    } else {
        Write-Step "Adding 'origin' remote -> $RepoUrl"
        Invoke-GitChecked -Arguments @("remote", "add", "origin", $RepoUrl) | Out-Null
    }

    # 6. Push.
    Write-Step "Pushing '$Branch' to origin."
    Invoke-GitChecked -Arguments @("push", "-u", "origin", $Branch)

    Write-Ok "Published. Open the repository on GitHub to verify."
}
catch {
    Write-Fail2 $_.Exception.Message
    exit 1
}
finally {
    Pop-Location
}
