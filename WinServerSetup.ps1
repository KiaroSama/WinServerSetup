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
    MenuNumber   = 'Cyan'
    MenuDefault  = 'Green'
    ExitHint     = 'DarkCyan'
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
    # The menu number carries the same light blue as the header without the bold, so the
    # numbers read as one column and the labels stay plain - the label is the content, the
    # number is only the key you press. The default marker is green because it is the one
    # thing on the line that is a VALUE rather than a label.
    MenuNumber   = "$([char]27)[38;5;117m"
    MenuDefault  = "$([char]27)[92m"
    ExitHint     = "$([char]27)[38;5;32m"
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
. (Join-Path $Global:ProjectRoot "scripts\RdpBlockerTask.ps1")
. (Join-Path $Global:ProjectRoot "scripts\Install.ps1")
. (Join-Path $Global:ProjectRoot "scripts\AppIntegration.ps1")
. (Join-Path $Global:ProjectRoot "scripts\Runtimes.ps1")
. (Join-Path $Global:ProjectRoot "scripts\SystemSettings.ps1")
. (Join-Path $Global:ProjectRoot "scripts\Maintenance.ps1")

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

function Get-ParallelStepBudget {
    # A ceiling, clamped to at least one: a budget of zero would schedule nothing at all.
    param([int]$Requested)
    if ($Requested -lt 1) { return 1 }
    return $Requested
}

function Split-ParallelStepWave {
    <#
        Groups steps into waves that may run concurrently.

        A step declares the RESOURCES it touches. Two steps claiming the same resource never
        share a wave, however large the budget. The concrete case is Explorer: both the dark
        mode and file-extension steps restart it, and running them together races a process
        kill against a process start - the loser leaves the operator with no shell.

        Greedy and order-preserving: a step joins the first wave that has room and no conflict,
        so declared order survives and an unresourced step is never pushed into a wave of its
        own.

        Returns a FLAT array of { Wave = <int>; Step = <step> }, not an array of arrays.
        PowerShell writes a returned collection to the pipeline element by element, so a
        nested result is flattened on the way out and cannot be reassembled; wrapping the
        inner arrays in a unary comma to prevent that throws "Argument types do not match" on
        both hosts. A flat projection with an explicit wave index sidesteps the whole problem.
        Wrap the call in @() - the outer collection is still enumerated on return.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Steps,
        [int]$MaxParallel = 1
    )
    $budget = Get-ParallelStepBudget -Requested $MaxParallel
    $counts = New-Object System.Collections.Generic.List[int]
    $claims = New-Object System.Collections.Generic.List[object]
    $assignments = New-Object System.Collections.Generic.List[object]

    foreach ($step in $Steps) {
        $resources = @(@($step.Resources) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $target = -1
        for ($i = 0; $i -lt $counts.Count; $i++) {
            if ($counts[$i] -ge $budget) { continue }
            $conflict = $false
            foreach ($resource in $resources) { if ($claims[$i].ContainsKey([string]$resource)) { $conflict = $true; break } }
            if ($conflict) { continue }
            $target = $i
            break
        }
        if ($target -lt 0) {
            $counts.Add(0) | Out-Null
            $claims.Add(@{}) | Out-Null
            $target = $counts.Count - 1
        }
        $counts[$target] = $counts[$target] + 1
        foreach ($resource in $resources) { $claims[$target][[string]$resource] = $true }
        $assignments.Add([pscustomobject]@{ Wave = $target; Step = $step }) | Out-Null
    }
    return $assignments.ToArray()
}

function Invoke-ParallelSetupSteps {
    <#
        Runs independent setup steps concurrently and merges their outcomes into
        $Global:RunStats in DECLARED order, so the final summary is byte-identical to what a
        sequential run would have produced. Completion order must not leak into the report.

        Only the CONFIGURATION half of setup is eligible. The install half is deliberately not
        parallelised: Windows Installer serialises every MSI behind a machine-global
        `_MSIExecute` mutex and a second concurrent install returns 1618 rather than waiting,
        so parallel installs would buy nothing and start reporting spurious failures. The
        download half is already parallel, in Start-ApplicationDownloadPrefetch.

        A budget of one is the degenerate sequential case and is executed inline - no runspace,
        no marshalling. That is also the fallback whenever the parallel path cannot start: this
        is new concurrency in a script that also changes RDP ports and administrator accounts,
        and it must never turn a working sequential run into a broken parallel one.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Steps,
        [int]$MaxParallel = 1
    )
    $budget = Get-ParallelStepBudget -Requested $MaxParallel
    $assignments = @(Split-ParallelStepWave -Steps $Steps -MaxParallel $budget)

    foreach ($waveIndex in @($assignments | ForEach-Object { $_.Wave } | Select-Object -Unique | Sort-Object)) {
        $waveSteps = @($assignments | Where-Object { $_.Wave -eq $waveIndex } | ForEach-Object { $_.Step })
        # Ordered slots, filled by whichever worker finishes first, drained in declared order.
        $outcomes = New-Object 'object[]' $waveSteps.Count

        if ($budget -le 1 -or $waveSteps.Count -le 1) {
            for ($i = 0; $i -lt $waveSteps.Count; $i++) {
                $outcomes[$i] = Invoke-IsolatedSetupStep -Step $waveSteps[$i]
            }
        } else {
            $outcomes = @(Invoke-SetupStepWaveConcurrently -Steps $waveSteps)
        }

        foreach ($outcome in $outcomes) {
            if ($null -eq $outcome) { continue }
            $null = $Global:RunStats.StartedTasks.Add([string]$outcome.Name)
            switch ([string]$outcome.Outcome) {
                'Skipped' {
                    $null = $Global:RunStats.SkippedTasks.Add(("{0} ({1})" -f $outcome.Name, $outcome.SkipReason))
                    Write-StructuredLog -Level TASK -Message ("Skipped: {0}; {1}" -f $outcome.Name, $outcome.SkipReason)
                }
                'Failed' {
                    $null = $Global:RunStats.FailedTasks.Add([string]$outcome.Name)
                    Write-StructuredLog -Level ERROR -Message ("Failed: {0}; {1}" -f $outcome.Name, $outcome.Error)
                    Write-Fail ("{0} failed: {1}" -f $outcome.Name, $outcome.Error)
                }
                default {
                    $null = $Global:RunStats.CompletedTasks.Add([string]$outcome.Name)
                    Write-StructuredLog -Level TASK -Message ("Completed: {0}" -f $outcome.Name)
                }
            }
        }
    }
}

function Invoke-IsolatedSetupStep {
    # Runs one step and reports its outcome as data rather than by mutating shared state, so
    # the same shape works inline and across a runspace boundary.
    param([Parameter(Mandatory)][object]$Step)
    $Global:CurrentStepSkipReason = $null
    try {
        $null = & $Step.Action
        if (-not [string]::IsNullOrWhiteSpace($Global:CurrentStepSkipReason)) {
            return [pscustomobject]@{ Name = [string]$Step.Name; Outcome = 'Skipped'; SkipReason = [string]$Global:CurrentStepSkipReason; Error = '' }
        }
        return [pscustomobject]@{ Name = [string]$Step.Name; Outcome = 'Completed'; SkipReason = ''; Error = '' }
    } catch {
        return [pscustomobject]@{ Name = [string]$Step.Name; Outcome = 'Failed'; SkipReason = ''; Error = [string]$_.Exception.Message }
    } finally {
        $Global:CurrentStepSkipReason = $null
    }
}

function Invoke-SetupStepWaveConcurrently {
    <#
        One runspace per step. Each rehydrates the globals and dot-sources the module library,
        because a fresh runspace shares nothing with this session - the modules are the whole
        function library and $Global:Config drives every step's behaviour.

        Anything that goes wrong establishing the pool degrades to inline execution rather than
        failing the wave. Slots are indexed, so results land in declared order regardless of
        which worker finishes first.
    #>
    param([Parameter(Mandatory)][object[]]$Steps)

    $pool = $null
    $running = New-Object System.Collections.Generic.List[object]
    $outcomes = New-Object 'object[]' $Steps.Count
    try {
        $pool = [runspacefactory]::CreateRunspacePool(1, $Steps.Count)
        $pool.Open()
        for ($i = 0; $i -lt $Steps.Count; $i++) {
            $shell = [powershell]::Create()
            $shell.RunspacePool = $pool
            $null = $shell.AddScript({
                    param($ProjectRoot, $ConfigPath, $Config, $StepName, $ActionText)
                    $Global:ProjectRoot = $ProjectRoot
                    $Global:ConfigPath = $ConfigPath
                    $Global:Config = $Config
                    $Global:CurrentStepSkipReason = $null
                    foreach ($module in @('Console', 'Core', 'Download', 'Rdp', 'RdpBlockerTask', 'Install', 'AppIntegration', 'Runtimes', 'SystemSettings', 'Maintenance')) {
                        . (Join-Path $ProjectRoot ("scripts\{0}.ps1" -f $module))
                    }
                    try {
                        $null = & ([scriptblock]::Create($ActionText))
                        if (-not [string]::IsNullOrWhiteSpace($Global:CurrentStepSkipReason)) {
                            return [pscustomobject]@{ Name = $StepName; Outcome = 'Skipped'; SkipReason = [string]$Global:CurrentStepSkipReason; Error = '' }
                        }
                        return [pscustomobject]@{ Name = $StepName; Outcome = 'Completed'; SkipReason = ''; Error = '' }
                    } catch {
                        return [pscustomobject]@{ Name = $StepName; Outcome = 'Failed'; SkipReason = ''; Error = [string]$_.Exception.Message }
                    }
                })
            # The scriptblock is passed as TEXT: a scriptblock object carries its originating
            # session state, which does not exist in the target runspace.
            $null = $shell.AddArgument($Global:ProjectRoot)
            $null = $shell.AddArgument($Global:ConfigPath)
            $null = $shell.AddArgument($Global:Config)
            $null = $shell.AddArgument([string]$Steps[$i].Name)
            $null = $shell.AddArgument([string]$Steps[$i].Action)
            $running.Add([pscustomobject]@{ Index = $i; Shell = $shell; Handle = $shell.BeginInvoke() }) | Out-Null
        }

        foreach ($worker in $running) {
            try {
                $result = @($worker.Shell.EndInvoke($worker.Handle)) | Where-Object { $_ -and $_.PSObject.Properties['Outcome'] } | Select-Object -First 1
                if ($null -eq $result) {
                    $result = [pscustomobject]@{ Name = [string]$Steps[$worker.Index].Name; Outcome = 'Failed'; SkipReason = ''; Error = 'the parallel worker returned no outcome' }
                }
                $outcomes[$worker.Index] = $result
            } catch {
                $outcomes[$worker.Index] = [pscustomobject]@{ Name = [string]$Steps[$worker.Index].Name; Outcome = 'Failed'; SkipReason = ''; Error = [string]$_.Exception.Message }
            } finally {
                try { $worker.Shell.Dispose() } catch { $null = $_ }
            }
        }
    } catch {
        Write-Warn ("Parallel execution could not start ({0}); running this group sequentially." -f $_.Exception.Message)
        for ($i = 0; $i -lt $Steps.Count; $i++) {
            if ($null -eq $outcomes[$i]) { $outcomes[$i] = Invoke-IsolatedSetupStep -Step $Steps[$i] }
        }
    } finally {
        if ($null -ne $pool) { try { $pool.Close(); $pool.Dispose() } catch { $null = $_ } }
    }
    return $outcomes
}

function Invoke-FullSetup {
    Write-Section "Running Full WinServerSetup"

    Invoke-RecordedSetupStep -Name "Apply configured account security" -Action { Invoke-ConfiguredAccountSecurity }

    $parallelEnabled = $Global:Config.parallel -and $Global:Config.parallel.enabled
    $maxPar          = if ($parallelEnabled) { [int]$Global:Config.parallel.maxParallel } else { 1 }
    if ($maxPar -lt 1) { $maxPar = 1 }

    # Quick wins / settings that don't need network. Apply early, and concurrently where the
    # steps genuinely do not touch the same thing.
    #
    # Dark mode and file extensions both declare 'explorer' so they can never overlap: dark
    # mode RESTARTS Explorer, and the file-extension change is only picked up BY that restart,
    # so running them together can land the write after the restart and silently not apply.
    # Defender exclusions are tagged too - Add-MpPreference calls serialise anyway, and letting
    # two run at once buys nothing.
    #
    # Installs are deliberately absent from every parallel group in this file. Windows
    # Installer serialises MSIs behind a machine-global `_MSIExecute` mutex and returns 1618 to
    # the loser rather than queueing it, so parallel installs would save no time and start
    # reporting failures that are not failures. The download half is already parallel, in
    # Start-ApplicationDownloadPrefetch.
    Invoke-ParallelSetupSteps -MaxParallel $maxPar -Steps @(
        @{ Name = "Apply dark mode"; Resources = @('explorer'); Action = { Set-WindowsDarkMode } }
        @{ Name = "Show file extensions"; Resources = @('explorer'); Action = { Enable-FileExtensions } }
        @{ Name = "Enable Windows long paths"; Resources = @(); Action = { Enable-LongPathSupport } }
        @{ Name = "Add Persian keyboard layout"; Resources = @(); Action = { Add-PersianKeyboardLayout } }
        @{ Name = "Create custom folders and Defender exclusions"; Resources = @('defender'); Action = { Configure-CustomFoldersAndDefenderExclusions } }
    )

    # Now run Windows Update in the foreground (heavy, ordered) while safe app
    # downloads run in a separate helper. Registry/configuration steps stay in
    # their normal config-aware functions to avoid duplicated writes.

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
        Write-Option -Number "1"  -Label "Run full setup" -IsDefault
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

        $choice = Read-HostThemed -Prompt "Selection" -DefaultValue "1" -Hint "0=exit"
        try {
            switch ($choice) {
                "1"  { Invoke-FullSetupWithActiveTimer | Out-Null }
                "2"  { Invoke-Timed -Name "Windows Update (multi-pass)"             -Action { Invoke-SystemUpdate } }
                "3"  { Invoke-Timed -Name "Activation from config"                  -Action { Invoke-ActivationIfConfigured } }
                "4"  { Invoke-Timed -Name "Apply dark mode"                         -Action { Set-WindowsDarkMode } }
                "5"  { Invoke-Timed -Name "Show file extensions"                    -Action { Enable-FileExtensions } }
                "5b" { Invoke-Timed -Name "Enable Windows long paths"                -Action { Enable-LongPathSupport } }
                "6"  { Invoke-Timed -Name "Add Persian keyboard layout"             -Action { Add-PersianKeyboardLayout } }
                "7"  { Invoke-Timed -Name "Install applications"                    -Action { Install-Applications } }
                "8"  { Invoke-Timed -Name "Install Brave extensions"                -Action { Install-BraveExtensions } }
                "9"  { Invoke-Timed -Name "Configure default browser/player"        -Action { Configure-DefaultApps } }
                "9b" { Invoke-Timed -Name "7-Zip as default for compressed files"   -Action { Set-SevenZipAsDefault } }
                "10" { Invoke-Timed -Name "Configure RDP port and firewall"         -Action { Configure-RdpPortAndFirewall } }
                "11" { Invoke-Timed -Name "Enable Search Indexing"                  -Action { Enable-SearchIndexing } }
                "12" { Invoke-Timed -Name ".NET + Visual C++ runtimes"              -Action { Install-Runtimes } }
                "13" { Invoke-Timed -Name "Empty Cache task"                        -Action { Install-EmptyStandbyList } }
                "14" { Invoke-Timed -Name "Windows Update bandwidth / QoS"          -Action { Configure-WindowsUpdateBandwidthPolicies } }
                "15" { Invoke-Timed -Name "RDP brute-force blocker"                 -Action { Install-RdpBruteforceBlocker } }
                "16" { Invoke-Timed -Name "Disable startup apps"                    -Action { Disable-ConfiguredStartupApps } }
                "17" { Invoke-Timed -Name "Remove Appx packages"                    -Action { Remove-ConfiguredAppxPackages } }
                "18" { Invoke-Timed -Name "Remove Windows capabilities"             -Action { Remove-ConfiguredWindowsCapabilities } }
                "19" { Invoke-Timed -Name "Replace Edge with Brave on taskbar"      -Action { Replace-EdgeTaskbarPinWithBrave } }
                "20" { Invoke-Timed -Name "Pin folders to Quick Access"             -Action { Add-ConfiguredQuickAccessPins } }
                "21" { Invoke-Timed -Name "Custom folders / Defender exclusions"    -Action { Configure-CustomFoldersAndDefenderExclusions } }
                "22" { Invoke-Timed -Name "Clean temp and cache"                    -Action { Clear-WinServerSetupTempAndCache } }
                "23" { Invoke-Timed -Name "Health check"                            -Action { Invoke-HealthCheck } }
                "24" { Show-FinalSummary }
                "25" { Invoke-Timed -Name "Schedule post-reboot SFC"                -Action { Register-PostRebootSfcTask } }
                "26" { Restart-AfterSetup }
                # $null = ... : these return structured result objects, which Invoke-Timed would
                # otherwise format-print to the console. Their outcome is already reported by the
                # Write-Ok/Write-Warn calls inside the functions themselves.
                "27" { Invoke-Timed -Name "Rename built-in Administrator" -Action { $null = Rename-BuiltinAdministratorAccount } }
                "28" { Invoke-Timed -Name "Disable local account lockout" -Action { $null = Disable-LocalAccountLockoutPolicy -RunGpupdate:([bool]$Global:Config.accountLockout.runGpupdate) } }
                "29" { Invoke-Timed -Name "Restore built-in Administrator name" -Action { $null = Restore-BuiltinAdministratorName } }
                "30" { Invoke-Timed -Name "Restore local account lockout policy" -Action { $null = Restore-LocalAccountLockoutPolicy } }
                "0"  { return }
                default { Write-Warn "Invalid option." }
            }
        } catch {
            Stop-ActiveTimer
            Write-Fail $_.Exception.Message
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
