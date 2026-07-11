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
    [switch]$NoRelocate
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
        try { Write-Host $line -ForegroundColor $Global:WinServerSetupColors['Status'] -NoNewline; return } catch { }
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
    try { Add-Content -LiteralPath $Global:StructuredLog -Value $line -Encoding utf8 } catch { }
}

# =============================================================================
# ACTIVE OPERATION TIMER
# =============================================================================
function Initialize-ActiveTimer {
    if (-not $Global:OpStopwatch) { $Global:OpStopwatch = [System.Diagnostics.Stopwatch]::new() }
}
function Start-ActiveTimer    { Initialize-ActiveTimer; $Global:OpStopwatch.Reset(); $Global:OpStopwatch.Start() }
function Suspend-ActiveTimer  { if ($Global:OpStopwatch -and $Global:OpStopwatch.IsRunning) { $Global:OpStopwatch.Stop() } }
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

function Invoke-RecordedSetupStep {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [switch]$PassThru
    )
    $null = $Global:RunStats.StartedTasks.Add($Name)
    Write-StructuredLog -Level TASK -Message ("Started: {0}" -f $Name)
    try {
        $result = & $Action
        $null = $Global:RunStats.CompletedTasks.Add($Name)
        Write-StructuredLog -Level TASK -Message ("Completed: {0}" -f $Name)
        if ($PassThru) { return $result }
    } catch {
        $null = $Global:RunStats.FailedTasks.Add($Name)
        Write-StructuredLog -Level ERROR -Message ("Failed: {0}; {1}" -f $Name, $_.Exception.Message)
        throw
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
    Suspend-ActiveTimer
    try {
        Write-Themed $Prompt -Kind Prompt
        try {
            if ($Host.UI.RawUI -and [Console]::IsInputRedirected -eq $false) {
                [void][Console]::ReadKey($true)
                return
            }
        } catch { }
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
    Suspend-ActiveTimer
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

function Read-HostUntimed {
    param(
        [string]$Prompt,
        [string]$DefaultValue = ""
    )
    Read-HostThemed -Prompt $Prompt -DefaultValue $DefaultValue
}

function Pause-IfNeeded {
    if (-not $Global:NoPause) {
        Write-Host ""
        Read-AnyKeyThemed
    }
}

# =============================================================================
# ADMIN / CONFIG / PATH HELPERS
# =============================================================================
function Assert-Admin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Fail "Run this script as Administrator."
        Pause-IfNeeded
        exit 1
    }
}

function Load-Config {
    if (-not (Test-Path $Global:ConfigPath)) {
        throw "Config file not found: $Global:ConfigPath"
    }
    $Global:Config = Get-Content -LiteralPath $Global:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Resolve-RelativePath {
    param([Parameter(Mandatory)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $Global:ProjectRoot $Path
}

function Set-RegistryDefaultValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    (Get-Item -Path $Path).SetValue('', $Value, [Microsoft.Win32.RegistryValueKind]::String)
}

function Get-RegistryDefaultValue {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return (Get-Item -Path $Path).GetValue('', $null)
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Write-Ok "Created directory: $Path"
    }
}

function Get-DownloadCachePath {
    # downloadRoot, if empty, defaults to a per-user temp folder so the script
    # never silently creates C:\portable\_downloads. Override via config.
    $cfgValue = ''
    if ($Global:Config) { $cfgValue = [string]$Global:Config.downloadRoot }
    if ([string]::IsNullOrWhiteSpace($cfgValue)) {
        $cfgValue = Join-Path $env:TEMP "WinServerSetup-downloads"
    }
    Ensure-Directory $cfgValue
    return $cfgValue
}

function Get-SafeDownloadCacheFilePath {
    param([Parameter(Mandatory)][string]$FileName)
    $leaf = Split-Path -Leaf $FileName
    if ([string]::IsNullOrWhiteSpace($leaf)) {
        throw "Download file name is empty."
    }
    if (-not [string]::Equals($leaf, $FileName, [System.StringComparison]::Ordinal)) {
        Write-Warn ("Download file name contained path segments; using safe leaf name: {0}" -f $leaf)
    }
    $root = [System.IO.Path]::GetFullPath((Get-DownloadCachePath)).TrimEnd('\')
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $root $leaf))
    if (-not $candidate.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Resolved download path is outside the configured cache: $candidate"
    }
    return $candidate
}

function Test-DownloadedFileSignature {
    param([Parameter(Mandatory)][string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -notin @('.exe', '.msi', '.msix', '.msixbundle', '.appx', '.appxbundle')) {
        Write-StructuredLog -Level SIGNATURE -Message ("Authenticode signature not applicable for file type: {0}" -f $Path)
        return $null
    }
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        if ($sig.Status -eq 'Valid') {
            Write-StructuredLog -Level SIGNATURE -Message ("Valid signature: {0}; signer={1}" -f $Path, $sig.SignerCertificate.Subject)
            return $true
        } else {
            Write-Warn ("Downloaded file signature is not valid for {0}: {1}. Installer will remain available, but verify the source if this is unexpected." -f (Split-Path -Leaf $Path), $sig.Status)
            Write-StructuredLog -Level SIGNATURE -Message ("Non-valid signature: {0}; status={1}; message={2}" -f $Path, $sig.Status, $sig.StatusMessage)
            return $false
        }
    } catch {
        Write-Warn ("Could not verify downloaded file signature for {0}: {1}" -f (Split-Path -Leaf $Path), $_.Exception.Message)
        return $false
    }
}

function Test-FileSha256 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedSha256 = ""
    )
    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) { return $true }
    try {
        $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
        if ([string]::Equals($actual, $ExpectedSha256.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-StructuredLog -Level HASH -Message ("SHA256 verified: {0}" -f $Path)
            return $true
        }
        Write-Warn ("SHA256 mismatch for {0}. Expected {1}, got {2}." -f (Split-Path -Leaf $Path), $ExpectedSha256, $actual)
        Write-StructuredLog -Level HASH -Message ("SHA256 mismatch: {0}; expected={1}; actual={2}" -f $Path, $ExpectedSha256, $actual)
        return $false
    } catch {
        Write-Warn ("Could not verify SHA256 for {0}: {1}" -f (Split-Path -Leaf $Path), $_.Exception.Message)
        return $false
    }
}

function Initialize-Environment {
    Load-Config

    $logRoot = Resolve-RelativePath ([string]$Global:Config.logRoot)
    Ensure-Directory $logRoot
    Ensure-Directory (Resolve-RelativePath "backups")

    Initialize-StructuredLog -LogDirectory $logRoot

    $portableRoot = [string]$Global:Config.portableRoot
    if (-not [string]::IsNullOrWhiteSpace($portableRoot)) { Ensure-Directory $portableRoot }

    if (-not $Global:TranscriptStarted) {
        $Global:LogFile = Join-Path $logRoot ("WinServerSetup-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
        try {
            Start-Transcript -Path $Global:LogFile -Append -Force | Out-Null
            $Global:TranscriptStarted = $true
            Write-StartupLine -State "VERSION" -Label "Version" -Value $Global:ScriptVersion -ValueKind "StartupValue"
            Write-StartupLine -State "LOG" -Label "Logging to" -Value $Global:LogFile -ValueKind "StartupPath"
            Write-StartupLine -State "LOG" -Label "Structured log" -Value $Global:StructuredLog -ValueKind "StartupPath"
        } catch {
            Write-Warn "Could not start transcript: $($_.Exception.Message)"
        }
    }
}

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Command)
    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Get-PreferredPowerShellForRelaunch {
    $candidates = New-Object System.Collections.Generic.List[string]

    try {
        $pwshFromPath = Get-Command "pwsh.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pwshFromPath -and $pwshFromPath.Source) {
            $candidates.Add($pwshFromPath.Source) | Out-Null
        }
    } catch {
        Write-StructuredLog -Level DEBUG -Message ("Could not resolve pwsh.exe from PATH: {0}" -f $_.Exception.Message)
    }

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates.Add((Join-Path $env:ProgramFiles "PowerShell\7\pwsh.exe")) | Out-Null
        $powerShellRoot = Join-Path $env:ProgramFiles "PowerShell"
        if (Test-Path -LiteralPath $powerShellRoot) {
            $installedPwsh = Get-ChildItem -LiteralPath $powerShellRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                ForEach-Object { Join-Path $_.FullName "pwsh.exe" }
            foreach ($candidate in $installedPwsh) {
                $candidates.Add($candidate) | Out-Null
            }
        }
    }

    if (($env:ProgramW6432) -and ($env:ProgramW6432 -ne $env:ProgramFiles)) {
        $candidates.Add((Join-Path $env:ProgramW6432 "PowerShell\7\pwsh.exe")) | Out-Null
    }

    try {
        $currentProcessPath = (Get-Process -Id $PID -ErrorAction Stop).Path
        if ($currentProcessPath) {
            $candidates.Add($currentProcessPath) | Out-Null
        }
    } catch {
        Write-StructuredLog -Level DEBUG -Message ("Could not resolve current PowerShell process path: {0}" -f $_.Exception.Message)
    }

    if (-not [string]::IsNullOrWhiteSpace($env:WINDIR)) {
        $candidates.Add((Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe")) | Out-Null
    }

    foreach ($candidate in ($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate) {
            return (Get-Item -LiteralPath $candidate).FullName
        }
    }

    return "powershell.exe"
}

# =============================================================================
# PENDING REBOOT TRACKER
# =============================================================================
function Set-PendingReboot {
    param([string]$Reason = "")
    $Global:RunStats.RebootRequired = $true
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        Write-Warn "Pending reboot flagged: $Reason"
    } else {
        Write-Warn "Pending reboot flagged."
    }
}

function Test-WindowsRebootRequired {
    $signals = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    )
    foreach ($p in $signals) { if (Test-Path $p) { return $true } }
    try {
        $pending = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)
        $ops = @($pending.PendingFileRenameOperations | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($ops.Count -gt 0) { return $true }
    } catch {
        Write-StructuredLog -Level DEBUG -Message ("PendingFileRenameOperations check failed: {0}" -f $_.Exception.Message)
    }
    return $false
}

# =============================================================================
# SELF-RELOCATE
# =============================================================================
# Move the entire project folder to C:\portable\Scripts\WinServerSetup on first
# run. Uses robocopy to preserve everything, then re-launches at the new path
# and exits the current process cleanly.

function Add-RelocationLog {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )

    Add-Content -LiteralPath $Path -Encoding utf8 -Value (
        "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    )
}

function Invoke-SelfRelocateIfNeeded {
    if ($Global:NoRelocate) {
        Write-StartupLine -State "SKIP" -Label "Self-relocate" -Value "skipped, -NoRelocate switch is set" -ValueKind "StartupDim"
        return $false
    }
    if (-not $Global:Config.selfRelocate -or -not $Global:Config.selfRelocate.enabled) {
        Write-StartupLine -State "SKIP" -Label "Self-relocate" -Value "disabled in config" -ValueKind "StartupDim"
        return $false
    }

    $target = [string]$Global:Config.targetProjectRoot
    if ([string]::IsNullOrWhiteSpace($target)) { $target = "C:\portable\Scripts\WinServerSetup" }

    $currentFull = (Resolve-Path -LiteralPath $Global:ProjectRoot).Path.TrimEnd('\')
    $targetFull  = $target.TrimEnd('\')

    if ([string]::Equals($currentFull, $targetFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-StartupLine -State "SKIP" -Label "Running from" -Value $target -ValueKind "StartupPath"
        return $false
    }

    Write-StartupLine -State "RUN" -Label "Relocating project to" -Value $targetFull -ValueKind "StartupPath"
    $parent = Split-Path -Parent $target
    Ensure-Directory $parent
    $targetLogDir = Join-Path $targetFull "logs"
    $relocateLog = Join-Path $targetLogDir ("WinServerSetup-relocate-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

    # Copy with robocopy, then schedule removal of the original source after the
    # relaunched target process starts. /E updates/merges without deleting
    # unexpected destination files.
    Write-StartupLine -State "COPY" -Label "Source" -Value $currentFull -ValueKind "StartupPath"
    Write-StartupLine -State "COPY" -Label "Target" -Value $targetFull -ValueKind "StartupPath"
    $robocopyLog = Join-Path $env:TEMP "WinServerSetup-relocate.log"
    $proc = Start-Process robocopy.exe `
        -ArgumentList @("`"$currentFull`"", "`"$targetFull`"", "/E", "/COPY:DAT", "/R:1", "/W:2", "/NFL", "/NDL", "/NJH", "/NJS", "/NC", "/NS", "/LOG:`"$robocopyLog`"") `
        -Wait -PassThru -WindowStyle Hidden
    # robocopy exit codes <=7 are success (8+ are real failures).
    if ($proc.ExitCode -ge 8) {
        throw "robocopy failed with exit code $($proc.ExitCode). See $robocopyLog"
    }
    Write-StartupLine -State "OK" -Label "Copied" -Value ("project files, robocopy exit code {0}." -f $proc.ExitCode) -ValueKind "StartupOk"
    Ensure-Directory $targetLogDir
    @(
        ("[{0}] [INFO] Source: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $currentFull),
        ("[{0}] [INFO] Target: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $targetFull),
        ("[{0}] [INFO] robocopy exit code: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $proc.ExitCode),
        ("[{0}] [INFO] robocopy log: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $robocopyLog)
    ) | Set-Content -LiteralPath $relocateLog -Encoding utf8
    Add-RelocationLog -Path $relocateLog -Level "OK" -Message ("Project files copied. robocopy exit code {0}." -f $proc.ExitCode)

    # Relaunch from the new location and exit this process.
    $newScript = Join-Path $targetFull "WinServerSetup.ps1"
    $childArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$newScript`"", "-NoRelocate")
    if ($Global:Full)    { $childArgs += "-Full" }
    if ($Global:NoPause) { $childArgs += "-NoPause" }
    if ($Global:NoColor) { $childArgs += "-NoColor" }
    if ($Global:NoReboot){ $childArgs += "-NoReboot" }

    Write-StartupLine -State "RUN" -Label "Relaunch script" -Value $newScript -ValueKind "StartupPath"
    Add-RelocationLog -Path $relocateLog -Level "RUN" -Message ("Relaunch script: {0}" -f $newScript)
    $relaunchPowerShellExe = Get-PreferredPowerShellForRelaunch
    Write-StartupLine -State "SHELL" -Label "PowerShell host" -Value $relaunchPowerShellExe -ValueKind "StartupPath"
    Add-RelocationLog -Path $relocateLog -Level "SHELL" -Message ("PowerShell host: {0}" -f $relaunchPowerShellExe)
    $relocatedProcess = Start-Process $relaunchPowerShellExe -ArgumentList $childArgs -NoNewWindow -PassThru
    Write-StartupLine -State "RUN" -Label "Relocated setup PID" -Value ([string]$relocatedProcess.Id) -ValueKind "StartupValue"
    Add-RelocationLog -Path $relocateLog -Level "RUN" -Message ("Relocated setup PID: {0}" -f $relocatedProcess.Id)
    Write-StartupLine -State "LOG" -Label "Relocation log" -Value $relocateLog -ValueKind "StartupPath"
    try {
        $cleanupScript = Join-Path $env:TEMP ("WinServerSetup-clean-source-{0}.ps1" -f ([guid]::NewGuid().ToString("N")))
        $parentPid = $PID
        $cleanup = @"
param(
    [Parameter(Mandatory = `$true)][string]`$SourcePath,
    [Parameter(Mandatory = `$true)][string]`$TargetPath,
    [Parameter(Mandatory = `$true)][int]`$ParentProcessId,
    [Parameter(Mandatory = `$true)][string]`$RelocateLog
)
`$ErrorActionPreference = 'SilentlyContinue'
try { Wait-Process -Id `$ParentProcessId -Timeout 60 } catch { Start-Sleep -Seconds 5 }
try {
    `$src = [System.IO.Path]::GetFullPath(`$SourcePath).TrimEnd('\')
    `$dst = [System.IO.Path]::GetFullPath(`$TargetPath).TrimEnd('\')
    if (`$src -and `$dst -and -not [string]::Equals(`$src, `$dst, [System.StringComparison]::OrdinalIgnoreCase) -and -not `$dst.StartsWith(`$src + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath `$src -Recurse -Force -ErrorAction Stop
        Add-Content -LiteralPath `$RelocateLog -Encoding utf8 -Value ("[{0}] [OK] Removed original source folder: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), `$src)
    }
} catch {
    Add-Content -LiteralPath `$RelocateLog -Encoding utf8 -Value ("[{0}] [WARN] Could not remove original source folder: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), `$_.Exception.Message)
}
try { Remove-Item -LiteralPath `$MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue } catch { }
"@
        Set-Content -LiteralPath $cleanupScript -Value $cleanup -Encoding utf8 -Force
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$cleanupScript`"",
            "-SourcePath", "`"$currentFull`"", "-TargetPath", "`"$targetFull`"",
            "-ParentProcessId", "$parentPid", "-RelocateLog", "`"$relocateLog`""
        )
        Write-StartupLine -State "CLEAN" -Label "Cleanup" -Value "original source is removed after this process exits." -ValueKind "StartupDim"
        Add-RelocationLog -Path $relocateLog -Level "CLEAN" -Message "Original source cleanup scheduled after this process exits."
    } catch {
        Write-Warn "Could not schedule source cleanup after relocation: $($_.Exception.Message)"
        Add-RelocationLog -Path $relocateLog -Level "WARN" -Message ("Could not schedule source cleanup after relocation: {0}" -f $_.Exception.Message)
    }
    Write-StartupLine -State "CLEAN" -Label "This process" -Value "exits now, setup continues in the relocated copy." -ValueKind "StartupDim"
    Add-RelocationLog -Path $relocateLog -Level "CLEAN" -Message "Original setup process will now exit."
    Write-StartupLine -State "NEXT" -Label "Future runs" -Value $targetFull -ValueKind "StartupPath"
    Add-RelocationLog -Path $relocateLog -Level "NEXT" -Message ("Future runs: {0}" -f $targetFull)
    return $true
}

# =============================================================================
# APPLICATION DOWNLOAD PREFETCH
# =============================================================================
# Runs the prefetch helper as a background process so installers download while
# sequential setup continues, then waits for it before the install pass.

function Start-ApplicationDownloadPrefetch {
    param([int]$MaxParallel = 4)
    $prefetchScript = Join-Path $Global:ProjectRoot "scripts\Prefetch-AppDownloads.ps1"
    if (-not (Test-Path $prefetchScript)) {
        Write-Warn "Application prefetch helper not found: $prefetchScript"
        return $null
    }
    if ($MaxParallel -lt 1) { $MaxParallel = 1 }

    $logRoot = Resolve-RelativePath ([string]$Global:Config.logRoot)
    Ensure-Directory $logRoot
    $prefetchLog = Join-Path $logRoot ("WinServerSetup-prefetch-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    $psExe = Join-Path $env:windir "System32\WindowsPowerShell\v1.0\powershell.exe"
    $prefetchArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$prefetchScript`"",
        "-ProjectRoot", "`"$Global:ProjectRoot`"",
        "-ConfigPath", "`"$Global:ConfigPath`"",
        "-MaxParallel", "$MaxParallel",
        "-LogPath", "`"$prefetchLog`""
    )

    try {
        $proc = Start-Process -FilePath $psExe -ArgumentList $prefetchArgs -PassThru -WindowStyle Hidden
        Write-Ok "Application download prefetch started in the background (max $MaxParallel downloads)."
        Write-Info "Prefetch log: $prefetchLog"
        Write-StructuredLog -Level PREFETCH -Message ("Started process {0}; log={1}" -f $proc.Id, $prefetchLog)
        return [pscustomobject]@{ Process = $proc; LogPath = $prefetchLog; Started = Get-Date }
    } catch {
        Write-Warn "Could not start application download prefetch: $($_.Exception.Message)"
        return $null
    }
}

function Wait-ApplicationDownloadPrefetch {
    param([object]$Prefetch)
    if (-not $Prefetch -or -not $Prefetch.Process) { return }
    $proc = $Prefetch.Process
    Write-Info "Waiting for application prefetch to finish before sequential installs..."
    while (-not $proc.HasExited) {
        $elapsed = (Get-Date) - $Prefetch.Started
        Write-StatusInPlace ("Application downloads still running... elapsed {0:hh\:mm\:ss}" -f $elapsed)
        Start-Sleep -Seconds 2
        try { $proc.Refresh() } catch { break }
    }
    Clear-StatusInPlace
    try { $proc.Refresh() } catch { }
    if ($proc.ExitCode -eq 0) {
        Write-Ok "Application download prefetch completed."
    } else {
        Write-Warn "Application prefetch exited with code $($proc.ExitCode). Sequential install will continue and may download missing installers."
    }
    Write-StructuredLog -Level PREFETCH -Message ("Finished process {0}; exit={1}; log={2}" -f $proc.Id, $proc.ExitCode, $Prefetch.LogPath)
}

# =============================================================================
# DOWNLOAD / INSTALL HELPERS
# =============================================================================
function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [int]$RetryCount = 2,
        [int64]$MinimumBytes = 1024,
        [string]$ExpectedSha256 = "",
        [bool]$RequireValidSignature = $false
    )
    $dir = Split-Path -Parent $Destination
    Ensure-Directory $dir
    if (Test-Path $Destination) {
        $existing = Get-Item -LiteralPath $Destination -ErrorAction SilentlyContinue
        if ($existing -and $existing.Length -ge $MinimumBytes) {
            if (-not (Test-FileSha256 -Path $Destination -ExpectedSha256 $ExpectedSha256)) {
                Write-Warn ("Cached file failed hash verification; re-downloading: {0}" -f (Split-Path -Leaf $Destination))
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            } elseif ($RequireValidSignature -and $true -ne (Test-DownloadedFileSignature -Path $Destination)) {
                Write-Warn ("Cached file failed required signature validation; re-downloading: {0}" -f (Split-Path -Leaf $Destination))
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            } else {
                Write-Ok ("Using cached download: {0}" -f (Split-Path -Leaf $Destination))
                Write-StructuredLog -Level DOWNLOAD -Message ("Cache hit: {0}; bytes={1}" -f $Destination, $existing.Length)
                return $true
            }
        } else {
            Write-Warn ("Cached file is missing or too small; re-downloading: {0}" -f (Split-Path -Leaf $Destination))
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        }
    }

    for ($i = 0; $i -le $RetryCount; $i++) {
        $partial = "$Destination.partial"
        try {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            Write-StructuredLog -Level DOWNLOAD -Message ("URL={0}; Destination={1}" -f $Url, $Destination)
            Write-StatusInPlace ("Downloading: {0}" -f (Split-Path -Leaf $Destination))
            Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing -ErrorAction Stop
            $downloaded = Get-Item -LiteralPath $partial -ErrorAction Stop
            if ($downloaded.Length -lt $MinimumBytes) {
                throw "Downloaded file is unexpectedly small ($($downloaded.Length) bytes)."
            }
            Move-Item -LiteralPath $partial -Destination $Destination -Force
            Clear-StatusInPlace
            if (-not (Test-FileSha256 -Path $Destination -ExpectedSha256 $ExpectedSha256)) {
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
                throw "Downloaded file failed SHA256 verification."
            }
            $signatureOk = Test-DownloadedFileSignature -Path $Destination
            if ($RequireValidSignature -and $true -ne $signatureOk) {
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
                throw "Downloaded file failed required Authenticode signature validation."
            }
            Write-Ok ("Downloaded: {0}" -f (Split-Path -Leaf $Destination))
            return $true
        } catch {
            Clear-StatusInPlace
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            if ($i -ge $RetryCount) {
                Write-Fail ("Download failed: {0}  ({1})" -f $Url, $_.Exception.Message)
                return $false
            }
            Write-Warn ("Download retry {0} for {1}: {2}" -f ($i + 1), $Url, $_.Exception.Message)
            Start-Sleep -Seconds 2
        }
    }
    return $false
}

function Get-InstalledRegistryDisplayName {
    param([Parameter(Mandatory)][string]$NameLike)
    $roots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($r in $roots) {
        try {
            Get-ChildItem $r -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                    if ($p -and $p.DisplayName -like "*$NameLike*") { return $p.DisplayName }
                } catch { }
            }
        } catch { }
    }
    return $null
}

function Invoke-SilentExeInstall {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Arguments = @("/S"),
        [int]$TimeoutSeconds = 600
    )
    Write-Info ("Running silent installer: {0} {1}" -f (Split-Path -Leaf $Path), ($Arguments -join ' '))
    Write-StructuredLog -Level COMMAND -Message ("Installer path: {0}" -f $Path)
    $proc = Start-Process -FilePath $Path -ArgumentList $Arguments -PassThru -WindowStyle Hidden
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill() } catch { }
        throw "Installer did not complete within $TimeoutSeconds seconds: $Path"
    }
    Write-StructuredLog -Level COMMAND -Message ("Installer exit code: {0}" -f $proc.ExitCode)
    return $proc.ExitCode
}

function Invoke-LoggedCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$DisplayName = ""
    )
    $label = if ([string]::IsNullOrWhiteSpace($DisplayName)) { (Split-Path -Leaf $FilePath) } else { $DisplayName }
    $commandLine = "{0} {1}" -f $FilePath, ($Arguments -join ' ')
    Write-StructuredLog -Level COMMAND -Message $commandLine
    $output = @()
    $exitCode = 1
    try {
        $output = @(& $FilePath @Arguments 2>&1)
        $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    } catch {
        $output = @($_.Exception.Message)
        $exitCode = 1
    }
    foreach ($line in $output) {
        $text = [string]$line
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            Write-StructuredLog -Level OUTPUT -Message ("{0}> {1}" -f $label, $text.TrimEnd())
        }
    }
    Write-StructuredLog -Level COMMAND -Message ("{0} exit code: {1}" -f $label, $exitCode)
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Invoke-LoggedProcessWithProgress {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$DisplayName = "",
        [string]$StatusMessage = ""
    )
    $label = if ([string]::IsNullOrWhiteSpace($DisplayName)) { (Split-Path -Leaf $FilePath) } else { $DisplayName }
    $status = if ([string]::IsNullOrWhiteSpace($StatusMessage)) { "Running $label" } else { $StatusMessage }
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        Write-StructuredLog -Level COMMAND -Message ("{0} {1}" -f $FilePath, ($Arguments -join ' '))
        $proc = Start-Process -FilePath $FilePath -ArgumentList $Arguments -RedirectStandardOutput $outFile -RedirectStandardError $errFile -WindowStyle Hidden -PassThru
        $start = Get-Date
        while (-not $proc.HasExited) {
            $elapsed = (Get-Date) - $start
            Write-StatusInPlace ("{0} [{1:hh\:mm\:ss}]" -f $status, $elapsed)
            Start-Sleep -Seconds 2
            try { $proc.Refresh() } catch { }
        }
        Clear-StatusInPlace

        $output = @()
        foreach ($path in @($outFile, $errFile)) {
            if (Test-Path $path) {
                $output += Get-Content -LiteralPath $path -ErrorAction SilentlyContinue
            }
        }
        foreach ($line in $output) {
            $text = [string]$line
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                Write-StructuredLog -Level OUTPUT -Message ("{0}> {1}" -f $label, $text.TrimEnd())
            }
        }
        Write-StructuredLog -Level COMMAND -Message ("{0} exit code: {1}" -f $label, $proc.ExitCode)
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; Output = $output }
    } catch {
        Clear-StatusInPlace
        Write-StructuredLog -Level ERROR -Message ("{0} failed to start or run: {1}" -f $label, $_.Exception.Message)
        throw
    } finally {
        Clear-StatusInPlace
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# WINGET ENSURE + MSSTORE FIX (item 9)
# =============================================================================
function Ensure-Winget {
    if (Test-CommandExists "winget") {
        Write-Ok "WinGet is available."
        Repair-WingetSources
        return $true
    }
    if (-not $Global:Config.winget.installIfMissing) {
        Write-Warn "WinGet is missing and installIfMissing is disabled."
        return $false
    }
    Write-Info "WinGet was not found. Downloading Microsoft App Installer package..."
    $bundle = Get-SafeDownloadCacheFilePath -FileName "Microsoft.DesktopAppInstaller.msixbundle"
    if (Invoke-DownloadFile -Url "https://aka.ms/getwinget" -Destination $bundle) {
        try {
            Add-AppxPackage -Path $bundle
            Write-Ok "WinGet package installed. A new shell may be required to pick it up."
        } catch {
            Write-Fail "Could not install WinGet automatically: $($_.Exception.Message)"
            return $false
        }
    }
    if (-not (Test-CommandExists "winget")) {
        Write-Warn "WinGet still not detected. Install App Installer manually and re-run."
        return $false
    }
    Repair-WingetSources
    return $true
}

function Repair-WingetSources {
    if (-not $Global:Config.winget.removeMsstoreSource) { return }
    $needsReset = $false
    try {
        $sourcesResult = Invoke-LoggedCommand -FilePath "winget" -Arguments @("source", "list") -DisplayName "winget source list"
        if ($sourcesResult.ExitCode -ne 0) {
            Write-Warn "winget source listing failed; attempting source reset fallback."
            $needsReset = $true
        } else {
            $sources = ($sourcesResult.Output -join "`n")
            if ($sources -match '(?im)^\s*msstore\b') {
                Write-Info "Removing msstore winget source (avoids 0x8a15005e certificate errors)."
                $removeResult = Invoke-LoggedCommand -FilePath "winget" -Arguments @("source", "remove", "msstore") -DisplayName "winget source remove msstore"
                if ($removeResult.ExitCode -eq 0) { Write-Ok "Removed winget source: msstore" }
                else {
                    Write-Warn "winget could not remove msstore source; attempting source reset fallback."
                    $needsReset = $true
                }
            } else {
                Write-Info "winget msstore source is already absent."
            }
        }
    } catch {
        Write-Warn "winget source listing failed: $($_.Exception.Message)"
        $needsReset = $true
    }

    try {
        Write-Info "Refreshing winget sources..."
        $updateResult = Invoke-LoggedCommand -FilePath "winget" -Arguments @("source", "update") -DisplayName "winget source update"
        if ($updateResult.ExitCode -eq 0) { Write-Ok "winget sources refreshed." }
        else {
            Write-Warn "winget source update exited with code $($updateResult.ExitCode)."
            if ($needsReset) {
                Write-Info "A winget source listing/removal failure was detected; using source reset fallback."
            } else {
                Write-Info "Skipping winget source reset because source listing/removal already succeeded and only source update failed."
            }
        }
    } catch {
        Write-Warn "winget source update failed: $($_.Exception.Message)"
        if ($needsReset) {
            Write-Info "A winget source listing/removal failure was detected; using source reset fallback."
        } else {
            Write-Info "Skipping winget source reset because source listing/removal already succeeded and only source update failed."
        }
    }

    if ($needsReset) {
        try {
            Write-Info "Resetting winget sources with --force..."
            $resetResult = Invoke-LoggedCommand -FilePath "winget" -Arguments @("source", "reset", "--force") -DisplayName "winget source reset"
            if ($resetResult.ExitCode -eq 0) { Write-Ok "winget sources reset." }
            else { Write-Warn "winget source reset exited with code $($resetResult.ExitCode)." }
            $removeAfterReset = Invoke-LoggedCommand -FilePath "winget" -Arguments @("source", "remove", "msstore") -DisplayName "winget source remove msstore after reset"
            if ($removeAfterReset.ExitCode -eq 0) { Write-Ok "Removed winget source after reset: msstore" }
            else {
                Write-Info "msstore source was not present after reset or could not be removed; details are in the structured log."
                Write-StructuredLog -Level WINGET -Message ("winget source remove msstore after reset exit code: {0}" -f $removeAfterReset.ExitCode)
            }
            $refreshResult = Invoke-LoggedCommand -FilePath "winget" -Arguments @("source", "update") -DisplayName "winget source update after reset"
            if ($refreshResult.ExitCode -eq 0) { Write-Ok "winget sources refreshed after reset." }
            else { Write-Warn "winget source update after reset exited with code $($refreshResult.ExitCode)." }
        } catch {
            Write-Warn "winget source reset fallback failed: $($_.Exception.Message)"
        }
    }
}

function Test-WingetPackageInstalled {
    param([Parameter(Mandatory)][string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }

    try {
        $listResult = Invoke-LoggedCommand -FilePath "winget" -Arguments @("list", "--id", $Id, "--exact", "--accept-source-agreements", "--source", "winget") -DisplayName "winget list $Id"
        return ($listResult.ExitCode -eq 0 -and (($listResult.Output -join "`n") -match [regex]::Escape($Id)))
    } catch {
        Write-StructuredLog -Level WINGET -Message ("Package detection failed for {0}: {1}" -f $Id, $_.Exception.Message)
        return $false
    }
}

function Test-WindowsTerminalInstalled {
    if (Test-CommandExists "wt") { return $true }
    $stable = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\wt.exe"
    if (Test-Path $stable) { return $true }
    return $false
}

# =============================================================================
# SECTION 1: SHOW FILE EXTENSIONS (item 1)
# =============================================================================
function Enable-FileExtensions {
    if ($Global:Config.appearance -and -not $Global:Config.appearance.showFileExtensions) {
        Write-Info "File-extension toggle disabled in config."
        return
    }
    $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    $cur = (Get-ItemProperty -Path $path -Name "HideFileExt" -ErrorAction SilentlyContinue).HideFileExt
    if ($cur -eq 0) {
        Write-Ok "File extensions are already shown in Explorer."
    } else {
        Set-ItemProperty -Path $path -Name "HideFileExt" -Type DWord -Value 0
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
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    Set-ItemProperty -Path $path -Name "AppsUseLightTheme"   -Type DWord -Value 0
    Set-ItemProperty -Path $path -Name "SystemUsesLightTheme" -Type DWord -Value 0

    # Some Windows 10/11 builds need the shell colorization keys touched too
    # before Start/taskbar pick up the system dark state.
    $colorPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes"
    if (Test-Path $colorPath) {
        try { Set-ItemProperty -Path $colorPath -Name "ThemeChangesDesktopIcons" -Value 0 -ErrorAction SilentlyContinue } catch { Write-StructuredLog -Level WARN -Message ("Could not set ThemeChangesDesktopIcons: {0}" -f $_.Exception.Message) }
    }
    $dwmPath = "HKCU:\Software\Microsoft\Windows\DWM"
    if (-not (Test-Path $dwmPath)) { New-Item -Path $dwmPath -Force | Out-Null }
    Set-ItemProperty -Path $dwmPath -Name "ColorPrevalence" -Type DWord -Value 0 -ErrorAction SilentlyContinue
    $accentPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent"
    if (-not (Test-Path $accentPath)) { New-Item -Path $accentPath -Force | Out-Null }
    Set-ItemProperty -Path $accentPath -Name "StartColorMenu" -Type DWord -Value 0xff202020 -ErrorAction SilentlyContinue
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
    } catch { }
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
    } catch { }
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
    if (-not $s -or -not $s.enabled) { return }

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
                    $upgradeResult = Invoke-LoggedCommand -FilePath "winget" -Arguments @("upgrade", "--id", $id, "--exact", "--accept-package-agreements", "--accept-source-agreements", "--source", "winget", "--silent") -DisplayName "winget upgrade $name"
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
            $installResult = Invoke-LoggedCommand -FilePath "winget" -Arguments $wingetArgs -DisplayName "winget install $name"
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

    if (-not (Invoke-DownloadFile -Url $url -Destination $exePath -ExpectedSha256 $expectedSha256 -RequireValidSignature $requireValidSignature)) {
        Write-Warn "$name download failed; skipping install."
        $null = $Global:RunStats.FailedApps.Add($name)
        return
    }

    Write-Info "Installing $name silently with args: $silentArgs"
    try {
        $code = Invoke-SilentExeInstall -Path $exePath -Arguments @($silentArgs)
        if ($code -eq 0) {
            Write-Ok "$name silent install succeeded."
            $null = $Global:RunStats.InstalledApps.Add($name)
        } else {
            Write-Warn "$name installer exited with code $code."
            if ($Spec.fallbackInteractive) {
                Write-Warn "Silent install may not be supported. Launching the installer interactively..."
                Start-Process -FilePath $exePath -Wait -ErrorAction SilentlyContinue
                Write-Info "$name interactive install finished. Verify manually."
                $null = $Global:RunStats.InstalledApps.Add("$name (interactive)")
            } else {
                $null = $Global:RunStats.FailedApps.Add($name)
            }
        }
    } catch {
        Write-Warn "$name silent install failed: $($_.Exception.Message)"
        if ($Spec.fallbackInteractive) {
            try {
                Start-Process -FilePath $exePath -Wait -ErrorAction SilentlyContinue
            } catch {
                Write-Warn "$name interactive fallback could not be started: $($_.Exception.Message)"
            }
            Write-Info "$name interactive install attempted. Verify manually."
            $null = $Global:RunStats.InstalledApps.Add("$name (interactive)")
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
                Write-Ok "Everything service set to Automatic + started."
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
        if ($s) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($s) } catch { } }
        if ($shell) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { } }
    }
}

function Install-V2RayN {
    $settings = $Global:Config.v2rayN
    if (-not $settings.enabled) { return }

    $installRoot   = [string]$settings.installDir
    $finalFolder   = [string]$settings.finalFolderName
    if ([string]::IsNullOrWhiteSpace($finalFolder)) { $finalFolder = "V2rayN" }
    $finalDir      = Join-Path $installRoot $finalFolder
    $exeName       = [string]$settings.exeName

    Ensure-Directory $installRoot
    $download = Get-DownloadCachePath

    $repo   = [string]$settings.githubRepo
    $apiUrl = "https://api.github.com/repos/$repo/releases/latest"
    Write-Info "Querying latest v2rayN release ($repo)..."
    try {
        $release = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -Headers @{ 'User-Agent' = 'WinServerSetup' }
        $regex   = [string]$settings.assetNameRegex
        $asset   = $release.assets | Where-Object { $_.name -match $regex } | Select-Object -First 1
        if (-not $asset) { throw "No asset matched regex: $regex" }
        $zipPath = Get-SafeDownloadCacheFilePath -FileName ([string]$asset.name)
        Write-Info "Downloading $($asset.name) ..."
        if (-not (Invoke-DownloadFile -Url $asset.browser_download_url -Destination $zipPath)) { throw "v2rayN download failed." }

        # Extract to a staging folder so we can rename to V2rayN cleanly.
        $stage = Join-Path $download ("v2rayN-stage-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
        Ensure-Directory $stage
        Expand-Archive -Path $zipPath -DestinationPath $stage -Force

        # Identify the root inside the archive (the zip ships with a v2rayN-windows-64 folder).
        $rootInside = Get-ChildItem -Path $stage -Directory | Select-Object -First 1
        $srcDir = if ($rootInside) { $rootInside.FullName } else { $stage }

        if (Test-Path $finalDir) {
            Write-Info "Existing $finalFolder folder found; refreshing it in place."
            # Copy new files without purging user-generated v2rayN configuration.
            $robocopyLog = Join-Path $env:TEMP "WinServerSetup-v2rayN.log"
            $robo = Start-Process robocopy.exe -ArgumentList @("`"$srcDir`"", "`"$finalDir`"", "/E", "/R:1", "/W:2", "/NJH","/NJS","/NFL","/NDL","/NC","/NS","/LOG:`"$robocopyLog`"") -Wait -PassThru -WindowStyle Hidden
            Write-StructuredLog -Level COMMAND -Message ("v2rayN robocopy exit code: {0}; log: {1}" -f $robo.ExitCode, $robocopyLog)
            if ($robo.ExitCode -ge 8) { throw "robocopy failed while refreshing v2rayN (exit $($robo.ExitCode)). See $robocopyLog" }
        } else {
            Move-Item -LiteralPath $srcDir -Destination $finalDir -Force
        }
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok "v2rayN extracted to $finalDir"
    } catch {
        Write-Warn "v2rayN install/update failed: $($_.Exception.Message)"
        return
    }

    $exePath = Get-ChildItem -Path $finalDir -Filter $exeName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exePath) {
        Write-Warn "v2rayN executable not found after extraction."
        return
    }
    $exeFull = $exePath.FullName
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
    if (-not (Invoke-DownloadFile -Url $asset.browser_download_url -Destination $msi)) { return }

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
        if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
            Write-Ok "PowerShell installer completed."
            if ($proc.ExitCode -eq 3010) { Set-PendingReboot "PowerShell 7 installer requested reboot" }
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
        try { [void](Invoke-LoggedCommand -FilePath "winget" -Arguments @("upgrade", "--id", $pkg, "--exact", "--accept-package-agreements", "--accept-source-agreements", "--silent", "--source", "winget") -DisplayName "winget upgrade Windows Terminal") } catch { Write-Warn "Windows Terminal upgrade check failed: $($_.Exception.Message)" }
    } else {
        $wingetInstallArgs = @("install", "--id", $pkg, "--exact", "--accept-package-agreements", "--accept-source-agreements", "--source", "winget")
        if ($s.interactiveInstaller) { $wingetInstallArgs += "--interactive" } else { $wingetInstallArgs += "--silent" }
        try {
            $terminalResult = Invoke-LoggedCommand -FilePath "winget" -Arguments $wingetInstallArgs -DisplayName "winget install Windows Terminal"
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
    if (-not (Test-Path $sk)) { New-Item -Path $sk -Force | Out-Null }
    Set-ItemProperty -Path $sk -Name "DelegationConsole"  -Type String -Value "{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}"
    Set-ItemProperty -Path $sk -Name "DelegationTerminal" -Type String -Value "{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}"
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
    if (-not (Test-Path $openWithPath)) { New-Item -Path $openWithPath -Force | Out-Null }
    New-ItemProperty -Path $openWithPath -Name $progId -Value "" -PropertyType String -Force | Out-Null

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

function Install-BraveExtensions {
    $cfg = $Global:Config.braveExtensions
    if (-not $cfg -or -not $cfg.enabled) { return }

    if ($cfg.useForceListPolicy) {
        try {
            $policyPath = "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave\ExtensionInstallForcelist"
            if (-not (Test-Path $policyPath)) { New-Item -Path $policyPath -Force | Out-Null }
            $i = 1
            foreach ($ext in $cfg.items) {
                $value = "{0};https://clients2.google.com/service/update2/crx" -f $ext.id
                Set-ItemProperty -Path $policyPath -Name ([string]$i) -Type String -Value $value
                Write-Ok "Policy added for $($ext.name) ($($ext.id))."
                $i++
            }
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
    if (-not (Test-Path $owpPath)) { New-Item -Path $owpPath -Force | Out-Null }
    Set-ItemProperty -Path $owpPath -Name $ProgId -Value "" -Type String

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
    if (-not $s -or -not $s.enabled) { return }
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
# SECTION 12: RDP PORT SAFETY (item 8) + bruteforce blocker (items 34, 36)
# =============================================================================
function Test-TcpPortListening {
    param([Parameter(Mandatory)][int]$Port)
    try {
        $conns = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop
        return [bool]$conns
    } catch { return $false }
}

function Wait-TcpPortListening {
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutSeconds = 30
    )
    $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSeconds))
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPortListening -Port $Port) {
            Clear-StatusInPlace
            return $true
        }
        $remaining = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalSeconds)
        Write-StatusInPlace ("Waiting for TCP {0} to listen... {1}s" -f $Port, $remaining)
        Start-Sleep -Seconds 1
    }
    Clear-StatusInPlace
    return (Test-TcpPortListening -Port $Port)
}

function Ensure-RdpFirewallRule {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][int]$Port
    )
    try {
        $rule = Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue
        if (-not $rule) {
            New-NetFirewallRule -DisplayName $DisplayName -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Any -ErrorAction Stop | Out-Null
        } else {
            $rule | Set-NetFirewallRule -Enabled True -Action Allow -Profile Any -ErrorAction Stop
            $rule | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -Protocol TCP -LocalPort $Port -ErrorAction Stop
        }

        $verifyRule = Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction Stop
        $verifyPort = $verifyRule | Get-NetFirewallPortFilter
        if ($verifyRule.Enabled -ne 'True' -or $verifyRule.Action -ne 'Allow' -or [string]$verifyPort.Protocol -ne 'TCP' -or [string]$verifyPort.LocalPort -ne [string]$Port) {
            throw "Firewall verification failed for $DisplayName."
        }
        Write-Ok "Firewall rule verified: $DisplayName allows TCP $Port."
        return $true
    } catch {
        Write-Fail "Failed to create/verify firewall rule for TCP ${Port}: $($_.Exception.Message)"
        return $false
    }
}

function Configure-RdpPortAndFirewall {
    $s = $Global:Config.rdp
    if (-not $s.enabled) { return }
    $newPort = [int]$s.newPort
    $oldPort = [int]$s.oldPort
    if ($newPort -lt 1 -or $newPort -gt 65535) { throw "Invalid RDP port: $newPort" }

    Write-Info "Step 1/5: Enable Remote Desktop in registry."
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue

    Write-Info "Step 2/5: Pre-create inbound firewall rule for new port $newPort BEFORE changing service port."
    $newRule = "WinServerSetup RDP TCP $newPort"
    if (-not (Ensure-RdpFirewallRule -DisplayName $newRule -Port $newPort)) {
        throw "ABORTING RDP port change to prevent lockout because firewall setup failed."
    }

    Write-Info "Step 3/5: Backup current PortNumber and update registry."
    $rdpPath = "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
    $backup = Resolve-RelativePath "backups\RDP-Tcp-PortNumber.reg"
    $previousPort = $oldPort
    try {
        $currentPortValue = (Get-ItemProperty -Path $rdpPath -Name "PortNumber" -ErrorAction Stop).PortNumber
        if ($currentPortValue) { $previousPort = [int]$currentPortValue }
    } catch {
        Write-StructuredLog -Level WARN -Message ("Could not read existing RDP PortNumber before change: {0}" -f $_.Exception.Message)
    }
    try { reg.exe export "HKLM\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" "$backup" /y | Out-Null } catch { Write-StructuredLog -Level WARN -Message ("RDP registry backup export failed: {0}" -f $_.Exception.Message) }
    Set-ItemProperty -Path $rdpPath -Name "PortNumber" -Type DWord -Value $newPort
    Write-Ok "PortNumber registry value set to $newPort."

    Write-Info "Step 4/5: Restart TermService to bind the new port."
    if ($s.restartRemoteDesktopService) {
        Write-Warn "Restarting Remote Desktop service -- your current RDP session may briefly disconnect."
        try {
            Restart-Service TermService -Force -ErrorAction Stop
        } catch {
            Write-Warn "Service restart failed: $($_.Exception.Message)"
            try {
                Set-ItemProperty -Path $rdpPath -Name "PortNumber" -Type DWord -Value $previousPort
                Write-Warn "Rolled RDP PortNumber back to $previousPort because TermService restart failed."
            } catch {
                Write-Warn "Could not roll RDP PortNumber back to $previousPort. Old port firewall rules were left unchanged."
                Set-PendingReboot "RDP service restart failed after port registry update"
            }
            return
        }
    } else {
        Write-Info "Skipping service restart (config). Reboot will apply the change."
        Set-PendingReboot "RDP port change requires service restart"
    }

    Write-Info "Step 5/5: Verify the new port is listening."
    if ($s.verifyListening) {
        if (Wait-TcpPortListening -Port $newPort -TimeoutSeconds 30) {
            Write-Ok "Confirmed: TCP $newPort is listening."
            if ($s.blockOldPort -and $oldPort -ne $newPort) {
                $blockName = "WinServerSetup Block Old RDP TCP $oldPort"
                if (-not (Get-NetFirewallRule -DisplayName $blockName -ErrorAction SilentlyContinue)) {
                    try {
                        New-NetFirewallRule -DisplayName $blockName -Direction Inbound -Protocol TCP -LocalPort $oldPort -Action Block -Profile Any | Out-Null
                        Write-Ok "Old port $oldPort blocked (only after new port verified)."
                    } catch { Write-Warn "Could not block old port $oldPort : $($_.Exception.Message)" }
                }
            }
        } else {
            Write-Warn "Could not confirm new port is listening yet. Old port will NOT be blocked to avoid lockout."
            Set-PendingReboot "RDP port change not confirmed listening yet"
        }
    }
}

function Install-RdpBruteforceBlocker {
    $s = $Global:Config.rdpBruteforceBlocker
    if (-not $s.enabled) { return }
    $scriptPath = Join-Path $Global:ProjectRoot "scripts\Block-RdpBruteforce.ps1"
    if (-not (Test-Path $scriptPath)) { throw "Blocker script not found: $scriptPath" }

    $taskName = [string]$s.taskName
    $interval = [int]$s.taskIntervalMinutes; if ($interval -lt 1) { $interval = 5 }
    $hidden   = $true

    $psExe = Join-Path $env:windir "System32\WindowsPowerShell\v1.0\powershell.exe"
    $hiddenFlag = if ($hidden) { "-WindowStyle Hidden " } else { "" }
    # Always use the CURRENT resolved config path (so post-relocate runs use the new path) -- item 36.
    $arguments = "${hiddenFlag}-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" -ConfigPath `"$Global:ConfigPath`""

    $action    = New-ScheduledTaskAction    -Execute $psExe -Argument $arguments
    $trigger   = New-ScheduledTaskTrigger   -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes $interval) -RepetitionDuration (New-TimeSpan -Days 3650)
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Ok ("Scheduled task registered: {0}  (hidden, highest privileges)" -f $taskName)
    Write-Info ("Task argument: {0}" -f $arguments)
    try {
        $registered = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $registeredAction = $registered.Actions | Select-Object -First 1
        Write-StructuredLog -Level TASK -Message ("{0} execute: {1}" -f $taskName, $registeredAction.Execute)
        Write-StructuredLog -Level TASK -Message ("{0} arguments: {1}" -f $taskName, $registeredAction.Arguments)
        if ([string]$registeredAction.Arguments -notlike "*$Global:ConfigPath*") {
            Write-Warn "RDP blocker task action does not appear to reference the resolved config path."
        } else {
            Write-Ok "RDP blocker task action verified with config path: $Global:ConfigPath"
        }
    } catch {
        Write-Warn "Could not verify RDP blocker scheduled task action: $($_.Exception.Message)"
    }

    Write-Info "Running blocker once now for verification..."
    try { & $psExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ConfigPath $Global:ConfigPath } catch { Write-Warn "Blocker test run failed: $($_.Exception.Message)" }
}

# =============================================================================
# SECTION 13: SEARCH INDEXING (carry over)
# =============================================================================
function Enable-SearchIndexing {
    if (-not $Global:Config.indexing.enabled) { return }
    Write-Info "Installing/enabling Windows Search service."
    try {
        $before = Get-Service -Name WSearch -ErrorAction SilentlyContinue
        if ($before) { Write-Info "Windows Search initial state: $($before.Status) / $($before.StartType)" }
        else { Write-Info "Windows Search service not found before enable attempt." }
    } catch { }
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
function Install-DotNetFramework35 {
    if (-not $Global:Config.runtimes.installDotNetFramework35) { return }
    Write-Info "Installing .NET Framework 3.5 feature."
    try {
        if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
            Install-WindowsFeature NET-Framework-Core -ErrorAction SilentlyContinue | Out-Null
        } else {
            Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart -ErrorAction SilentlyContinue | Out-Null
        }
        Write-Ok ".NET Framework 3.5 feature step completed."
    } catch { Write-Warn ".NET 3.5 feature install warning: $($_.Exception.Message)" }
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
    if (-not (Invoke-DownloadFile -Url $url -Destination $msi)) { return }
    Write-Info "Installing .NET Framework 4.8.1 (passive, no restart)..."
    try {
        $proc = Start-Process -FilePath $msi -ArgumentList "/passive /norestart" -Wait -PassThru -WindowStyle Hidden
        Write-StructuredLog -Level COMMAND -Message (".NET Framework 4.8.1 installer exit code: {0}" -f $proc.ExitCode)
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
        $runtimeResult = Invoke-LoggedCommand -FilePath "winget" -Arguments @("install", "--id", $Id, "--exact", "--accept-package-agreements", "--accept-source-agreements", "--source", "winget", "--silent") -DisplayName "winget runtime $Name"
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
    if (-not $s.enabled) { return }
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
            $repo = [string]$s.sourceRepo
            $raw  = "https://raw.githubusercontent.com/$repo/master/$exeName"
            if (-not (Invoke-DownloadFile -Url $raw -Destination $exePath)) {
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

    try { Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }
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
    if (-not $s.enabled) { return }
    Write-Info "Applying QoS / DeliveryOptimization / WindowsUpdate bandwidth policies..."

    $qos = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched"
    if (-not (Test-Path $qos)) { New-Item -Path $qos -Force | Out-Null }
    Set-ItemProperty -Path $qos -Name "NonBestEffortLimit" -Type DWord -Value ([int]$s.qosNonBestEffortLimit)

    $do = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"
    if (-not (Test-Path $do)) { New-Item -Path $do -Force | Out-Null }
    Set-ItemProperty -Path $do -Name "DODownloadMode" -Type DWord -Value ([int]$s.deliveryOptimizationDownloadMode)

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
                    Remove-ItemProperty -Path $k -Name $prop.Name -ErrorAction SilentlyContinue
                    Write-Ok "Removed startup entry: $k :: $($prop.Name)"
                    $removedEntries.Add("$k :: $($prop.Name)") | Out-Null
                }
            }
        } catch { }
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
            } catch { }
            if ($_.Name -match [regex]::Escape($Pattern) -or $target -match [regex]::Escape($Pattern)) {
                Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                Write-Ok "Removed startup shortcut: $($_.FullName)"
                $removedEntries.Add($_.FullName) | Out-Null
            }
        }
    }
    if ($removedEntries.Count -eq 0) { Write-Info "Startup entry not found (already disabled?): $Pattern" }
    return ($removedEntries.Count -gt 0)
}

function Disable-ConfiguredStartupApps {
    $s = $Global:Config.startupDisable
    if (-not $s -or -not $s.enabled) { return }
    foreach ($p in $s.patterns) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        Write-Info "Disabling startup entry: $p"
        Disable-StartupEntry -Pattern $p | Out-Null
    }
}

function Remove-ConfiguredAppxPackages {
    $s = $Global:Config.removeAppxPackages
    if (-not $s -or -not $s.enabled) { return }
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
    if (-not $s -or -not $s.enabled) { return }
    foreach ($cap in $s.capabilities) {
        if ([string]::IsNullOrWhiteSpace($cap)) { continue }
        Write-Info "Removing Windows capability: $cap"
        try {
            $state = Get-WindowsCapability -Online -Name $cap -ErrorAction SilentlyContinue
            if (-not $state) { Write-Info "Capability not present: $cap"; continue }
            if ($state.State -eq 'NotPresent') { Write-Ok "Capability already NotPresent: $cap"; continue }
            $dism = Invoke-LoggedCommand -FilePath "dism.exe" -Arguments @("/online", "/Remove-Capability", "/CapabilityName:$cap") -DisplayName "DISM remove capability $cap"
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
    if (-not $s -or -not $s.enabled) { return }
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
                if ($shortcut) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) } catch { } }
            }
        }
        return $false
    } catch {
        Write-StructuredLog -Level TASKBAR -Message ("Could not inspect taskbar pinned folder: {0}" -f $_.Exception.Message)
        return $null
    } finally {
        if ($wsh) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) } catch { } }
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
function Initialize-WindowsUpdateEnvironment {
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        try { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:$false | Out-Null } catch { Write-Warn "Install-PackageProvider NuGet failed: $($_.Exception.Message)" }
    }
    try { Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted -ErrorAction SilentlyContinue } catch { Write-StructuredLog -Level WARN -Message ("Could not set PSGallery trusted: {0}" -f $_.Exception.Message) }
    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        try { Install-Module -Name PSWindowsUpdate -Force -AllowClobber -Confirm:$false | Out-Null } catch { Write-Warn "Install PSWindowsUpdate failed: $($_.Exception.Message)" }
    }
    Import-Module PSWindowsUpdate -Force -ErrorAction SilentlyContinue
    try { Add-WUServiceManager -MicrosoftUpdate -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { Write-StructuredLog -Level WARN -Message ("Could not add Microsoft Update service manager: {0}" -f $_.Exception.Message) }
}

function Invoke-WindowsUpdatePass {
    param([int]$PassNumber)
    Write-Info "Windows Update pass ${PassNumber}: scanning..."
    $updates = @()
    try {
        $updates = Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Verbose:$false -ErrorAction Stop
    } catch { Write-Warn "Get-WindowsUpdate failed: $($_.Exception.Message)" }

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
    try {
        $wuJob = Start-Job -Name "WinServerSetup-WindowsUpdate-$PassNumber" -ScriptBlock {
            Import-Module PSWindowsUpdate -Force
            Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -Verbose:$false -Confirm:$false
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($wuJob.State -eq 'Running') {
            Write-StatusInPlace ("Pass {0}: downloading/installing updates... elapsed {1:hh\:mm\:ss}" -f $PassNumber, $sw.Elapsed)
            Start-Sleep -Seconds 2
            $wuJob = Get-Job -Id $wuJob.Id
        }
        Clear-StatusInPlace
        $wuOutput = @()
        try { $wuOutput = @(Receive-Job -Job $wuJob -ErrorAction SilentlyContinue) } catch { $wuOutput = @($_.Exception.Message) }
        foreach ($line in $wuOutput) {
            $text = [string]$line
            if (-not [string]::IsNullOrWhiteSpace($text)) { Write-StructuredLog -Level UPDATE -Message ("Pass {0}: {1}" -f $PassNumber, $text.TrimEnd()) }
        }
        if ($wuJob.State -eq 'Completed') {
            foreach ($u in $updates) {
                $title = if ($u.Title) { $u.Title } else { [string]$u }
                Write-StructuredLog -Level UPDATE -Message ("Pass {0}: downloaded {1}" -f $PassNumber, $title)
                Write-StructuredLog -Level UPDATE -Message ("Pass {0}: installed {1}" -f $PassNumber, $title)
            }
            Write-Ok "Pass ${PassNumber}: Windows Update install command completed."
        } else {
            foreach ($u in $updates) {
                $title = if ($u.Title) { $u.Title } else { [string]$u }
                Write-StructuredLog -Level UPDATE -Message ("Pass {0}: failed {1}" -f $PassNumber, $title)
            }
            Write-Warn "Pass ${PassNumber}: Windows Update job ended with state $($wuJob.State). Details are in the structured log."
        }
        Remove-Job -Job $wuJob -Force -ErrorAction SilentlyContinue | Out-Null
    } catch {
        Clear-StatusInPlace
        Write-Warn "Install-WindowsUpdate raised: $($_.Exception.Message)"
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
    if (-not $Global:Config.windowsUpdate.enabled) { Write-Info "Windows Update section disabled in config."; return }
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
        $remaining = Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Verbose:$false -ErrorAction SilentlyContinue
        if ($remaining -and $remaining.Count -gt 0) {
            Write-Warn ("{0} update(s) still pending after {1} passes." -f $remaining.Count, $maxPasses)
            foreach ($r in $remaining) { Write-Warn ("  pending: {0}" -f $r.Title) }
        } else {
            Write-Ok "All applicable Windows Updates installed."
        }
    } catch { }
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

function Invoke-ActivationIfConfigured {
    $a = $Global:Config.activation
    if (-not $a -or -not $a.enabled) { Write-Info "Activation disabled in config."; return }
    $kms  = [string]$a.kmsServer
    $key  = [string]$a.productKey
    if ([string]::IsNullOrWhiteSpace($kms) -and [string]::IsNullOrWhiteSpace($key)) {
        Write-Warn "Activation enabled but no kmsServer or productKey set."
        return
    }
    Write-Warn "Use Activation only with a key/server you are entitled to use."
    if (-not [string]::IsNullOrWhiteSpace($key)) { Invoke-Slmgr -Arguments @("/ipk", $key)  | Out-Null }
    if (-not [string]::IsNullOrWhiteSpace($kms)) { Invoke-Slmgr -Arguments @("/skms", $kms) | Out-Null }
    Invoke-Slmgr -Arguments @("/ato") | Out-Null
    Invoke-Slmgr -Arguments @("/xpr") | Out-Null
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
    $trigger   = New-ScheduledTaskTrigger   -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -Hidden

    try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Ok "Scheduled post-reboot task registered: $taskName"
}

# =============================================================================
# CLEANUP + HEALTH CHECK (carry over)
# =============================================================================
function Remove-DirectoryContentsSafe {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) { return }
    Write-Info "Cleaning: $Path"
    try {
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop } catch { Write-StructuredLog -Level CLEANUP -Message ("Could not remove {0}: {1}" -f $_.FullName, $_.Exception.Message) }
        }
        Write-Ok "Cleaned: $Path"
    } catch { Write-Warn "Could not clean $Path : $($_.Exception.Message)" }
}

function Remove-WinServerSetupTempArtifacts {
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
                    Write-StructuredLog -Level CLEANUP -Message ("Could not remove project temp artifact {0}: {1}" -f $_.FullName, $_.Exception.Message)
                }
            }
        }
    }
    Write-Ok "Scoped user temp cleanup completed for WinServerSetup artifacts only."
}

function Clear-WinServerSetupTempAndCache {
    $s = $Global:Config.cleanup
    if (-not $s -or -not $s.enabled) { return }
    Write-Section "Cleaning temp and cache files"
    if ($s.cleanProjectDownloadCache) { Remove-DirectoryContentsSafe -Path (Get-DownloadCachePath) }
    if ($s.cleanUserTemp)             { Remove-WinServerSetupTempArtifacts }
    if ($s.cleanWindowsTemp)          { Remove-DirectoryContentsSafe -Path (Join-Path $env:WINDIR "Temp") }
    if ($s.cleanWindowsUpdateDownloadCache) {
        try {
            Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
            Stop-Service -Name bits     -Force -ErrorAction SilentlyContinue
            Remove-DirectoryContentsSafe -Path (Join-Path $env:WINDIR "SoftwareDistribution\Download")
            Start-Service -Name bits -ErrorAction SilentlyContinue
            Start-Service -Name wuauserv -ErrorAction SilentlyContinue
        } catch { Write-Warn "WU cache cleanup: $($_.Exception.Message)" }
    }
    if ($s.cleanRecycleBin) {
        try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue; Write-Ok "Recycle Bin cleared." }
        catch { Write-Warn "Could not clear Recycle Bin: $($_.Exception.Message)" }
    }
}

function Invoke-HealthCheck {
    Write-Section "WinServerSetup Health Check"
    $items = @(
        @{ Name = "WinGet";                                  Test = { Test-CommandExists "winget" } },
        @{ Name = "C:\portable";                             Test = { Test-Path ([string]$Global:Config.customFolders.portablePath) } },
        @{ Name = "C:\portable\Scripts";                     Test = { Test-Path ([string]$Global:Config.customFolders.scriptsPath) } },
        @{ Name = "Downloads\compressed";                    Test = { Test-Path (Join-Path (Get-CurrentUserDownloadsFolder) ([string]$Global:Config.customFolders.compressedFolderName)) } },
        @{ Name = "Defender exclusion for compressed";       Test = { Test-DefenderExclusionPath -Path (Join-Path (Get-CurrentUserDownloadsFolder) ([string]$Global:Config.customFolders.compressedFolderName)) } },
        @{ Name = "PowerShell 7";                            Test = { Test-CommandExists "pwsh" } },
        @{ Name = "Windows Terminal";                        Test = { $null -ne (Get-Command wt -ErrorAction SilentlyContinue) } },
        @{ Name = "Brave";                                   Test = { Test-Path "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe" } },
        @{ Name = "Python";                                  Test = { Test-CommandExists "python" } },
        @{ Name = "FFmpeg";                                  Test = { Test-CommandExists "ffmpeg" } },
        @{ Name = "7-Zip";                                   Test = { (Test-Path "$env:ProgramFiles\7-Zip\7z.exe") -or (Test-CommandExists "7z") } },
        @{ Name = "V2rayN portable folder";                  Test = { Test-Path (Join-Path (Join-Path ([string]$Global:Config.v2rayN.installDir) ([string]$Global:Config.v2rayN.finalFolderName)) ([string]$Global:Config.v2rayN.exeName)) } },
        @{ Name = "Everything Service";                      Test = { [bool](Get-Service -Name "Everything" -ErrorAction SilentlyContinue) } },
        @{ Name = "Windows Search";                          Test = { (Get-Service -Name WSearch -ErrorAction SilentlyContinue).Status -eq "Running" } },
        @{ Name = "RDP Port matches config";                 Test = { (Get-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name PortNumber).PortNumber -eq [int]$Global:Config.rdp.newPort } },
        @{ Name = "EmptyStandbyList Task";                   Test = { [bool](Get-ScheduledTask -TaskName ([string]$Global:Config.emptyStandbyList.taskName) -TaskPath ([string]$Global:Config.emptyStandbyList.taskPath) -ErrorAction SilentlyContinue) } },
        @{ Name = "RDP Blocker Task";                        Test = { [bool](Get-ScheduledTask -TaskName ([string]$Global:Config.rdpBruteforceBlocker.taskName) -ErrorAction SilentlyContinue) } },
        @{ Name = "Show File Extensions";                    Test = { (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name HideFileExt -ErrorAction SilentlyContinue).HideFileExt -eq 0 } },
        @{ Name = "Windows Long Paths";                      Test = { (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled -eq 1 } },
        @{ Name = "Dark Mode";                               Test = { (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name AppsUseLightTheme -ErrorAction SilentlyContinue).AppsUseLightTheme -eq 0 } },
        @{ Name = "PowerShell 7 default for .ps1";            Test = { (Get-RegistryDefaultValue -Path "HKCU:\Software\Classes\.ps1") -eq "WinServerSetup.PowerShell7Script" } },
        @{ Name = "7-Zip default for .zip";                  Test = { (Get-RegistryDefaultValue -Path "HKCU:\Software\Classes\.zip") -eq "7-Zip.zip" } },
        @{ Name = "7-Zip default for .7z";                   Test = { (Get-RegistryDefaultValue -Path "HKCU:\Software\Classes\.7z") -eq "7-Zip.7z"  } },
        @{ Name = "7-Zip default for .rar";                  Test = { (Get-RegistryDefaultValue -Path "HKCU:\Software\Classes\.rar") -eq "7-Zip.rar" } }
    )
    foreach ($i in $items) {
        try { if (& $i.Test) { Write-Ok $i.Name } else { Write-Warn $i.Name } }
        catch { Write-Warn $i.Name }
    }
}

# =============================================================================
# FINAL SUMMARY + AUTO REBOOT (items 11, 26)
# =============================================================================
function Show-FinalSummary {
    Write-Host ""
    Write-Section "Setup Summary"
    $s = $Global:RunStats
    $elapsed = Format-ActiveTimerElapsed
    Write-Themed ("Started   : {0}" -f $s.StartedTasks.Count)   -Kind Info
    Write-Themed ("Completed : {0}" -f $s.CompletedTasks.Count) -Kind Success
    Write-Themed ("Failed    : {0}" -f $s.FailedTasks.Count)    -Kind $(if ($s.FailedTasks.Count -gt 0) { 'Error' } else { 'Success' })
    Write-Themed ("Skipped   : {0}" -f $s.SkippedTasks.Count)   -Kind Status
    Write-Themed ("Warnings  : {0}" -f $s.Warnings.Count)       -Kind $(if ($s.Warnings.Count -gt 0) { 'Warning' } else { 'Success' })
    Write-Themed ("Installed apps : {0}" -f ($s.InstalledApps -join ', ')) -Kind Info
    if ($s.FailedApps.Count -gt 0) {
        Write-Themed ("Failed apps    : {0}" -f ($s.FailedApps -join ', ')) -Kind Error
    }
    if ($s.RebootRequired) {
        Write-Themed "Reboot required: YES" -Kind Warning
    } else {
        Write-Themed "Reboot required: no"  -Kind Success
    }
    Write-Themed ("Total active elapsed: {0}" -f $elapsed) -Kind Summary
    if ($Global:LogFile)       { Write-Themed ("Console log    : {0}" -f $Global:LogFile)       -Kind SummaryDim }
    if ($Global:StructuredLog) { Write-Themed ("Structured log : {0}" -f $Global:StructuredLog) -Kind SummaryDim }
    Write-StructuredLog -Level SUMMARY -Message ("Started={0}; Completed={1}; Failed={2}; Skipped={3}; Warnings={4}; RebootRequired={5}; ActiveElapsed={6}" -f $s.StartedTasks.Count, $s.CompletedTasks.Count, $s.FailedTasks.Count, $s.SkippedTasks.Count, $s.Warnings.Count, $s.RebootRequired, $elapsed)
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
    Invoke-RecordedSetupStep -Name "Run health check" -Action { Invoke-HealthCheck }
    Invoke-RecordedSetupStep -Name "Clean temp and cache" -Action { Clear-WinServerSetupTempAndCache }

    Show-FinalSummary

    Write-Ok "Full setup completed."

    Restart-AfterSetup
}

function Invoke-FullSetupWithActiveTimer {
    Start-ActiveTimer
    try {
        Invoke-FullSetup
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
        Write-Option -Number "0"  -Label "Back / Exit"
        Write-Host ""

        $choice = Read-HostUntimed -Prompt "Select" -DefaultValue "1"
        try {
            switch ($choice) {
                "1"  { Invoke-FullSetupWithActiveTimer;                                                                          Pause-IfNeeded }
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

    Initialize-Environment

    if ($Global:Full) {
        Invoke-FullSetupWithActiveTimer
    } else {
        Show-MainMenu
    }
}
finally {
    if ($Global:TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}
