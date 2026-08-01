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
