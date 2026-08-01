# Install.ps1 - application installation: winget packages, direct installers, v2rayN,
# PowerShell 7, Windows Terminal, Brave and its extensions, 7-Zip file associations,
# default apps, and the .NET / Visual C++ runtimes.
#
# Dot-sourced by WinServerSetup.ps1. Contains function definitions only; it reads the
# globals initialized there ($Global:Config, $Global:ProjectRoot, $Global:RunStats) at
# call time, never at load time.

# =============================================================================
# SECTION 5: WINGET INSTALL (items 9 indirect)
# =============================================================================
function Install-WingetPackages {
    if (-not (Ensure-Winget)) { return }
    $interactive = [bool]$Global:Config.winget.interactiveInstallers
    foreach ($pkg in $Global:Config.winget.packages) {
        if (-not $pkg.enabled) { continue }
        $name = [string]$pkg.name
        $id   = [string]$pkg.id
        if ([string]::IsNullOrWhiteSpace($id)) { Write-Warn "Skipping $name (empty id)."; continue }

        Write-Info "Checking package: $name ($id)"
        if (Test-WingetPackageInstalled -Id $id) {
            Write-Ok "$name is already installed."
            if ($Global:Config.winget.upgradeExistingPackages) {
                try {
                    $upgradeResult = Invoke-LoggedCommand -FilePath (Get-WingetExecutable) -Arguments @("upgrade", "--id", $id, "--exact", "--accept-package-agreements", "--accept-source-agreements", "--source", "winget", "--silent") -DisplayName "winget upgrade $name"
                    if ($upgradeResult.ExitCode -ne 0) { Write-Warn "Upgrade check for $name exited with code $($upgradeResult.ExitCode)." }
                } catch { Write-Warn "Upgrade failed for $name : $($_.Exception.Message)" }
            }
            $null = $Global:RunStats.InstalledApps.Add($name)
            continue
        }

        $wingetArgs = @("install", "--id", $id, "--exact", "--accept-package-agreements", "--accept-source-agreements", "--source", "winget")
        if ($interactive) { $wingetArgs += "--interactive" } else { $wingetArgs += "--silent" }
        Write-Info "Installing $name ..."
        try {
            $installResult = Invoke-LoggedCommand -FilePath (Get-WingetExecutable) -Arguments $wingetArgs -DisplayName "winget install $name"
            if ($installResult.ExitCode -eq 0) {
                Write-Ok "$name installed."
                $null = $Global:RunStats.InstalledApps.Add($name)
            } else {
                Write-Warn "$name install exited with code $($installResult.ExitCode). See structured log for winget output."
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

    if (-not [string]::IsNullOrWhiteSpace($verifyName)) {
        $existing = Get-InstalledRegistryDisplayName -NameLike $verifyName
        if ($existing) {
            Write-Ok "$name already installed (registry: $existing)."
            $null = $Global:RunStats.InstalledApps.Add($name)
            return
        }
    }

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
        Write-Warn "$name download failed; skipping install."
        $null = $Global:RunStats.FailedApps.Add($name)
        return
    }

    Write-Info "Installing $name silently with args: $silentArgs"
    try {
        $code = Invoke-SilentExeInstall -Path $exePath -Arguments @($silentArgs)
        $silentResult = Resolve-InstallerExitCode -ExitCode $code
        if ($silentResult.Succeeded) {
            if ($silentResult.RebootPending) { Set-PendingReboot "$name installer returned $code" }
            if (Test-DirectInstallerInstalled -Name $name -RegistryName $verifyName) {
                Write-Ok "$name silent install succeeded and was verified."
                $null = $Global:RunStats.InstalledApps.Add($name)
            } else {
                Write-Warn "$name installer returned success code $code, but independent registry verification failed."
                $null = $Global:RunStats.FailedApps.Add($name)
            }
        } else {
            Write-Warn "$name installer exited with code $code."
            if ($Spec.fallbackInteractive) {
                Write-Warn "Silent install may not be supported. Launching the installer interactively..."
                $interactive = Start-Process -FilePath $exePath -Wait -PassThru -ErrorAction Stop
                $interactiveResult = Resolve-InstallerExitCode -ExitCode $interactive.ExitCode
                if ($interactiveResult.Succeeded -and (Test-DirectInstallerInstalled -Name $name -RegistryName $verifyName)) {
                    if ($interactiveResult.RebootPending) { Set-PendingReboot "$name interactive installer returned $($interactive.ExitCode)" }
                    $null = $Global:RunStats.InstalledApps.Add("$name (interactive)")
                } else {
                    Write-Warn "$name interactive install was not independently verified."
                    $null = $Global:RunStats.FailedApps.Add($name)
                }
            } else {
                $null = $Global:RunStats.FailedApps.Add($name)
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
            if ($fallbackSucceeded -and (Test-DirectInstallerInstalled -Name $name -RegistryName $verifyName)) {
                $null = $Global:RunStats.InstalledApps.Add("$name (interactive)")
            } else {
                Write-Warn "$name interactive fallback was not independently verified."
                $null = $Global:RunStats.FailedApps.Add($name)
            }
        } else {
            $null = $Global:RunStats.FailedApps.Add($name)
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

    if (-not [string]::IsNullOrWhiteSpace($verifyName)) {
        $verified = Get-InstalledRegistryDisplayName -NameLike $verifyName
        if ($verified) { Write-Ok "$name verified after install (registry: $verified)." }
        else { Write-Warn "$name was not found in uninstall registry after install; verify manually if the installer used a per-user or portable layout." }
    }
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

        if (Test-Path -LiteralPath $finalDir) {
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

    $exeFull = Join-Path $finalDir $exeRelative
    if (-not (Test-Path -LiteralPath $exeFull)) {
        Write-Warn "v2rayN executable not found after extraction."
        return
    }
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

# =============================================================================
# SECTION 8: POWERSHELL 7 FROM GITHUB (carry-over, cleaner output)
# =============================================================================
function Get-PowerShellCoreVersion {
    if (-not (Test-CommandExists "pwsh")) { return $null }
    try {
        $v = & pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
        if ([string]::IsNullOrWhiteSpace($v)) { return $null }
        return [version]([string]$v).Trim()
    } catch { return $null }
}

function Install-LatestPowerShellFromGitHub {
    $s = $Global:Config.powershell
    if (-not $s -or -not $s.enabled) { return }
    if ($s.PSObject.Properties.Name -contains "installLatestFromGitHub" -and -not $s.installLatestFromGitHub) {
        Write-Info "PowerShell GitHub install disabled via installLatestFromGitHub."
        return
    }
    $repo = [string]$s.githubRepo; if ([string]::IsNullOrWhiteSpace($repo)) { $repo = "PowerShell/PowerShell" }
    Write-Info "Querying latest PowerShell release ($repo)..."
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -UseBasicParsing -Headers @{ 'User-Agent' = 'WinServerSetup' }
    } catch { Write-Warn "GitHub query failed: $($_.Exception.Message)"; return }

    $latestVer = $null
    try { $latestVer = [version](([string]$release.tag_name).TrimStart("v")) } catch { Write-StructuredLog -Level WARN -Message ("Could not parse PowerShell release tag '{0}': {1}" -f $release.tag_name, $_.Exception.Message) }
    $currentVer = Get-PowerShellCoreVersion
    if ($currentVer -and $latestVer -and -not $s.forceInstall -and $currentVer -ge $latestVer) {
        Write-Ok "PowerShell $currentVer already current vs GitHub latest $latestVer."
        return
    }

    $regex = [string]$s.assetNameRegex; if ([string]::IsNullOrWhiteSpace($regex)) { $regex = "^PowerShell-.*-win-x64\.msi$" }
    $asset = $release.assets | Where-Object { $_.name -match $regex } | Select-Object -First 1
    if (-not $asset) { Write-Warn "No PowerShell asset matched regex $regex"; return }

    $msi = Get-SafeDownloadCacheFilePath -FileName ([string]$asset.name)
    # An empty hash means "not pinned", not "refuse": this URL resolves to whatever the latest
    # GitHub release is, so blocking on an unset hash would break a default run. When the config
    # sets one, Invoke-DownloadFile enforces it.
    $expectedSha256 = if ($s.PSObject.Properties.Name -contains "expectedSha256") { [string]$s.expectedSha256 } else { "" }
    if (-not (Invoke-DownloadFile -Url $asset.browser_download_url -Destination $msi -ExpectedSha256 $expectedSha256 `
                -AllowedHosts @('github.com', '*.github.com', 'objects.githubusercontent.com', '*.githubusercontent.com'))) { return }

    $msiArgs = @("/i", "`"$msi`"")
    if ($s.interactiveInstaller) {
        if (-not [string]::IsNullOrWhiteSpace([string]$s.msiArguments)) { $msiArgs += ([string]$s.msiArguments) }
    } else {
        $msiArgs += @("/qn","/norestart")
        if (-not [string]::IsNullOrWhiteSpace([string]$s.silentMsiArguments)) { $msiArgs += ([string]$s.silentMsiArguments) }
    }
    Write-Info "Installing PowerShell silently ..."
    try {
        $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList ($msiArgs -join ' ') -Wait -PassThru -WindowStyle Hidden
        Write-StructuredLog -Level COMMAND -Message ("PowerShell MSI exit code: {0}" -f $proc.ExitCode)
        # This path used to accept only 0 and 3010, so an MSI that returned 1641 (success,
        # reboot already initiated) was reported as a failed install. The shared helper is
        # the single definition of installer success.
        $msiResult = Resolve-InstallerExitCode -ExitCode $proc.ExitCode
        if ($msiResult.Succeeded) {
            Write-Ok "PowerShell installer completed."
            if ($msiResult.RebootPending) { Set-PendingReboot "PowerShell 7 installer requested reboot" }
            $null = $Global:RunStats.InstalledApps.Add("PowerShell 7")
        } else {
            Write-Warn "PowerShell installer exited with code $($proc.ExitCode)."
            $null = $Global:RunStats.FailedApps.Add("PowerShell 7")
        }
    } catch {
        Write-Fail "PowerShell installer failed: $($_.Exception.Message)"
        $null = $Global:RunStats.FailedApps.Add("PowerShell 7")
    }
}

# =============================================================================
# SECTION 9: WINDOWS TERMINAL + PS7 DEFAULT PROFILE (items 4)
# =============================================================================
function Install-WindowsTerminal {
    $s = $Global:Config.windowsTerminal
    if (-not $s -or -not $s.enabled) { return }
    if (-not (Ensure-Winget)) { return }

    $pkg = [string]$s.packageId; if ([string]::IsNullOrWhiteSpace($pkg)) { $pkg = "Microsoft.WindowsTerminal" }
    if (Test-WingetPackageInstalled -Id $pkg) {
        Write-Ok "Windows Terminal already installed."
        try { [void](Invoke-LoggedCommand -FilePath (Get-WingetExecutable) -Arguments @("upgrade", "--id", $pkg, "--exact", "--accept-package-agreements", "--accept-source-agreements", "--silent", "--source", "winget") -DisplayName "winget upgrade Windows Terminal") } catch { Write-Warn "Windows Terminal upgrade check failed: $($_.Exception.Message)" }
    } else {
        $wingetInstallArgs = @("install", "--id", $pkg, "--exact", "--accept-package-agreements", "--accept-source-agreements", "--source", "winget")
        if ($s.interactiveInstaller) { $wingetInstallArgs += "--interactive" } else { $wingetInstallArgs += "--silent" }
        try {
            $terminalResult = Invoke-LoggedCommand -FilePath (Get-WingetExecutable) -Arguments $wingetInstallArgs -DisplayName "winget install Windows Terminal"
            if ($terminalResult.ExitCode -eq 0) { Write-Ok "Windows Terminal install completed." }
            else { Write-Warn "Windows Terminal install exited with code $($terminalResult.ExitCode)." }
        }
        catch { Write-Fail "Windows Terminal install failed: $($_.Exception.Message)"; return }
    }

    if (-not (Test-WindowsTerminalInstalled)) {
        Write-Warn "Windows Terminal executable was not found; default terminal/profile settings were skipped."
        return
    }
    if ($s.setAsDefaultTerminal)              { Set-WindowsTerminalAsDefault }
    if ($s.setPowerShell7AsDefaultProfile)    { Set-WindowsTerminalPowerShell7Default }
}

function Set-WindowsTerminalAsDefault {
    Write-Info "Setting Windows Terminal as default terminal (current user)."
    $sk = "HKCU:\Console\%%Startup"
    Set-RegistryValue -Path $sk -Name "DelegationConsole"  -Type String -Value "{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}"
    Set-RegistryValue -Path $sk -Name "DelegationTerminal" -Type String -Value "{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}"
    Write-Ok "Windows Terminal set as default terminal application."
}

function Get-WindowsTerminalSettingsPath {
    $stable = Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
    if (Test-Path $stable) { return $stable }
    $root = Join-Path $env:LOCALAPPDATA "Packages"
    if (Test-Path $root) {
        $c = Get-ChildItem -Path $root -Directory -Filter "Microsoft.WindowsTerminal_*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { return (Join-Path $c.FullName "LocalState\settings.json") }
    }
    return $stable
}

function Set-WindowsTerminalPowerShell7Default {
    $pwshPath = Get-PowerShell7ExePath
    if ([string]::IsNullOrWhiteSpace($pwshPath) -or -not (Test-Path $pwshPath)) { Write-Warn "PowerShell 7 not found; default profile not changed."; return }

    $settingsPath = Get-WindowsTerminalSettingsPath
    $settingsDir  = Split-Path -Parent $settingsPath
    Ensure-Directory $settingsDir

    # Deterministic GUID matched by Windows Terminal for stock PowerShell-Core fragment.
    $profileGuid = "{574e775e-4f2a-5b96-ac1e-a2962a402336}"

    if (-not (Test-Path $settingsPath)) {
        $escaped = $pwshPath -replace '\\','\\'
        $json = @"
{
  "`$schema": "https://aka.ms/terminal-profiles-schema",
  "defaultProfile": "$profileGuid",
  "profiles": {
    "defaults": {},
    "list": [
      { "guid": "$profileGuid", "name": "PowerShell 7", "commandline": "$escaped", "hidden": false }
    ]
  }
}
"@
        Set-Content -LiteralPath $settingsPath -Value $json -Encoding utf8
        Write-Ok "Created Windows Terminal settings.json with PowerShell 7 default."
        return
    }

    try {
        $raw = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
        $sj  = $raw | ConvertFrom-Json
    } catch {
        Write-Warn "Could not parse Windows Terminal settings.json. Leaving it untouched."
        return
    }
    try {
        if (-not $sj.profiles) {
            $sj | Add-Member -NotePropertyName profiles -NotePropertyValue ([pscustomobject]@{ defaults=([pscustomobject]@{}); list=@() }) -Force
        } elseif ($sj.profiles -is [array]) {
            $legacyProfiles = @($sj.profiles)
            $sj.profiles = [pscustomobject]@{
                defaults = [pscustomobject]@{}
                list     = $legacyProfiles
            }
            Write-Info "Normalized legacy Windows Terminal profiles array into the current profiles.list format."
        } elseif (-not ($sj.profiles.PSObject.Properties.Name -contains 'list')) {
            $sj.profiles | Add-Member -NotePropertyName list -NotePropertyValue @() -Force
        }
        if ($null -eq $sj.profiles.list) { $sj.profiles.list = @() }

        $existing = $sj.profiles.list | Where-Object {
            ($_.guid -eq $profileGuid) -or
            ($_.name -match 'PowerShell' -and $_.commandline -match 'pwsh') -or
            ($_.source -match 'Windows.Terminal.PowershellCore')
        } | Select-Object -First 1
        if ($existing) {
            $profileGuid = [string]$existing.guid
            if ([string]::IsNullOrWhiteSpace($profileGuid)) {
                $profileGuid = "{574e775e-4f2a-5b96-ac1e-a2962a402336}"
                $existing | Add-Member -NotePropertyName guid -NotePropertyValue $profileGuid -Force
            }
        } else {
            $sj.profiles.list = @($sj.profiles.list) + ([pscustomobject]@{
                guid = $profileGuid; name = "PowerShell 7"; commandline = $pwshPath; hidden = $false
            })
        }
        $sj | Add-Member -NotePropertyName defaultProfile -NotePropertyValue $profileGuid -Force
        $sj | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $settingsPath -Encoding utf8
        Write-Ok "Windows Terminal default profile is now PowerShell 7."
    } catch {
        Write-Warn "Could not update Windows Terminal settings safely: $($_.Exception.Message)"
    }
}

function Get-PowerShell7ExePath {
    $pwshPath = Join-Path $env:ProgramFiles "PowerShell\7\pwsh.exe"
    if (Test-Path $pwshPath) { return $pwshPath }
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Set-PowerShell7AsPs1Default {
    $s = $Global:Config.powershell
    if ($s -and ($s.PSObject.Properties.Name -contains "setPs1DefaultApp") -and -not $s.setPs1DefaultApp) {
        Write-Info "PowerShell 7 .ps1 default app step disabled in config."
        return
    }

    $pwshPath = Get-PowerShell7ExePath
    if (-not $pwshPath -or -not (Test-Path $pwshPath)) {
        Write-Warn "PowerShell 7 executable not found; .ps1 default handler was not changed."
        return
    }

    $progId = "WinServerSetup.PowerShell7Script"
    $progPath = "HKCU:\Software\Classes\$progId"
    $cmdPath = Join-Path $progPath "shell\open\command"
    $iconPath = Join-Path $progPath "DefaultIcon"
    Set-RegistryDefaultValue -Path $progPath -Value "PowerShell 7 Script"
    Set-ItemProperty -Path $progPath -Name "FriendlyTypeName" -Type String -Value "PowerShell 7 Script"
    Set-ItemProperty -Path $progPath -Name "EditFlags" -Type DWord -Value 0
    Set-RegistryDefaultValue -Path $iconPath -Value ("`"{0}`",0" -f $pwshPath)
    Set-RegistryDefaultValue -Path $cmdPath -Value ("`"{0}`" -NoLogo -File `"%1`" %*" -f $pwshPath)

    $extPath = "HKCU:\Software\Classes\.ps1"
    Set-RegistryDefaultValue -Path $extPath -Value $progId
    $openWithPath = Join-Path $extPath "OpenWithProgids"
    Set-RegistryValue -Path $openWithPath -Name $progId -Type String -Value ""

    $userChoice = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.ps1\UserChoice"
    if (Test-Path $userChoice) {
        try {
            Remove-Item -Path $userChoice -Recurse -Force -ErrorAction Stop
            Write-Info "Removed protected .ps1 UserChoice key so HKCU class default can apply."
        } catch {
            Write-Warn "Windows blocked .ps1 UserChoice removal; choose PowerShell 7 once from Open with if the old handler remains."
        }
    }

    Write-Ok ".ps1 default open command is configured for PowerShell 7."
}

# =============================================================================
# SECTION 10: BRAVE EXTENSIONS (item 13)
# =============================================================================
function Open-BraveBrowser {
    param([string]$Url)
    $candidates = @(
        (Join-Path $env:ProgramFiles "BraveSoftware\Brave-Browser\Application\brave.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "BraveSoftware\Brave-Browser\Application\brave.exe")
    )
    $exe = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $exe) { return $false }
    try {
        if ([string]::IsNullOrWhiteSpace($Url)) { Start-Process $exe } else { Start-Process $exe -ArgumentList $Url }
        return $true
    } catch { return $false }
}

function Test-ChromeExtensionId {
    param([AllowEmptyString()][string]$Id)
    # Chrome/Brave extension IDs are exactly 32 characters drawn from 'a'-'p'.
    return $Id -cmatch '^[a-p]{32}$'
}

function Sync-BraveForceListPolicy {
    <#
        Reconciles the Brave ExtensionInstallForcelist policy with the configured extensions.

        Ownership is tracked explicitly under HKLM:\SOFTWARE\WinServerSetup so values written by
        this project can be removed once an extension is dropped from config, while values placed
        there by any other administrator are never touched. Without an ownership record, stale
        numbered values simply accumulated: removing an extension from config left Brave
        force-installing it forever, and an admin-forced extension cannot be removed from the UI.
    #>
    param([Parameter(Mandatory)]$Items)

    $policyPath = "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave\ExtensionInstallForcelist"
    $ownershipPath = "HKLM:\SOFTWARE\WinServerSetup"
    $ownershipName = "BraveManagedExtensionIds"
    $updateUrl = "https://clients2.google.com/service/update2/crx"

    $desiredIds = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Items)) {
        $id = [string]$item.id
        if (-not (Test-ChromeExtensionId $id)) {
            Write-Warn "Skipping Brave extension '$($item.name)': '$id' is not a valid 32-character extension ID."
            continue
        }
        if (-not $desiredIds.Contains($id)) { $desiredIds.Add($id) }
    }

    if (-not (Test-Path $policyPath)) { New-Item -Path $policyPath -Force | Out-Null }
    if (-not (Test-Path $ownershipPath)) { New-Item -Path $ownershipPath -Force | Out-Null }

    $previouslyManaged = @()
    $ownership = Get-ItemProperty -Path $ownershipPath -Name $ownershipName -ErrorAction SilentlyContinue
    if ($ownership) { $previouslyManaged = @($ownership.$ownershipName | Where-Object { $_ }) }

    # Map every existing numbered value to the extension ID it carries.
    $existing = @{}
    foreach ($name in (Get-Item -Path $policyPath).GetValueNames()) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $data = [string](Get-ItemProperty -Path $policyPath -Name $name -ErrorAction SilentlyContinue).$name
        $existing[$name] = ($data -split ';')[0]
    }

    # Remove only values this project previously wrote whose extension is no longer configured.
    $removed = 0
    foreach ($entry in @($existing.GetEnumerator())) {
        $id = [string]$entry.Value
        if ($previouslyManaged -contains $id -and -not $desiredIds.Contains($id)) {
            Remove-ItemProperty -Path $policyPath -Name $entry.Key -ErrorAction Stop
            $existing.Remove($entry.Key)
            $removed++
            Write-Ok "Removed stale managed Brave policy for $id."
        }
    }

    foreach ($id in $desiredIds) {
        $value = "{0};{1}" -f $id, $updateUrl
        # Reuse the slot this extension already occupies so unrelated values keep their numbering.
        $slot = ($existing.GetEnumerator() | Where-Object { $_.Value -eq $id } | Select-Object -First 1).Key
        if (-not $slot) {
            $candidate = 1
            while ($existing.ContainsKey([string]$candidate)) { $candidate++ }
            $slot = [string]$candidate
        }
        Set-ItemProperty -Path $policyPath -Name $slot -Type String -Value $value -ErrorAction Stop
        $existing[$slot] = $id
        Write-Ok "Policy applied for $id (slot $slot)."
    }

    Set-ItemProperty -Path $ownershipPath -Name $ownershipName -Type MultiString -Value ([string[]]$desiredIds) -ErrorAction Stop

    return [pscustomobject]@{
        Applied   = $desiredIds.Count
        Removed   = $removed
        Unmanaged = (@($existing.Keys).Count - $desiredIds.Count)
    }
}

function Install-BraveExtensions {
    $cfg = $Global:Config.braveExtensions
    if (-not $cfg -or -not $cfg.enabled) { Set-StepSkipped "disabled in config"; return }

    if ($cfg.useForceListPolicy) {
        try {
            $result = Sync-BraveForceListPolicy -Items $cfg.items
            Write-Info ("Brave force-list reconciled: {0} applied, {1} stale removed, {2} left to other administrators." -f `
                    $result.Applied, $result.Removed, $result.Unmanaged)
            Write-Info "Brave will install force-listed extensions on next start (Chrome policy honored)."
        } catch {
            Write-Warn "Could not set Brave ExtensionInstallForcelist policy: $($_.Exception.Message)"
        }
    }

    if ($cfg.openInBrave) {
        $opened = $false
        foreach ($ext in $cfg.items) {
            if (Open-BraveBrowser -Url $ext.url) {
                Write-Ok "Opened Brave to $($ext.name): $($ext.url)"
                $opened = $true
            } else {
                Write-Warn "Brave not installed yet; could not open $($ext.name) install page."
            }
        }
        if (-not $opened) { Write-Warn "Install Brave first, then re-run option 'Install Brave extensions'." }
    }
}

# =============================================================================
# SECTION 10b: 7-ZIP AS DEFAULT FOR COMPRESSED FILE EXTENSIONS
# =============================================================================
# Registers 7-Zip ProgIds (7-Zip.zip, 7-Zip.rar, ...) as the per-user default
# handler for the configured extensions, under HKCU:\Software\Classes. This is
# the only programmatic association that Windows 10/11 honors reliably without
# the protected UserChoice hash. The DefaultAppAssociations.xml file already
# contains the equivalent entries for new user profiles (applied via DISM).

function Test-SevenZipInstalled {
    param([string]$InstallPath = "C:\Program Files\7-Zip")
    $exe = Join-Path $InstallPath "7zFM.exe"
    if (Test-Path $exe) { return $exe }
    $alt = Join-Path ${env:ProgramFiles(x86)} "7-Zip\7zFM.exe"
    if (Test-Path $alt) { return $alt }
    if (Test-CommandExists "7z") { return (Get-Command 7z -ErrorAction SilentlyContinue).Source }
    return $null
}

function Test-SevenZipProgIdRegistered {
    param([Parameter(Mandatory)][string]$ProgId)
    # 7-Zip writes its ProgIds into HKLM\Software\Classes during install (HKCR).
    return (Test-Path "Registry::HKEY_CLASSES_ROOT\$ProgId") -or (Test-Path "HKLM:\SOFTWARE\Classes\$ProgId")
}

function Set-FileExtensionDefaultHandler {
    param(
        [Parameter(Mandatory)][string]$Extension,
        [Parameter(Mandatory)][string]$ProgId,
        [switch]$RemoveUserChoice
    )
    if (-not $Extension.StartsWith('.')) { $Extension = ".$Extension" }

    # HKCU\Software\Classes\<.ext> -> (Default) = ProgId
    $classPath = "HKCU:\Software\Classes\$Extension"
    Set-RegistryDefaultValue -Path $classPath -Value $ProgId

    # HKCU\Software\Classes\<.ext>\OpenWithProgids\<ProgId> = ""
    $owpPath = Join-Path $classPath "OpenWithProgids"
    Set-RegistryValue -Path $owpPath -Name $ProgId -Type String -Value ""

    if ($RemoveUserChoice) {
        # If a previous UserChoice exists, Windows enforces it (with a hash) and
        # ignores our Classes default. Try to remove it. Some Windows builds
        # protect this key against deletion; we log and continue.
        $ucPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$Extension\UserChoice"
        if (Test-Path $ucPath) {
            try {
                Remove-Item -Path $ucPath -Force -Recurse -ErrorAction Stop
            } catch {
                Write-Warn ("UserChoice key locked for {0} ({1}). Default may not switch until you 'Open with' once manually." -f $Extension, $_.Exception.Message)
            }
        }
    }
}

function Set-SevenZipAsDefault {
    $s = $Global:Config.sevenZipDefaults
    if (-not $s -or -not $s.enabled) {
        Write-Info "7-Zip default-handler step disabled in config."
        return
    }

    $installPath = if ([string]::IsNullOrWhiteSpace([string]$s.installPath)) { "C:\Program Files\7-Zip" } else { [string]$s.installPath }
    $exe = Test-SevenZipInstalled -InstallPath $installPath
    if (-not $exe) {
        Write-Warn "7-Zip not installed yet; install it first (Install applications) and re-run this step."
        return
    }
    Write-Info ("7-Zip detected at: {0}" -f $exe)

    $exts        = @($s.extensions)
    $removeUC    = [bool]$s.removeUserChoice
    $applied     = 0
    $skipped     = 0
    $missingPid  = New-Object System.Collections.Generic.List[string]

    foreach ($ext in $exts) {
        if ([string]::IsNullOrWhiteSpace($ext)) { continue }
        if (-not $ext.StartsWith('.')) { $ext = ".$ext" }
        $progId = "7-Zip" + $ext   # 7-Zip ProgIds look like "7-Zip.zip", "7-Zip.rar", ...

        if (-not (Test-SevenZipProgIdRegistered -ProgId $progId)) {
            $missingPid.Add($ext) | Out-Null
            $skipped++
            continue
        }
        try {
            Set-FileExtensionDefaultHandler -Extension $ext -ProgId $progId -RemoveUserChoice:$removeUC
            Write-Ok ("Default handler set: {0,-8} -> {1}" -f $ext, $progId)
            $applied++
        } catch {
            Write-Warn ("Could not set default for {0}: {1}" -f $ext, $_.Exception.Message)
        }
    }

    if ($missingPid.Count -gt 0) {
        Write-Warn ("7-Zip has no ProgId registered for these extensions; skipped: {0}" -f ($missingPid -join ', '))
        Write-Warn "Open 7-Zip File Manager -> Tools -> Options -> 7-Zip tab and pick the missing types manually if needed."
    }

    # Refresh Explorer so the new icons/associations are visible without re-login.
    try {
        $sig = '[DllImport("shell32.dll")] public static extern int SHChangeNotify(int eventId, int flags, IntPtr item1, IntPtr item2);'
        $shell = Add-Type -MemberDefinition $sig -Namespace WinShell -Name Notify -PassThru -ErrorAction SilentlyContinue
        if ($shell) { [void]$shell::SHChangeNotify(0x8000000, 0x1000, [IntPtr]::Zero, [IntPtr]::Zero) }
    } catch {
        Write-StructuredLog -Level WARN -Message ("7-Zip association shell refresh failed: {0}" -f $_.Exception.Message)
    }

    Write-Ok ("7-Zip default handler step done. Applied: {0}, Skipped: {1}." -f $applied, $skipped)
}

# =============================================================================
# SECTION 11: DEFAULT APPS (carry over)
# =============================================================================
function Configure-DefaultApps {
    $s = $Global:Config.defaultApps
    if (-not $s -or -not $s.enabled) { Set-StepSkipped "disabled in config"; return }
    if ($s.importXmlIfExists) {
        $xml = Resolve-RelativePath ([string]$s.xmlPath)
        if (Test-Path $xml) {
            Write-Info "Importing default app associations: $xml"
            Write-Info "DISM default app import applies to new user profiles; current-user protected defaults may still require Settings."
            try {
                $dismResult = Invoke-LoggedCommand -FilePath "dism.exe" -Arguments @("/Online", "/Import-DefaultAppAssociations:$xml") -DisplayName "DISM default app import"
                if ($dismResult.ExitCode -eq 0) {
                    Write-Ok "Default associations import completed."
                } else {
                    Write-Warn "Default associations import exited with code $($dismResult.ExitCode). Windows may require manual default-app selection for the current user."
                }
            } catch { Write-Warn "DISM import failed: $($_.Exception.Message)" }
        } else { Write-Warn "Default app associations XML not found: $xml" }
    }
    if ($s.openSettingsAfterInstall) { try { Start-Process "ms-settings:defaultapps" -ErrorAction SilentlyContinue } catch { Write-Warn "Could not open Default Apps settings: $($_.Exception.Message)" } }
}

# =============================================================================
# SECTION 14: .NET + VC++ RUNTIMES (items 23, 31)
# =============================================================================
function Test-DotNetFramework35Enabled {
    # Reads the resulting feature state rather than trusting the install command's silence.
    try {
        if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
            $feature = Get-WindowsFeature -Name NET-Framework-Core -ErrorAction Stop
            if ($feature) { return [bool]$feature.Installed }
        }
    } catch { $null = $_ }
    try {
        if (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
            $optional = Get-WindowsOptionalFeature -Online -FeatureName NetFx3 -ErrorAction Stop
            if ($optional) { return ([string]$optional.State -eq 'Enabled') }
        }
    } catch { $null = $_ }
    return $null
}

function Install-DotNetFramework35 {
    if (-not $Global:Config.runtimes.installDotNetFramework35) { Set-StepSkipped "disabled in config"; return }
    Write-Info "Installing .NET Framework 3.5 feature."

    if ($true -eq (Test-DotNetFramework35Enabled)) {
        Write-Ok ".NET Framework 3.5 is already enabled."
        return
    }

    $restartNeeded = $false
    try {
        if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
            $result = Install-WindowsFeature NET-Framework-Core -ErrorAction Stop
            if ($result -and $result.RestartNeeded -and [string]$result.RestartNeeded -ne 'No') { $restartNeeded = $true }
        } else {
            $result = Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart -ErrorAction Stop
            if ($result -and $result.RestartNeeded) { $restartNeeded = $true }
        }
    } catch {
        Write-Fail ".NET Framework 3.5 install failed: $($_.Exception.Message)"
        $null = $Global:RunStats.FailedApps.Add(".NET Framework 3.5")
        return
    }

    if ($restartNeeded) { Set-PendingReboot ".NET Framework 3.5 feature" }

    # Verify the resulting state; a suppressed failure previously printed unconditional success.
    $state = Test-DotNetFramework35Enabled
    if ($true -eq $state) {
        Write-Ok ".NET Framework 3.5 feature is enabled."
    } elseif ($null -eq $state) {
        Write-Warn ".NET Framework 3.5 install completed but its state could not be verified on this system."
    } elseif ($restartNeeded) {
        Write-Warn ".NET Framework 3.5 requires a restart before it reports as enabled."
    } else {
        Write-Fail ".NET Framework 3.5 did not report as enabled after installation."
        $null = $Global:RunStats.FailedApps.Add(".NET Framework 3.5")
    }
}

function Get-DotNetFrameworkReleaseValue {
    try {
        $k = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -Name Release -ErrorAction Stop
        return [int]$k.Release
    } catch { return 0 }
}

function Install-DotNetFramework4Plus {
    if (-not $Global:Config.runtimes.installDotNetFramework4Plus) { return }
    $rv = Get-DotNetFrameworkReleaseValue
    if ($rv -ge 533320) { Write-Ok ".NET Framework 4.8.1+ already installed (release $rv)."; return }
    $url = [string]$Global:Config.runtimes.dotNetFramework481OfflineUrl
    if ([string]::IsNullOrWhiteSpace($url)) { $url = "https://go.microsoft.com/fwlink/?linkid=2203305" }
    $msi = Get-SafeDownloadCacheFilePath -FileName "NDP481-x86-x64-AllOS-ENU.exe"
    # An empty hash means "not pinned", not "refuse": this fwlink resolves to the current 4.8.1
    # package, so blocking on an unset hash would break a default run. When the config sets one,
    # Invoke-DownloadFile enforces it.
    $rt = $Global:Config.runtimes
    $expectedSha256 = if ($rt.PSObject.Properties.Name -contains "dotNetFramework481ExpectedSha256") { [string]$rt.dotNetFramework481ExpectedSha256 } else { "" }
    if (-not (Invoke-DownloadFile -Url $url -Destination $msi -ExpectedSha256 $expectedSha256 `
                -AllowedHosts @('go.microsoft.com', '*.microsoft.com', 'download.visualstudio.microsoft.com', '*.download.visualstudio.microsoft.com'))) { return }
    Write-Info "Installing .NET Framework 4.8.1 (passive, no restart)..."
    try {
        $proc = Start-Process -FilePath $msi -ArgumentList "/passive /norestart" -Wait -PassThru -WindowStyle Hidden
        Write-StructuredLog -Level COMMAND -Message (".NET Framework 4.8.1 installer exit code: {0}" -f $proc.ExitCode)
        # Deliberately NOT routed through Resolve-InstallerExitCode: this installer reports
        # several distinct outcomes (1638 already-installed, 1602 cancelled, 1603 fatal) and
        # each success code gets its own message. Collapsing them into Succeeded/RebootPending
        # would lose that detail for no gain.
        switch ([int]$proc.ExitCode) {
            0 {
                Write-Ok ".NET Framework 4.8.1 install command finished."
            }
            3010 {
                Write-Ok ".NET Framework 4.8.1 install command finished; reboot required."
                Set-PendingReboot ".NET Framework 4.8.1 installer requested reboot"
            }
            1641 {
                Write-Ok ".NET Framework 4.8.1 installer reported success with reboot required."
                Set-PendingReboot ".NET Framework 4.8.1 installer requested reboot"
            }
            1638 {
                Write-Ok ".NET Framework 4.8.1 or a newer equivalent is already installed."
            }
            1602 {
                Write-Warn ".NET Framework 4.8.1 install was cancelled by the user or installer UI."
                $null = $Global:RunStats.FailedApps.Add(".NET Framework 4.8.1")
            }
            1603 {
                Write-Warn ".NET Framework 4.8.1 install failed with fatal MSI error 1603."
                $null = $Global:RunStats.FailedApps.Add(".NET Framework 4.8.1")
            }
            default {
                Write-Warn ".NET Framework 4.8.1 installer exited with code $($proc.ExitCode)."
                $null = $Global:RunStats.FailedApps.Add(".NET Framework 4.8.1")
            }
        }
    } catch { Write-Warn ".NET 4.8.1 install failed: $($_.Exception.Message)" }
}

function Install-WingetRuntimePackage {
    param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$Id)
    try {
        if (Test-WingetPackageInstalled -Id $Id) {
            Write-Ok "$Name already installed."
            return
        }
        $runtimeResult = Invoke-LoggedCommand -FilePath (Get-WingetExecutable) -Arguments @("install", "--id", $Id, "--exact", "--accept-package-agreements", "--accept-source-agreements", "--source", "winget", "--silent") -DisplayName "winget runtime $Name"
        if ($runtimeResult.ExitCode -eq 0) { Write-Ok "$Name installed." } else { Write-Warn "$Name install exit code $($runtimeResult.ExitCode)." }
    } catch { Write-Warn "${Name}: $($_.Exception.Message)" }
}

function Install-DotNetDesktopRuntimes {
    if (-not $Global:Config.runtimes.installDotNetDesktopRuntimes) { return }
    if (-not (Ensure-Winget)) { return }
    $packages = @()
    if ($Global:Config.runtimes.includeUnsupportedDotNetVersions) {
        $packages += @(
            @{ Name = ".NET Desktop Runtime 5 x64 (unsupported)"; Id = "Microsoft.DotNet.DesktopRuntime.5" },
            @{ Name = ".NET Desktop Runtime 6 x64 (unsupported)"; Id = "Microsoft.DotNet.DesktopRuntime.6" },
            @{ Name = ".NET Desktop Runtime 7 x64 (unsupported)"; Id = "Microsoft.DotNet.DesktopRuntime.7" }
        )
    }
    $packages += @(
        @{ Name = ".NET Desktop Runtime 8 x64"; Id = "Microsoft.DotNet.DesktopRuntime.8" },
        @{ Name = ".NET Desktop Runtime 9 x64"; Id = "Microsoft.DotNet.DesktopRuntime.9" },
        @{ Name = ".NET Desktop Runtime 10 x64"; Id = "Microsoft.DotNet.DesktopRuntime.10" }
    )
    foreach ($p in $packages) { Install-WingetRuntimePackage -Name $p.Name -Id $p.Id }
}

function Install-DotNetCoreRuntimes {
    if (-not $Global:Config.runtimes.installDotNetCoreRuntimes) { return }
    if (-not (Ensure-Winget)) { return }
    $packages = @()
    if ($Global:Config.runtimes.includeUnsupportedDotNetVersions) {
        $packages += @(
            @{ Name = ".NET Runtime 5 x64 (unsupported)"; Id = "Microsoft.DotNet.Runtime.5" },
            @{ Name = ".NET Runtime 6 x64 (unsupported)"; Id = "Microsoft.DotNet.Runtime.6" },
            @{ Name = ".NET Runtime 7 x64 (unsupported)"; Id = "Microsoft.DotNet.Runtime.7" }
        )
    }
    $packages += @(
        @{ Name = ".NET Runtime 8 x64"; Id = "Microsoft.DotNet.Runtime.8" },
        @{ Name = ".NET Runtime 9 x64"; Id = "Microsoft.DotNet.Runtime.9" },
        @{ Name = ".NET Runtime 10 x64"; Id = "Microsoft.DotNet.Runtime.10" }
    )
    foreach ($p in $packages) { Install-WingetRuntimePackage -Name $p.Name -Id $p.Id }
}

# NOTE: ASP.NET Core Runtimes are intentionally NOT installed (item 31).
# The installAspNetCoreRuntimes flag in config is forced to false and this
# function is left here as a no-op for backwards compatibility.
function Install-DotNetAspNetCoreRuntimes {
    if ($Global:Config.runtimes.installDotNetAspNetCoreRuntimes) {
        Write-Warn "ASP.NET Core Runtime install requested in config but explicitly disabled per project policy."
    } else {
        Write-Info "ASP.NET Core Runtime install is disabled by project policy (item 31)."
    }
}

function Install-VisualCppRuntimes {
    if (-not $Global:Config.runtimes.installVisualCppRuntimes) { return }
    if (-not (Ensure-Winget)) { return }
    $packages = @(
        @{ Name = "VC++ 2015-2022 x64"; Id = "Microsoft.VCRedist.2015+.x64" },
        @{ Name = "VC++ 2015-2022 x86"; Id = "Microsoft.VCRedist.2015+.x86" }
    )
    if ($Global:Config.runtimes.installLegacyVisualCppRuntimes) {
        $packages += @(
            @{ Name = "VC++ 2013 x64"; Id = "Microsoft.VCRedist.2013.x64" },
            @{ Name = "VC++ 2013 x86"; Id = "Microsoft.VCRedist.2013.x86" },
            @{ Name = "VC++ 2012 x64"; Id = "Microsoft.VCRedist.2012.x64" },
            @{ Name = "VC++ 2012 x86"; Id = "Microsoft.VCRedist.2012.x86" },
            @{ Name = "VC++ 2010 x64"; Id = "Microsoft.VCRedist.2010.x64" },
            @{ Name = "VC++ 2010 x86"; Id = "Microsoft.VCRedist.2010.x86" },
            @{ Name = "VC++ 2008 x64"; Id = "Microsoft.VCRedist.2008.x64" },
            @{ Name = "VC++ 2008 x86"; Id = "Microsoft.VCRedist.2008.x86" },
            @{ Name = "VC++ 2005 x86"; Id = "Microsoft.VCRedist.2005.x86" }
        )
    }
    foreach ($p in $packages) { Install-WingetRuntimePackage -Name $p.Name -Id $p.Id }
}

function Install-Runtimes {
    Install-DotNetFramework35
    Install-DotNetFramework4Plus
    Install-DotNetDesktopRuntimes
    Install-DotNetCoreRuntimes
    Install-DotNetAspNetCoreRuntimes   # no-op (policy)
    Install-VisualCppRuntimes
}
