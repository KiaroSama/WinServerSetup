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
            $key = [string]$cfg.activation.productKey
            if (-not [string]::IsNullOrWhiteSpace($key) -and -not $Force) {
                throw "WinServerSetup.config.json contains a non-empty activation.productKey. Clear it before publishing, or re-run with -Force."
            }
        } catch {
            Write-Warn2 "Could not validate config.json before publishing: $($_.Exception.Message)"
        }
    }

    # 1. Initialize repository if needed.
    if (-not (Test-Path ".\.git")) {
        Write-Step "Initializing new git repository on branch '$Branch'."
        git init -b $Branch | Out-Null
    } else {
        Write-Step "Git repository already exists. Reusing it."
    }

    # 2. Configure default branch name (idempotent).
    git symbolic-ref HEAD "refs/heads/$Branch" 2>$null | Out-Null

    # 3. Stage and commit.
    Write-Step "Staging files."
    git add --all
    $pendingChanges = (git status --porcelain).Trim()

    if ([string]::IsNullOrEmpty($pendingChanges)) {
        Write-Warn2 "No changes to commit. Skipping commit step."
    } else {
        Write-Step "Creating commit: $CommitMessage"
        git commit -m $CommitMessage | Out-Null
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

    $remotes = (git remote) 2>$null
    if ($remotes -contains "origin") {
        $currentOrigin = (git remote get-url origin) 2>$null
        if ($currentOrigin -and -not (Test-GitHubRemoteUrl -Url $currentOrigin) -and -not $Force) {
            throw "Existing origin is not a GitHub remote. Pass -Force to overwrite it intentionally: $currentOrigin"
        }
        if ($Force) {
            Write-Step "Updating existing 'origin' remote to $RepoUrl."
            git remote set-url origin $RepoUrl
        } else {
            Write-Warn2 "Remote 'origin' already exists. Pass -Force to overwrite its URL."
        }
    } else {
        Write-Step "Adding 'origin' remote -> $RepoUrl"
        git remote add origin $RepoUrl
    }

    # 6. Push.
    Write-Step "Pushing '$Branch' to origin."
    git push -u origin $Branch
    if ($LASTEXITCODE -ne 0) {
        throw "git push failed with exit code $LASTEXITCODE."
    }

    Write-Ok "Published. Open the repository on GitHub to verify."
}
catch {
    Write-Fail2 $_.Exception.Message
    exit 1
}
finally {
    Pop-Location
}
