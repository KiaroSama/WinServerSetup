# Prefetch-AppDownloads.ps1
# Downloads application installers/packages into the configured cache before the
# sequential install phase. Intended to run hidden while Windows Update is active.

[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [string]$ConfigPath = "",
    [int]$MaxParallel = 4,
    [string]$LogPath = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor `
    [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11

function Resolve-ProjectRoot {
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot) -and (Test-Path $ProjectRoot)) { return (Resolve-Path -LiteralPath $ProjectRoot).Path }
    if ($PSScriptRoot) { return (Split-Path -Parent $PSScriptRoot) }
    return (Get-Location).Path
}

function Write-PrefetchLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Level = "INFO"
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -LiteralPath $script:ResolvedLogPath -Value $line -Encoding utf8
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Resolve-DownloadCachePath {
    param([Parameter(Mandatory)][object]$Config)
    $cfgValue = [string]$Config.downloadRoot
    if ([string]::IsNullOrWhiteSpace($cfgValue)) {
        $cfgValue = Join-Path $env:TEMP "WinServerSetup-downloads"
    }
    Ensure-Directory $cfgValue
    return $cfgValue
}

function Add-Task {
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Tasks,
        [Parameter(Mandatory)][hashtable]$Task
    )
    $Tasks.Add([pscustomobject]$Task) | Out-Null
}

function Resolve-EverythingDownload {
    param([string]$Url)
    try {
        $page = Invoke-WebRequest -Uri $Url -UseBasicParsing -ErrorAction Stop
        $matches = [regex]::Matches([string]$page.Content, 'Everything-(\d+\.\d+\.\d+\.\d+)\.x64-Setup\.exe')
        $latest = $matches | ForEach-Object {
            [pscustomobject]@{ Version = [version]$_.Groups[1].Value; File = $_.Value }
        } | Sort-Object Version -Descending | Select-Object -First 1
        if ($latest) {
            return [pscustomobject]@{
                Url = "https://www.voidtools.com/{0}" -f $latest.File
                FileName = $latest.File
            }
        }
    } catch { }
    return [pscustomobject]@{
        Url = "https://www.voidtools.com/Everything-1.4.1.1032.x64-Setup.exe"
        FileName = "Everything-1.4.1.1032.x64-Setup.exe"
    }
}

function New-PrefetchTasks {
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$DownloadRoot
    )
    $tasks = New-Object System.Collections.Generic.List[object]

    foreach ($spec in @($Config.directInstallers)) {
        if (-not $spec.enabled) { continue }
        $name = [string]$spec.name
        $url = [string]$spec.url
        $fileName = [string]$spec.fileName
        if ([string]::IsNullOrWhiteSpace($fileName)) { $fileName = "${name}-installer.exe" -replace '\s','' }
        if ($name -ieq "Everything" -and $url -match 'voidtools\.com/downloads/?$') {
            $resolved = Resolve-EverythingDownload -Url $url
            $url = $resolved.Url
            $fileName = $resolved.FileName
        }
        Add-Task -Tasks $tasks -Task @{
            Kind = "Url"
            Name = $name
            Url = $url
            Destination = (Join-Path $DownloadRoot $fileName)
        }
    }

    if ($Config.v2rayN -and $Config.v2rayN.enabled) {
        Add-Task -Tasks $tasks -Task @{
            Kind = "GitHubAsset"
            Name = "v2rayN"
            Repo = [string]$Config.v2rayN.githubRepo
            Regex = [string]$Config.v2rayN.assetNameRegex
            DownloadRoot = $DownloadRoot
        }
    }

    if ($Config.powershell -and $Config.powershell.enabled -and $Config.powershell.installLatestFromGitHub) {
        Add-Task -Tasks $tasks -Task @{
            Kind = "GitHubAsset"
            Name = "PowerShell 7"
            Repo = [string]$Config.powershell.githubRepo
            Regex = [string]$Config.powershell.assetNameRegex
            DownloadRoot = $DownloadRoot
        }
    }

    $wingetRoot = Join-Path $DownloadRoot "winget"
    foreach ($pkg in @($Config.winget.packages)) {
        if (-not $pkg.enabled) { continue }
        Add-Task -Tasks $tasks -Task @{
            Kind = "WingetDownload"
            Name = [string]$pkg.name
            Id = [string]$pkg.id
            DownloadRoot = $wingetRoot
        }
    }
    if ($Config.windowsTerminal -and $Config.windowsTerminal.enabled) {
        Add-Task -Tasks $tasks -Task @{
            Kind = "WingetDownload"
            Name = "Windows Terminal"
            Id = [string]$Config.windowsTerminal.packageId
            DownloadRoot = $wingetRoot
        }
    }

    return @($tasks)
}

function Invoke-TaskJob {
    param(
        [Parameter(Mandatory)][object]$Task,
        [Parameter(Mandatory)][string]$LogPath
    )

    $jobScript = {
        param($Task, $LogPath)
        $ErrorActionPreference = "Stop"
        $ProgressPreference = "SilentlyContinue"
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor `
            [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11

        function Log {
            param([string]$Message, [string]$Level = "INFO")
            $line = "[{0}] [{1}] [{2}] {3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, [string]$Task.Name, $Message
            Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
        }

        function EnsureDir {
            param([string]$Path)
            if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
        }

        function DownloadUrl {
            param([string]$Url, [string]$Destination)
            $dir = Split-Path -Parent $Destination
            EnsureDir $dir
            if ((Test-Path $Destination) -and ((Get-Item -LiteralPath $Destination).Length -gt 0)) {
                Log "Already cached: $Destination" "OK"
                return
            }
            $tmp = "$Destination.partial"
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            Log "Downloading $Url -> $Destination"
            Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -ErrorAction Stop
            Move-Item -LiteralPath $tmp -Destination $Destination -Force
            Log "Downloaded: $Destination" "OK"
        }

        try {
            switch ([string]$Task.Kind) {
                "Url" {
                    DownloadUrl -Url ([string]$Task.Url) -Destination ([string]$Task.Destination)
                }
                "GitHubAsset" {
                    $repo = [string]$Task.Repo
                    $regex = [string]$Task.Regex
                    $downloadRoot = [string]$Task.DownloadRoot
                    EnsureDir $downloadRoot
                    Log "Querying latest GitHub release: $repo"
                    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -UseBasicParsing -Headers @{ 'User-Agent' = 'WinServerSetup' }
                    $asset = $release.assets | Where-Object { $_.name -match $regex } | Select-Object -First 1
                    if (-not $asset) { throw "No release asset matched regex: $regex" }
                    $destination = Join-Path $downloadRoot $asset.name
                    DownloadUrl -Url ([string]$asset.browser_download_url) -Destination $destination
                }
                "WingetDownload" {
                    $id = [string]$Task.Id
                    if ([string]::IsNullOrWhiteSpace($id)) { throw "Empty winget id." }
                    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
                        Log "winget not available; pre-download skipped. Install phase will handle it." "WARN"
                        break
                    }
                    $downloadRoot = [string]$Task.DownloadRoot
                    EnsureDir $downloadRoot
                    $args = @("download", "--id", $id, "--exact", "--source", "winget", "--download-directory", $downloadRoot, "--accept-package-agreements", "--accept-source-agreements")
                    Log ("Running: winget {0}" -f ($args -join ' '))
                    $output = @(& winget @args 2>&1)
                    foreach ($line in $output) {
                        $text = [string]$line
                        if (-not [string]::IsNullOrWhiteSpace($text)) { Log ("winget> {0}" -f $text.TrimEnd()) }
                    }
                    if ($LASTEXITCODE -eq 0) {
                        Log "winget download completed." "OK"
                    } else {
                        Log "winget download exited with code $LASTEXITCODE. Sequential install may download during install." "WARN"
                    }
                }
            }
        } catch {
            Log $_.Exception.Message "ERROR"
            throw
        }
    }

    return Start-Job -Name ([string]$Task.Name) -ScriptBlock $jobScript -ArgumentList $Task, $LogPath
}

$root = Resolve-ProjectRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $root "WinServerSetup.config.json" }
if (-not (Test-Path $ConfigPath)) { throw "Config file not found: $ConfigPath" }

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$logDir = Join-Path $root ([string]$config.logRoot)
Ensure-Directory $logDir
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $logDir ("WinServerSetup-prefetch-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
}
$script:ResolvedLogPath = $LogPath
Set-Content -LiteralPath $script:ResolvedLogPath -Encoding utf8 -Value ("# WinServerSetup app prefetch started {0}" -f (Get-Date -Format "u"))

if ($MaxParallel -lt 1) { $MaxParallel = 1 }
$downloadRoot = Resolve-DownloadCachePath -Config $config
$tasks = @(New-PrefetchTasks -Config $config -DownloadRoot $downloadRoot)
Write-PrefetchLog "Task count: $($tasks.Count); MaxParallel: $MaxParallel; DownloadRoot: $downloadRoot"

$pending = New-Object System.Collections.Generic.Queue[object]
foreach ($task in $tasks) { $pending.Enqueue($task) }
$jobs = @{}
$failed = 0

while ($pending.Count -gt 0 -or $jobs.Count -gt 0) {
    while ($jobs.Count -lt $MaxParallel -and $pending.Count -gt 0) {
        $task = $pending.Dequeue()
        try {
            $job = Invoke-TaskJob -Task $task -LogPath $script:ResolvedLogPath
            $jobs[$job.Id] = [pscustomobject]@{ Job = $job; Name = [string]$task.Name; Started = Get-Date }
            Write-PrefetchLog "Started: $($task.Name)"
        } catch {
            $failed++
            Write-PrefetchLog "Could not start $($task.Name): $($_.Exception.Message)" "ERROR"
        }
    }

    if ($jobs.Count -eq 0) { break }
    $finished = Wait-Job -Job ($jobs.Values.Job) -Any -Timeout 2
    if (-not $finished) { continue }

    foreach ($job in @($finished)) {
        $meta = $jobs[$job.Id]
        $elapsed = (Get-Date) - $meta.Started
        try { Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-Null } catch { }
        if ($job.State -eq "Completed") {
            Write-PrefetchLog ("Completed: {0} [{1:N1}s]" -f $meta.Name, $elapsed.TotalSeconds) "OK"
        } else {
            $failed++
            Write-PrefetchLog ("Failed: {0} [{1:N1}s] state={2}" -f $meta.Name, $elapsed.TotalSeconds, $job.State) "ERROR"
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
        $jobs.Remove($job.Id) | Out-Null
    }
}

Write-PrefetchLog "Finished. Failed tasks: $failed"
if ($failed -gt 0) { exit 2 }
exit 0
