# Console.ps1 - themed terminal output, structured logging, the active timer, recorded
# setup steps and the interactive prompts.
#
# Dot-sourced by WinServerSetup.ps1. Contains function definitions only; it reads the
# globals initialized there ($Global:Config, $Global:RunStats, $Global:NoColor, the
# colour tables) at call time, never at load time.

function Test-ColorSupported {
    if ($Global:NoColor) { return $false }
    if (-not [string]::IsNullOrEmpty($env:NO_COLOR)) { return $false }
    if (-not [string]::IsNullOrEmpty($env:WINSERVERSETUP_NOCOLOR)) { return $false }
    return $true
}

# Pure capability decision, kept separate from host probing so the whole matrix
# stays testable. Two hosts must never see escape sequences:
#   * a redirected stream, which is a file or a pipe where they are noise;
#   * Windows PowerShell 5.1, which copies raw escape bytes into Start-Transcript
#     logs. Both the launcher and the self-relocation relaunch prefer pwsh 7, so
#     5.1 is a fallback host and degrades to the ConsoleColor palette.
function Get-AnsiCapability {
    param(
        [Parameter(Mandatory)][bool]$IsOutputRedirected,
        [Parameter(Mandatory)][int]$PSMajorVersion,
        [bool]$SupportsVirtualTerminal = $false,
        [bool]$IsWindowsTerminal = $false
    )
    if ($IsOutputRedirected) { return $false }
    if ($PSMajorVersion -lt 6) { return $false }
    if ($SupportsVirtualTerminal) { return $true }
    return $IsWindowsTerminal
}

function Test-AnsiSupported {
    if (-not (Test-ColorSupported)) { return $false }
    if ($null -ne $Global:WinServerSetupAnsiSupported) { return $Global:WinServerSetupAnsiSupported }

    $supported = $false
    try {
        $supportsVt = $false
        if ($Host.UI.PSObject.Properties.Match('SupportsVirtualTerminal').Count -gt 0) {
            $supportsVt = [bool]$Host.UI.SupportsVirtualTerminal
        }
        $supported = Get-AnsiCapability `
            -IsOutputRedirected ([Console]::IsOutputRedirected) `
            -PSMajorVersion $PSVersionTable.PSVersion.Major `
            -SupportsVirtualTerminal $supportsVt `
            -IsWindowsTerminal (-not [string]::IsNullOrEmpty($env:WT_SESSION))
    } catch {
        $supported = $false
    }

    $Global:WinServerSetupAnsiSupported = $supported
    return $supported
}

function Write-Themed {
    param(
        [Parameter(Mandatory, Position=0)][AllowEmptyString()][string]$Message,
        [ValidateSet('Success','Error','Warning','Info','Prompt','Default','Section','Status','Summary','SummaryDim','Banner','BannerRule','MenuHeader','StartupLabel','StartupValue','StartupPath','StartupOk','StartupDim','StartupNote','Plain')]
        [string]$Kind = 'Plain',
        [switch]$NoNewline
    )
    if ($Kind -ne 'Plain' -and $Global:WinServerSetupAnsiColors.ContainsKey($Kind) -and (Test-AnsiSupported)) {
        try {
            Write-Host ("{0}{1}{2}[0m" -f $Global:WinServerSetupAnsiColors[$Kind], $Message, [char]27) -NoNewline:$NoNewline
            return
        } catch {
            Write-Host $Message -NoNewline:$NoNewline
            return
        }
    }

    $useColor = (Test-ColorSupported) -and ($Kind -ne 'Plain')
    $color = $null
    if ($useColor) {
        $color = $Global:WinServerSetupColors[$Kind]
        if ([string]::IsNullOrEmpty($color)) { $useColor = $false }
    }
    try {
        if ($useColor) {
            Write-Host $Message -ForegroundColor $color -NoNewline:$NoNewline
        } else {
            Write-Host $Message -NoNewline:$NoNewline
        }
    } catch {
        Write-Host $Message -NoNewline:$NoNewline
    }
}

# Semantic console helpers (also forward to the structured log when active).
function Write-Info {
    param([string]$Message)
    Write-Themed ((("[INFO]").PadRight(10)) + $Message) -Kind Info
    Write-StructuredLog -Level INFO -Message $Message
}
function Write-Ok {
    param([string]$Message)
    Write-Themed ((("[OK]").PadRight(10)) + $Message) -Kind Success
    Write-StructuredLog -Level OK -Message $Message
}
function Write-Warn {
    param([string]$Message)
    Write-Themed ((("[WARN]").PadRight(10)) + $Message) -Kind Warning
    Write-StructuredLog -Level WARN -Message $Message
    $null = $Global:RunStats.Warnings.Add($Message)
}
function Write-Fail {
    param([string]$Message)
    Write-Themed ((("[ERROR]").PadRight(10)) + $Message) -Kind Error
    Write-StructuredLog -Level ERROR -Message $Message
}
function Write-Summary { param([string]$Message) Write-Themed $Message -Kind Summary;           Write-StructuredLog -Level SUMMARY -Message $Message }

# Startup facts print as plain "Label: value" lines. The label carries the
# meaning, so no bracketed state column is drawn, but $State is still forwarded
# to the structured log so machine-readable state names survive.
function Write-StartupLine {
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowEmptyString()][string]$Value = '',
        [ValidateSet('StartupValue','StartupPath','StartupOk','StartupDim')]
        [string]$ValueKind = 'StartupValue',
        [ValidateSet('COPY','RUN','SHELL','LOG','CLEAN','NEXT','SKIP','VERSION','OK','INFO')]
        [string]$State = 'INFO'
    )

    $plainMessage = if ([string]::IsNullOrEmpty($Value)) { $Label } else { "{0}: {1}" -f $Label, $Value }

    if ($State -eq 'LOG') {
        # Print the log line as one solid note-yellow line, not a split
        # label/value pair.
        Write-Themed $plainMessage -Kind StartupNote
    } elseif ([string]::IsNullOrEmpty($Value)) {
        Write-Themed $Label -Kind StartupDim
    } else {
        Write-Themed ($Label + ': ') -Kind StartupLabel -NoNewline
        Write-Themed $Value -Kind $ValueKind
    }
    Write-StructuredLog -Level $State -Message $plainMessage
}

# Hosts without a real console (bare runspaces, some remoting sessions) report no
# window size or throw outright, so fall back to a classic 80 columns. A null or
# non-positive width fails the comparison and takes the same fallback.
function Get-ConsoleWidth {
    param([int]$Fallback = 80)
    try {
        $hostWidth = $Host.UI.RawUI.WindowSize.Width
        if ($hostWidth -gt 0) { return [int]$hostWidth }
    } catch {
        return $Fallback
    }
    return $Fallback
}

# Centered title over a full-width rule, printed once before any other output.
function Write-Banner {
    param([int]$Width = 0)

    $title = "Windows Server Setup"
    if ($Width -le 0) { $Width = Get-ConsoleWidth }
    if ($Width -lt $title.Length) { $Width = $title.Length }

    $padding = [Math]::Max(0, [int](($Width - $title.Length) / 2))
    Write-Host ""
    Write-Themed ((' ' * $padding) + $title) -Kind Banner
    Write-Themed ('=' * $Width) -Kind BannerRule
}

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ""
    Write-Themed ("==== {0} ====" -f $Title) -Kind Section
    Write-StructuredLog -Level SECTION -Message $Title
}

# Menu style: light-blue option number, plain label.
function Write-Option {
    param(
        [Parameter(Mandatory)][string]$Number,
        [Parameter(Mandatory)][string]$Label
    )
    Write-Themed ("{0,3}. " -f $Number) -Kind StartupLabel -NoNewline
    Write-Host $Label
}

# In-place status line (overwrites previous line, no spinner spam).
function Write-StatusInPlace {
    param([Parameter(Mandatory)][string]$Message)
    $line = "`r{0,-100}" -f $Message
    if (Test-ColorSupported) {
        try { Write-Host $line -ForegroundColor $Global:WinServerSetupColors['Status'] -NoNewline; return } catch { $null = $_ }
    }
    Write-Host $line -NoNewline
}

function Clear-StatusInPlace {
    Write-Host ("`r{0,-100}`r" -f " ") -NoNewline
}

# =============================================================================
# STRUCTURED LOGGING (UTF-8)
# =============================================================================
# Two log streams:
#   1) Transcript (Start-Transcript) -> human-readable copy of the console
#   2) Structured log  -> machine-friendly:  [timestamp] [level] [section] message
# Both are written under logs/ in UTF-8.

function Initialize-StructuredLog {
    param([Parameter(Mandatory)][string]$LogDirectory)
    if (-not (Test-Path $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $Global:StructuredLog = Join-Path $LogDirectory ("WinServerSetup-structured-{0}.log" -f $stamp)
    Set-Content -LiteralPath $Global:StructuredLog -Value ("# WinServerSetup {0} structured log started {1}" -f $Global:ScriptVersion, (Get-Date -Format "u")) -Encoding utf8
}

function Write-StructuredLog {
    param(
        [string]$Level = 'INFO',
        [string]$Message = '',
        [string]$Section = ''
    )
    if (-not $Global:StructuredLog) { return }
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = if ($Section) {
        "[{0}] [{1,-7}] [{2}] {3}" -f $ts, $Level, $Section, $Message
    } else {
        "[{0}] [{1,-7}] {2}" -f $ts, $Level, $Message
    }
    try { Add-Content -LiteralPath $Global:StructuredLog -Value $line -Encoding utf8 } catch { $null = $_ }
}

# =============================================================================
# ACTIVE OPERATION TIMER
# =============================================================================
function Initialize-ActiveTimer {
    if (-not $Global:OpStopwatch) { $Global:OpStopwatch = [System.Diagnostics.Stopwatch]::new() }
}
function Start-ActiveTimer    { Initialize-ActiveTimer; $Global:OpStopwatch.Reset(); $Global:OpStopwatch.Start() }
function Resume-ActiveTimer   { if ($Global:OpStopwatch -and -not $Global:OpStopwatch.IsRunning -and $Global:OpStopwatch.Elapsed -gt [TimeSpan]::Zero) { $Global:OpStopwatch.Start() } }
function Stop-ActiveTimer     { if ($Global:OpStopwatch -and $Global:OpStopwatch.IsRunning) { $Global:OpStopwatch.Stop() } }
function Get-ActiveTimerElapsed { if (-not $Global:OpStopwatch) { return [TimeSpan]::Zero }; return $Global:OpStopwatch.Elapsed }
function Format-ActiveTimerElapsed {
    $ts = Get-ActiveTimerElapsed
    $hours = [int][Math]::Floor($ts.TotalHours)
    return ('{0:00}:{1:00}:{2:00}' -f $hours, $ts.Minutes, $ts.Seconds)
}
function Write-ActiveTimerSummary {
    param([string]$Name = "")
    $elapsed = Format-ActiveTimerElapsed
    if ([string]::IsNullOrWhiteSpace($Name)) {
        Write-Summary ("Total time elapsed: {0}" -f $elapsed)
    } else {
        Write-Summary ("Total time elapsed: {0}  ({1})" -f $elapsed, $Name)
    }
    Write-Themed "(active operation time only; user prompts and menu waits are excluded)" -Kind SummaryDim
}

function Invoke-Timed {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Action)
    $null = $Global:RunStats.StartedTasks.Add($Name)
    Start-ActiveTimer
    try {
        & $Action
        $null = $Global:RunStats.CompletedTasks.Add($Name)
    } catch {
        $null = $Global:RunStats.FailedTasks.Add($Name)
        Write-Fail ("Task '{0}' failed: {1}" -f $Name, $_.Exception.Message)
        throw
    } finally {
        Stop-ActiveTimer
        Write-Host ""
        Write-ActiveTimerSummary -Name $Name
    }
}

# A step's action calls this to report that it did nothing because the feature is switched off.
# Without it, a config-disabled step was recorded as Completed and RunStats.SkippedTasks - which
# is shown in the final summary - stayed empty for the whole run.
function Set-StepSkipped {
    param([Parameter(Mandatory)][string]$Reason)
    $Global:CurrentStepSkipReason = $Reason
}

function Invoke-RecordedSetupStep {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [switch]$PassThru
    )
    $null = $Global:RunStats.StartedTasks.Add($Name)
    Write-StructuredLog -Level TASK -Message ("Started: {0}" -f $Name)
    $Global:CurrentStepSkipReason = $null
    try {
        $result = & $Action
        if ([string]::IsNullOrWhiteSpace($Global:CurrentStepSkipReason)) {
            $null = $Global:RunStats.CompletedTasks.Add($Name)
            Write-StructuredLog -Level TASK -Message ("Completed: {0}" -f $Name)
        } else {
            $null = $Global:RunStats.SkippedTasks.Add(("{0} ({1})" -f $Name, $Global:CurrentStepSkipReason))
            Write-StructuredLog -Level TASK -Message ("Skipped: {0}; {1}" -f $Name, $Global:CurrentStepSkipReason)
        }
        if ($PassThru) { return $result }
    } catch {
        $null = $Global:RunStats.FailedTasks.Add($Name)
        Write-StructuredLog -Level ERROR -Message ("Failed: {0}; {1}" -f $Name, $_.Exception.Message)
        Write-Fail "$Name failed: $($_.Exception.Message)"
        # A bare return emits nothing. 'return $null' would write $null to the output stream, and
        # because Invoke-FullSetup calls this as a bare statement ~24 times, each failure appended
        # a $null to its output. Its 'return 1' then became the last element of an array, and
        # 'exit @($null,1)' evaluates to 0 - so a failed setup reported success.
        return
    } finally {
        $Global:CurrentStepSkipReason = $null
    }
}

# =============================================================================
# PRESS-ANY-KEY PROMPTS
# =============================================================================
# Uses [Console]::ReadKey($true) where supported (true any-key). Falls back to
# Read-Host (Enter-only) for non-interactive hosts. Both forms suspend the
# active timer so user-wait time is never counted as work time.

function Read-AnyKeyThemed {
    param([string]$Prompt = "Press any key to continue...")
    $wasRunning = ($Global:OpStopwatch -and $Global:OpStopwatch.IsRunning)
    Stop-ActiveTimer
    try {
        Write-Themed $Prompt -Kind Prompt
        try {
            if ($Host.UI.RawUI -and [Console]::IsInputRedirected -eq $false) {
                [void][Console]::ReadKey($true)
                return
            }
        } catch { $null = $_ }
        # Fallback for hosts without RawUI:
        Read-Host | Out-Null
    } finally {
        if ($wasRunning) { Resume-ActiveTimer }
    }
}

function Read-HostThemed {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$DefaultValue = ""
    )
    $wasRunning = ($Global:OpStopwatch -and $Global:OpStopwatch.IsRunning)
    Stop-ActiveTimer
    try {
        Write-Themed ($Prompt + ": ") -Kind Prompt -NoNewline
        if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
            Write-Themed ("[{0}]" -f $DefaultValue) -Kind Default -NoNewline
            Write-Host " " -NoNewline
        }
        $value = Read-Host
        if ([string]::IsNullOrWhiteSpace($value) -and -not [string]::IsNullOrWhiteSpace($DefaultValue)) {
            return $DefaultValue
        }
        return $value
    } finally {
        if ($wasRunning) { Resume-ActiveTimer }
    }
}

function Pause-IfNeeded {
    if (-not $Global:NoPause) {
        Write-Host ""
        Read-AnyKeyThemed
    }
}
