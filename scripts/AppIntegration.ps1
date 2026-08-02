# AppIntegration.ps1 - applications that are installed AND then wired into the shell as a
# default handler or policy: PowerShell 7, Windows Terminal and the .ps1 open handler, Brave
# and its extension force-list, 7-Zip archive associations, and the default-apps import.
#
# Split out of Install.ps1, which kept the installation machinery itself. Dot-sourced by
# WinServerSetup.ps1; function definitions only, globals read at call time.

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
    # M-08: PowerShell 7 is enabled in the shipped config, so every path that leaves it
    # uninstalled has to be recorded. Returning silently reported success for the whole run.
    $repo = [string]$s.githubRepo; if ([string]::IsNullOrWhiteSpace($repo)) { $repo = "PowerShell/PowerShell" }
    Write-Info "Querying latest PowerShell release ($repo)..."
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -UseBasicParsing -Headers @{ 'User-Agent' = 'WinServerSetup' }
    } catch {
        Write-Warn "GitHub query failed: $($_.Exception.Message)"
        $null = $Global:RunStats.FailedApps.Add("PowerShell 7")
        return
    }

    $latestVer = $null
    try { $latestVer = [version](([string]$release.tag_name).TrimStart("v")) } catch { Write-StructuredLog -Level WARN -Message ("Could not parse PowerShell release tag '{0}': {1}" -f $release.tag_name, $_.Exception.Message) }
    $currentVer = Get-PowerShellCoreVersion
    if ($currentVer -and $latestVer -and -not $s.forceInstall -and $currentVer -ge $latestVer) {
        Register-AppOutcome -Name "PowerShell 7" -Outcome AlreadyCurrent -Detail ("installed {0}, GitHub latest {1}" -f $currentVer, $latestVer)
        return
    }

    $regex = [string]$s.assetNameRegex; if ([string]::IsNullOrWhiteSpace($regex)) { $regex = "^PowerShell-.*-win-x64\.msi$" }
    $asset = $release.assets | Where-Object { $_.name -match $regex } | Select-Object -First 1
    if (-not $asset) {
        Write-Warn "No PowerShell asset matched regex $regex"
        $null = $Global:RunStats.FailedApps.Add("PowerShell 7")
        return
    }

    $msi = Get-SafeDownloadCacheFilePath -FileName ([string]$asset.name)
    # An empty hash means "not pinned", not "refuse": this URL resolves to whatever the latest
    # GitHub release is, so blocking on an unset hash would break a default run. When the config
    # sets one, Invoke-DownloadFile enforces it.
    $expectedSha256 = if ($s.PSObject.Properties.Name -contains "expectedSha256") { [string]$s.expectedSha256 } else { "" }
    if (-not (Invoke-DownloadFile -Url $asset.browser_download_url -Destination $msi -ExpectedSha256 $expectedSha256 `
                -AllowedHosts @('github.com', '*.github.com', 'objects.githubusercontent.com', '*.githubusercontent.com'))) {
        Write-Warn "PowerShell 7 download failed; skipping install."
        $null = $Global:RunStats.FailedApps.Add("PowerShell 7")
        return
    }

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
            if ($msiResult.RebootPending) { Set-PendingReboot "PowerShell 7 installer requested reboot" }
            # M-08: pwsh.exe on disk is the independent evidence; the MSI exit code is not.
            $installedPwsh = Get-PowerShell7ExePath
            if ($installedPwsh) {
                # The MSI is a major upgrade of the same product, so an existing PowerShell 7 is
                # replaced where it already sits rather than installed alongside itself.
                if ($currentVer) { Register-AppOutcome -Name "PowerShell 7" -Outcome Updated -Detail ([string]$installedPwsh) }
                else { Register-AppOutcome -Name "PowerShell 7" -Outcome Installed -Detail ([string]$installedPwsh) }
            } else {
                Write-Warn "PowerShell installer reported success but pwsh.exe was not found afterwards."
                $null = $Global:RunStats.FailedApps.Add("PowerShell 7")
            }
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
    # M-08: Windows Terminal is enabled in the shipped config. Every path that leaves it
    # uninstalled - no WinGet, a failing install, or wt.exe missing afterwards - is recorded, so
    # none of them can leave the run reporting success.
    $s = $Global:Config.windowsTerminal
    if (-not $s -or -not $s.enabled) { return }
    if (-not (Ensure-Winget)) {
        Write-Warn "Windows Terminal was not installed: WinGet is unavailable."
        $null = $Global:RunStats.FailedApps.Add("Windows Terminal")
        return
    }

    $pkg = [string]$s.packageId; if ([string]::IsNullOrWhiteSpace($pkg)) { $pkg = "Microsoft.WindowsTerminal" }
    # Carried to the single recording point below rather than recorded here: wt.exe on disk is
    # this component's verification contract, so the outcome is only booked once that check ran.
    $outcome = 'Installed'
    $outcomeDetail = ""
    if (Test-WingetPackageInstalled -Id $pkg) {
        Write-Ok "Windows Terminal is already installed."
        $update = Update-WingetPackageInPlace -Name "Windows Terminal" -Id $pkg
        $outcome = $update.Outcome
        $outcomeDetail = $update.Detail
    } else {
        $wingetInstallArgs = @("install", "--id", $pkg, "--exact", "--accept-package-agreements", "--accept-source-agreements", "--source", "winget")
        if ($s.interactiveInstaller) { $wingetInstallArgs += "--interactive" } else { $wingetInstallArgs += "--silent" }
        try {
            $terminalResult = Invoke-LoggedCommand -FilePath (Get-WingetExecutable) -Arguments $wingetInstallArgs -DisplayName "winget install Windows Terminal"
            if ($terminalResult.ExitCode -eq 0) { Write-Ok "Windows Terminal install completed." }
            else {
                Write-Warn "Windows Terminal install exited with code $($terminalResult.ExitCode)."
                $null = $Global:RunStats.FailedApps.Add("Windows Terminal")
                return
            }
        }
        catch {
            Write-Fail "Windows Terminal install failed: $($_.Exception.Message)"
            $null = $Global:RunStats.FailedApps.Add("Windows Terminal")
            return
        }
    }

    # wt.exe is the independent evidence: winget reports success for a package that the machine
    # cannot actually run (Server SKUs without the Store, a blocked App Execution Alias).
    if (-not (Test-WindowsTerminalInstalled)) {
        Write-Warn "Windows Terminal executable was not found; default terminal/profile settings were skipped."
        $null = $Global:RunStats.FailedApps.Add("Windows Terminal")
        return
    }
    Register-AppOutcome -Name "Windows Terminal" -Outcome $outcome -Detail $outcomeDetail
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
