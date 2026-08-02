# Runtimes.ps1 - the .NET Framework, .NET desktop/core and Visual C++ runtimes, plus the winget
# helpers they share.
#
# Split out of Install.ps1. These are runtimes rather than applications: nothing here registers a
# handler or a shortcut, and M-08 requires that a REQUESTED runtime which fails to install fails
# the run. Dot-sourced by WinServerSetup.ps1; function definitions only, globals read at call time.

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
    # M-08: the verification contract for this runtime is the resulting feature state, and every
    # outcome - enabled, unverifiable, or still disabled - is recorded so none of them can leave
    # the run reporting success.
    if (-not $Global:Config.runtimes.installDotNetFramework35) { Set-StepSkipped "disabled in config"; return }
    $runtimeName = ".NET Framework 3.5"
    Write-Info "Installing .NET Framework 3.5 feature."

    if ($true -eq (Test-DotNetFramework35Enabled)) {
        Register-AppOutcome -Name $runtimeName -Outcome AlreadyCurrent -Detail "the Windows feature is already enabled"
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
        $null = $Global:RunStats.FailedApps.Add($runtimeName)
        return
    }

    if ($restartNeeded) { Set-PendingReboot ".NET Framework 3.5 feature" }

    # Verify the resulting state; a suppressed failure previously printed unconditional success.
    $state = Test-DotNetFramework35Enabled
    if ($true -eq $state) {
        Write-Ok ".NET Framework 3.5 feature is enabled."
        $null = $Global:RunStats.InstalledApps.Add($runtimeName)
    } elseif ($null -eq $state) {
        # M-08: "installed but undetectable" is not a success. Neither feature API could report
        # the state, so there is no evidence the runtime is there and the run must say so.
        Write-Fail ".NET Framework 3.5 install completed but its state could not be verified on this system."
        $null = $Global:RunStats.FailedApps.Add($runtimeName)
    } elseif ($restartNeeded) {
        # The feature genuinely reports EnablePending until the restart that is already tracked
        # in RunStats.RebootRequired, so this is a success whose evidence settles after reboot.
        Write-Warn ".NET Framework 3.5 requires a restart before it reports as enabled."
        $null = $Global:RunStats.InstalledApps.Add($runtimeName)
    } else {
        Write-Fail ".NET Framework 3.5 did not report as enabled after installation."
        $null = $Global:RunStats.FailedApps.Add($runtimeName)
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
    # Declared inside the function on purpose: the test suites extract a single function by AST,
    # so a module-level $script: constant would be undefined there.
    # 533320 is the NDP v4 Release value for .NET Framework 4.8.1, and reading it back is this
    # runtime's independent verification contract (M-08).
    $runtimeName = ".NET Framework 4.8.1"
    $requiredRelease = 533320
    $rv = Get-DotNetFrameworkReleaseValue
    if ($rv -ge $requiredRelease) {
        Register-AppOutcome -Name $runtimeName -Outcome AlreadyCurrent -Detail ("NDP v4 release {0}" -f $rv)
        return
    }
    $url = [string]$Global:Config.runtimes.dotNetFramework481OfflineUrl
    if ([string]::IsNullOrWhiteSpace($url)) { $url = "https://go.microsoft.com/fwlink/?linkid=2203305" }
    $msi = Get-SafeDownloadCacheFilePath -FileName "NDP481-x86-x64-AllOS-ENU.exe"
    # An empty hash means "not pinned", not "refuse": this fwlink resolves to the current 4.8.1
    # package, so blocking on an unset hash would break a default run. When the config sets one,
    # Invoke-DownloadFile enforces it.
    $rt = $Global:Config.runtimes
    $expectedSha256 = if ($rt.PSObject.Properties.Name -contains "dotNetFramework481ExpectedSha256") { [string]$rt.dotNetFramework481ExpectedSha256 } else { "" }
    if (-not (Invoke-DownloadFile -Url $url -Destination $msi -ExpectedSha256 $expectedSha256 `
                -AllowedHosts @('go.microsoft.com', '*.microsoft.com', 'download.visualstudio.microsoft.com', '*.download.visualstudio.microsoft.com'))) {
        # M-08: returning silently here left a requested runtime uninstalled and the run at exit 0.
        Write-Warn "$runtimeName download failed; skipping install."
        $null = $Global:RunStats.FailedApps.Add($runtimeName)
        return
    }
    Write-Info "Installing .NET Framework 4.8.1 (passive, no restart)..."
    try {
        $proc = Start-Process -FilePath $msi -ArgumentList "/passive /norestart" -Wait -PassThru -WindowStyle Hidden
        Write-StructuredLog -Level COMMAND -Message (".NET Framework 4.8.1 installer exit code: {0}" -f $proc.ExitCode)
        # Deliberately NOT routed through Resolve-InstallerExitCode: this installer reports
        # several distinct outcomes (1638 already-installed, 1602 cancelled, 1603 fatal) and
        # each success code gets its own message. Collapsing them into Succeeded/RebootPending
        # would lose that detail for no gain.
        $claimedSuccess = $false
        $rebootPending = $false
        switch ([int]$proc.ExitCode) {
            0 {
                Write-Ok ".NET Framework 4.8.1 install command finished."
                $claimedSuccess = $true
            }
            3010 {
                Write-Ok ".NET Framework 4.8.1 install command finished; reboot required."
                Set-PendingReboot ".NET Framework 4.8.1 installer requested reboot"
                $claimedSuccess = $true
                $rebootPending = $true
            }
            1641 {
                Write-Ok ".NET Framework 4.8.1 installer reported success with reboot required."
                Set-PendingReboot ".NET Framework 4.8.1 installer requested reboot"
                $claimedSuccess = $true
                $rebootPending = $true
            }
            1638 {
                Write-Ok ".NET Framework 4.8.1 or a newer equivalent is already installed."
                $claimedSuccess = $true
            }
            1602 {
                Write-Warn ".NET Framework 4.8.1 install was cancelled by the user or installer UI."
            }
            1603 {
                Write-Warn ".NET Framework 4.8.1 install failed with fatal MSI error 1603."
            }
            default {
                Write-Warn ".NET Framework 4.8.1 installer exited with code $($proc.ExitCode)."
            }
        }

        # M-08: the exit code above is only the installer's own claim. The NDP v4 release value is
        # the independent evidence, and it is read back before the runtime counts as installed.
        # A reboot-pending success is exempt because that evidence only settles after the restart
        # that is already tracked in RunStats.RebootRequired.
        if (-not $claimedSuccess) {
            $null = $Global:RunStats.FailedApps.Add($runtimeName)
        } elseif ($rebootPending) {
            $null = $Global:RunStats.InstalledApps.Add($runtimeName)
        } else {
            $installedRelease = Get-DotNetFrameworkReleaseValue
            if ($installedRelease -ge $requiredRelease) {
                Write-Ok ("$runtimeName verified (release $installedRelease).")
                $null = $Global:RunStats.InstalledApps.Add($runtimeName)
            } else {
                Write-Warn ("$runtimeName reported success but the NDP v4 release value is still $installedRelease (expected at least $requiredRelease).")
                $null = $Global:RunStats.FailedApps.Add($runtimeName)
            }
        }
    } catch {
        Write-Warn ".NET 4.8.1 install failed: $($_.Exception.Message)"
        $null = $Global:RunStats.FailedApps.Add($runtimeName)
    }
}

function Install-WingetRuntimePackage {
    <#
        M-08: the verification contract for one requested runtime, and the single funnel every
        .NET Desktop, .NET Core and Visual C++ runtime passes through.

        The installer's exit code is only its own claim - winget exits 0 for a package that was
        not actually placed on the machine - so the runtime has to be detectable afterwards
        before the run may record it as installed. A non-zero exit code, an exception, and an
        unverifiable install all land in FailedApps, which is what makes the final exit code
        non-zero. Every one of those three used to be a bare Write-Warn.
    #>
    param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$Id)
    try {
        if (Test-WingetPackageInstalled -Id $Id) {
            # Check then update: recording an installed runtime and returning left every machine
            # on the runtime build it was first provisioned with, for good.
            $update = Update-WingetPackageInPlace -Name $Name -Id $Id
            Register-AppOutcome -Name $Name -Outcome $update.Outcome -Detail $update.Detail
            return
        }
        $runtimeResult = Invoke-LoggedCommand -FilePath (Get-WingetExecutable) -Arguments @("install", "--id", $Id, "--exact", "--accept-package-agreements", "--accept-source-agreements", "--source", "winget", "--silent") -DisplayName "winget runtime $Name"
        if ($runtimeResult.ExitCode -ne 0) {
            Write-Warn "$Name install exit code $($runtimeResult.ExitCode)."
            $null = $Global:RunStats.FailedApps.Add($Name)
        } elseif (Test-WingetPackageInstalled -Id $Id) {
            Register-AppOutcome -Name $Name -Outcome Installed
        } else {
            Write-Warn "$Name reported a successful install but is not detectable afterwards."
            $null = $Global:RunStats.FailedApps.Add($Name)
        }
    } catch {
        Write-Warn "${Name}: $($_.Exception.Message)"
        $null = $Global:RunStats.FailedApps.Add($Name)
    }
}

function Install-RequestedWingetRuntime {
    <#
        M-08: WinGet being unavailable used to make each runtime group return before installing
        anything, so a run that installed no runtime at all still exited 0. A runtime this config
        asked for is recorded as failed when it cannot even be attempted, which keeps the whole
        requested set accounted for rather than a subset of it.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Packages)
    if (-not (Ensure-Winget)) {
        foreach ($package in $Packages) {
            Write-Warn ("{0} was not installed: WinGet is unavailable." -f $package.Name)
            $null = $Global:RunStats.FailedApps.Add([string]$package.Name)
        }
        return
    }
    foreach ($package in $Packages) { Install-WingetRuntimePackage -Name $package.Name -Id $package.Id }
}

# The two .NET runtime families differ only in their winget id prefix and display label - same
# config gate, same unsupported/supported split, same version numbers. Kept as one builder so a
# new .NET release is added in one place instead of two that can silently drift apart.
function Install-DotNetRuntimeFamily {
    param(
        [Parameter(Mandatory)][string]$ConfigKey,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$IdPrefix
    )
    if (-not $Global:Config.runtimes.$ConfigKey) { return }
    $packages = @()
    if ($Global:Config.runtimes.includeUnsupportedDotNetVersions) {
        $packages += @(5, 6, 7 | ForEach-Object { @{ Name = "$Label $_ x64 (unsupported)"; Id = "$IdPrefix.$_" } })
    }
    $packages += @(8, 9, 10 | ForEach-Object { @{ Name = "$Label $_ x64"; Id = "$IdPrefix.$_" } })
    Install-RequestedWingetRuntime -Packages $packages
}

function Install-DotNetDesktopRuntimes {
    Install-DotNetRuntimeFamily -ConfigKey 'installDotNetDesktopRuntimes' `
        -Label '.NET Desktop Runtime' -IdPrefix 'Microsoft.DotNet.DesktopRuntime'
}

function Install-DotNetCoreRuntimes {
    Install-DotNetRuntimeFamily -ConfigKey 'installDotNetCoreRuntimes' `
        -Label '.NET Runtime' -IdPrefix 'Microsoft.DotNet.Runtime'
}

# NOTE: ASP.NET Core Runtimes are intentionally NOT installed (item 31). The shipped
# WinServerSetup.config.json carries no installDotNetAspNetCoreRuntimes key at all, so a default
# run never requests them and this is a silent no-op.
function Install-DotNetAspNetCoreRuntimes {
    if ($Global:Config.runtimes.installDotNetAspNetCoreRuntimes) {
        # M-08: this is the one case where config and project policy disagree. The operator asked
        # for a runtime that will not be installed, so the run must fail rather than warn - a
        # warning here is indistinguishable from success and leaves the conflict unresolved.
        Write-Fail "ASP.NET Core Runtime install requested in config but explicitly disabled per project policy (item 31). Remove runtimes.installDotNetAspNetCoreRuntimes from the config to clear this."
        $null = $Global:RunStats.FailedApps.Add("ASP.NET Core Runtime")
    } else {
        Write-Info "ASP.NET Core Runtime install is disabled by project policy (item 31)."
    }
}

function Install-VisualCppRuntimes {
    if (-not $Global:Config.runtimes.installVisualCppRuntimes) { return }
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
    Install-RequestedWingetRuntime -Packages $packages
}

function Install-Runtimes {
    Install-DotNetFramework35
    Install-DotNetFramework4Plus
    Install-DotNetDesktopRuntimes
    Install-DotNetCoreRuntimes
    Install-DotNetAspNetCoreRuntimes   # no-op (policy)
    Install-VisualCppRuntimes
}
