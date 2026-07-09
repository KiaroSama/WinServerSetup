# Run-WinServerSetup.ps1
# Launcher: right-click "Run with PowerShell" or run from any PowerShell window.
# Auto-elevates if not already running as Administrator. Forwards all switches
# to WinServerSetup.ps1 so callers can do e.g. `Run-WinServerSetup.ps1 -Full -NoPause`.

[CmdletBinding()]
param(
    [switch]$Full,
    [switch]$NoPause,
    [switch]$NoColor,
    [switch]$NoReboot,
    [switch]$NoRelocate
)

$ErrorActionPreference = "Stop"
$launcherStartedUtc = [DateTime]::UtcNow
$executionId = [Guid]::NewGuid().ToString("N")
$scriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
$mainScriptPath = Join-Path $scriptRoot "WinServerSetup.ps1"
$logDir = Join-Path $scriptRoot "logs"
$script:LauncherLog = $null
$script:LauncherLogReady = $false

function New-UniqueLogPath {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $Path }

    $directory = Split-Path -Parent $Path
    $name = [IO.Path]::GetFileNameWithoutExtension($Path)
    $extension = [IO.Path]::GetExtension($Path)
    for ($index = 1; $index -lt 1000; $index++) {
        $candidate = Join-Path $directory ("{0}-{1}{2}" -f $name, $index, $extension)
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    }

    throw "Could not allocate a unique launcher log path under $directory."
}

function Initialize-LauncherLog {
    try {
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        $stamp = [DateTime]::UtcNow.ToString("yyyy-MM-dd_HH-mm-ss")
        $script:LauncherLog = New-UniqueLogPath -Path (Join-Path $logDir "Run-WinServerSetup_$stamp`_UTC.log")
        "" | Set-Content -LiteralPath $script:LauncherLog -Encoding UTF8
        $script:LauncherLogReady = $true
    } catch {
        $script:LauncherLogReady = $false
        Write-Host ("Launcher logging could not be initialized: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Write-LauncherLog {
    param(
        [ValidateSet("DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL")]
        [string]$Level = "INFO",
        [Parameter(Mandatory)][string]$Message
    )

    $line = "[{0} UTC] [{1}] [LAUNCHER] {2}" -f ([DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ss")), $Level, $Message
    if ($script:LauncherLogReady -and -not [string]::IsNullOrWhiteSpace($script:LauncherLog)) {
        try {
            Add-Content -LiteralPath $script:LauncherLog -Value $line -Encoding UTF8
        } catch {
            $script:LauncherLogReady = $false
            Write-Host ("Launcher logging failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}

function Write-LauncherException {
    param(
        [ValidateSet("ERROR", "CRITICAL")]
        [string]$Level = "ERROR",
        [Parameter(Mandatory)]$ErrorRecord,
        [string]$Context = "Unhandled launcher error"
    )

    Write-LauncherLog -Level $Level -Message ("{0}: {1}" -f $Context, $ErrorRecord.Exception.Message)
    if ($ErrorRecord.InvocationInfo) {
        Write-LauncherLog -Level $Level -Message ("Invocation: {0}" -f $ErrorRecord.InvocationInfo.PositionMessage)
    }
    if ($ErrorRecord.ScriptStackTrace) {
        Write-LauncherLog -Level $Level -Message ("ScriptStackTrace: {0}" -f ($ErrorRecord.ScriptStackTrace -replace "(`r`n|`n|`r)", " | "))
    }
}

function Read-LauncherPause {
    param([string]$Prompt = "Press Enter to close this launcher")

    try {
        Read-Host $Prompt | Out-Null
    } catch {
        Write-LauncherLog -Level "WARNING" -Message ("Could not read launcher pause input: {0}" -f $_.Exception.Message)
    }
}

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PreferredPowerShellExe {
    $candidates = New-Object System.Collections.Generic.List[string]

    try {
        $pwshFromPath = Get-Command "pwsh.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pwshFromPath -and $pwshFromPath.Source) {
            $candidates.Add($pwshFromPath.Source) | Out-Null
        }
    } catch {
        Write-LauncherLog -Level "DEBUG" -Message ("Could not resolve pwsh.exe from PATH: {0}" -f $_.Exception.Message)
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

    if (-not [string]::IsNullOrWhiteSpace($env:WINDIR)) {
        $candidates.Add((Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe")) | Out-Null
    }

    try {
        $windowsPowerShellFromPath = Get-Command "powershell.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($windowsPowerShellFromPath -and $windowsPowerShellFromPath.Source) {
            $candidates.Add($windowsPowerShellFromPath.Source) | Out-Null
        }
    } catch {
        Write-LauncherLog -Level "DEBUG" -Message ("Could not resolve powershell.exe from PATH: {0}" -f $_.Exception.Message)
    }

    foreach ($candidate in ($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate) {
            return (Get-Item -LiteralPath $candidate).FullName
        }
    }

    throw "No PowerShell executable was found. Install PowerShell 7 or ensure Windows PowerShell is available."
}

function Get-WindowsTerminalExe {
    $candidates = New-Object System.Collections.Generic.List[string]

    try {
        $wtFromPath = Get-Command "wt.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($wtFromPath -and $wtFromPath.Source) {
            $candidates.Add($wtFromPath.Source) | Out-Null
        }
    } catch {
        Write-LauncherLog -Level "DEBUG" -Message ("Could not resolve wt.exe from PATH: {0}" -f $_.Exception.Message)
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\wt.exe")) | Out-Null
    }

    foreach ($candidate in ($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate) {
            return (Get-Item -LiteralPath $candidate).FullName
        }
    }

    return $null
}

function Join-CommandLineArgument {
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }

    $escaped = $Value.Replace('"', '\"')
    return '"' + $escaped + '"'
}

function Join-PowerShellLiteral {
    param([AllowEmptyString()][string]$Value)

    return "'" + ($Value -replace "'", "''") + "'"
}

function Get-SafeProcessArgumentSummary {
    param([string[]]$Arguments)

    if (-not $Arguments -or $Arguments.Count -eq 0) { return "<none>" }
    return ($Arguments -join " ")
}

Initialize-LauncherLog

try {
    Write-LauncherLog -Level "INFO" -Message ("Launcher started. executionId={0}" -f $executionId)
    Write-LauncherLog -Level "INFO" -Message ("scriptRoot={0}" -f $scriptRoot)
    Write-LauncherLog -Level "INFO" -Message ("mainScriptPath={0}" -f $mainScriptPath)
    Write-LauncherLog -Level "INFO" -Message ("currentDirectory={0}" -f (Get-Location).Path)
    Write-LauncherLog -Level "INFO" -Message ("user={0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
    Write-LauncherLog -Level "INFO" -Message ("host={0} psVersion={1} os={2}" -f $Host.Name, $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString)
    Write-LauncherLog -Level "INFO" -Message ("switches Full={0} NoPause={1} NoColor={2} NoReboot={3} NoRelocate={4}" -f $Full.IsPresent, $NoPause.IsPresent, $NoColor.IsPresent, $NoReboot.IsPresent, $NoRelocate.IsPresent)

    try {
        Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force | Out-Null
        Write-LauncherLog -Level "DEBUG" -Message "Process execution policy set to Bypass."
    } catch {
        Write-LauncherException -Level "ERROR" -ErrorRecord $_ -Context "Could not set process execution policy"
        Write-Host ("Could not set process execution policy: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Read-LauncherPause
        exit 1
    }

    if (-not (Test-Path -LiteralPath $mainScriptPath)) {
        Write-LauncherLog -Level "ERROR" -Message ("Main script was not found: {0}" -f $mainScriptPath)
        Write-Host "WinServerSetup.ps1 was not found next to this launcher." -ForegroundColor Red
        if ($script:LauncherLogReady) { Write-Host ("Launcher log: {0}" -f $script:LauncherLog) -ForegroundColor Yellow }
        Read-LauncherPause
        exit 1
    }

    $powerShellExe = Get-PreferredPowerShellExe
    $windowsTerminalExe = Get-WindowsTerminalExe
    Write-LauncherLog -Level "INFO" -Message ("powerShellExe={0}" -f $powerShellExe)
    if ($windowsTerminalExe) {
        Write-LauncherLog -Level "INFO" -Message ("windowsTerminalExe={0}" -f $windowsTerminalExe)
    } else {
        Write-LauncherLog -Level "WARNING" -Message "Windows Terminal was not found; elevated relaunch will use the selected PowerShell host directly."
    }

    $childArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $mainScriptPath)
    $forwardedSwitches = @()
    if ($Full)       { $childArgs += "-Full";       $forwardedSwitches += "-Full" }
    if ($NoPause)    { $childArgs += "-NoPause";    $forwardedSwitches += "-NoPause" }
    if ($NoColor)    { $childArgs += "-NoColor";    $forwardedSwitches += "-NoColor" }
    if ($NoReboot)   { $childArgs += "-NoReboot";   $forwardedSwitches += "-NoReboot" }
    if ($NoRelocate) { $childArgs += "-NoRelocate"; $forwardedSwitches += "-NoRelocate" }
    Write-LauncherLog -Level "INFO" -Message ("childArgs={0}" -f (Get-SafeProcessArgumentSummary -Arguments $childArgs))

    $isElevated = Test-IsElevated
    Write-LauncherLog -Level "INFO" -Message ("isElevated={0}" -f $isElevated)

    if ($isElevated) {
        Write-LauncherLog -Level "INFO" -Message "Already elevated; running WinServerSetup in the current console."
        try {
            Push-Location -LiteralPath $scriptRoot
            & $powerShellExe @childArgs
            $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
            Write-LauncherLog -Level "INFO" -Message ("WinServerSetup exited in current console. exitCode={0}" -f $exitCode)
            if ($exitCode -ne 0) {
                Write-Host ("WinServerSetup exited with code {0}." -f $exitCode) -ForegroundColor Red
                if ($script:LauncherLogReady) { Write-Host ("Launcher log: {0}" -f $script:LauncherLog) -ForegroundColor Yellow }
                Read-LauncherPause
            }
            exit $exitCode
        } catch {
            Write-LauncherException -Level "CRITICAL" -ErrorRecord $_ -Context "WinServerSetup failed in current console"
            Write-Host "WinServerSetup failed before it could continue." -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Red
            if ($script:LauncherLogReady) { Write-Host ("Launcher log: {0}" -f $script:LauncherLog) -ForegroundColor Yellow }
            Read-LauncherPause
            exit 1
        } finally {
            try { Pop-Location } catch { Write-LauncherLog -Level "WARNING" -Message ("Could not restore location: {0}" -f $_.Exception.Message) }
        }
    }

    $switchInvocation = if ($forwardedSwitches.Count -gt 0) { " " + ($forwardedSwitches -join " ") } else { "" }
    $wrapperCommand = @"
`$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $(Join-PowerShellLiteral -Value $scriptRoot)
try {
    & $(Join-PowerShellLiteral -Value $mainScriptPath)$switchInvocation
    `$exitCode = if (`$null -ne `$LASTEXITCODE) { `$LASTEXITCODE } else { 0 }
    if (`$exitCode -ne 0) {
        Write-Host ('WinServerSetup exited with code {0}.' -f `$exitCode) -ForegroundColor Red
        Read-Host 'Press Enter to close this launcher' | Out-Null
    }
    exit `$exitCode
} catch {
    Write-Host 'WinServerSetup failed before it could continue.' -ForegroundColor Red
    Write-Host `$_.Exception.Message -ForegroundColor Red
    if (`$_.InvocationInfo) { Write-Host `$_.InvocationInfo.PositionMessage -ForegroundColor DarkYellow }
    Read-Host 'Press Enter to close this launcher' | Out-Null
    exit 1
}
"@
    $elevatedArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $wrapperCommand)
    $elevatedArgumentLine = ($elevatedArgs | ForEach-Object { Join-CommandLineArgument -Value $_ }) -join " "
    Write-LauncherLog -Level "INFO" -Message "Not elevated; starting elevated child through UAC."
    Write-LauncherLog -Level "DEBUG" -Message ("elevatedArgumentLine={0}" -f $elevatedArgumentLine)

    if ($windowsTerminalExe) {
        $terminalArgs = @("-w", "0", "new-tab", "--title", "Administrator: WinServerSetup", "--suppressApplicationTitle", "--startingDirectory", $scriptRoot, $powerShellExe) + $elevatedArgs
        $terminalArgumentLine = ($terminalArgs | ForEach-Object { Join-CommandLineArgument -Value $_ }) -join " "
        Write-LauncherLog -Level "INFO" -Message "Windows Terminal is available; starting elevated child in a Terminal tab."
        Write-LauncherLog -Level "DEBUG" -Message ("terminalArgumentLine={0}" -f $terminalArgumentLine)

        try {
            $terminal = Start-Process $windowsTerminalExe -ArgumentList $terminalArgumentLine -WorkingDirectory $scriptRoot -Verb RunAs -Wait -PassThru
            $terminalExitCode = if ($null -ne $terminal.ExitCode) { $terminal.ExitCode } else { 0 }
            Write-LauncherLog -Level "INFO" -Message ("Windows Terminal launch completed. processId={0} exitCode={1}" -f $terminal.Id, $terminalExitCode)
            exit $terminalExitCode
        } catch {
            Write-LauncherException -Level "CRITICAL" -ErrorRecord $_ -Context "Failed to start elevated Windows Terminal child"
            Write-Host "Failed to elevate through Windows Terminal." -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Red
            if ($script:LauncherLogReady) { Write-Host ("Launcher log: {0}" -f $script:LauncherLog) -ForegroundColor Yellow }
            Read-LauncherPause
            exit 1
        }
    } else {
        try {
            $elevated = Start-Process $powerShellExe -ArgumentList $elevatedArgumentLine -WorkingDirectory $scriptRoot -Verb RunAs -Wait -PassThru
            $exitCode = if ($null -ne $elevated.ExitCode) { $elevated.ExitCode } else { 0 }
            Write-LauncherLog -Level "INFO" -Message ("Elevated child completed. processId={0} exitCode={1}" -f $elevated.Id, $exitCode)
            exit $exitCode
        } catch {
            Write-LauncherException -Level "CRITICAL" -ErrorRecord $_ -Context "Failed to start elevated child"
            Write-Host "Failed to elevate. Please right-click PowerShell and choose 'Run as Administrator'." -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Red
            if ($script:LauncherLogReady) { Write-Host ("Launcher log: {0}" -f $script:LauncherLog) -ForegroundColor Yellow }
            Read-LauncherPause
            exit 1
        }
    }
} finally {
    $duration = [DateTime]::UtcNow - $launcherStartedUtc
    Write-LauncherLog -Level "INFO" -Message ("Launcher finished. executionId={0} durationSeconds={1:N2}" -f $executionId, $duration.TotalSeconds)
}
