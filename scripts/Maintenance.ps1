# Maintenance.ps1 - Windows Update, activation, the post-reboot SFC task, temp/cache
# cleanup, the health check, the final run summary and the post-setup restart.
#
# Dot-sourced by WinServerSetup.ps1. Contains function definitions only; it reads the
# globals initialized there ($Global:Config, $Global:ProjectRoot, $Global:RunStats) at
# call time, never at load time.

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
