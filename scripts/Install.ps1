# Install.ps1 - installing applications: the shared check-then-update decision, winget
# packages, direct installers, and v2rayN.
#
# Shell and default-handler integration lives in AppIntegration.ps1, and the .NET / Visual C++
# runtimes in Runtimes.ps1. All three are dot-sourced by WinServerSetup.ps1 and contain function
# definitions only; they read the globals initialized there ($Global:Config, $Global:ProjectRoot,
# $Global:RunStats) at call time, never at load time.

# =============================================================================
# SHARED: CHECK BEFORE INSTALLING, THEN UPDATE WHERE THE APPLICATION ALREADY LIVES
#
# Detecting that an application is already installed is only half the job. Skipping it outright
# leaves it on the version it was first provisioned with, and installing it again without
# aiming at the existing directory produces a second copy rather than an update. Every installer
# below routes that decision through these helpers so the rule is defined once.
# =============================================================================
function Resolve-InstallDirectory {
    <#
        Turns uninstall-key values into the directory an application actually occupies.

        InstallLocation is the direct answer when the installer wrote one. DisplayIcon and
        UninstallString both point at a file inside the install folder, so their parent is the
        next best evidence - DisplayIcon carries a trailing icon index and UninstallString
        carries arguments, both of which have to come off first.

        A candidate that does not resolve to a directory that exists is rejected rather than
        guessed at: an "update in place" aimed at the wrong tree is worse than not updating.
    #>
    param([string[]]$Candidates = @())
    foreach ($candidate in $Candidates) {
        $value = ([string]$candidate).Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if ($value.StartsWith('"')) {
            $closing = $value.IndexOf('"', 1)
            if ($closing -gt 0) { $value = $value.Substring(1, $closing - 1) } else { $value = $value.Trim('"') }
        } else {
            $comma = $value.LastIndexOf(',')
            if ($comma -gt 0 -and $value.Substring($comma + 1) -match '^\s*-?\d+\s*$') { $value = $value.Substring(0, $comma) }
            $switchStart = $value.IndexOf(' /')
            if ($switchStart -gt 0) { $value = $value.Substring(0, $switchStart) }
        }
        $value = $value.Trim().TrimEnd('\')
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        # A RELATIVE candidate must be rejected before GetFullPath sees it. An MSI package records
        # UninstallString as "MsiExec.exe /X{GUID}", which reduces to a bare file name once the
        # arguments come off - GetFullPath then resolves it against the CURRENT directory and
        # hands back a directory that genuinely exists and has nothing to do with the
        # application. Measured on this machine: PowerShell 7-x64 resolved to the project folder.
        # Only a drive-qualified or UNC path is evidence of where something is installed, so a
        # root of "\" alone (current drive) is rejected too.
        $root = ""
        try { $root = [string][System.IO.Path]::GetPathRoot($value) } catch { $null = $_ }
        if ($root.Length -le 1) { continue }
        # GetFullPath on every path this project compares: it needs no existing path and maps an
        # 8.3 short name and its long spelling to one form, which Resolve-Path does not.
        $full = $null
        try { $full = [System.IO.Path]::GetFullPath($value) } catch { $null = $_ }
        if ([string]::IsNullOrWhiteSpace($full)) { continue }
        if ([System.IO.Directory]::Exists($full)) { return $full.TrimEnd('\') }
        $parent = [System.IO.Path]::GetDirectoryName($full)
        if (-not [string]::IsNullOrWhiteSpace($parent) -and [System.IO.Directory]::Exists($parent)) { return $parent.TrimEnd('\') }
    }
    return ""
}

function Get-InstalledAppRecord {
    <#
        Detection WITH a location. Get-InstalledRegistryDisplayName answers only "is it
        installed?", so an application it found could never be updated - there was nothing to
        aim an update at. This reads the same three uninstall roots and returns the first match
        as a record whose InstallLocation is empty when no evidence resolves to a real directory.
    #>
    param([Parameter(Mandatory)][string]$NameLike)
    if ([string]::IsNullOrWhiteSpace($NameLike)) { return }
    $roots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($root in $roots) {
        # `return` inside ForEach-Object exits one iteration, not the function. Emit the match
        # and take the first outside the block, exactly as Get-InstalledRegistryDisplayName does.
        $match = Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $properties = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                if ($properties -and $properties.DisplayName -like "*$NameLike*") { $properties }
            } catch { $null = $_ }
        } | Select-Object -First 1
        if ($match) {
            return [pscustomobject]@{
                DisplayName     = [string]$match.DisplayName
                DisplayVersion  = [string]$match.DisplayVersion
                InstallLocation = (Resolve-InstallDirectory -Candidates @([string]$match.InstallLocation, [string]$match.DisplayIcon, [string]$match.UninstallString))
            }
        }
    }
    # Bare `return`, never `return $null`: a $null on the output stream corrupts a caller that
    # invokes this as a bare statement.
    return
}

function Register-AppOutcome {
    <#
        The single place an application's outcome becomes both a console line and a RunStats
        entry, so every installer answers "was it already there, and did we update it where it
        lives?" the same way.

        Installed, Updated, AlreadyCurrent and Skipped all mean the application is present on
        the machine, so all four keep it in InstalledApps - the existing counters and the M-08
        contract that a requested component missing from the machine fails the run are unchanged.
        Only Failed reaches FailedApps.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Installed', 'Updated', 'AlreadyCurrent', 'Skipped', 'Failed')][string]$Outcome,
        [string]$Detail = ""
    )
    $suffix = ""
    if (-not [string]::IsNullOrWhiteSpace($Detail)) { $suffix = " - {0}" -f $Detail }
    switch ($Outcome) {
        'Installed'      { Write-Ok   ("{0}: installed and verified{1}" -f $Name, $suffix) }
        'Updated'        { Write-Ok   ("{0}: updated in place{1}" -f $Name, $suffix) }
        'AlreadyCurrent' { Write-Ok   ("{0}: already current{1}" -f $Name, $suffix) }
        'Skipped'        { Write-Warn ("{0}: left unchanged{1}" -f $Name, $suffix) }
        'Failed'         { Write-Warn ("{0}: install failed{1}" -f $Name, $suffix) }
    }
    if ($Outcome -eq 'Failed') { $null = $Global:RunStats.FailedApps.Add($Name) }
    else { $null = $Global:RunStats.InstalledApps.Add($Name) }
}

function Update-WingetPackageInPlace {
    <#
        Check-then-update for a package winget already reports installed. winget upgrades a
        package in the location it already occupies, so "in place" here means calling upgrade
        instead of install - a second install is what produces a parallel copy.

        Returns the outcome rather than recording it, because Windows Terminal owns its own
        verification contract (wt.exe on disk) and must record the application exactly once,
        after that check rather than before it.
    #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Id)
    $wingetConfig = $Global:Config.winget
    $upgradeEnabled = $false
    if ($wingetConfig -and ($wingetConfig.PSObject.Properties.Name -contains 'upgradeExistingPackages')) {
        $upgradeEnabled = [bool]$wingetConfig.upgradeExistingPackages
    }
    if (-not $upgradeEnabled) {
        return [pscustomobject]@{ Outcome = 'Skipped'; Detail = 'already installed, and winget.upgradeExistingPackages is off' }
    }
    try {
        $result = Invoke-LoggedCommand -FilePath (Get-WingetExecutable) `
            -Arguments @("upgrade", "--id", $Id, "--exact", "--accept-package-agreements", "--accept-source-agreements", "--source", "winget", "--silent") `
            -DisplayName "winget upgrade $Name"
        if ($result.ExitCode -eq 0) {
            return [pscustomobject]@{ Outcome = 'Updated'; Detail = 'upgraded by winget where it was already installed' }
        }
        # Not a bare -ne 0: "no applicable upgrade found" is the normal answer for an
        # already-current package and is a different outcome, not a failure.
        if (Test-WingetUpgradeExitCode -ExitCode $result.ExitCode) {
            return [pscustomobject]@{ Outcome = 'AlreadyCurrent'; Detail = 'winget reports no applicable upgrade' }
        }
        return [pscustomobject]@{ Outcome = 'Skipped'; Detail = ("upgrade check exited with code {0}" -f $result.ExitCode) }
    } catch {
        return [pscustomobject]@{ Outcome = 'Skipped'; Detail = ("upgrade check failed: {0}" -f $_.Exception.Message) }
    }
}

# =============================================================================
# SECTION 5: WINGET INSTALL (items 9 indirect)
# =============================================================================
function Install-WingetPackages {
    # M-08: every package the config enables must end up in InstalledApps or FailedApps. WinGet
    # being unavailable used to return silently, so a run that installed no application at all
    # still reported success and exited 0.
    $requested = @($Global:Config.winget.packages | Where-Object { $_.enabled })
    if (-not (Ensure-Winget)) {
        foreach ($pkg in $requested) {
            Write-Warn ("{0} was not installed: WinGet is unavailable." -f [string]$pkg.name)
            $null = $Global:RunStats.FailedApps.Add([string]$pkg.name)
        }
        return
    }
    $interactive = [bool]$Global:Config.winget.interactiveInstallers
    foreach ($pkg in $requested) {
        $name = [string]$pkg.name
        $id   = [string]$pkg.id
        if ([string]::IsNullOrWhiteSpace($id)) {
            Write-Warn "$name cannot be installed: its configured package id is empty."
            $null = $Global:RunStats.FailedApps.Add($name)
            continue
        }

        Write-Info "Checking package: $name ($id)"
        if (Test-WingetPackageInstalled -Id $id) {
            $update = Update-WingetPackageInPlace -Name $name -Id $id
            Register-AppOutcome -Name $name -Outcome $update.Outcome -Detail $update.Detail
            continue
        }

        $wingetArgs = @("install", "--id", $id, "--exact", "--accept-package-agreements", "--accept-source-agreements", "--source", "winget")
        if ($interactive) { $wingetArgs += "--interactive" } else { $wingetArgs += "--silent" }
        Write-Info "Installing $name ..."
        try {
            $installResult = Invoke-LoggedCommand -FilePath (Get-WingetExecutable) -Arguments $wingetArgs -DisplayName "winget install $name"
            if ($installResult.ExitCode -ne 0) {
                Write-Warn "$name install exited with code $($installResult.ExitCode). See structured log for winget output."
                $null = $Global:RunStats.FailedApps.Add($name)
            } elseif (Test-WingetPackageInstalled -Id $id) {
                # M-08: exit code 0 is the installer's own claim. The package has to be detectable
                # afterwards before the run may call it installed.
                Register-AppOutcome -Name $name -Outcome Installed
            } else {
                Write-Warn "$name reported a successful install but is not detectable afterwards."
                $null = $Global:RunStats.FailedApps.Add($name)
            }
        } catch {
            Write-Warn "winget install failed for $name : $($_.Exception.Message)"
            $null = $Global:RunStats.FailedApps.Add($name)
        }
    }
}

# =============================================================================
# SECTION 6: DIRECT INSTALLERS (items 10, 16, 25)
# =============================================================================
function Complete-DirectInstall {
    <#
        The single verdict for a direct installer that has just run, shared by the silent path
        and both interactive fallbacks so the rule cannot drift between them.

        When this was an update of an existing installation, the registry has to still place the
        application in the directory it occupied before. An installer that ignored the existing
        install and put a fresh copy somewhere else has produced a second copy, not an update,
        and reporting that as a successful install would hide it.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$RegistryName = "",
        [string]$UpdateTarget = "",
        [switch]$Interactive
    )
    $recorded = $Name
    if ($Interactive) { $recorded = "$Name (interactive)" }
    if (-not (Test-DirectInstallerInstalled -Name $Name -RegistryName $RegistryName)) {
        Register-AppOutcome -Name $Name -Outcome Failed -Detail "the installer reported success but independent registry verification failed"
        return
    }
    if ([string]::IsNullOrWhiteSpace($UpdateTarget)) {
        Register-AppOutcome -Name $recorded -Outcome Installed
        return
    }
    $after = Get-InstalledAppRecord -NameLike $RegistryName
    $location = ""
    if ($after) { $location = [string]$after.InstallLocation }
    # An installer that stopped publishing a location tells us nothing either way; only a
    # location that resolved and MOVED is evidence of a relocation.
    if ([string]::IsNullOrWhiteSpace($location) -or $location -ieq $UpdateTarget) {
        Register-AppOutcome -Name $recorded -Outcome Updated -Detail $UpdateTarget
        return
    }
    Register-AppOutcome -Name $Name -Outcome Failed `
        -Detail ("the update did not stay in place: it moved from {0} to {1}, so the machine now carries two copies" -f $UpdateTarget, $location)
}

function Install-DirectInstaller {
    param([Parameter(Mandatory)][object]$Spec)
    if (-not $Spec.enabled) { return }
    $name        = [string]$Spec.name
    $url         = [string]$Spec.url
    $fileName    = [string]$Spec.fileName
    $silentArgs  = if ($Spec.silentArgs) { [string]$Spec.silentArgs } else { "/S" }
    $verifyName  = [string]$Spec.verifyRegistryName
    $expectedSha256 = if ($Spec.PSObject.Properties.Name -contains "expectedSha256") { [string]$Spec.expectedSha256 } else { "" }
    $requireValidSignature = if ($Spec.PSObject.Properties.Name -contains "requireValidSignature") { [bool]$Spec.requireValidSignature } else { $false }
    # An absent JSON property is $null, and @($null) is a ONE-element array, not an empty one.
    # Unfiltered it defeats every "no restriction configured" shortcut downstream.
    $allowedDownloadHosts = @($Spec.allowedDownloadHosts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $allowedSignerSubjects = @($Spec.allowedSignerSubjects | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    # Check before installing. An application that is already here is updated in the directory it
    # already occupies; the installer is re-run only once that directory is known, because
    # running it blind would put a second copy at whatever default path the installer prefers.
    $updateTarget = ""
    if (-not [string]::IsNullOrWhiteSpace($verifyName)) {
        $existing = Get-InstalledAppRecord -NameLike $verifyName
        if ($existing) {
            if ([string]::IsNullOrWhiteSpace($existing.InstallLocation)) {
                Register-AppOutcome -Name $name -Outcome Skipped `
                    -Detail ("already installed (registry: {0}), but its install location could not be resolved, so an update cannot be verified to stay in place" -f $existing.DisplayName)
                return
            }
            $updateTarget = [string]$existing.InstallLocation
            Write-Info ("{0} is already installed at {1}; updating it there." -f $name, $updateTarget)
        }
    }
    # An update that cannot be carried out leaves the existing installation exactly as it was, so
    # it is a warning rather than a failed run: the application is still on the machine. M-08 is
    # about a requested component that is genuinely ABSENT, and that case still fails the run.
    $attemptFailureOutcome = 'Failed'
    if (-not [string]::IsNullOrWhiteSpace($updateTarget)) { $attemptFailureOutcome = 'Skipped' }

    if ([string]::IsNullOrWhiteSpace($fileName)) { $fileName = "${name}-installer.exe" -replace '\s','' }

    if ($name -ieq "Everything" -and $url -match 'voidtools\.com/.*/?downloads/?$|voidtools\.com/downloads/?$') {
        $resolvedEverything = $false
        try {
            Write-Info "Resolving latest Everything x64 installer from Voidtools downloads page..."
            $page = Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop
            $regexMatches = [regex]::Matches([string]$page.Content, 'Everything-(\d+\.\d+\.\d+\.\d+)\.x64-Setup\.exe')
            $latest = $regexMatches | ForEach-Object {
                [pscustomobject]@{ Version = [version]$_.Groups[1].Value; File = $_.Value }
            } | Sort-Object Version -Descending | Select-Object -First 1
            if ($latest) {
                $url = "https://www.voidtools.com/{0}" -f $latest.File
                $fileName = $latest.File
                $resolvedEverything = $true
                Write-Ok "Latest Everything installer resolved: $($latest.File)"
            } else {
                Write-Warn "Could not parse the Voidtools downloads page; using configured URL as-is."
            }
        } catch {
            Write-Warn "Could not resolve latest Everything installer: $($_.Exception.Message)"
        }
        if (-not $resolvedEverything) {
            $fileName = "Everything-1.4.1.1032.x64-Setup.exe"
            $url = "https://www.voidtools.com/$fileName"
            Write-Warn "Falling back to known Everything x64 installer: $fileName"
        }
    }

    $exePath  = Get-SafeDownloadCacheFilePath -FileName $fileName

    if (-not (Invoke-DownloadFile -Url $url -Destination $exePath -ExpectedSha256 $expectedSha256 -RequireValidSignature $requireValidSignature -AllowedHosts $allowedDownloadHosts -AllowedSignerSubjects $allowedSignerSubjects)) {
        Register-AppOutcome -Name $name -Outcome $attemptFailureOutcome -Detail "the installer download failed"
        return
    }

    Write-Info "Installing $name silently with args: $silentArgs"
    try {
        # H-01: hand the same trust anchor to the launcher so it revalidates the exact artifact
        # immediately before executing it, rather than trusting the download-time result.
        $code = Invoke-SilentExeInstall -Path $exePath -Arguments @($silentArgs) -ExpectedSha256 $expectedSha256 -AllowedSignerSubjects $allowedSignerSubjects
        $silentResult = Resolve-InstallerExitCode -ExitCode $code
        if ($silentResult.Succeeded) {
            if ($silentResult.RebootPending) { Set-PendingReboot "$name installer returned $code" }
            Complete-DirectInstall -Name $name -RegistryName $verifyName -UpdateTarget $updateTarget
        } else {
            Write-Warn "$name installer exited with code $code."
            if ($Spec.fallbackInteractive) {
                Write-Warn "Silent install may not be supported. Launching the installer interactively..."
                $interactive = Start-Process -FilePath $exePath -Wait -PassThru -ErrorAction Stop
                $interactiveResult = Resolve-InstallerExitCode -ExitCode $interactive.ExitCode
                if ($interactiveResult.Succeeded) {
                    if ($interactiveResult.RebootPending) { Set-PendingReboot "$name interactive installer returned $($interactive.ExitCode)" }
                    Complete-DirectInstall -Name $name -RegistryName $verifyName -UpdateTarget $updateTarget -Interactive
                } else {
                    Register-AppOutcome -Name $name -Outcome $attemptFailureOutcome -Detail ("the interactive installer exited with code {0}" -f $interactive.ExitCode)
                }
            } else {
                Register-AppOutcome -Name $name -Outcome $attemptFailureOutcome -Detail ("the installer exited with code {0}" -f $code)
            }
        }
    } catch {
        Write-Warn "$name silent install failed: $($_.Exception.Message)"
        if ($Spec.fallbackInteractive) {
            $interactive = $null
            try {
                $interactive = Start-Process -FilePath $exePath -Wait -PassThru -ErrorAction Stop
            } catch {
                Write-Warn "$name interactive fallback could not be started: $($_.Exception.Message)"
            }
            # -and short-circuits, so the helper is never handed a null exit code.
            $fallbackSucceeded = ($null -ne $interactive) -and (Resolve-InstallerExitCode -ExitCode $interactive.ExitCode).Succeeded
            if ($fallbackSucceeded) {
                Complete-DirectInstall -Name $name -RegistryName $verifyName -UpdateTarget $updateTarget -Interactive
            } else {
                Register-AppOutcome -Name $name -Outcome $attemptFailureOutcome -Detail "the interactive fallback did not complete successfully"
            }
        } else {
            Register-AppOutcome -Name $name -Outcome $attemptFailureOutcome -Detail "the silent install threw"
        }
    }

    if ($Spec.enableService -and $name -ieq 'Everything') {
        try {
            $svc = Get-Service -Name "Everything" -ErrorAction SilentlyContinue
            if ($svc) {
                Set-Service -Name "Everything" -StartupType Automatic -ErrorAction SilentlyContinue
                Start-Service -Name "Everything" -ErrorAction SilentlyContinue
                # Both calls above are silenced, so re-read the service and report what actually
                # happened instead of claiming success unconditionally.
                $after = Get-Service -Name "Everything" -ErrorAction SilentlyContinue
                if ($after -and $after.Status -eq 'Running') {
                    Write-Ok "Everything service set to Automatic and running."
                } else {
                    Write-Warn ("Everything service did not reach Running (current: {0})." -f $(if ($after) { $after.Status } else { 'not found' }))
                }
            }
        } catch { Write-Warn "Could not configure Everything service: $($_.Exception.Message)" }
    }
    # No trailing registry re-check: Complete-DirectInstall already made the verified/failed call
    # on every path above, and a second pass only reported the same fact a second time.
}

function Install-DirectInstallers {
    if (-not $Global:Config.directInstallers) { return }
    foreach ($spec in $Global:Config.directInstallers) {
        Install-DirectInstaller -Spec $spec
    }
}

# =============================================================================
# SECTION 7: v2rayN INSTALL + RENAME (item 14)
# =============================================================================
function New-Shortcut {
    param([Parameter(Mandatory)][string]$TargetPath,[Parameter(Mandatory)][string]$ShortcutPath,[string]$WorkingDirectory = "",[string]$Description = "")
    $shell = $null
    $s = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $s = $shell.CreateShortcut($ShortcutPath)
        $s.TargetPath = $TargetPath
        if ($WorkingDirectory) { $s.WorkingDirectory = $WorkingDirectory }
        if ($Description)      { $s.Description      = $Description }
        $s.Save()
    } finally {
        if ($s) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($s) } catch { $null = $_ } }
        if ($shell) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { $null = $_ } }
    }
}

function Test-UnsafeReplaceTarget {
    # Refuses a drive root, a Windows/Program Files directory, or anything too shallow to be an
    # application folder, before any recursive delete runs against it.
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($full)) { return $true }
    if ($full -eq [System.IO.Path]::GetPathRoot($full).TrimEnd('\')) { return $true }
    foreach ($protected in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:SystemDrive)) {
        if ([string]::IsNullOrWhiteSpace($protected)) { continue }
        if ($full -eq ([System.IO.Path]::GetFullPath($protected).TrimEnd('\'))) { return $true }
    }
    return $false
}

function Install-V2RayN {
    $settings = $Global:Config.v2rayN
    if (-not $settings.enabled) { Set-StepSkipped "disabled in config"; return }

    $installRoot   = [string]$settings.installDir
    $finalFolder   = [string]$settings.finalFolderName
    if ([string]::IsNullOrWhiteSpace($finalFolder)) { $finalFolder = "V2rayN" }
    $finalDir      = Join-Path $installRoot $finalFolder
    $exeName       = [string]$settings.exeName

    # Only these paths survive an upgrade. Everything else in the install folder is application
    # payload and is replaced wholesale, so binaries from an older release cannot linger.
    $preserve = @($settings.preserveUserDataPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($preserve.Count -eq 0) { $preserve = @('guiNDB.db', 'guiConfigs', 'config.json') }

    Ensure-Directory $installRoot
    $download = Get-DownloadCachePath
    $stage = $null
    $preserveDir = $null
    $exeRelative = $null
    # Recorded before the payload is touched: once the folder has been emptied and refilled there
    # is no way to tell an update of an existing install from a first install.
    $updatingExisting = Test-Path -LiteralPath $finalDir

    $repo   = [string]$settings.githubRepo
    $apiUrl = "https://api.github.com/repos/$repo/releases/latest"
    Write-Info "Querying latest v2rayN release ($repo)..."
    try {
        $release = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = 'WinServerSetup' }
        $regex   = [string]$settings.assetNameRegex
        $asset   = $release.assets | Where-Object { $_.name -match $regex } | Select-Object -First 1
        if (-not $asset) { throw "No asset matched regex: $regex" }

        # GitHub publishes a 'digest' (sha256:...) for newer release assets. Use it when present
        # so the archive is integrity-checked; a zip cannot carry an Authenticode signature.
        $expectedSha = ""
        if ($asset.PSObject.Properties.Name -contains 'digest' -and $asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
            $expectedSha = $matches[1]
            Write-Info "Release asset publishes a SHA256 digest; it will be verified."
        }

        $zipPath = Get-SafeDownloadCacheFilePath -FileName ([string]$asset.name)
        Write-Info "Downloading $($asset.name) ..."
        if (-not (Invoke-DownloadFile -Url $asset.browser_download_url -Destination $zipPath `
                    -ExpectedSha256 $expectedSha `
                    -AllowedHosts @('github.com', '*.github.com', 'objects.githubusercontent.com', '*.githubusercontent.com'))) {
            throw "v2rayN download failed."
        }

        $stage = Join-Path $download ("v2rayN-stage-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        Ensure-Directory $stage
        Expand-Archive -Path $zipPath -DestinationPath $stage -Force

        # Locate the payload by finding the expected executable INSIDE the freshly extracted
        # staging tree. Taking "the first top-level directory" picked an arbitrary folder, and
        # searching the merged install folder afterwards could select a stale exe from an
        # earlier release.
        $stagedExe = Get-ChildItem -LiteralPath $stage -Filter $exeName -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } | Select-Object -First 1
        if (-not $stagedExe) { throw "The downloaded archive does not contain $exeName." }
        $payloadRoot = Split-Path -Parent $stagedExe.FullName
        $exeRelative = $stagedExe.FullName.Substring($payloadRoot.Length).TrimStart('\')

        if ($updatingExisting) {
            if (Test-UnsafeReplaceTarget -Path $finalDir) { throw "Refusing to replace an unsafe install path: $finalDir" }
            Write-Info "Existing $finalFolder folder found; replacing the application payload and keeping user data."

            $preserveDir = Join-Path $download ("v2rayN-keep-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
            Ensure-Directory $preserveDir
            foreach ($relative in $preserve) {
                $source = Join-Path $finalDir $relative
                if (-not (Test-Path -LiteralPath $source)) { continue }
                $destination = Join-Path $preserveDir $relative
                Ensure-Directory (Split-Path -Parent $destination)
                Move-Item -LiteralPath $source -Destination $destination -Force
                Write-Info "Preserved user data: $relative"
            }

            Get-ChildItem -LiteralPath $finalDir -Force -ErrorAction Stop |
                Remove-Item -Recurse -Force -ErrorAction Stop
        } else {
            Ensure-Directory $finalDir
        }

        Get-ChildItem -LiteralPath $payloadRoot -Force -ErrorAction Stop |
            Move-Item -Destination $finalDir -Force -ErrorAction Stop

        if ($preserveDir -and (Test-Path -LiteralPath $preserveDir)) {
            foreach ($item in Get-ChildItem -LiteralPath $preserveDir -Force -ErrorAction SilentlyContinue) {
                Move-Item -LiteralPath $item.FullName -Destination (Join-Path $finalDir $item.Name) -Force
            }
            Write-Ok "Restored preserved v2rayN user data."
        }
        Write-Ok "v2rayN payload installed to $finalDir"
    } catch {
        Write-Warn "v2rayN install/update failed: $($_.Exception.Message)"
        if ($preserveDir -and (Test-Path -LiteralPath $preserveDir)) {
            Write-Warn "Preserved v2rayN user data was left for manual recovery at: $preserveDir"
        }
        # M-08: v2rayN is enabled in the shipped config, so a failed update is a failed run.
        $null = $Global:RunStats.FailedApps.Add("v2rayN")
        return
    } finally {
        # Staging always goes away, on success and on every failure path.
        if ($stage -and (Test-Path -LiteralPath $stage)) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($preserveDir -and (Test-Path -LiteralPath $preserveDir) -and
            -not (Get-ChildItem -LiteralPath $preserveDir -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $preserveDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # M-08: the installed executable is v2rayN's independent verification contract - the archive
    # extracting without error is not evidence that anything runnable landed on disk.
    $exeFull = Join-Path $finalDir $exeRelative
    if (-not (Test-Path -LiteralPath $exeFull)) {
        Write-Warn "v2rayN executable not found after extraction."
        $null = $Global:RunStats.FailedApps.Add("v2rayN")
        return
    }
    # v2rayN is a portable payload, so its install folder IS its location of record: an update
    # replaces the binaries in the folder that was already there and keeps the user data.
    if ($updatingExisting) { Register-AppOutcome -Name "v2rayN" -Outcome Updated -Detail $finalDir }
    else { Register-AppOutcome -Name "v2rayN" -Outcome Installed -Detail $finalDir }
    $workDir = Split-Path -Parent $exeFull

    if ($settings.createDesktopShortcut) {
        $desk = [Environment]::GetFolderPath("Desktop")
        New-Shortcut -TargetPath $exeFull -ShortcutPath (Join-Path $desk "V2rayN.lnk") -WorkingDirectory $workDir -Description "V2rayN"
        Write-Ok "Desktop shortcut created/updated -> $exeFull"
    }
    if ($settings.createStartMenuShortcut) {
        $sm = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\WinServerSetup"
        Ensure-Directory $sm
        New-Shortcut -TargetPath $exeFull -ShortcutPath (Join-Path $sm "V2rayN.lnk") -WorkingDirectory $workDir -Description "V2rayN"
        Write-Ok "Start Menu shortcut created/updated -> $exeFull"
    }
}


# Relocated from Rdp.ps1, where it had always sat by accident: it verifies a DIRECT INSTALLER,
# not anything about RDP.
function Test-DirectInstallerInstalled {
    param([string]$Name, [string]$RegistryName)
    if ([string]::IsNullOrWhiteSpace($RegistryName)) {
        Write-Warn "$Name has no independent verification contract."
        return $false
    }
    return -not [string]::IsNullOrWhiteSpace([string](Get-InstalledRegistryDisplayName -NameLike $RegistryName))
}

