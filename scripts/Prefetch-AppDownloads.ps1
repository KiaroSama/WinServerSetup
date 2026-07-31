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

$script:ProjectRootOverride = $ProjectRoot
$script:PrefetchJobTimeoutSeconds = 300
# Ceiling for the whole prefetch phase. Per-job timeouts alone do not bound the loop: a queue
# that keeps starting fresh jobs can outlive the sequential setup it is supposed to run beside.
$script:PrefetchTotalTimeoutSeconds = 1800

function Resolve-ProjectRoot {
    if (-not [string]::IsNullOrWhiteSpace($script:ProjectRootOverride) -and (Test-Path $script:ProjectRootOverride)) { return (Resolve-Path -LiteralPath $script:ProjectRootOverride).Path }
    if ($PSScriptRoot) { return (Split-Path -Parent $PSScriptRoot) }
    return (Get-Location).Path
}

function Write-PrefetchLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Level = "INFO"
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    # 'Local\' (per-session), not 'Global\': creating a kernel object in the global namespace
    # needs SeCreateGlobalPrivilege, which a standard user does not hold. This script is
    # documented as directly runnable, and every worker is a child job of this one process
    # tree in the same session, so the session-local namespace is sufficient.
    $mutex = New-Object System.Threading.Mutex($false, 'Local\WinServerSetup-PrefetchLog')
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(30000) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw "Timed out waiting for the prefetch log lock." }
        Add-Content -LiteralPath $script:ResolvedLogPath -Value $line -Encoding utf8
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# Drains a job's stdout/error into the prefetch log so a failure can actually be diagnosed.
# Previously this output went to Out-Null, leaving only "Failed: <name> state=Failed".
function Write-JobDiagnostics {
    param(
        [Parameter(Mandatory)][string]$Name,
        [object[]]$Output
    )
    $written = 0
    foreach ($item in @($Output)) {
        $text = [string]$item
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        # Redact credentials embedded in URLs and token-bearing query parameters before logging.
        $text = [regex]::Replace($text, '(?i)://[^/@\s]+:[^/@\s]+@', '://***:***@')
        $text = [regex]::Replace($text, '(?i)([?&](?:token|key|sig|signature|password|secret|access[_-]?key)=)[^&\s]*', '${1}***')
        foreach ($rawLine in ($text -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($rawLine)) { continue }
            if ($written -ge 40) {
                Write-PrefetchLog ("[{0}] (output truncated)" -f $Name) "JOB"
                return
            }
            $line = $rawLine.Trim()
            if ($line.Length -gt 500) { $line = $line.Substring(0, 500) + " ..." }
            Write-PrefetchLog ("[{0}] {1}" -f $Name, $line) "JOB"
            $written++
        }
    }
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

function Join-SafeDownloadPath {
    param(
        [Parameter(Mandatory)][string]$DownloadRoot,
        [Parameter(Mandatory)][string]$FileName
    )
    $leaf = Split-Path -Leaf $FileName
    if ([string]::IsNullOrWhiteSpace($leaf)) { throw "Download file name is empty." }
    $root = [System.IO.Path]::GetFullPath($DownloadRoot).TrimEnd('\')
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $root $leaf))
    if (-not $candidate.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Resolved download path is outside the download root: $candidate"
    }
    return $candidate
}

function Add-Task {
    param(
        # AllowEmptyCollection is required: a Mandatory collection parameter otherwise rejects an
        # empty list, so the FIRST task could never be added and New-PrefetchTasks threw on every
        # run before a single download started.
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Tasks,
        [Parameter(Mandatory)][hashtable]$Task
    )
    $Tasks.Add([pscustomobject]$Task) | Out-Null
}

function Resolve-EverythingDownload {
    param([string]$Url)
    try {
        $page = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        $regexMatches = [regex]::Matches([string]$page.Content, 'Everything-(\d+\.\d+\.\d+\.\d+)\.x64-Setup\.exe')
        $latest = $regexMatches | ForEach-Object {
            [pscustomobject]@{ Version = [version]$_.Groups[1].Value; File = $_.Value }
        } | Sort-Object Version -Descending | Select-Object -First 1
        if ($latest) {
            return [pscustomobject]@{
                Url = "https://www.voidtools.com/{0}" -f $latest.File
                FileName = $latest.File
            }
        }
    } catch {
        Write-PrefetchLog "Could not resolve Everything latest installer: $($_.Exception.Message)" "WARN"
    }
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
    # ::new(), not New-Object: a List[object] built by New-Object comes back PSObject-wrapped,
    # and wrapping THAT in @() throws "Argument types do not match" on both 5.1 and 7 - which
    # made `return @($tasks)` below fail on every run. List[string] is unaffected, so the trap
    # only shows up for object lists.
    $tasks = [System.Collections.Generic.List[object]]::new()

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
            Destination = (Join-SafeDownloadPath -DownloadRoot $DownloadRoot -FileName $fileName)
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
        $script:WorkerLogPath = $LogPath
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor `
            [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11

        function Log {
            param([string]$Message, [string]$Level = "INFO")
            $line = "[{0}] [{1}] [{2}] {3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, [string]$Task.Name, $Message
            $mutex = New-Object System.Threading.Mutex($false, 'Local\WinServerSetup-PrefetchLog')
            $acquired = $false
            try {
                try { $acquired = $mutex.WaitOne(30000) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
                if (-not $acquired) { throw "Timed out waiting for the prefetch log lock." }
                Add-Content -LiteralPath $script:WorkerLogPath -Value $line -Encoding utf8
            } finally {
                if ($acquired) { $mutex.ReleaseMutex() }
                $mutex.Dispose()
            }
        }

        function EnsureDir {
            param([string]$Path)
            if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
        }

        function DownloadUrl {
            param([string]$Url, [string]$Destination)
            $dir = Split-Path -Parent $Destination
            EnsureDir $dir
            if ((Test-Path $Destination) -and ((Get-Item -LiteralPath $Destination).Length -ge 1024)) {
                Log "Already cached: $Destination" "OK"
                return
            }
            if (Test-Path $Destination) {
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            }
            $tmp = "$Destination.partial"
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            Log "Downloading $Url -> $Destination"
            Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -TimeoutSec 120 -MaximumRedirection 5 -ErrorAction Stop
            if ((Get-Item -LiteralPath $tmp).Length -lt 1024) {
                throw "Downloaded file is unexpectedly small."
            }
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
                    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -UseBasicParsing -TimeoutSec 120 -Headers @{ 'User-Agent' = 'WinServerSetup' }
                    $asset = $release.assets | Where-Object { $_.name -match $regex } | Select-Object -First 1
                    if (-not $asset) { throw "No release asset matched regex: $regex" }
                    $destination = Join-Path $downloadRoot (Split-Path -Leaf ([string]$asset.name))
                    DownloadUrl -Url ([string]$asset.browser_download_url) -Destination $destination
                }
            }
        } catch {
            # Capture the real failure first. Logging can itself fail (lock timeout, unwritable
            # path, full disk); if it does, that secondary error must not replace the cause.
            $original = $_
            try { Log $original.Exception.Message "ERROR" } catch { $null = $_ }
            throw $original
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

$deadline = (Get-Date).AddSeconds($script:PrefetchTotalTimeoutSeconds)

while ($pending.Count -gt 0 -or $jobs.Count -gt 0) {
    if ((Get-Date) -ge $deadline) {
        Write-PrefetchLog ("Overall prefetch deadline of {0}s reached; stopping remaining work." -f $script:PrefetchTotalTimeoutSeconds) "ERROR"
        foreach ($entry in @($jobs.GetEnumerator())) {
            $failed++
            Write-PrefetchLog "Incomplete at deadline: $($entry.Value.Name)" "ERROR"
            Stop-Job -Job $entry.Value.Job -ErrorAction SilentlyContinue
            $deadlineErrors = $null
            $deadlineOutput = @()
            try { $deadlineOutput = @(Receive-Job -Job $entry.Value.Job -ErrorAction SilentlyContinue -ErrorVariable deadlineErrors) } catch { $deadlineErrors = @($_) }
            Write-JobDiagnostics -Name $entry.Value.Name -Output (@($deadlineOutput) + @($deadlineErrors))
            Remove-Job -Job $entry.Value.Job -Force -ErrorAction SilentlyContinue
            $jobs.Remove($entry.Key) | Out-Null
        }
        while ($pending.Count -gt 0) {
            $failed++
            Write-PrefetchLog "Never started before the deadline: $(($pending.Dequeue()).Name)" "ERROR"
        }
        break
    }

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
    foreach ($entry in @($jobs.GetEnumerator())) {
        if (((Get-Date) - $entry.Value.Started).TotalSeconds -le $script:PrefetchJobTimeoutSeconds) { continue }
        $failed++
        Write-PrefetchLog "Timed out: $($entry.Value.Name) after $($script:PrefetchJobTimeoutSeconds)s" "ERROR"
        Stop-Job -Job $entry.Value.Job -ErrorAction SilentlyContinue
        $timeoutErrors = $null
        $timeoutOutput = @()
        try { $timeoutOutput = @(Receive-Job -Job $entry.Value.Job -ErrorAction SilentlyContinue -ErrorVariable timeoutErrors) } catch { $timeoutErrors = @($_) }
        Write-JobDiagnostics -Name $entry.Value.Name -Output (@($timeoutOutput) + @($timeoutErrors))
        Remove-Job -Job $entry.Value.Job -Force -ErrorAction SilentlyContinue
        $jobs.Remove($entry.Key) | Out-Null
    }
    if ($jobs.Count -eq 0) { continue }
    $finished = Wait-Job -Job ($jobs.Values.Job) -Any -Timeout 2
    if (-not $finished) { continue }

    foreach ($job in @($finished)) {
        $meta = $jobs[$job.Id]
        $elapsed = (Get-Date) - $meta.Started
        $jobErrors = $null
        $jobOutput = @()
        try { $jobOutput = @(Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErrors) } catch { $jobErrors = @($_) }
        if ($job.State -eq "Completed") {
            Write-PrefetchLog ("Completed: {0} [{1:N1}s]" -f $meta.Name, $elapsed.TotalSeconds) "OK"
        } else {
            $failed++
            Write-PrefetchLog ("Failed: {0} [{1:N1}s] state={2}" -f $meta.Name, $elapsed.TotalSeconds, $job.State) "ERROR"
            Write-JobDiagnostics -Name $meta.Name -Output (@($jobOutput) + @($jobErrors))
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
        $jobs.Remove($job.Id) | Out-Null
    }
}

Write-PrefetchLog "Finished. Failed tasks: $failed"
if ($failed -gt 0) { exit 2 }
exit 0
