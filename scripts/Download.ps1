# Download.ps1 - the download prefetch handoff, the retrying download path, silent
# installer execution, logged external commands, and winget bootstrap/detection.
#
# Dot-sourced by WinServerSetup.ps1. Contains function definitions only; it reads the
# globals initialized there ($Global:Config, $Global:ProjectRoot, $Global:RunStats) at
# call time, never at load time.

# =============================================================================
# APPLICATION DOWNLOAD PREFETCH
# =============================================================================
# Runs the prefetch helper as a background process so installers download while
# sequential setup continues, then waits for it before the install pass.

function Start-ApplicationDownloadPrefetch {
    param([int]$MaxParallel = 4)
    $prefetchScript = Join-Path $Global:ProjectRoot "scripts\Prefetch-AppDownloads.ps1"
    if (-not (Test-Path $prefetchScript)) {
        Write-Warn "Application prefetch helper not found: $prefetchScript"
        return $null
    }
    if ($MaxParallel -lt 1) { $MaxParallel = 1 }

    $logRoot = Resolve-RelativePath ([string]$Global:Config.logRoot)
    Ensure-Directory $logRoot
    $prefetchLog = Join-Path $logRoot ("WinServerSetup-prefetch-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    $psExe = Join-Path $env:windir "System32\WindowsPowerShell\v1.0\powershell.exe"
    $prefetchArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$prefetchScript`"",
        "-ProjectRoot", "`"$Global:ProjectRoot`"",
        "-ConfigPath", "`"$Global:ConfigPath`"",
        "-MaxParallel", "$MaxParallel",
        "-LogPath", "`"$prefetchLog`""
    )

    try {
        $proc = Start-Process -FilePath $psExe -ArgumentList $prefetchArgs -PassThru -WindowStyle Hidden
        Write-Ok "Application download prefetch started in the background (max $MaxParallel downloads)."
        Write-Info "Prefetch log: $prefetchLog"
        Write-StructuredLog -Level PREFETCH -Message ("Started process {0}; log={1}" -f $proc.Id, $prefetchLog)
        return [pscustomobject]@{ Process = $proc; LogPath = $prefetchLog; Started = Get-Date }
    } catch {
        Write-Warn "Could not start application download prefetch: $($_.Exception.Message)"
        return $null
    }
}

function Wait-ProcessWithStatus {
    # Spins an in-place status line while $Process runs. $StatusFormat receives the elapsed
    # TimeSpan and returns the line to show.
    # A Refresh() failure breaks the loop rather than being swallowed: the handle is gone, so
    # continuing would poll a dead object every 2s forever.
    param(
        [Parameter(Mandatory)][object]$Process,
        [Parameter(Mandatory)][datetime]$Started,
        [Parameter(Mandatory)][scriptblock]$StatusFormat
    )
    while (-not $Process.HasExited) {
        Write-StatusInPlace (& $StatusFormat ((Get-Date) - $Started))
        Start-Sleep -Seconds 2
        try { $Process.Refresh() } catch { break }
    }
    Clear-StatusInPlace
}

function Wait-ApplicationDownloadPrefetch {
    param([object]$Prefetch)
    if (-not $Prefetch -or -not $Prefetch.Process) { return }
    $proc = $Prefetch.Process
    Write-Info "Waiting for application prefetch to finish before sequential installs..."
    Wait-ProcessWithStatus -Process $proc -Started $Prefetch.Started -StatusFormat {
        param($elapsed) "Application downloads still running... elapsed {0:hh\:mm\:ss}" -f $elapsed
    }
    try { $proc.Refresh() } catch { $null = $_ }
    if ($proc.ExitCode -eq 0) {
        Write-Ok "Application download prefetch completed."
    } else {
        Write-Warn "Application prefetch exited with code $($proc.ExitCode). Sequential install will continue and may download missing installers."
    }
    Write-StructuredLog -Level PREFETCH -Message ("Finished process {0}; exit={1}; log={2}" -f $proc.Id, $proc.ExitCode, $Prefetch.LogPath)
}

# =============================================================================
# DOWNLOAD / INSTALL HELPERS
# =============================================================================
function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [int]$RetryCount = 2,
        [int64]$MinimumBytes = 1024,
        [string]$ExpectedSha256 = "",
        [bool]$RequireValidSignature = $false,
        [string[]]$AllowedHosts = @(),
        [string[]]$AllowedSignerSubjects = @(),
        [int]$TimeoutSeconds = 120
    )
    $initialUri = [uri]$Url
    if (-not (Test-DownloadHostAllowed -Uri $initialUri -AllowedHosts $AllowedHosts)) { throw "Download URL is not an allowed HTTPS host: $($initialUri.Host)" }
    if ($TimeoutSeconds -lt 5 -or $TimeoutSeconds -gt 1800) { throw "Download timeout must be between 5 and 1800 seconds." }
    $dir = Split-Path -Parent $Destination
    Ensure-Directory $dir
    # H-01: the cache directory must not be writable by a non-administrator, or an unprivileged
    # user can plant the artifact this elevated run is about to execute. Fail closed.
    $untrustedWriters = @(Get-UntrustedAclWriter -Path $dir)
    if ($untrustedWriters.Count -gt 0) {
        throw ("Download cache is writable by a non-administrator and cannot be trusted for elevated installs: {0} [{1}]" -f $dir, ($untrustedWriters -join '; '))
    }
    if (Test-PathContainsReparsePoint -Path $Destination) {
        throw "Download destination is reached through a reparse point: $Destination"
    }

    if (Test-Path $Destination) {
        $existing = Get-Item -LiteralPath $Destination -ErrorAction SilentlyContinue
        # H-01: ONE contract for cache hits and fresh downloads. Size alone is never sufficient -
        # an executable needs a pinned hash or an allowlisted valid signature either way.
        if ($existing -and $existing.Length -ge $MinimumBytes -and
            (Assert-TrustedArtifact -Path $Destination -ExpectedSha256 $ExpectedSha256 -AllowedSignerSubjects $AllowedSignerSubjects)) {
            Write-Ok ("Using cached download: {0}" -f (Split-Path -Leaf $Destination))
            Write-StructuredLog -Level DOWNLOAD -Message ("Cache hit: {0}; bytes={1}" -f $Destination, $existing.Length)
            return $true
        }
        Write-Warn ("Cached file is missing, too small or untrusted; evicting and re-downloading: {0}" -f (Split-Path -Leaf $Destination))
        Write-StructuredLog -Level DOWNLOAD -Message ("Cache evicted: {0}" -f $Destination)
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    }

    for ($i = 0; $i -le $RetryCount; $i++) {
        $partial = "$Destination.partial"
        try {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            Write-StructuredLog -Level DOWNLOAD -Message ("URL={0}; Destination={1}" -f $Url, $Destination)
            Write-StatusInPlace ("Downloading: {0}" -f (Split-Path -Leaf $Destination))
            $response = Invoke-WebRequest -Uri $Url -OutFile $partial -PassThru -UseBasicParsing -TimeoutSec $TimeoutSeconds -MaximumRedirection 5 -ErrorAction Stop
            $finalUri = Get-WebResponseFinalUri -Response $response
            if (-not (Test-DownloadHostAllowed -Uri $finalUri -AllowedHosts $AllowedHosts)) {
                throw "Download redirected to a disallowed host: $($finalUri.Host)"
            }
            $downloaded = Get-Item -LiteralPath $partial -ErrorAction Stop
            if ($downloaded.Length -lt $MinimumBytes) {
                throw "Downloaded file is unexpectedly small ($($downloaded.Length) bytes)."
            }
            Move-Item -LiteralPath $partial -Destination $Destination -Force
            Clear-StatusInPlace
            # H-01: same contract as the cache-hit branch above. RequireValidSignature is kept
            # for callers that want to state the intent explicitly, but it can no longer make
            # verification optional: an executable without a pinned hash or an allowlisted valid
            # signature is rejected regardless of how the caller set it.
            if (-not (Assert-TrustedArtifact -Path $Destination -ExpectedSha256 $ExpectedSha256 -AllowedSignerSubjects $AllowedSignerSubjects)) {
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
                throw "Downloaded file failed trust validation (pinned hash or allowlisted Authenticode signature required)."
            }
            if ($RequireValidSignature -and $true -ne (Test-DownloadedFileSignature -Path $Destination -AllowedSignerSubjects $AllowedSignerSubjects)) {
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
                throw "Downloaded file failed required Authenticode signature validation."
            }
            Write-Ok ("Downloaded: {0}" -f (Split-Path -Leaf $Destination))
            return $true
        } catch {
            Clear-StatusInPlace
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            if ($i -ge $RetryCount) {
                Write-Fail ("Download failed: {0}  ({1})" -f $Url, $_.Exception.Message)
                return $false
            }
            Write-Warn ("Download retry {0} for {1}: {2}" -f ($i + 1), $Url, $_.Exception.Message)
            Start-Sleep -Seconds 2
        }
    }
    return $false
}

function Get-InstalledRegistryDisplayName {
    param([Parameter(Mandatory)][string]$NameLike)
    $roots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($r in $roots) {
        try {
            # `return` inside ForEach-Object exits only that iteration, not the function: the
            # matched name leaks into the pipeline, the scan continues across every remaining key,
            # and the trailing `return $null` appends a $null - so callers received an array, not a
            # name. Emit the value instead and take the first match outside the block.
            $match = Get-ChildItem $r -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                    if ($p -and $p.DisplayName -like "*$NameLike*") { $p.DisplayName }
                } catch { $null = $_ }
            } | Select-Object -First 1
            if ($match) { return [string]$match }
        } catch { $null = $_ }
    }
    # Bare `return`, never `return $null`: $null written to the output stream is exactly how a
    # caller invoking this as a bare statement gets its own return value corrupted.
    return
}

function Invoke-SilentExeInstall {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Arguments = @("/S"),
        [int]$TimeoutSeconds = 600,
        [string]$ExpectedSha256 = "",
        [string[]]$AllowedSignerSubjects = @()
    )
    # H-01: revalidate immediately before launching. Validation at download time leaves a window
    # in which the artifact can be swapped; this closes it as far as a user-mode check can, and
    # the identity snapshot below detects a swap that happens between these two lines.
    if (-not (Assert-TrustedArtifact -Path $Path -ExpectedSha256 $ExpectedSha256 -AllowedSignerSubjects $AllowedSignerSubjects)) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        throw "Refusing to execute an installer that failed trust revalidation: $Path"
    }
    $identityBefore = Get-TrustedFileIdentity -Path $Path

    Write-Info ("Running silent installer: {0} {1}" -f (Split-Path -Leaf $Path), ($Arguments -join ' '))
    Write-StructuredLog -Level COMMAND -Message ("Installer path: {0}; sha256={1}" -f $Path, $identityBefore.Sha256)

    $identityNow = Get-TrustedFileIdentity -Path $Path
    if ($identityNow.Sha256 -ne $identityBefore.Sha256 -or $identityNow.Length -ne $identityBefore.Length) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        throw "Installer changed between verification and execution; it was quarantined and not run: $Path"
    }
    $proc = Start-Process -FilePath $Path -ArgumentList $Arguments -PassThru -WindowStyle Hidden
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill() } catch { $null = $_ }
        throw "Installer did not complete within $TimeoutSeconds seconds: $Path"
    }
    Write-StructuredLog -Level COMMAND -Message ("Installer exit code: {0}" -f $proc.ExitCode)
    return $proc.ExitCode
}

function Resolve-InstallerExitCode {
    <#
        Single definition of what a Windows Installer exit code means.
        0    = success
        3010 = success, reboot required
        1641 = success, reboot already initiated by the installer
        Anything else is a failure. Keeping this in one place stops each new installer
        from re-deriving the rule and getting it subtly wrong - the PowerShell 7 MSI path
        accepted only 0 and 3010, so a successful 1641 was reported as a failure.

        Pure by design: callers decide what to do with RebootPending, so the rule itself
        is trivially testable without a registry or a real installer.
    #>
    param([Parameter(Mandatory)][int]$ExitCode)
    return [pscustomobject]@{
        ExitCode      = $ExitCode
        Succeeded     = ($ExitCode -in @(0, 1641, 3010))
        RebootPending = ($ExitCode -in @(1641, 3010))
    }
}

function Invoke-LoggedCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$DisplayName = ""
    )
    $label = if ([string]::IsNullOrWhiteSpace($DisplayName)) { (Split-Path -Leaf $FilePath) } else { $DisplayName }
    $commandLine = "{0} {1}" -f $FilePath, ($Arguments -join ' ')
    Write-StructuredLog -Level COMMAND -Message $commandLine
    $output = @()
    $exitCode = 1
    try {
        $output = @(& $FilePath @Arguments 2>&1)
        $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    } catch {
        $output = @($_.Exception.Message)
        $exitCode = 1
    }
    foreach ($line in $output) {
        $text = [string]$line
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            Write-StructuredLog -Level OUTPUT -Message ("{0}> {1}" -f $label, $text.TrimEnd())
        }
    }
    Write-StructuredLog -Level COMMAND -Message ("{0} exit code: {1}" -f $label, $exitCode)
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Invoke-LoggedProcessWithProgress {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$DisplayName = "",
        [string]$StatusMessage = ""
    )
    $label = if ([string]::IsNullOrWhiteSpace($DisplayName)) { (Split-Path -Leaf $FilePath) } else { $DisplayName }
    $status = if ([string]::IsNullOrWhiteSpace($StatusMessage)) { "Running $label" } else { $StatusMessage }
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        Write-StructuredLog -Level COMMAND -Message ("{0} {1}" -f $FilePath, ($Arguments -join ' '))
        $proc = Start-Process -FilePath $FilePath -ArgumentList $Arguments -RedirectStandardOutput $outFile -RedirectStandardError $errFile -WindowStyle Hidden -PassThru
        $start = Get-Date
        Wait-ProcessWithStatus -Process $proc -Started $start -StatusFormat {
            param($elapsed) "{0} [{1:hh\:mm\:ss}]" -f $status, $elapsed
        }

        $output = @()
        foreach ($path in @($outFile, $errFile)) {
            if (Test-Path $path) {
                $output += Get-Content -LiteralPath $path -ErrorAction SilentlyContinue
            }
        }
        foreach ($line in $output) {
            $text = [string]$line
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                Write-StructuredLog -Level OUTPUT -Message ("{0}> {1}" -f $label, $text.TrimEnd())
            }
        }
        Write-StructuredLog -Level COMMAND -Message ("{0} exit code: {1}" -f $label, $proc.ExitCode)
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; Output = $output }
    } catch {
        Clear-StatusInPlace
        Write-StructuredLog -Level ERROR -Message ("{0} failed to start or run: {1}" -f $label, $_.Exception.Message)
        throw
    } finally {
        Clear-StatusInPlace
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# WINGET ENSURE + MSSTORE FIX (item 9)
# =============================================================================
function Update-ProcessPathFromRegistry {
    # A freshly installed App Execution Alias lands in a directory that the already-running
    # shell's PATH snapshot may predate. Rebuild the process PATH from the machine and user
    # values so the alias becomes reachable without starting a new shell.
    try {
        $machine = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
        $user = [System.Environment]::GetEnvironmentVariable('Path', 'User')
        $combined = @($machine, $user, (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $env:Path = ($combined -join ';')
    } catch { $null = $_ }
}

function Resolve-WingetExecutable {
    <#
        Returns a usable winget path, or $null.

        Test-CommandExists alone is not enough right after an install: Get-Command caches, and
        the App Execution Alias under %LOCALAPPDATA%\Microsoft\WindowsApps may not be on the
        running shell's PATH. Fall back to the alias path and then to the real binary under
        Program Files\WindowsApps, picking the highest version present.
    #>
    $command = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command -and $command.Source) { return $command.Source }

    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $alias) { return $alias }

    $installed = Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps') `
        -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
    foreach ($directory in $installed) {
        $candidate = Join-Path $directory.FullName 'winget.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Get-WingetExecutable {
    # Cached for the run so every call site uses the same resolved binary.
    if (-not [string]::IsNullOrWhiteSpace($Global:WingetExecutable)) { return $Global:WingetExecutable }
    $resolved = Resolve-WingetExecutable
    if ($resolved) { $Global:WingetExecutable = $resolved }
    return $(if ($resolved) { $resolved } else { 'winget' })
}

function Test-IsWindowsServer {
    try { return ((Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).ProductType -ne 1) }
    catch { return $false }
}

function Install-WingetAppInstaller {
    <#
        Installs the App Installer (winget) package.

        Windows Server needs the VCLibs desktop framework package, and a per-user Add-AppxPackage
        is the wrong shape there - the package must be provisioned for the image. Try the
        provisioned route first on Server, then fall back to Add-AppxPackage.
    #>
    $bundle = Get-SafeDownloadCacheFilePath -FileName "Microsoft.DesktopAppInstaller.msixbundle"
    if (-not (Invoke-DownloadFile -Url "https://aka.ms/getwinget" -Destination $bundle `
                -AllowedHosts @('aka.ms', '*.microsoft.com', '*.windows.net', '*.azureedge.net', '*.delivery.mp.microsoft.com'))) {
        Write-Fail "Could not download the App Installer package."
        return $false
    }

    $dependency = Get-SafeDownloadCacheFilePath -FileName "Microsoft.VCLibs.x64.14.00.Desktop.appx"
    $dependencyPaths = @()
    if (Invoke-DownloadFile -Url "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx" -Destination $dependency `
            -AllowedHosts @('aka.ms', '*.microsoft.com', '*.windows.net', '*.azureedge.net', '*.delivery.mp.microsoft.com')) {
        $dependencyPaths += $dependency
    } else {
        Write-Warn "Could not download the VCLibs desktop dependency; the App Installer package may refuse to install."
    }

    if (Test-IsWindowsServer) {
        try {
            $parameters = @{ Online = $true; PackagePath = $bundle; SkipLicense = $true; ErrorAction = 'Stop' }
            if ($dependencyPaths.Count -gt 0) { $parameters.DependencyPackagePath = $dependencyPaths }
            Add-AppxProvisionedPackage @parameters | Out-Null
            Write-Ok "App Installer provisioned for Windows Server."
            return $true
        } catch {
            Write-Warn "Provisioning App Installer failed ($($_.Exception.Message)); trying a per-user install."
        }
    }

    try {
        if ($dependencyPaths.Count -gt 0) {
            Add-AppxPackage -Path $bundle -DependencyPath $dependencyPaths -ErrorAction Stop
        } else {
            Add-AppxPackage -Path $bundle -ErrorAction Stop
        }
        Write-Ok "App Installer package installed."
        return $true
    } catch {
        Write-Fail ("Could not install WinGet automatically: {0}" -f $_.Exception.Message)
        Write-Info "If this reports a missing Microsoft.UI.Xaml dependency, install that framework package and re-run."
        return $false
    }
}

function Ensure-Winget {
    if (Resolve-WingetExecutable) {
        Write-Ok "WinGet is available."
        Repair-WingetSources
        return $true
    }
    if (-not $Global:Config.winget.installIfMissing) {
        Write-Warn "WinGet is missing and installIfMissing is disabled."
        return $false
    }

    Write-Info "WinGet was not found. Downloading Microsoft App Installer package..."
    if (-not (Install-WingetAppInstaller)) { return $false }

    # Refresh discovery instead of failing merely because this shell cannot see the new alias.
    Update-ProcessPathFromRegistry
    $Global:WingetExecutable = $null
    if (-not (Resolve-WingetExecutable)) {
        Write-Warn "WinGet still not detected after installation. Open a new shell and re-run, or install App Installer manually."
        return $false
    }
    Write-Ok ("WinGet resolved at: {0}" -f (Get-WingetExecutable))
    Repair-WingetSources
    return $true
}

function Repair-WingetSources {
    if (-not $Global:Config.winget.removeMsstoreSource) { return }
    $needsReset = $false
    try {
        $sourcesResult = Invoke-LoggedCommand -FilePath (Get-WingetExecutable) -Arguments @("source", "list") -DisplayName "winget source list"
        if ($sourcesResult.ExitCode -ne 0) {
            Write-Warn "winget source listing failed; attempting source reset fallback."
            $needsReset = $true
        } else {
            $sources = ($sourcesResult.Output -join "`n")
            if ($sources -match '(?im)^\s*msstore\b') {
                Write-Info "Removing msstore winget source (avoids 0x8a15005e certificate errors)."
                $removeResult = Invoke-LoggedCommand -FilePath (Get-WingetExecutable) -Arguments @("source", "remove", "msstore") -DisplayName "winget source remove msstore"
                if ($removeResult.ExitCode -eq 0) { Write-Ok "Removed winget source: msstore" }
                else {
                    Write-Warn "winget could not remove msstore source; attempting source reset fallback."
                    $needsReset = $true
                }
            } else {
                Write-Info "winget msstore source is already absent."
            }
        }
    } catch {
        Write-Warn "winget source listing failed: $($_.Exception.Message)"
        $needsReset = $true
    }

    try {
        Write-Info "Refreshing winget sources..."
        $updateResult = Invoke-LoggedCommand -FilePath (Get-WingetExecutable) -Arguments @("source", "update") -DisplayName "winget source update"
        if ($updateResult.ExitCode -eq 0) { Write-Ok "winget sources refreshed." }
        else {
            Write-Warn "winget source update exited with code $($updateResult.ExitCode)."
            if ($needsReset) {
                Write-Info "A winget source listing/removal failure was detected; using source reset fallback."
            } else {
                Write-Info "Skipping winget source reset because source listing/removal already succeeded and only source update failed."
            }
        }
    } catch {
        Write-Warn "winget source update failed: $($_.Exception.Message)"
        if ($needsReset) {
            Write-Info "A winget source listing/removal failure was detected; using source reset fallback."
        } else {
            Write-Info "Skipping winget source reset because source listing/removal already succeeded and only source update failed."
        }
    }

    if ($needsReset) {
        try {
            Write-Info "Resetting winget sources with --force..."
            $resetResult = Invoke-LoggedCommand -FilePath (Get-WingetExecutable) -Arguments @("source", "reset", "--force") -DisplayName "winget source reset"
            if ($resetResult.ExitCode -eq 0) { Write-Ok "winget sources reset." }
            else { Write-Warn "winget source reset exited with code $($resetResult.ExitCode)." }
            $removeAfterReset = Invoke-LoggedCommand -FilePath (Get-WingetExecutable) -Arguments @("source", "remove", "msstore") -DisplayName "winget source remove msstore after reset"
            if ($removeAfterReset.ExitCode -eq 0) { Write-Ok "Removed winget source after reset: msstore" }
            else {
                Write-Info "msstore source was not present after reset or could not be removed; details are in the structured log."
                Write-StructuredLog -Level WINGET -Message ("winget source remove msstore after reset exit code: {0}" -f $removeAfterReset.ExitCode)
            }
            $refreshResult = Invoke-LoggedCommand -FilePath (Get-WingetExecutable) -Arguments @("source", "update") -DisplayName "winget source update after reset"
            if ($refreshResult.ExitCode -eq 0) { Write-Ok "winget sources refreshed after reset." }
            else { Write-Warn "winget source update after reset exited with code $($refreshResult.ExitCode)." }
        } catch {
            Write-Warn "winget source reset fallback failed: $($_.Exception.Message)"
        }
    }
}

function Test-WingetPackageInstalled {
    <#
        Detects an installed package without producing false negatives.

        The previous implementation passed --source winget, which reports "not installed" for a
        package that was installed from msstore, installed out of band, or that simply has no
        current source association - and this project removes the msstore source by default,
        making that failure mode routine. Query without pinning a source first, then fall back
        to the uninstall registry.
    #>
    param([Parameter(Mandatory)][string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }

    $winget = Get-WingetExecutable
    try {
        $listResult = Invoke-LoggedCommand -FilePath $winget `
            -Arguments @("list", "--id", $Id, "--exact", "--accept-source-agreements", "--disable-interactivity") `
            -DisplayName "winget list $Id"
        if ($listResult.ExitCode -eq 0 -and (($listResult.Output -join "`n") -match [regex]::Escape($Id))) { return $true }
    } catch {
        Write-StructuredLog -Level WINGET -Message ("Package detection failed for {0}: {1}" -f $Id, $_.Exception.Message)
    }

    # Fall back to the uninstall registry: a package installed outside winget still lands there.
    try {
        $displayName = ($Id -split '\.') | Select-Object -Last 1
        if (-not [string]::IsNullOrWhiteSpace($displayName) -and (Get-InstalledRegistryDisplayName -NameLike $displayName)) {
            Write-StructuredLog -Level WINGET -Message ("Package {0} detected through the uninstall registry." -f $Id)
            return $true
        }
    } catch { $null = $_ }

    return $false
}

function Test-WingetUpgradeExitCode {
    param([int]$ExitCode)
    # 0x8A15002B APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE - "no applicable upgrade found" is
    # the normal result for an already-current package, not a failure worth warning about.
    return ($ExitCode -eq 0 -or $ExitCode -eq -1978335189)
}

function Test-WindowsTerminalInstalled {
    if (Test-CommandExists "wt") { return $true }
    $stable = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\wt.exe"
    if (Test-Path $stable) { return $true }
    return $false
}
