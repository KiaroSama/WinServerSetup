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
    # Every themed console line is redacted here rather than at the ~400 call sites, so a secret
    # cannot reach the screen (or the transcript, which copies it) through a message some future
    # caller builds. The structured log is guarded the same way, in Write-StructuredLog.
    $Message = Protect-SensitiveLogText $Message
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
    # Third console sink: it bypasses Write-Themed, and download progress carries URLs.
    $line = "`r{0,-100}" -f (Protect-SensitiveLogText $Message)
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
#   2) Structured log  -> [YYYY-MM-DD HH:mm:ss UTC] [LEVEL] [COMPONENT] message key=value
# Both are written under logs/ in UTF-8. The console stays short and scannable; the file log is
# the diagnostic record and keeps the detail, including DEBUG.

<#
    The one place a secret can be removed from a message.

    Every console line goes through Write-Themed or Write-StatusInPlace and every file line goes
    through Write-StructuredLog, so scrubbing here covers all of them - including any level, any
    caller, and any future verbose mode, none of which get their own write path. The tracked
    config ships the activation key empty and only the ignored local override may carry one, but
    a key can still be built into a message anywhere, which is what this catches.
#>
function Protect-SensitiveLogText {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $safe = $Text
    # A Windows product key in its documented 5x5 shape.
    $safe = [regex]::Replace($safe, '(?i)\b[A-Z0-9]{5}(-[A-Z0-9]{5}){4}\b', '[REDACTED-KEY]')
    # user:password in a URL authority.
    $safe = [regex]::Replace($safe, '(?i)://[^/@\s]+:[^/@\s]+@', '://***:***@')
    # Token-bearing query parameters.
    $safe = [regex]::Replace($safe, '(?i)([?&](?:token|key|sig|signature|password|passwd|pwd|secret|access[_-]?key|api[_-]?key|auth|credential)=)[^&\s]*', '${1}***')
    # key=value and key: value pairs in free text, and the same shape inside a connection string.
    $safe = [regex]::Replace($safe, '(?i)\b(password|passwd|pwd|secret|token|apikey|api[_-]key|accesskey|access[_-]key|productkey|product[_-]key|credential|connectionstring)\b(\s*[:=]\s*)("[^"]*"|''[^'']*''|[^\s;,)]+)', '${1}${2}***')
    # PowerShell-style secret parameters, which is the shape a captured command line arrives in.
    $safe = [regex]::Replace($safe, '(?i)(\s-{1,2}\w*(?:token|password|passwd|pwd|secret|key|credential))(\s+|:)("[^"]*"|''[^'']*''|\S+)', '${1}${2}***')
    # Authorization headers. The 20-character floor keeps ordinary prose ("Basic authentication")
    # out of it while still covering every real token shape.
    $safe = [regex]::Replace($safe, '(?i)\b(bearer|basic)\s+([A-Za-z0-9\-\._~\+/]{20,}={0,2})', '${1} ***')
    return $safe
}

<#
    Derives the [COMPONENT] column from the call stack, so all ~200 existing call sites gain
    attribution without being edited.

    The logging module's own wrappers are skipped BY NAME. Skipping by file would break the
    moment one of them moves between modules, and skipping nothing would attribute every
    Write-Info line to Console.ps1 - which tells an operator nothing about what actually ran.
#>
function Get-LogComponent {
    # The two step recorders are skipped as well: a TASK line already names the step, so pointing
    # at the recorder says nothing, while the frame behind it is the orchestration line that
    # declared the step.
    $wrappers = @(
        'Get-LogComponent', 'Write-StructuredLog', 'Protect-SensitiveLogText',
        'Write-Info', 'Write-Ok', 'Write-Warn', 'Write-Fail', 'Write-Summary',
        'Write-Section', 'Write-StartupLine', 'Write-Themed', 'Write-StatusInPlace',
        'Invoke-RecordedSetupStep', 'Invoke-Timed'
    )
    try {
        foreach ($frame in @(Get-PSCallStack)) {
            if ($wrappers -contains $frame.FunctionName) { continue }
            if (-not [string]::IsNullOrWhiteSpace($frame.ScriptName)) {
                return ("{0}:{1}" -f [System.IO.Path]::GetFileNameWithoutExtension($frame.ScriptName), $frame.ScriptLineNumber)
            }
            if ((-not [string]::IsNullOrWhiteSpace($frame.FunctionName)) -and ($frame.FunctionName -ne '<ScriptBlock>')) {
                return $frame.FunctionName
            }
        }
    } catch { $null = $_ }
    return 'SETUP'
}

<#
    Opens this run's log and records everything needed to reconstruct the run later: version,
    execution id, host and runtime, OS, elevation, resolved paths, the command line, and the
    effective configuration.

    Failure degrades to the console. The path is only recorded once the file really exists, so a
    log that could not be opened is never reported as if it had been.
#>
function Initialize-StructuredLog {
    param([Parameter(Mandatory)][string]$LogDirectory)

    $Global:StructuredLog = $null
    $Global:StructuredLogCompleted = $false
    $Global:StructuredLogStartedUtc = [DateTime]::UtcNow
    if ([string]::IsNullOrWhiteSpace([string]$Global:ExecutionId)) {
        $Global:ExecutionId = [guid]::NewGuid().ToString('N').Substring(0, 12)
    }

    try {
        if (-not (Test-Path -LiteralPath $LogDirectory)) {
            New-Item -ItemType Directory -Path $LogDirectory -Force -ErrorAction Stop | Out-Null
        }
        # CreateNew is atomic and never truncates, so a previous run's log cannot be overwritten -
        # not by a same-second restart, and not by a second process racing this one.
        $stamp = $Global:StructuredLogStartedUtc.ToString('yyyy-MM-dd_HH-mm-ss')
        $attempt = 0
        while ($true) {
            $candidate = if ($attempt -eq 0) {
                Join-Path $LogDirectory ("WinServerSetup_{0}_UTC.log" -f $stamp)
            } else {
                Join-Path $LogDirectory ("WinServerSetup_{0}_UTC-{1}.log" -f $stamp, $attempt)
            }
            try {
                $stream = [System.IO.File]::Open($candidate, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
                $stream.Dispose()
                $Global:StructuredLog = $candidate
                break
            } catch [System.IO.IOException] {
                # DirectoryNotFoundException is an IOException too, so only an existing file is
                # treated as a name collision; anything else is a real failure.
                if ((-not (Test-Path -LiteralPath $candidate)) -or ($attempt -ge 500)) { throw }
                $attempt++
            }
        }
    } catch {
        $Global:StructuredLog = $null
        Write-Warn ("File logging is unavailable; continuing with console output only. Log directory '{0}': {1}" -f $LogDirectory, $_.Exception.Message)
        return
    }

    $elevated = $false
    try {
        $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $elevated = $false }

    # Registry rather than CIM: no WMI dependency, and it reports the real build on both hosts.
    $osName = ''
    $osBuild = ''
    try {
        $currentVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $osName = [string]$currentVersion.ProductName
        $osBuild = ("{0}.{1} {2}" -f $currentVersion.CurrentBuild, $currentVersion.UBR, $currentVersion.DisplayVersion).Trim()
    } catch { $null = $_ }
    if ([string]::IsNullOrWhiteSpace($osName)) { $osName = [string][Environment]::OSVersion.VersionString }
    if ([string]::IsNullOrWhiteSpace($osBuild)) { $osBuild = [string][Environment]::OSVersion.Version }

    Write-StructuredLog -Level INFO -Section 'SETUP' -Message ("Run started; version={0}; executionId={1}; pid={2}; logFile={3}" -f `
            $Global:ScriptVersion, $Global:ExecutionId, $PID, $Global:StructuredLog)
    Write-StructuredLog -Level INFO -Section 'SETUP' -Message ("host=PowerShell {0}; edition={1}; clr={2}; culture={3}" -f `
            $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, [Environment]::Version, (Get-Culture).Name)
    Write-StructuredLog -Level INFO -Section 'SETUP' -Message ("os={0}; build={1}; arch={2}; computer={3}; user={4}\{5}; elevated={6}" -f `
            $osName, $osBuild, $env:PROCESSOR_ARCHITECTURE, $env:COMPUTERNAME, $env:USERDOMAIN, $env:USERNAME, $elevated)
    Write-StructuredLog -Level INFO -Section 'SETUP' -Message ("projectRoot={0}; configPath={1}; logDirectory={2}; workingDirectory={3}" -f `
            $Global:ProjectRoot, $Global:ConfigPath, $LogDirectory, (Get-Location).Path)
    Write-StructuredLog -Level INFO -Section 'SETUP' -Message ("commandLine={0}" -f [Environment]::CommandLine)

    # The effective configuration is what actually drove the run, so it is worth more than the
    # file on disk. Masked by PROPERTY NAME as well: a secret that does not look like one still
    # must not be written, and the value-shape pass cannot know which key a value came from.
    $configText = '(not loaded)'
    try {
        if ($Global:Config) {
            $configText = [string]($Global:Config | ConvertTo-Json -Depth 6 -Compress)
            $configText = [regex]::Replace($configText, '(?i)"([^"]*(?:key|password|secret|token|credential)[^"]*)"\s*:\s*"[^"]*"', '"${1}":"***"')
            if ($configText.Length -gt 4000) { $configText = $configText.Substring(0, 4000) + ' ...(truncated)' }
        }
    } catch { $configText = ("(unreadable: {0})" -f $_.Exception.Message) }
    Write-StructuredLog -Level INFO -Section 'SETUP' -Message ("config={0}" -f $configText)

    # The entry point's own finally cannot cover every exit path, and it lives in a file this
    # module does not own, so the closing record hangs off the engine's exiting event instead.
    # Registered once per process; the handler is idempotent.
    if (-not $Global:StructuredLogExitHook) {
        try {
            $Global:StructuredLogExitHook = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Complete-StructuredLog }
        } catch { $null = $_ }
    }
}

# Closes the log with the run's outcome. A log that simply stops cannot be told apart from a
# crash, which is exactly the ambiguity this removes.
function Complete-StructuredLog {
    if (-not $Global:StructuredLog) { return }
    if ($Global:StructuredLogCompleted) { return }
    $Global:StructuredLogCompleted = $true

    $elapsedSeconds = 0
    if ($Global:StructuredLogStartedUtc) {
        $elapsedSeconds = [Math]::Round(([DateTime]::UtcNow - $Global:StructuredLogStartedUtc).TotalSeconds, 1)
    }
    $outcome = 'no run statistics were recorded'
    try {
        if ($Global:RunStats) {
            $outcome = "started={0}; completed={1}; failed={2}; skipped={3}; warnings={4}; installedApps={5}; failedApps={6}; rebootRequired={7}" -f `
                $Global:RunStats.StartedTasks.Count, $Global:RunStats.CompletedTasks.Count,
                $Global:RunStats.FailedTasks.Count, $Global:RunStats.SkippedTasks.Count,
                $Global:RunStats.Warnings.Count, $Global:RunStats.InstalledApps.Count,
                $Global:RunStats.FailedApps.Count, $Global:RunStats.RebootRequired
        }
    } catch { $outcome = ("run statistics were unreadable: {0}" -f $_.Exception.Message) }

    Write-StructuredLog -Level SUMMARY -Section 'SETUP' -Message ("Run ended; elapsedSeconds={0}; {1}" -f $elapsedSeconds, $outcome)
}

function Write-StructuredLog {
    param(
        [string]$Level = 'INFO',
        [string]$Message = '',
        [string]$Section = ''
    )
    if (-not $Global:StructuredLog) { return }
    # $Section keeps its position and meaning; it is now simply an explicit component, used where
    # the derived one would be wrong (the run header, the closing record).
    $component = if ([string]::IsNullOrWhiteSpace($Section)) { Get-LogComponent } else { $Section }
    # Flattened centrally so a multi-line value - a stack trace, an installer's output - cannot
    # produce a line no parser and no grep can read.
    $safeMessage = [regex]::Replace((Protect-SensitiveLogText $Message), '\r?\n', ' | ')
    $line = "[{0} UTC] [{1,-8}] [{2}] {3}" -f ([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')), $Level, $component, $safeMessage

    # Serialised with the same session-local mutex pattern the prefetch child uses, so two
    # writers cannot interleave a half-written line or lose one to a sharing violation.
    $mutex = New-Object System.Threading.Mutex($false, 'Local\WinServerSetup-StructuredLog')
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        Add-Content -LiteralPath $Global:StructuredLog -Value $line -Encoding utf8
    } catch {
        $null = $_
    } finally {
        if ($acquired) { try { $mutex.ReleaseMutex() } catch { $null = $_ } }
        $mutex.Dispose()
    }
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
    Write-StructuredLog -Level TASK -Message ("Started: {0}" -f $Name)
    $stepWatch = [System.Diagnostics.Stopwatch]::StartNew()
    Start-ActiveTimer
    try {
        & $Action
        $stepWatch.Stop()
        $null = $Global:RunStats.CompletedTasks.Add($Name)
        Write-StructuredLog -Level TASK -Message ("Completed: {0}; durationMs={1}" -f $Name, $stepWatch.ElapsedMilliseconds)
    } catch {
        $stepWatch.Stop()
        $null = $Global:RunStats.FailedTasks.Add($Name)
        $failure = $_
        $stack = @($failure.ScriptStackTrace, $failure.Exception.StackTrace) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($stack)) { $stack = '(unavailable)' }
        Write-StructuredLog -Level ERROR -Message ("Failed: {0}; durationMs={1}; type={2}; errorId={3}; message={4}" -f `
                $Name, $stepWatch.ElapsedMilliseconds, $failure.Exception.GetType().FullName, $failure.FullyQualifiedErrorId, $failure.Exception.Message)
        Write-StructuredLog -Level ERROR -Message ("Failed: {0}; stack={1}" -f $Name, $stack)
        Write-Fail ("Task '{0}' failed: {1}" -f $Name, $failure.Exception.Message)
        throw
    } finally {
        $stepWatch.Stop()
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
    $stepWatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $result = & $Action
        $stepWatch.Stop()
        if ([string]::IsNullOrWhiteSpace($Global:CurrentStepSkipReason)) {
            $null = $Global:RunStats.CompletedTasks.Add($Name)
            Write-StructuredLog -Level TASK -Message ("Completed: {0}; durationMs={1}" -f $Name, $stepWatch.ElapsedMilliseconds)
        } else {
            $null = $Global:RunStats.SkippedTasks.Add(("{0} ({1})" -f $Name, $Global:CurrentStepSkipReason))
            Write-StructuredLog -Level TASK -Message ("Skipped: {0}; {1}; durationMs={2}" -f $Name, $Global:CurrentStepSkipReason, $stepWatch.ElapsedMilliseconds)
        }
        if ($PassThru) { return $result }
    } catch {
        $stepWatch.Stop()
        $null = $Global:RunStats.FailedTasks.Add($Name)
        # The failure detail is formatted inline rather than in a shared helper because
        # tests\RuntimeInstallOutcome.Tests.ps1 lifts this one function out by AST: a call to
        # anything else defined in this module would be unresolvable there.
        $failure = $_
        $stack = @($failure.ScriptStackTrace, $failure.Exception.StackTrace) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($stack)) { $stack = '(unavailable)' }
        Write-StructuredLog -Level ERROR -Message ("Failed: {0}; durationMs={1}; type={2}; errorId={3}; message={4}" -f `
                $Name, $stepWatch.ElapsedMilliseconds, $failure.Exception.GetType().FullName, $failure.FullyQualifiedErrorId, $failure.Exception.Message)
        Write-StructuredLog -Level ERROR -Message ("Failed: {0}; stack={1}" -f $Name, $stack)
        Write-Fail "$Name failed: $($failure.Exception.Message)"
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
