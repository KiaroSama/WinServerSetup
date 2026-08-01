# SystemSettings.ps1 - Windows appearance and shell settings: file extensions, long
# paths, dark mode, keyboard layout, custom folders and Defender exclusions, search
# indexing, the empty-standby-list task, update bandwidth policy, startup/appx/capability
# removal, Quick Access pins and taskbar pinning.
#
# Dot-sourced by WinServerSetup.ps1. Contains function definitions only; it reads the
# globals initialized there ($Global:Config, $Global:ProjectRoot, $Global:RunStats) at
# call time, never at load time.

# =============================================================================
# SECTION 1: SHOW FILE EXTENSIONS (item 1)
# =============================================================================
function Enable-FileExtensions {
    if ($Global:Config.appearance -and -not $Global:Config.appearance.showFileExtensions) {
        Write-Info "File-extension toggle disabled in config."
        return
    }
    $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    $cur = (Get-ItemProperty -Path $path -Name "HideFileExt" -ErrorAction SilentlyContinue).HideFileExt
    if ($cur -eq 0) {
        Write-Ok "File extensions are already shown in Explorer."
    } else {
        Set-RegistryValue -Path $path -Name "HideFileExt" -Value 0
        Write-Ok "Enabled 'Show file extensions' in Explorer for current user."
        try {
            $sig = '[DllImport("shell32.dll")] public static extern int SHChangeNotify(int eventId, int flags, IntPtr item1, IntPtr item2);'
            $shell = Add-Type -MemberDefinition $sig -Namespace WinShell -Name ExplorerSettingsNotify -PassThru -ErrorAction SilentlyContinue
            if ($shell) { [void]$shell::SHChangeNotify(0x8000000, 0x1000, [IntPtr]::Zero, [IntPtr]::Zero) }
        } catch {
            Write-StructuredLog -Level WARN -Message ("Explorer file-extension refresh failed: {0}" -f $_.Exception.Message)
        }
    }
}

# =============================================================================
# SECTION 1B: WINDOWS LONG PATHS
# =============================================================================
function Enable-LongPathSupport {
    if ($Global:Config.filesystem -and ($Global:Config.filesystem.PSObject.Properties.Name -contains "enableLongPaths") -and -not $Global:Config.filesystem.enableLongPaths) {
        Write-Info "Windows long paths toggle disabled in config."
        return
    }

    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"
    $current = (Get-ItemProperty -Path $regPath -Name "LongPathsEnabled" -ErrorAction SilentlyContinue).LongPathsEnabled
    if ($current -eq 1) {
        Write-Ok "Windows long paths are already enabled."
        return
    }

    $result = Invoke-LoggedCommand -FilePath "reg.exe" -Arguments @(
        "add",
        "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem",
        "/v",
        "LongPathsEnabled",
        "/t",
        "REG_DWORD",
        "/d",
        "1",
        "/f"
    ) -DisplayName "reg add LongPathsEnabled"

    if ($result.ExitCode -eq 0) {
        Write-Ok "Enabled Windows long paths (LongPathsEnabled=1)."
    } else {
        Write-Warn ("Could not enable Windows long paths; reg.exe exited with code {0}." -f $result.ExitCode)
    }
}

# =============================================================================
# SECTION 2: DARK MODE + TASKBAR (item 12)
# =============================================================================
function Set-WindowsDarkMode {
    if (-not $Global:Config.appearance.darkMode) {
        Write-Info "Dark mode disabled in config."
        return
    }
    $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
    Set-RegistryValue -Path $path -Name "AppsUseLightTheme"   -Value 0
    Set-RegistryValue -Path $path -Name "SystemUsesLightTheme" -Value 0

    # Some Windows 10/11 builds need the shell colorization keys touched too
    # before Start/taskbar pick up the system dark state.
    $colorPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes"
    if (Test-Path $colorPath) {
        try { Set-ItemProperty -Path $colorPath -Name "ThemeChangesDesktopIcons" -Value 0 -ErrorAction SilentlyContinue } catch { Write-StructuredLog -Level WARN -Message ("Could not set ThemeChangesDesktopIcons: {0}" -f $_.Exception.Message) }
    }
    $dwmPath = "HKCU:\Software\Microsoft\Windows\DWM"
    Set-RegistryValue -Path $dwmPath -Name "ColorPrevalence" -Value 0 -IgnoreErrors
    $accentPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent"
    Set-RegistryValue -Path $accentPath -Name "StartColorMenu" -Value 0xff202020 -IgnoreErrors
    Write-Ok "Dark mode registry keys set for apps + system."

    if ($Global:Config.appearance.restartExplorer) {
        Restart-ExplorerGracefully
    } else {
        Write-Info "Sign out / sign in to fully apply the taskbar dark theme, or enable restartExplorer in config."
    }
}

function Restart-ExplorerGracefully {
    Write-Info "Restarting Explorer to apply theme + Explorer settings..."
    try {
        Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 600
        # Windows auto-starts Explorer; only start manually if it didn't come back.
        if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) {
            Start-Process explorer.exe
        }
        Write-Ok "Explorer restarted."
    } catch {
        Write-Warn "Could not restart Explorer cleanly: $($_.Exception.Message)"
    }
}

# =============================================================================
# SECTION 3: PERSIAN KEYBOARD LAYOUT (item 7)
# =============================================================================
function Add-PersianKeyboardLayout {
    if (-not $Global:Config.keyboard -or -not $Global:Config.keyboard.addPersianLayout) {
        Write-Info "Persian keyboard step disabled in config."
        return
    }
    try {
        $existing = Get-WinUserLanguageList -ErrorAction Stop
        if ($existing | Where-Object { $_.LanguageTag -eq 'fa-IR' }) {
            Write-Ok "Persian (fa-IR) keyboard layout is already in the user language list."
            return
        }
        $existing.Add("fa-IR")
        Set-WinUserLanguageList -LanguageList $existing -Force
        Write-Ok "Added Persian (fa-IR) to the user language list."
    } catch {
        Write-Warn "Could not modify user language list with Set-WinUserLanguageList: $($_.Exception.Message)"
        Write-Warn "Try adding the Persian keyboard layout manually from Settings -> Time & Language -> Language."
    }
}

# =============================================================================
# SECTION 4: CUSTOM FOLDERS + DEFENDER + SCRIPTS PATH (items 14, 15, 20)
# =============================================================================
function Get-CurrentUserDownloadsFolder {
    $shf = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
    $guid = "{374DE290-123F-4565-9164-39C4925E467B}"
    try {
        $p = Get-ItemProperty -Path $shf -ErrorAction SilentlyContinue
        if ($p) {
            $prop = $p.PSObject.Properties[$guid]
            if ($prop -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
                return [Environment]::ExpandEnvironmentVariables([string]$prop.Value)
            }
        }
    } catch { $null = $_ }
    $up = [Environment]::GetFolderPath("UserProfile")
    if ([string]::IsNullOrWhiteSpace($up)) { $up = $env:USERPROFILE }
    return (Join-Path $up "Downloads")
}

function Test-DefenderExclusionPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Get-Command Get-MpPreference -ErrorAction SilentlyContinue)) { return $false }
    try {
        $fp = [System.IO.Path]::GetFullPath($Path).TrimEnd("\")
        $prefs = Get-MpPreference
        foreach ($e in @($prefs.ExclusionPath)) {
            if ([string]::IsNullOrWhiteSpace([string]$e)) { continue }
            $n = [System.IO.Path]::GetFullPath([string]$e).TrimEnd("\")
            if ([string]::Equals($n, $fp, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    } catch { $null = $_ }
    return $false
}

function Add-DefenderExclusionPathSafe {
    param([Parameter(Mandatory)][string]$Path)
    $fp = [System.IO.Path]::GetFullPath($Path)
    if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) {
        Write-Warn "Defender PowerShell module not available; cannot add exclusion: $fp"
        return
    }
    if (Test-DefenderExclusionPath -Path $fp) {
        Write-Ok "Defender exclusion already present: $fp"
        return
    }
    try {
        Add-MpPreference -ExclusionPath $fp
        Write-Ok "Added Defender exclusion: $fp"
    } catch {
        Write-Warn ("Could not add Defender exclusion for {0}: {1}" -f $fp, $_.Exception.Message)
    }
}

function Configure-CustomFoldersAndDefenderExclusions {
    $s = $Global:Config.customFolders
    if (-not $s -or -not $s.enabled) { Set-StepSkipped "disabled in config"; return }

    Ensure-Directory ([string]$s.portablePath)
    Ensure-Directory ([string]$s.scriptsPath)

    if ($s.createCompressedInDownloads) {
        $downloads = Get-CurrentUserDownloadsFolder
        Ensure-Directory $downloads
        $name = [string]$s.compressedFolderName
        if ([string]::IsNullOrWhiteSpace($name)) { $name = "compressed" }
        $cmp = Join-Path $downloads $name
        Ensure-Directory $cmp
        if ($s.excludeCompressedFromDefender) { Add-DefenderExclusionPathSafe -Path $cmp }
    }
}

# =============================================================================
# SECTION 13: SEARCH INDEXING (carry over)
# =============================================================================
function Enable-SearchIndexing {
    if (-not $Global:Config.indexing.enabled) { Set-StepSkipped "disabled in config"; return }
    Write-Info "Installing/enabling Windows Search service."
    try {
        $before = Get-Service -Name WSearch -ErrorAction SilentlyContinue
        if ($before) { Write-Info "Windows Search initial state: $($before.Status) / $($before.StartType)" }
        else { Write-Info "Windows Search service not found before enable attempt." }
    } catch { $null = $_ }
    try {
        if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
            Install-WindowsFeature Search-Service -ErrorAction SilentlyContinue | Out-Null
        }
    } catch { Write-Warn "Install-WindowsFeature Search-Service: $($_.Exception.Message)" }
    try {
        Set-Service -Name WSearch -StartupType Automatic
        Start-Service -Name WSearch -ErrorAction SilentlyContinue
        $after = Get-Service -Name WSearch -ErrorAction SilentlyContinue
        if ($after) { Write-Ok "Windows Search service final state: $($after.Status) / $($after.StartType)" }
        else { Write-Warn "Windows Search service is still not available after enable attempt." }
    } catch { Write-Warn "Could not start WSearch: $($_.Exception.Message)" }
}

# =============================================================================
# SECTION 15: EMPTY STANDBY LIST TASK (item 21)
# =============================================================================
function Install-EmptyStandbyList {
    $s = $Global:Config.emptyStandbyList
    if (-not $s.enabled) { Set-StepSkipped "disabled in config"; return }
    $installDir = [string]$s.installDir
    $exeName    = [string]$s.exeName
    $exePath    = Join-Path $installDir $exeName
    $xmlName    = if ($s.PSObject.Properties.Name -contains "taskXmlName") { [string]$s.taskXmlName } else { "EmptyStandbyList.xml" }
    $xmlPath    = Join-Path $installDir $xmlName
    $taskName   = [string]$s.taskName
    $taskPath   = if ($s.PSObject.Properties.Name -contains "taskPath") { [string]$s.taskPath } else { "\" }
    $repeat     = [int]$s.repeatMinutes
    if (-not $taskPath.StartsWith("\")) { $taskPath = "\" + $taskPath }
    if (-not $taskPath.EndsWith("\"))   { $taskPath = $taskPath + "\" }

    Ensure-Directory $installDir
    if (-not (Test-Path $exePath)) {
        $local = Resolve-RelativePath ("apps\installers\" + $exeName)
        if (Test-Path $local) {
            Copy-Item -LiteralPath $local -Destination $exePath -Force
            Write-Ok "Copied EmptyStandbyList.exe from local installers folder."
        } else {
            # This binary is unsigned and gets registered as a repeating SYSTEM task, so
            # Authenticode cannot be the anchor and a pinned hash is the only control left.
            # Refuse rather than fetch mutable bytes that will run as SYSTEM.
            $expectedSha256 = if ($s.PSObject.Properties.Name -contains "expectedSha256") { [string]$s.expectedSha256 } else { "" }
            if ([string]::IsNullOrWhiteSpace($expectedSha256)) {
                Write-Warn "EmptyStandbyList.exe is not pinned. Put the binary in apps\installers, or set emptyStandbyList.expectedSha256 in config, and re-run."
                return
            }
            $repo = [string]$s.sourceRepo
            $ref  = if ($s.PSObject.Properties.Name -contains "sourceRef" -and -not [string]::IsNullOrWhiteSpace([string]$s.sourceRef)) { [string]$s.sourceRef } else { "master" }
            $raw  = "https://raw.githubusercontent.com/$repo/$ref/$exeName"
            if (-not (Invoke-DownloadFile -Url $raw -Destination $exePath -ExpectedSha256 $expectedSha256 -AllowedHosts @('raw.githubusercontent.com'))) {
                Write-Warn "Could not obtain EmptyStandbyList.exe. Put it in apps\installers and re-run."
                return
            }
        }
    } else { Write-Ok "EmptyStandbyList.exe already at $exePath" }

    $start = (Get-Date).AddMinutes(1).ToString("yyyy-MM-ddTHH:mm:ss")
    $interval = "PT${repeat}M"
    $taskUri  = "$taskPath$taskName"
    $arg      = ([string]$s.argument).Replace("&","&amp;").Replace("<","&lt;").Replace(">","&gt;")
    $cmd      = $exePath.Replace("&","&amp;").Replace("<","&lt;").Replace(">","&gt;")

    $xmlContent = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>WinServerSetup</Author>
    <Description>Clear standby memory every $repeat minutes using EmptyStandbyList.exe $arg.</Description>
    <URI>$taskUri</URI>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <Repetition><Interval>$interval</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>
      <StartBoundary>$start</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT72H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec><Command>$cmd</Command><Arguments>$arg</Arguments></Exec>
  </Actions>
</Task>
"@
    $xmlContent | Set-Content -LiteralPath $xmlPath -Encoding Unicode -Force
    Write-Ok "Task XML written to: $xmlPath"

    try { Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { $null = $_ }
    Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Xml (Get-Content -LiteralPath $xmlPath -Raw) -Force | Out-Null
    Write-Ok ("Empty Cache scheduled task registered: {0}{1}  every {2} min (hidden, highest privileges)" -f $taskPath, $taskName, $repeat)

    # Verify
    $verify = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
    if ($verify) { Write-Ok "Task verified in Task Scheduler." } else { Write-Warn "Could not verify Empty Cache task after registration." }
}

# =============================================================================
# SECTION 16: QoS / BANDWIDTH (item 22)
# =============================================================================
function Configure-WindowsUpdateBandwidthPolicies {
    $s = $Global:Config.windowsUpdateBandwidth
    if (-not $s.enabled) { Set-StepSkipped "disabled in config"; return }
    Write-Info "Applying QoS / DeliveryOptimization / WindowsUpdate bandwidth policies..."

    $qos = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched"
    Set-RegistryValue -Path $qos -Name "NonBestEffortLimit" -Value ([int]$s.qosNonBestEffortLimit)

    $do = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"
    Set-RegistryValue -Path $do -Name "DODownloadMode" -Value ([int]$s.deliveryOptimizationDownloadMode)

    if ($s.disableUpdateBandwidthLimits) {
        $doLimitValues = @(
            "DOPercentageMaxBackgroundBandwidth",
            "DOPercentageMaxForegroundBandwidth"
        )
        $osBuild = [Environment]::OSVersion.Version.Build
        if ($osBuild -ge 17134) {
            $doLimitValues += @(
                "DOAbsoluteMaxDownloadBandwidth",
                "DOAbsoluteMaxDownloadBandwidthForeground"
            )
        } else {
            Write-Info "Skipping absolute Delivery Optimization bandwidth keys on Windows builds older than 1803."
        }
        foreach ($valueName in $doLimitValues) {
            Set-ItemProperty -Path $do -Name $valueName -Type DWord -Value 0
        }

        # Remove old no-op values written by earlier project builds under the
        # WindowsUpdate policy key. Delivery Optimization owns these limits.
        $wu = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
        if (Test-Path $wu) {
            foreach ($legacyName in @(
                "SetDownloadThrottle",
                "SetBusinessHoursDownloadThrottle",
                "SetDownloadThrottlePercentage",
                "SetBusinessHoursDownloadThrottlePercentage"
            )) {
                Remove-ItemProperty -Path $wu -Name $legacyName -ErrorAction SilentlyContinue
            }
        }
    }

    if ($s.runGpupdate) {
        try {
            Write-Info "Refreshing computer policy with gpupdate..."
            # Invoke-BoundedGpupdate (scripts\AccountSecurity.ps1) is the project's only gpupdate
            # runner. The progress runner used here previously waits on HasExited with no deadline,
            # so a slow or unreachable domain controller hung the whole setup. A refresh that stalls
            # or fails is still only a warning: the bandwidth policies themselves are already written.
            Invoke-BoundedGpupdate
            Write-Ok "Computer policy refreshed."
        } catch {
            Write-Warn "gpupdate failed: $($_.Exception.Message)"
        }
    }

    $applied = (Get-ItemProperty -Path $qos -Name NonBestEffortLimit -ErrorAction SilentlyContinue).NonBestEffortLimit
    Write-Ok ("NonBestEffortLimit verified = {0}" -f $applied)
}

# =============================================================================
# SECTION 17: STARTUP DISABLE / APPX REMOVE / CAPABILITY REMOVE
#  (items 17, 28, 29, 30)
# =============================================================================
function Disable-StartupEntry {
    param([Parameter(Mandatory)][string]$Pattern)
    $removedEntries = New-Object System.Collections.Generic.List[string]
    $runKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
    )
    foreach ($k in $runKeys) {
        if (-not (Test-Path $k)) { continue }
        try {
            $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            foreach ($prop in $p.PSObject.Properties) {
                if ($prop.Name -like 'PS*') { continue }
                if ([string]$prop.Value -match [regex]::Escape($Pattern) -or $prop.Name -match [regex]::Escape($Pattern)) {
                    # Only count an entry that really went away; a silenced failure previously made
                    # this function report a removal it never performed.
                    try {
                        Remove-ItemProperty -Path $k -Name $prop.Name -ErrorAction Stop
                        Write-Ok "Removed startup entry: $k :: $($prop.Name)"
                        $removedEntries.Add("$k :: $($prop.Name)") | Out-Null
                    } catch {
                        Write-Warn "Could not remove startup entry $k :: $($prop.Name): $($_.Exception.Message)"
                    }
                }
            }
        } catch { $null = $_ }
    }
    # Startup folders
    $folders = @([Environment]::GetFolderPath("Startup"), [Environment]::GetFolderPath("CommonStartup"))
    foreach ($f in $folders) {
        if (-not $f -or -not (Test-Path $f)) { continue }
        Get-ChildItem $f -Filter '*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
            $target = ""
            try {
                $ws = New-Object -ComObject WScript.Shell
                $target = $ws.CreateShortcut($_.FullName).TargetPath
            } catch { $null = $_ }
            # Captured before the try: inside catch, $_ is the ErrorRecord, not the shortcut.
            $shortcutPath = $_.FullName
            if ($_.Name -match [regex]::Escape($Pattern) -or $target -match [regex]::Escape($Pattern)) {
                try {
                    Remove-Item $shortcutPath -Force -ErrorAction Stop
                    Write-Ok "Removed startup shortcut: $shortcutPath"
                    $removedEntries.Add($shortcutPath) | Out-Null
                } catch {
                    Write-Warn "Could not remove startup shortcut ${shortcutPath}: $($_.Exception.Message)"
                }
            }
        }
    }
    if ($removedEntries.Count -eq 0) { Write-Info "Startup entry not found (already disabled?): $Pattern" }
    return ($removedEntries.Count -gt 0)
}

function Disable-ConfiguredStartupApps {
    $s = $Global:Config.startupDisable
    if (-not $s -or -not $s.enabled) { Set-StepSkipped "disabled in config"; return }
    foreach ($p in $s.patterns) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        Write-Info "Disabling startup entry: $p"
        Disable-StartupEntry -Pattern $p | Out-Null
    }
}

function Remove-ConfiguredAppxPackages {
    $s = $Global:Config.removeAppxPackages
    if (-not $s -or -not $s.enabled) { Set-StepSkipped "disabled in config"; return }
    foreach ($name in $s.packages) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        Write-Info "Removing Appx package (current user): $name"
        try {
            Get-AppxPackage -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-AppxPackage -Package $_.PackageFullName -ErrorAction SilentlyContinue
                Write-Ok "Removed $($_.PackageFullName) for current user."
            }
        } catch { Write-Warn "Per-user Appx removal failed for $name : $($_.Exception.Message)" }
        try {
            Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq $name } |
                ForEach-Object {
                    Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null
                    Write-Ok "Removed provisioned package $($_.PackageName)."
                }
        } catch { Write-Warn "Provisioned Appx removal failed for $name : $($_.Exception.Message)" }
    }
}

function Remove-ConfiguredWindowsCapabilities {
    $s = $Global:Config.removeWindowsCapabilities
    if (-not $s -or -not $s.enabled) { Set-StepSkipped "disabled in config"; return }
    foreach ($cap in $s.capabilities) {
        if ([string]::IsNullOrWhiteSpace($cap)) { continue }
        Write-Info "Removing Windows capability: $cap"
        try {
            $state = Get-WindowsCapability -Online -Name $cap -ErrorAction SilentlyContinue
            if (-not $state) { Write-Info "Capability not present: $cap"; continue }
            if ($state.State -eq 'NotPresent') { Write-Ok "Capability already NotPresent: $cap"; continue }
            $dism = Invoke-LoggedCommand -FilePath "dism.exe" -Arguments @("/online", "/Remove-Capability", "/CapabilityName:$cap") -DisplayName "DISM remove capability $cap"
            # Deliberately NOT routed through Resolve-InstallerExitCode: DISM is not a Windows
            # Installer package and never returns 1641, so the shared helper would widen the
            # accepted exit-code set here for no reason.
            if ($dism.ExitCode -eq 0 -or $dism.ExitCode -eq 3010) {
                Write-Ok "Capability removal command completed: $cap"
                if ($dism.ExitCode -eq 3010) { Set-PendingReboot "Capability removal requested reboot: $cap" }
            } else {
                Write-Warn "Capability removal exited with code $($dism.ExitCode): $cap"
            }
        } catch { Write-Warn "Capability removal failed for $cap : $($_.Exception.Message)" }
    }
}

# =============================================================================
# SECTION 18: QUICK ACCESS PIN (item 33)
# =============================================================================
function Add-FolderToQuickAccess {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { Ensure-Directory $Path }
    try {
        $shell = New-Object -ComObject Shell.Application
        $ns    = $shell.NameSpace($Path)
        if (-not $ns) { Write-Warn "Shell cannot access folder: $Path"; return $false }
        $ns.Self.InvokeVerb("pintohome")
        Start-Sleep -Milliseconds 250
        Write-Ok "Requested Quick Access pin (or already pinned): $Path"
        return $true
    } catch {
        Write-Warn "Quick Access pin failed for $Path : $($_.Exception.Message)"
        return $false
    }
}

function Add-RecycleBinToQuickAccess {
    try {
        $shell = New-Object -ComObject Shell.Application
        $bin = $shell.NameSpace(10) # ssfBITBUCKET
        if (-not $bin -or -not $bin.Self) {
            Write-Warn "Shell cannot access Recycle Bin for Quick Access pinning."
            return $false
        }
        $bin.Self.InvokeVerb("pintohome")
        Start-Sleep -Milliseconds 250
        Write-Ok "Requested Recycle Bin Quick Access pin (or already pinned)."
        return $true
    } catch {
        Write-Warn "Quick Access pin failed for Recycle Bin: $($_.Exception.Message)"
        return $false
    }
}

function Add-ConfiguredQuickAccessPins {
    $s = $Global:Config.quickAccess
    if (-not $s -or -not $s.enabled) { Set-StepSkipped "disabled in config"; return }
    foreach ($p in $s.folders) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        Add-FolderToQuickAccess -Path $p | Out-Null
    }
    $includeRecycleBin = $true
    if ($s.PSObject.Properties.Name -contains "includeRecycleBin") { $includeRecycleBin = [bool]$s.includeRecycleBin }
    if ($includeRecycleBin) { Add-RecycleBinToQuickAccess | Out-Null }
}

# =============================================================================
# SECTION 19: EDGE UNPIN / BRAVE PIN  (item 18, best-effort)
# =============================================================================
function Test-TaskbarPinnedPath {
    param([Parameter(Mandatory)][string]$Path)
    $pinDir = Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    if (-not (Test-Path $pinDir)) { return $null }

    $targetFull = [System.IO.Path]::GetFullPath($Path)
    $wsh = $null
    try {
        $wsh = New-Object -ComObject WScript.Shell
        foreach ($link in Get-ChildItem -LiteralPath $pinDir -Filter '*.lnk' -ErrorAction SilentlyContinue) {
            $shortcut = $null
            try {
                $shortcut = $wsh.CreateShortcut($link.FullName)
                if (-not [string]::IsNullOrWhiteSpace($shortcut.TargetPath)) {
                    $shortcutTarget = [System.IO.Path]::GetFullPath($shortcut.TargetPath)
                    if ([string]::Equals($shortcutTarget, $targetFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                        return $true
                    }
                }
            } catch {
                Write-StructuredLog -Level TASKBAR -Message ("Could not inspect taskbar shortcut {0}: {1}" -f $link.FullName, $_.Exception.Message)
            } finally {
                if ($shortcut) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) } catch { $null = $_ } }
            }
        }
        return $false
    } catch {
        Write-StructuredLog -Level TASKBAR -Message ("Could not inspect taskbar pinned folder: {0}" -f $_.Exception.Message)
        return $null
    } finally {
        if ($wsh) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) } catch { $null = $_ } }
    }
}

function Invoke-ShellPinUnpin {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$VerbNames,
        [string]$CanonicalVerb = "",
        [object]$ShouldBePinned = $null
    )
    if (-not (Test-Path $Path)) { return $false }
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.Namespace((Split-Path -Parent $Path))
        if (-not $folder) { return $false }
        $item = $folder.ParseName((Split-Path -Leaf $Path))
        if (-not $item) { return $false }

        if (-not [string]::IsNullOrWhiteSpace($CanonicalVerb)) {
            try {
                $item.InvokeVerb($CanonicalVerb)
                Start-Sleep -Milliseconds 600
                $state = Test-TaskbarPinnedPath -Path $Path
                if ($null -ne $state -and $state -eq [bool]$ShouldBePinned) { return $true }
                if ($null -eq $state) {
                    Write-StructuredLog -Level TASKBAR -Message ("Canonical taskbar verb {0} finished but pin state is indeterminate for {1}; trying fallback verb matching." -f $CanonicalVerb, $Path)
                } else {
                    Write-StructuredLog -Level TASKBAR -Message ("Canonical taskbar verb {0} did not reach expected state for {1}." -f $CanonicalVerb, $Path)
                }
            } catch {
                Write-StructuredLog -Level TASKBAR -Message ("Canonical taskbar verb {0} failed for {1}: {2}" -f $CanonicalVerb, $Path, $_.Exception.Message)
            }
        }

        $candidates = @($VerbNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ -replace '&','' })
        $verb = $item.Verbs() | Where-Object {
            $name = $_.Name -replace '&',''
            $matched = $false
            foreach ($candidate in $candidates) {
                if ($name -ieq $candidate -or $name -ilike "*$candidate*") {
                    $matched = $true
                    break
                }
            }
            $matched
        } | Select-Object -First 1
        if (-not $verb) { return $false }
        $verb.DoIt()
        Start-Sleep -Milliseconds 400
        if ($null -ne $ShouldBePinned) {
            $state = Test-TaskbarPinnedPath -Path $Path
            if ($null -ne $state) { return ($state -eq [bool]$ShouldBePinned) }
            Write-StructuredLog -Level TASKBAR -Message ("Taskbar pin state is indeterminate after fallback verb for {0}." -f $Path)
            return $false
        }
        return $true
    } catch { return $false }
}

function Replace-EdgeTaskbarPinWithBrave {
    $s = $Global:Config.taskbar
    if (-not $s) { return }
    if ($s.unpinEdge) {
        $edge = "$env:ProgramFiles (x86)\Microsoft\Edge\Application\msedge.exe"
        if (-not (Test-Path $edge)) { $edge = "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe" }
        if (Test-Path $edge) {
            if (Invoke-ShellPinUnpin -Path $edge -VerbNames @("Unpin from taskbar") -CanonicalVerb "taskbarunpin" -ShouldBePinned $false) {
                Write-Ok "Unpinned Edge from taskbar."
            } else {
                Write-Warn "Could not unpin Edge automatically. Windows 11 often blocks programmatic taskbar pin changes; unpin Edge manually if it remains."
            }
        } else { Write-Info "Edge executable not found; skipping unpin." }
    }
    if ($s.pinBrave) {
        $brave = "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe"
        if (-not (Test-Path $brave)) { $brave = "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application\brave.exe" }
        if (Test-Path $brave) {
            if (Invoke-ShellPinUnpin -Path $brave -VerbNames @("Pin to taskbar") -CanonicalVerb "taskbarpin" -ShouldBePinned $true) {
                Write-Ok "Pinned Brave to taskbar."
            } else {
                Write-Warn "Could not pin Brave automatically. Drag brave.exe to taskbar manually as a fallback."
            }
        } else { Write-Warn "Brave not installed yet; cannot pin to taskbar." }
    }
}
