# WinServerSetup.ps1
# Main provisioning script for Windows / Windows Server after a clean install.
# Designed to be re-runnable, idempotent, admin-only, and to leave the machine
# in a known good state at the end (with an optional auto-restart).
#
# All CLI text, logs, and inline comments are in English by design.

[CmdletBinding()]
param(
    [switch]$Full,
    [switch]$NoPause,
    [switch]$NoColor,
    [switch]$NoReboot,
    [switch]$NoRelocate,
    [string]$RelocationReadyPath = "",
    [string]$RelocationReadyToken = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor `
    [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11

$Global:NoColor    = [bool]$NoColor
$Global:NoPause    = [bool]$NoPause
$Global:NoReboot   = [bool]$NoReboot
$Global:NoRelocate = [bool]$NoRelocate
$Global:Full       = [bool]$Full

function Get-ProjectRoot {
    if ($PSScriptRoot) { return $PSScriptRoot }
    return Split-Path -Parent $MyInvocation.MyCommand.Path
}

$Global:ProjectRoot      = Get-ProjectRoot
$Global:ConfigPath       = Join-Path $Global:ProjectRoot "WinServerSetup.config.json"
$Global:Config           = $null
$Global:ScriptVersion    = "1.2.0"
$Global:TranscriptStarted= $false
$Global:LogFile          = $null
$Global:StructuredLog    = $null

. (Join-Path $Global:ProjectRoot "scripts\AccountSecurity.ps1")

# Summary tracking used by Show-FinalSummary at the end of Full setup.
$Global:RunStats = [pscustomobject]@{
    StartedTasks    = New-Object System.Collections.Generic.List[string]
    CompletedTasks  = New-Object System.Collections.Generic.List[string]
    FailedTasks     = New-Object System.Collections.Generic.List[string]
    SkippedTasks    = New-Object System.Collections.Generic.List[string]
    Warnings        = New-Object System.Collections.Generic.List[string]
    InstalledApps   = New-Object System.Collections.Generic.List[string]
    FailedApps      = New-Object System.Collections.Generic.List[string]
    RebootRequired  = $false
}

# Set by Set-StepSkipped while a recorded step is running; consumed and cleared by
# Invoke-RecordedSetupStep so a switched-off feature is counted as Skipped, not Completed.
$Global:CurrentStepSkipReason = $null

# =============================================================================
# COLORED TERMINAL OUTPUT
# =============================================================================
# All terminal output goes through Write-Themed or a semantic wrapper. The
# palette can be retuned from $Global:WinServerSetupColors. Color is disabled
# by any of: -NoColor switch, $env:NO_COLOR, $env:WINSERVERSETUP_NOCOLOR.
# Long-running task output uses Write-Host -ForegroundColor (ConsoleColor) so
# the transcript stays free of escape sequences.

# Semantic ConsoleColor tokens. Every kind resolves here, so any host that
# cannot render ANSI still gets a readable PowerShell 5-compatible color.
$Global:WinServerSetupColors = @{
    Success      = 'Green'
    Error        = 'Red'
    Warning      = 'Yellow'
    Info         = 'Cyan'
    Prompt       = 'Yellow'
    Default      = 'Green'
    Section      = 'Yellow'
    Status       = 'Cyan'
    Summary      = 'White'
    SummaryDim   = 'Gray'
    Banner       = 'Magenta'
    BannerRule   = 'Magenta'
    MenuHeader   = 'Cyan'
    StartupLabel = 'Cyan'
    StartupValue = 'Yellow'
    StartupPath  = 'White'
    StartupOk    = 'Green'
    StartupDim   = 'DarkGray'
    StartupNote  = 'Yellow'
}

# The startup banner, startup facts, and menu header are the only output that
# asks for colors ConsoleColor cannot express (the exact banner pink). They opt
# into 24-bit / 256-color ANSI when the host can render it without dirtying the
# transcript, and fall back to the ConsoleColor token above when it cannot.
$Global:WinServerSetupAnsiColors = @{
    Banner       = "$([char]27)[1m$([char]27)[38;2;255;50;115m"
    BannerRule   = "$([char]27)[38;2;255;50;115m"
    MenuHeader   = "$([char]27)[1m$([char]27)[38;5;117m"
    StartupLabel = "$([char]27)[38;5;117m"
    StartupValue = "$([char]27)[38;5;229m"
    StartupPath  = "$([char]27)[38;5;159m"
    StartupOk    = "$([char]27)[38;5;120m"
    StartupDim   = "$([char]27)[38;5;250m"
    StartupNote  = "$([char]27)[38;5;227m"
}

$Global:WinServerSetupAnsiSupported = $null

# =============================================================================
# FUNCTION LIBRARY
# =============================================================================
# Every function definition below this point lives in scripts\. The modules are
# dot-sourced here: after the globals above are initialized, and before the entry
# point runs. A module contains only function definitions and comments - nothing
# executes at load time, so the order between them does not matter.
. (Join-Path $Global:ProjectRoot "scripts\Console.ps1")
. (Join-Path $Global:ProjectRoot "scripts\Core.ps1")
. (Join-Path $Global:ProjectRoot "scripts\Download.ps1")
. (Join-Path $Global:ProjectRoot "scripts\Rdp.ps1")
. (Join-Path $Global:ProjectRoot "scripts\Install.ps1")

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
            $gp = Invoke-LoggedProcessWithProgress -FilePath "gpupdate.exe" -Arguments @("/target:computer", "/force") -DisplayName "gpupdate" -StatusMessage "Refreshing computer policy"
            if ($gp.ExitCode -eq 0) { Write-Ok "Computer policy refreshed." }
            else { Write-Warn "gpupdate exited with code $($gp.ExitCode)." }
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

# =============================================================================
# SECTION 20: WINDOWS UPDATE (items 5, 19)
# =============================================================================
function Invoke-WithPSGalleryTrust {
    param([Parameter(Mandatory)][scriptblock]$Action)
    $repository = Get-PSRepository -Name "PSGallery" -ErrorAction Stop
    $originalPolicy = [string]$repository.InstallationPolicy
    try {
        if ($originalPolicy -ne 'Trusted') { Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted -ErrorAction Stop }
        & $Action
    } finally {
        if ($originalPolicy -and $originalPolicy -ne 'Trusted') {
            Set-PSRepository -Name "PSGallery" -InstallationPolicy $originalPolicy -ErrorAction Stop
        }
    }
}

function Initialize-WindowsUpdateEnvironment {
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        try { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:$false | Out-Null } catch { Write-Warn "Install-PackageProvider NuGet failed: $($_.Exception.Message)" }
    }
    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Invoke-WithPSGalleryTrust { Install-Module -Name PSWindowsUpdate -Force -AllowClobber -Confirm:$false -ErrorAction Stop | Out-Null }
    }
    Import-Module PSWindowsUpdate -Force -ErrorAction Stop
    Add-WUServiceManager -MicrosoftUpdate -Confirm:$false -ErrorAction Stop | Out-Null
}

function Invoke-WindowsUpdatePass {
    param([int]$PassNumber)
    Write-Info "Windows Update pass ${PassNumber}: scanning..."
    $updates = @()
    try { $updates = @(Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Verbose:$false -ErrorAction Stop) }
    catch { throw "Windows Update scan failed on pass ${PassNumber}: $($_.Exception.Message)" }

    if (-not $updates -or $updates.Count -eq 0) {
        Write-Ok "Pass ${PassNumber}: no applicable updates."
        return 0
    }
    Write-Info ("Pass ${PassNumber}: detected {0} update(s)." -f $updates.Count)

    $i = 0
    foreach ($u in $updates) {
        $i++
        $title = if ($u.Title) { $u.Title } else { [string]$u }
        Write-StructuredLog -Level UPDATE -Message ("Pass {0}: detected [{1}/{2}] {3}" -f $PassNumber, $i, $updates.Count, $title)
        Write-StructuredLog -Level UPDATE -Message ("Pass {0}: accepted [{1}/{2}] {3}" -f $PassNumber, $i, $updates.Count, $title)
    }

    Write-Info "Pass ${PassNumber}: downloading/installing accepted updates with reboot suppressed."
    $wuJob = $null
    try {
        $wuJob = Start-Job -Name "WinServerSetup-WindowsUpdate-$PassNumber" -ScriptBlock {
            Import-Module PSWindowsUpdate -Force
            Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -Verbose:$false -Confirm:$false
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $WindowsUpdateJobTimeoutMinutes = [int]$Global:Config.windowsUpdate.jobTimeoutMinutes
        if ($WindowsUpdateJobTimeoutMinutes -lt 1) { $WindowsUpdateJobTimeoutMinutes = 120 }
        while ($wuJob.State -eq 'Running') {
            if ($sw.Elapsed.TotalMinutes -ge $WindowsUpdateJobTimeoutMinutes) {
                Stop-Job -Job $wuJob -ErrorAction SilentlyContinue
                throw "Windows Update job timed out after $WindowsUpdateJobTimeoutMinutes minutes."
            }
            Write-StatusInPlace ("Pass {0}: downloading/installing updates... elapsed {1:hh\:mm\:ss}" -f $PassNumber, $sw.Elapsed)
            Start-Sleep -Seconds 2
            $wuJob = Get-Job -Id $wuJob.Id
        }
        Clear-StatusInPlace
        $wuOutput = @()
        $jobErrors = @()
        $wuOutput = @(Receive-Job -Job $wuJob -ErrorAction SilentlyContinue -ErrorVariable jobErrors)
        foreach ($line in $wuOutput) {
            $text = [string]$line
            if (-not [string]::IsNullOrWhiteSpace($text)) { Write-StructuredLog -Level UPDATE -Message ("Pass {0}: {1}" -f $PassNumber, $text.TrimEnd()) }
        }
        if ($wuJob.State -ne 'Completed' -or $jobErrors.Count -gt 0) { throw "Windows Update install job failed with state $($wuJob.State): $($jobErrors -join '; ')" }
        $resultObjects = @($wuOutput | Where-Object { $_.PSObject.Properties.Name -contains 'Result' -or $_.PSObject.Properties.Name -contains 'ResultCode' })
        $failedResults = @($resultObjects | Where-Object {
            $resultText = if ($_.PSObject.Properties.Name -contains 'Result') { [string]$_.Result } else { [string]$_.ResultCode }
            $resultText -notmatch 'Installed|Succeeded|Success|Downloaded'
        })
        if ($failedResults.Count -gt 0) { throw "$($failedResults.Count) Windows Update result(s) did not report success." }
        Write-Ok "Pass ${PassNumber}: install command completed; a follow-up scan will verify remaining updates."
    } catch {
        Clear-StatusInPlace
        throw "Install-WindowsUpdate failed on pass ${PassNumber}: $($_.Exception.Message)"
    } finally {
        if ($null -ne $wuJob) { Remove-Job -Job $wuJob -Force -ErrorAction SilentlyContinue | Out-Null }
    }

    if (Test-WindowsRebootRequired) {
        Set-PendingReboot "Windows Update pass $PassNumber requested reboot"
        foreach ($u in $updates) {
            $title = if ($u.Title) { $u.Title } else { [string]$u }
            Write-StructuredLog -Level UPDATE -Message ("Pass {0}: reboot required after {1}" -f $PassNumber, $title)
        }
    }
    return $updates.Count
}

function Invoke-SystemUpdate {
    if (-not $Global:Config.windowsUpdate.enabled) { Write-Info "Windows Update section disabled in config."; Set-StepSkipped "disabled in config"; return }
    if (-not $Global:Config.windowsUpdate.usePSWindowsUpdateModule) {
        Write-Info "Opening Settings -> Windows Update (PSWindowsUpdate disabled)."
        try { Start-Process "ms-settings:windowsupdate" } catch { Write-Warn "Could not open Windows Update settings: $($_.Exception.Message)" }
        return
    }
    Initialize-WindowsUpdateEnvironment
    $maxPasses = [int]$Global:Config.windowsUpdate.maxPasses
    if ($maxPasses -lt 1) { $maxPasses = 4 }
    for ($pass = 1; $pass -le $maxPasses; $pass++) {
        $n = Invoke-WindowsUpdatePass -PassNumber $pass
        if ($n -eq 0) { break }
    }
    # Final summary
    try {
        $remaining = @(Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Verbose:$false -ErrorAction Stop)
        if ($remaining -and $remaining.Count -gt 0) {
            Write-Warn ("{0} update(s) still pending after {1} passes." -f $remaining.Count, $maxPasses)
            foreach ($r in $remaining) { Write-Warn ("  pending: {0}" -f $r.Title) }
        } else {
            Write-Ok "All applicable Windows Updates installed."
        }
    } catch { throw "Final Windows Update verification scan failed: $($_.Exception.Message)" }
}

# =============================================================================
# SECTION 21: ACTIVATION (carry over)
# =============================================================================
function Invoke-Slmgr {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $slmgr = Join-Path $env:windir "System32\slmgr.vbs"
    if (-not (Test-Path $slmgr)) { throw "slmgr.vbs not found at $slmgr" }
    & cscript.exe //nologo $slmgr @Arguments | Out-Host
    return $LASTEXITCODE
}

function Invoke-SlmgrChecked {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $exitCode = Invoke-Slmgr -Arguments $Arguments
    if ($exitCode -ne 0) { throw "Windows licensing command failed with exit code $exitCode." }
}

function Invoke-ActivationIfConfigured {
    $a = $Global:Config.activation
    if (-not $a -or -not $a.enabled) { Write-Info "Activation disabled in config."; Set-StepSkipped "disabled in config"; return }
    $kms  = [string]$a.kmsServer
    $key  = [string]$a.productKey
    if ([string]::IsNullOrWhiteSpace($kms) -and [string]::IsNullOrWhiteSpace($key)) {
        Write-Warn "Activation enabled but no kmsServer or productKey set."
        return
    }
    Write-Warn "Use Activation only with a key/server you are entitled to use."
    if (-not [string]::IsNullOrWhiteSpace($key)) { Invoke-SlmgrChecked -Arguments @("/ipk", $key) }
    if (-not [string]::IsNullOrWhiteSpace($kms)) { Invoke-SlmgrChecked -Arguments @("/skms", $kms) }
    Invoke-SlmgrChecked -Arguments @("/ato")
    Invoke-SlmgrChecked -Arguments @("/xpr")
    Write-Ok "Activation completed and license status was queried."
}

# =============================================================================
# SECTION 22: POST-REBOOT SFC (item 32)
# =============================================================================
function Register-PostRebootSfcTask {
    if (-not $Global:Config.autoReboot.scheduleSfcAfterReboot) { return }
    $sfcScript = Join-Path $Global:ProjectRoot "scripts\Run-PostRebootSfc.ps1"
    if (-not (Test-Path $sfcScript)) {
        Write-Warn "Post-reboot SFC helper not found: $sfcScript"
        return
    }
    $psExe = Join-Path $env:windir "System32\WindowsPowerShell\v1.0\powershell.exe"
    $taskName = "WinServerSetup Post-Reboot SFC"
    $arguments = "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$sfcScript`" -ProjectRoot `"$Global:ProjectRoot`""

    $action    = New-ScheduledTaskAction    -Execute $psExe -Argument $arguments
    # Delay the scan so it does not contend with boot-time servicing, which is the usual reason
    # a post-reboot SFC run fails in the first place. -StartWhenAvailable is not a delay.
    $trigger   = New-ScheduledTaskTrigger   -AtStartup -RandomDelay (New-TimeSpan -Minutes 3)
    try { $trigger.Delay = 'PT2M' } catch { $null = $_ }
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -Hidden

    try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { $null = $_ }
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

    # Verify the registration instead of trusting that the call returned. A task that exists but
    # carries the wrong action, principal or trigger will silently never do its job.
    if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
        throw "Post-reboot SFC task '$taskName' was not found after registration."
    }
    if (-not (Test-ScheduledTaskContract -TaskName $taskName -ExpectedExecutable $psExe -ExpectedArgumentPattern ([regex]::Escape($sfcScript)))) {
        throw "Post-reboot SFC task '$taskName' registered with an unexpected action, principal or trigger."
    }
    Write-Ok "Scheduled post-reboot task registered and verified: $taskName"
}

# =============================================================================
# CLEANUP + HEALTH CHECK (carry over)
# =============================================================================
function Remove-DirectoryContentsSafe {
    <#
        Deletes the CONTENTS of a directory and reports exactly what happened.

        Returns a structured result (Path, Succeeded, Removed, Failed, Unsafe) rather than a bare
        boolean, so callers can report real counts instead of a yes/no.

        The unsafe-path guard matters: Get-DownloadCachePath returns the configured downloadRoot
        verbatim, so a config value of "C:\" would otherwise enumerate and recursively delete
        every child of the system drive.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $result = [pscustomobject]@{ Path = $Path; Succeeded = $true; Removed = 0; Failed = 0; Unsafe = $false }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) { return $result }

    if (Test-UnsafeReplaceTarget -Path $Path) {
        $result.Succeeded = $false
        $result.Unsafe = $true
        Write-Fail "Refusing to clean an unsafe path (drive root or protected system directory): $Path"
        Write-StructuredLog -Level CLEANUP -Message ("Refused unsafe cleanup target: {0}" -f $Path)
        return $result
    }

    Write-Info "Cleaning: $Path"
    try {
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop | ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                $result.Removed++
            } catch {
                $result.Failed++
                Write-StructuredLog -Level CLEANUP -Message ("Could not remove {0}: {1}" -f $_.FullName, $_.Exception.Message)
            }
        }
    } catch {
        $result.Failed++
        Write-StructuredLog -Level CLEANUP -Message ("Could not enumerate {0}: {1}" -f $Path, $_.Exception.Message)
    }

    if ($result.Failed -gt 0) {
        $result.Succeeded = $false
        Write-Warn ("Cleanup failed for {0} ({1} removed, {2} item/error(s) remaining)." -f $Path, $result.Removed, $result.Failed)
        return $result
    }
    Write-Ok ("Cleaned: {0} ({1} item(s) removed)" -f $Path, $result.Removed)
    return $result
}

function Remove-WinServerSetupTempArtifacts {
    $failures = 0
    $roots = @($env:TEMP, $env:TMP) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    $patterns = @(
        "WinServerSetup-downloads",
        "WinServerSetup-*.log",
        "WinServerSetup-clean-source-*.ps1",
        "WinServerSetup-v2rayN.log",
        "WinServerSetup-*.partial"
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($pattern in $patterns) {
            Get-ChildItem -LiteralPath $root -Force -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                    Write-StructuredLog -Level CLEANUP -Message ("Removed project temp artifact: {0}" -f $_.FullName)
                } catch {
                    $failures++
                    Write-StructuredLog -Level CLEANUP -Message ("Could not remove project temp artifact {0}: {1}" -f $_.FullName, $_.Exception.Message)
                }
            }
        }
    }
    if ($failures -gt 0) { Write-Warn "Scoped temp cleanup failed for $failures artifact(s)."; return $false }
    Write-Ok "Scoped user temp cleanup completed for WinServerSetup artifacts only."
    return $true
}

function Restore-ServiceState {
    param([string]$Name, [bool]$WasRunning)
    if ($WasRunning) { Start-Service -Name $Name -ErrorAction Stop }
    else { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
}

function Clear-WinServerSetupTempAndCache {
    $s = $Global:Config.cleanup
    if (-not $s -or -not $s.enabled) { Set-StepSkipped "disabled in config"; return }
    Write-Section "Cleaning temp and cache files"
    $failures = 0
    if ($s.cleanProjectDownloadCache -and -not (Remove-DirectoryContentsSafe -Path (Get-DownloadCachePath)).Succeeded) { $failures++ }
    if ($s.cleanUserTemp -and -not (Remove-WinServerSetupTempArtifacts)) { $failures++ }
    if ($s.cleanWindowsTemp -and -not (Remove-DirectoryContentsSafe -Path (Join-Path $env:WINDIR "Temp")).Succeeded) { $failures++ }
    if ($s.cleanWindowsUpdateDownloadCache) {
        $wuWasRunning = (Get-Service -Name wuauserv -ErrorAction Stop).Status -eq 'Running'
        $bitsWasRunning = (Get-Service -Name bits -ErrorAction Stop).Status -eq 'Running'
        try {
            Stop-Service -Name wuauserv -Force -ErrorAction Stop
            Stop-Service -Name bits -Force -ErrorAction Stop
            if (-not (Remove-DirectoryContentsSafe -Path (Join-Path $env:WINDIR "SoftwareDistribution\Download")).Succeeded) { $failures++ }
        } catch { $failures++; Write-Warn "WU cache cleanup: $($_.Exception.Message)" }
        finally {
            try { Restore-ServiceState -Name bits -WasRunning $bitsWasRunning } catch { $failures++; Write-Warn "Could not restore BITS state: $($_.Exception.Message)" }
            try { Restore-ServiceState -Name wuauserv -WasRunning $wuWasRunning } catch { $failures++; Write-Warn "Could not restore Windows Update service state: $($_.Exception.Message)" }
        }
    }
    if ($s.cleanRecycleBin) {
        try { Clear-RecycleBin -Force -ErrorAction Stop; Write-Ok "Recycle Bin cleared." }
        catch { $failures++; Write-Warn "Could not clear Recycle Bin: $($_.Exception.Message)" }
    }
    if ($failures -gt 0) { throw "Cleanup failed with $failures operation error(s)." }
}

function Test-ConfiguredWingetPackage {
    param([string]$Id)
    return @($Global:Config.winget.packages | Where-Object { $_.enabled -and [string]$_.id -eq $Id }).Count -gt 0
}

function Test-ScheduledTaskContract {
    <#
        Validates that a registered task will actually do its job: right action, right principal,
        at least one trigger, and - when asked - that its last run did not fail and a next run is
        scheduled. Merely existing is not evidence a task is healthy.
    #>
    param(
        [string]$TaskName,
        [string]$ExpectedExecutable,
        [string]$ExpectedArgumentPattern,
        [switch]$RequireHealthyLastResult
    )
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $action = @($task.Actions)[0]
        $contractOk = $task.Principal.UserId -eq 'SYSTEM' -and [string]$task.Principal.RunLevel -eq 'Highest' -and
            @($task.Triggers).Count -gt 0 -and [string]$action.Execute -eq $ExpectedExecutable -and
            [string]$action.Arguments -match $ExpectedArgumentPattern
        if (-not $contractOk) { return $false }
        if (-not $RequireHealthyLastResult) { return $true }

        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
        # 0 = success, 267011 (0x00041303) = "task has not yet run" - both are healthy states.
        $lastResult = [int]$info.LastTaskResult
        if ($lastResult -ne 0 -and $lastResult -ne 267011) {
            Write-StructuredLog -Level HEALTH -Message ("Task {0} last result was {1}." -f $TaskName, $lastResult)
            return $false
        }
        if ([string]$task.State -eq 'Disabled') {
            Write-StructuredLog -Level HEALTH -Message ("Task {0} is disabled." -f $TaskName)
            return $false
        }
        if (-not $info.NextRunTime) {
            Write-StructuredLog -Level HEALTH -Message ("Task {0} has no scheduled next run." -f $TaskName)
            return $false
        }
        return $true
    } catch { return $false }
}

function Invoke-HealthCheck {
    Write-Section "WinServerSetup Health Check"
    $items = @(
        @{ Name = "WinGet"; Enabled = [bool]$Global:Config.winget.installIfMissing; Test = { [bool](Resolve-WingetExecutable) } },
        @{ Name = "Portable folders"; Enabled = [bool]$Global:Config.customFolders.enabled; Test = { (Test-Path ([string]$Global:Config.customFolders.portablePath)) -and (Test-Path ([string]$Global:Config.customFolders.scriptsPath)) } },
        @{ Name = "Downloads compressed folder"; Enabled = [bool]$Global:Config.customFolders.createCompressedInDownloads; Test = { Test-Path (Join-Path (Get-CurrentUserDownloadsFolder) ([string]$Global:Config.customFolders.compressedFolderName)) } },
        @{ Name = "Defender exclusion for compressed"; Enabled = [bool]$Global:Config.customFolders.excludeCompressedFromDefender; Test = { Test-DefenderExclusionPath -Path (Join-Path (Get-CurrentUserDownloadsFolder) ([string]$Global:Config.customFolders.compressedFolderName)) } },
        @{ Name = "PowerShell 7"; Enabled = [bool]$Global:Config.powershell.enabled; Test = { Test-CommandExists "pwsh" } },
        @{ Name = "Windows Terminal"; Enabled = [bool]$Global:Config.windowsTerminal.enabled; Test = { $null -ne (Get-Command wt -ErrorAction SilentlyContinue) } },
        @{ Name = "Brave"; Enabled = (Test-ConfiguredWingetPackage 'Brave.Brave'); Test = { Test-Path "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe" } },
        @{ Name = "Python"; Enabled = (Test-ConfiguredWingetPackage 'Python.Python.3.11'); Test = { Test-CommandExists "python" } },
        @{ Name = "FFmpeg"; Enabled = (Test-ConfiguredWingetPackage 'Gyan.FFmpeg'); Test = { Test-CommandExists "ffmpeg" } },
        @{ Name = "7-Zip"; Enabled = (Test-ConfiguredWingetPackage '7zip.7zip'); Test = { (Test-Path "$env:ProgramFiles\7-Zip\7z.exe") -or (Test-CommandExists "7z") } },
        @{ Name = "V2rayN portable folder"; Enabled = [bool]$Global:Config.v2rayN.enabled; Test = { Test-Path (Join-Path (Join-Path ([string]$Global:Config.v2rayN.installDir) ([string]$Global:Config.v2rayN.finalFolderName)) ([string]$Global:Config.v2rayN.exeName)) } },
        @{ Name = "Everything Service"; Enabled = [bool](@($Global:Config.directInstallers | Where-Object { $_.enabled -and $_.enableService }).Count); Test = { [bool](Get-Service -Name "Everything" -ErrorAction SilentlyContinue) } },
        @{ Name = "Windows Search"; Enabled = [bool]$Global:Config.indexing.enabled; Test = { (Get-Service -Name WSearch -ErrorAction SilentlyContinue).Status -eq "Running" } },
        @{ Name = "RDP Port matches config"; Enabled = [bool]$Global:Config.rdp.enabled; Test = { (Get-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name PortNumber).PortNumber -eq [int]$Global:Config.rdp.newPort -and (Test-TermServiceOwnsTcpPort ([int]$Global:Config.rdp.newPort)) } },
        @{ Name = "EmptyStandbyList Task"; Enabled = [bool]$Global:Config.emptyStandbyList.enabled; Test = { Test-ScheduledTaskContract ([string]$Global:Config.emptyStandbyList.taskName) (Join-Path ([string]$Global:Config.emptyStandbyList.installDir) ([string]$Global:Config.emptyStandbyList.exeName)) ([regex]::Escape([string]$Global:Config.emptyStandbyList.argument)) } },
        # -RequireHealthyLastResult: the blocker is a security control, so "the task exists" is not
        # good enough. A task whose last run failed, that is disabled, or that has no next run
        # scheduled is silently protecting nothing.
        @{ Name = "RDP Blocker Task"; Enabled = [bool]$Global:Config.rdpBruteforceBlocker.enabled; Test = { Test-ScheduledTaskContract -TaskName ([string]$Global:Config.rdpBruteforceBlocker.taskName) -ExpectedExecutable (Join-Path $env:windir "System32\WindowsPowerShell\v1.0\powershell.exe") -ExpectedArgumentPattern ([regex]::Escape($Global:ConfigPath)) -RequireHealthyLastResult } },
        @{ Name = "Show File Extensions"; Enabled = [bool]$Global:Config.appearance.showFileExtensions; Test = { (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name HideFileExt -ErrorAction SilentlyContinue).HideFileExt -eq 0 } },
        @{ Name = "Windows Long Paths"; Enabled = [bool]$Global:Config.filesystem.enableLongPaths; Test = { (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled -eq 1 } },
        @{ Name = "Dark Mode"; Enabled = [bool]$Global:Config.appearance.darkMode; Test = { (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name AppsUseLightTheme -ErrorAction SilentlyContinue).AppsUseLightTheme -eq 0 } },
        @{ Name = "PowerShell 7 default for .ps1"; Enabled = [bool]$Global:Config.powershell.setPs1DefaultApp; Test = { (Get-RegistryDefaultValue -Path "HKCU:\Software\Classes\.ps1") -eq "WinServerSetup.PowerShell7Script" } },
        @{ Name = "7-Zip associations"; Enabled = [bool]$Global:Config.sevenZipDefaults.enabled; Test = { (Get-RegistryDefaultValue -Path "HKCU:\Software\Classes\.zip") -eq "7-Zip.zip" -and (Get-RegistryDefaultValue -Path "HKCU:\Software\Classes\.7z") -eq "7-Zip.7z" -and (Get-RegistryDefaultValue -Path "HKCU:\Software\Classes\.rar") -eq "7-Zip.rar" } }
    )
    $passed = 0; $failed = 0; $skipped = 0
    foreach ($i in $items) {
        if (-not $i.Enabled) { $skipped++; Write-Info "$($i.Name) (disabled; skipped)"; continue }
        try { if (& $i.Test) { $passed++; Write-Ok $i.Name } else { $failed++; Write-Warn $i.Name } }
        catch { $failed++; Write-Warn "$($i.Name): $($_.Exception.Message)" }
    }
    return [pscustomobject]@{ Passed = $passed; Failed = $failed; Skipped = $skipped }
}

# =============================================================================
# FINAL SUMMARY + AUTO REBOOT (items 11, 26)
# =============================================================================
function Get-DeduplicatedAppNames {
    <#
        Menu option 7 followed by option 1 re-runs the install step in one session, so the same
        name was appended repeatedly, and a name could sit in BOTH lists at once. Failures are
        dropped once the same app is confirmed installed, so the summary reflects the FINAL state.
    #>
    param($Installed, $Failed)
    $installedNames = @($Installed | Where-Object { $_ } | Sort-Object -Unique)
    $baseInstalled = @($installedNames | ForEach-Object { ($_ -replace '\s*\(interactive\)$', '').Trim() })
    $failedNames = @($Failed | Where-Object { $_ } | Sort-Object -Unique |
            Where-Object { $baseInstalled -notcontains ($_ -replace '\s*\(interactive\)$', '').Trim() })
    return [pscustomobject]@{ Installed = $installedNames; Failed = $failedNames }
}

function Show-FinalSummary {
    Write-Host ""
    Write-Section "Setup Summary"
    $s = $Global:RunStats
    $elapsed = Format-ActiveTimerElapsed
    $apps = Get-DeduplicatedAppNames -Installed $s.InstalledApps -Failed $s.FailedApps
    $state = if ($s.FailedTasks.Count -gt 0 -or $apps.Failed.Count -gt 0) { 'Failed' }
             elseif ($s.Warnings.Count -gt 0) { 'CompletedWithWarnings' }
             elseif ($s.CompletedTasks.Count -eq 0 -and $s.SkippedTasks.Count -gt 0) { 'Skipped' }
             else { 'Completed' }
    Write-Themed ("Result    : {0}" -f $state) -Kind $(switch ($state) { 'Failed' { 'Error' } 'CompletedWithWarnings' { 'Warning' } 'Skipped' { 'Status' } default { 'Success' } })
    Write-Themed ("Started   : {0}" -f $s.StartedTasks.Count)   -Kind Info
    Write-Themed ("Completed : {0}" -f $s.CompletedTasks.Count) -Kind Success
    Write-Themed ("Failed    : {0}" -f $s.FailedTasks.Count)    -Kind $(if ($s.FailedTasks.Count -gt 0) { 'Error' } else { 'Success' })
    Write-Themed ("Skipped   : {0}" -f $s.SkippedTasks.Count)   -Kind Status
    Write-Themed ("Warnings  : {0}" -f $s.Warnings.Count)       -Kind $(if ($s.Warnings.Count -gt 0) { 'Warning' } else { 'Success' })
    Write-Themed ("Installed apps : {0}" -f ($apps.Installed -join ', ')) -Kind Info
    if ($apps.Failed.Count -gt 0) {
        Write-Themed ("Failed apps    : {0}" -f ($apps.Failed -join ', ')) -Kind Error
    }
    if ($s.RebootRequired) {
        Write-Themed "Reboot required: YES" -Kind Warning
    } else {
        Write-Themed "Reboot required: no"  -Kind Success
    }
    Write-Themed ("Total active elapsed: {0}" -f $elapsed) -Kind Summary
    if ($Global:LogFile)       { Write-Themed ("Console log    : {0}" -f $Global:LogFile)       -Kind SummaryDim }
    if ($Global:StructuredLog) { Write-Themed ("Structured log : {0}" -f $Global:StructuredLog) -Kind SummaryDim }
    # Deliberately emits nothing: Invoke-FullSetup calls this as a bare statement, so any returned
    # value would land in its output stream and corrupt the setup exit code.
    Write-StructuredLog -Level SUMMARY -Message ("State={0}; Started={1}; Completed={2}; Failed={3}; Skipped={4}; Warnings={5}; RebootRequired={6}; ActiveElapsed={7}" -f $state, $s.StartedTasks.Count, $s.CompletedTasks.Count, $s.FailedTasks.Count, $s.SkippedTasks.Count, $s.Warnings.Count, $s.RebootRequired, $elapsed)
}

function Restart-AfterSetup {
    if ($Global:NoReboot) { Write-Info "Auto-reboot skipped: -NoReboot is set."; return }
    if (-not $Global:Config.autoReboot.enabled) { Write-Info "Auto-reboot disabled in config."; return }
    if (-not $Global:RunStats.RebootRequired -and -not (Test-WindowsRebootRequired)) {
        Write-Info "No pending reboot signal detected. Skipping auto-reboot."
        return
    }
    $countdown = [int]$Global:Config.autoReboot.countdownSeconds
    if ($countdown -lt 1) { $countdown = 30 }
    if ($Global:Config.autoReboot.scheduleSfcAfterReboot) { Register-PostRebootSfcTask }

    if ($Global:NoPause) {
        Write-Warn "Rebooting now (silent mode)..."
        Restart-Computer -Force
        return
    }
    Write-Warn ("Rebooting in {0} seconds. Press Ctrl+C to abort." -f $countdown)
    for ($i = $countdown; $i -gt 0; $i--) {
        Write-StatusInPlace ("Reboot in {0} s ... (Ctrl+C to abort)" -f $i)
        Start-Sleep -Seconds 1
    }
    Clear-StatusInPlace
    Write-Warn "Issuing Restart-Computer now."
    Restart-Computer -Force
}

# =============================================================================
# FULL SETUP ORCHESTRATION  (item 2 reboot deferral, item 3 parallel)
# =============================================================================
function Install-Applications {
    Install-WingetPackages
    Install-DirectInstallers
    Install-V2RayN
    Install-LatestPowerShellFromGitHub
    Install-WindowsTerminal
    Set-PowerShell7AsPs1Default
    Install-BraveExtensions
}

function Invoke-FullSetup {
    Write-Section "Running Full WinServerSetup"

    Invoke-RecordedSetupStep -Name "Apply configured account security" -Action { Invoke-ConfiguredAccountSecurity }

    # Quick wins / settings that don't need network. Apply early.
    Invoke-RecordedSetupStep -Name "Apply dark mode" -Action { Set-WindowsDarkMode }
    Invoke-RecordedSetupStep -Name "Show file extensions" -Action { Enable-FileExtensions }
    Invoke-RecordedSetupStep -Name "Enable Windows long paths" -Action { Enable-LongPathSupport }
    Invoke-RecordedSetupStep -Name "Add Persian keyboard layout" -Action { Add-PersianKeyboardLayout }
    Invoke-RecordedSetupStep -Name "Create custom folders and Defender exclusions" -Action { Configure-CustomFoldersAndDefenderExclusions }

    # Now run Windows Update in the foreground (heavy, ordered) while safe app
    # downloads run in a separate helper. Registry/configuration steps stay in
    # their normal config-aware functions to avoid duplicated writes.
    $parallelEnabled = $Global:Config.parallel -and $Global:Config.parallel.enabled
    $maxPar          = if ($parallelEnabled) { [int]$Global:Config.parallel.maxParallel } else { 1 }
    if ($maxPar -lt 1) { $maxPar = 1 }

    $appPrefetch = $null
    if ($parallelEnabled) {
        $appPrefetch = Invoke-RecordedSetupStep -Name "Start app download prefetch" -Action { Start-ApplicationDownloadPrefetch -MaxParallel $maxPar } -PassThru
    }
    Invoke-RecordedSetupStep -Name "Run Windows Update" -Action { Invoke-SystemUpdate }
    if ($parallelEnabled) {
        Invoke-RecordedSetupStep -Name "Wait for app download prefetch" -Action { Wait-ApplicationDownloadPrefetch -Prefetch $appPrefetch }
    }

    # The rest is sequential because of resource contention and ordering.
    Invoke-RecordedSetupStep -Name "Activation from config" -Action { Invoke-ActivationIfConfigured }
    Invoke-RecordedSetupStep -Name "Configure Windows Update bandwidth and QoS" -Action { Configure-WindowsUpdateBandwidthPolicies }
    Invoke-RecordedSetupStep -Name "Install applications" -Action { Install-Applications }
    Invoke-RecordedSetupStep -Name "Configure default apps" -Action { Configure-DefaultApps }
    Invoke-RecordedSetupStep -Name "Set 7-Zip archive associations" -Action { Set-SevenZipAsDefault }
    Invoke-RecordedSetupStep -Name "Configure RDP port and firewall" -Action { Configure-RdpPortAndFirewall }
    Invoke-RecordedSetupStep -Name "Enable Search Indexing" -Action { Enable-SearchIndexing }
    Invoke-RecordedSetupStep -Name "Install runtimes" -Action { Install-Runtimes }
    Invoke-RecordedSetupStep -Name "Install EmptyStandbyList task" -Action { Install-EmptyStandbyList }
    Invoke-RecordedSetupStep -Name "Install RDP brute-force blocker" -Action { Install-RdpBruteforceBlocker }
    Invoke-RecordedSetupStep -Name "Disable configured startup apps" -Action { Disable-ConfiguredStartupApps }
    Invoke-RecordedSetupStep -Name "Remove configured Appx packages" -Action { Remove-ConfiguredAppxPackages }
    Invoke-RecordedSetupStep -Name "Remove configured Windows capabilities" -Action { Remove-ConfiguredWindowsCapabilities }
    Invoke-RecordedSetupStep -Name "Replace Edge taskbar pin with Brave" -Action { Replace-EdgeTaskbarPinWithBrave }
    Invoke-RecordedSetupStep -Name "Add Quick Access pins" -Action { Add-ConfiguredQuickAccessPins }
    Invoke-RecordedSetupStep -Name "Run health check" -Action { $health = Invoke-HealthCheck; if ($health.Failed -gt 0) { throw "Health check reported $($health.Failed) failure(s)." } }
    Invoke-RecordedSetupStep -Name "Clean temp and cache" -Action { Clear-WinServerSetupTempAndCache }

    Show-FinalSummary

    if ($Global:RunStats.FailedTasks.Count -gt 0 -or $Global:RunStats.FailedApps.Count -gt 0) {
        Write-Fail "Full setup completed with failures. Review the summary and logs; reboot was not started."
        return 1
    }
    Write-Ok "Full setup completed successfully."
    Restart-AfterSetup
    return 0
}

function Invoke-FullSetupWithActiveTimer {
    Start-ActiveTimer
    try {
        return (Invoke-FullSetup)
    } finally {
        Stop-ActiveTimer
    }
}

# =============================================================================
# MAIN MENU
# =============================================================================
function Show-MainMenu {
    while ($true) {
        Write-Host ""
        Write-Themed "WinServerSetup Main menu:" -Kind MenuHeader
        Write-Option -Number "1"  -Label "Run full setup"
        Write-Option -Number "2"  -Label "Windows Update (multi-pass)"
        Write-Option -Number "3"  -Label "Activation from config only"
        Write-Option -Number "4"  -Label "Apply dark mode + taskbar"
        Write-Option -Number "5"  -Label "Show file extensions"
        Write-Option -Number "5b" -Label "Enable Windows long paths"
        Write-Option -Number "6"  -Label "Add Persian keyboard layout"
        Write-Option -Number "7"  -Label "Install applications (winget + direct + v2rayN + PS7 + WT)"
        Write-Option -Number "8"  -Label "Install Brave extensions"
        Write-Option -Number "9"  -Label "Configure default browser/player"
        Write-Option -Number "9b" -Label "Set 7-Zip as default for compressed file extensions"
        Write-Option -Number "10" -Label "Configure RDP port and firewall (safe)"
        Write-Option -Number "11" -Label "Enable Search Indexing"
        Write-Option -Number "12" -Label "Install .NET + Visual C++ runtimes (no ASP.NET)"
        Write-Option -Number "13" -Label "Setup Empty Cache task"
        Write-Option -Number "14" -Label "Configure Windows Update bandwidth / QoS"
        Write-Option -Number "15" -Label "Install RDP brute-force blocker (hidden)"
        Write-Option -Number "16" -Label "Disable startup apps (AzureArcSysTray, S9Proxy, etc)"
        Write-Option -Number "17" -Label "Remove Feedback Hub / Appx packages"
        Write-Option -Number "18" -Label "Remove Windows capabilities (AzureArcSetup, etc)"
        Write-Option -Number "19" -Label "Replace Edge taskbar pin with Brave"
        Write-Option -Number "20" -Label "Pin folders to Quick Access"
        Write-Option -Number "21" -Label "Custom folders and Defender exclusions"
        Write-Option -Number "22" -Label "Clean temp and cache"
        Write-Option -Number "23" -Label "Health check"
        Write-Option -Number "24" -Label "Final summary"
        Write-Option -Number "25" -Label "Schedule post-reboot SFC"
        Write-Option -Number "26" -Label "Reboot now (if pending)"
        Write-Option -Number "27" -Label "Rename built-in Administrator (RID 500)"
        Write-Option -Number "28" -Label "Disable local account lockout (machine-wide)"
        Write-Option -Number "29" -Label "Restore built-in Administrator name"
        Write-Option -Number "30" -Label "Restore local account lockout policy"
        Write-Option -Number "0"  -Label "Back / Exit"
        Write-Host ""

        $choice = Read-HostUntimed -Prompt "Select" -DefaultValue "1"
        try {
            switch ($choice) {
                "1"  { Invoke-FullSetupWithActiveTimer | Out-Null;                                                               Pause-IfNeeded }
                "2"  { Invoke-Timed -Name "Windows Update (multi-pass)"             -Action { Invoke-SystemUpdate };                           Pause-IfNeeded }
                "3"  { Invoke-Timed -Name "Activation from config"                  -Action { Invoke-ActivationIfConfigured };                 Pause-IfNeeded }
                "4"  { Invoke-Timed -Name "Apply dark mode"                         -Action { Set-WindowsDarkMode };                           Pause-IfNeeded }
                "5"  { Invoke-Timed -Name "Show file extensions"                    -Action { Enable-FileExtensions };                         Pause-IfNeeded }
                "5b" { Invoke-Timed -Name "Enable Windows long paths"                -Action { Enable-LongPathSupport };                       Pause-IfNeeded }
                "6"  { Invoke-Timed -Name "Add Persian keyboard layout"             -Action { Add-PersianKeyboardLayout };                     Pause-IfNeeded }
                "7"  { Invoke-Timed -Name "Install applications"                    -Action { Install-Applications };                          Pause-IfNeeded }
                "8"  { Invoke-Timed -Name "Install Brave extensions"                -Action { Install-BraveExtensions };                       Pause-IfNeeded }
                "9"  { Invoke-Timed -Name "Configure default browser/player"        -Action { Configure-DefaultApps };                         Pause-IfNeeded }
                "9b" { Invoke-Timed -Name "7-Zip as default for compressed files"   -Action { Set-SevenZipAsDefault };                         Pause-IfNeeded }
                "10" { Invoke-Timed -Name "Configure RDP port and firewall"         -Action { Configure-RdpPortAndFirewall };                  Pause-IfNeeded }
                "11" { Invoke-Timed -Name "Enable Search Indexing"                  -Action { Enable-SearchIndexing };                         Pause-IfNeeded }
                "12" { Invoke-Timed -Name ".NET + Visual C++ runtimes"              -Action { Install-Runtimes };                              Pause-IfNeeded }
                "13" { Invoke-Timed -Name "Empty Cache task"                        -Action { Install-EmptyStandbyList };                      Pause-IfNeeded }
                "14" { Invoke-Timed -Name "Windows Update bandwidth / QoS"          -Action { Configure-WindowsUpdateBandwidthPolicies };      Pause-IfNeeded }
                "15" { Invoke-Timed -Name "RDP brute-force blocker"                 -Action { Install-RdpBruteforceBlocker };                  Pause-IfNeeded }
                "16" { Invoke-Timed -Name "Disable startup apps"                    -Action { Disable-ConfiguredStartupApps };                 Pause-IfNeeded }
                "17" { Invoke-Timed -Name "Remove Appx packages"                    -Action { Remove-ConfiguredAppxPackages };                 Pause-IfNeeded }
                "18" { Invoke-Timed -Name "Remove Windows capabilities"             -Action { Remove-ConfiguredWindowsCapabilities };          Pause-IfNeeded }
                "19" { Invoke-Timed -Name "Replace Edge with Brave on taskbar"      -Action { Replace-EdgeTaskbarPinWithBrave };               Pause-IfNeeded }
                "20" { Invoke-Timed -Name "Pin folders to Quick Access"             -Action { Add-ConfiguredQuickAccessPins };                 Pause-IfNeeded }
                "21" { Invoke-Timed -Name "Custom folders / Defender exclusions"    -Action { Configure-CustomFoldersAndDefenderExclusions }; Pause-IfNeeded }
                "22" { Invoke-Timed -Name "Clean temp and cache"                    -Action { Clear-WinServerSetupTempAndCache };              Pause-IfNeeded }
                "23" { Invoke-Timed -Name "Health check"                            -Action { Invoke-HealthCheck };                            Pause-IfNeeded }
                "24" { Show-FinalSummary; Pause-IfNeeded }
                "25" { Invoke-Timed -Name "Schedule post-reboot SFC"                -Action { Register-PostRebootSfcTask };                    Pause-IfNeeded }
                "26" { Restart-AfterSetup; Pause-IfNeeded }
                # $null = ... : these return structured result objects, which Invoke-Timed would
                # otherwise format-print to the console. Their outcome is already reported by the
                # Write-Ok/Write-Warn calls inside the functions themselves.
                "27" { Invoke-Timed -Name "Rename built-in Administrator" -Action { $null = Rename-BuiltinAdministratorAccount }; Pause-IfNeeded }
                "28" { Invoke-Timed -Name "Disable local account lockout" -Action { $null = Disable-LocalAccountLockoutPolicy -RunGpupdate:([bool]$Global:Config.accountLockout.runGpupdate) }; Pause-IfNeeded }
                "29" { Invoke-Timed -Name "Restore built-in Administrator name" -Action { $null = Restore-BuiltinAdministratorName }; Pause-IfNeeded }
                "30" { Invoke-Timed -Name "Restore local account lockout policy" -Action { $null = Restore-LocalAccountLockoutPolicy }; Pause-IfNeeded }
                "0"  { return }
                default { Write-Warn "Invalid option." }
            }
        } catch {
            Stop-ActiveTimer
            Write-Fail $_.Exception.Message
            Pause-IfNeeded
        }
    }
}

# =============================================================================
# ENTRY POINT
# =============================================================================
try {
    Write-Banner
    Assert-Admin
    Load-Config

    if (Invoke-SelfRelocateIfNeeded) {
        # Relaunched at new path; exit current process cleanly.
        exit 0
    }

    Write-RelocationReadyMarker -Path $RelocationReadyPath -Token $RelocationReadyToken

    Initialize-Environment

    if ($Global:Full) {
        # Take the last emitted value and coerce it: if any step ever leaks output again, the
        # process must still exit with the real status rather than silently reporting success.
        $setupResult = @(Invoke-FullSetupWithActiveTimer)
        $exitCode = if ($setupResult.Count -gt 0) { $setupResult[-1] } else { 1 }
        exit ([int]$exitCode)
    } else {
        Show-MainMenu
    }
}
finally {
    if ($Global:TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch { $null = $_ }
    }
}
