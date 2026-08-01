# Run-WinServerSetup.ps1
# Launcher: right-click "Run with PowerShell" or run from any PowerShell window.
# Prefers Windows Terminal as the console host, PowerShell 7 as the shell, and
# Windows PowerShell 5 only as a fallback. Auto-elevates and forwards all switches.

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

function Test-IsWindowsTerminalSession {
    return -not [string]::IsNullOrWhiteSpace($env:WT_SESSION)
}

function Get-LauncherRoute {
    param(
        [Parameter(Mandatory)][bool]$WindowsTerminalAvailable,
        [Parameter(Mandatory)][bool]$IsWindowsTerminalSession,
        [Parameter(Mandatory)][bool]$IsElevated
    )

    if ($WindowsTerminalAvailable -and ((-not $IsWindowsTerminalSession) -or (-not $IsElevated))) {
        return "WindowsTerminal"
    }

    if ($IsElevated) {
        return "CurrentConsole"
    }

    return "ElevatedPowerShell"
}

function Test-TrustedElevationExecutable {
    <#
        L-04. Whatever this approves is handed to Start-Process -Verb RunAs, so it must live
        where an unprivileged user cannot replace it. A valid signature alone is not enough:
        a byte-copy of the real powershell.exe keeps its signature after being dropped into a
        user-writable directory, so the location has to be proven too. Fail closed - a candidate
        that cannot be verified is rejected.

        Self-contained on purpose: the launcher runs before scripts\Core.ps1 is dot-sourced and
        cannot reach the equivalent helpers there.
    #>
    param([string]$Path)

    # Declared inside the function because the test suites extract a single function by AST; a
    # module-level $script: variable would be undefined there and every principal would look
    # untrusted. Compared by SID, never by display name: names are localized and renameable.
    $trustedSids = @(
        'S-1-5-18',      # LOCAL SYSTEM
        'S-1-5-32-544',  # BUILTIN\Administrators
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464' # NT SERVICE\TrustedInstaller
    )
    $writeRights = 'Write|Modify|FullControl|CreateFiles|Delete|ChangePermissions|TakeOwnership'

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    # A bare name would be resolved by Start-Process through PATH, which is this whole finding.
    if (-not [IO.Path]::IsPathRooted($Path)) { return $false }

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }

        # A reparse point anywhere between the volume root and the file lets whoever controls
        # that one directory redirect the path after it has been checked. The per-user Windows
        # Terminal app-execution alias is exactly this shape.
        $current = $Path
        while (-not [string]::IsNullOrWhiteSpace($current)) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint) { return $false }
            $parent = [IO.Path]::GetDirectoryName($current)
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) { break }
            $current = $parent
        }

        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        # The owner is a writer too: it can always rewrite the DACL and then replace the file.
        if ($trustedSids -notcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) { return $false }
        foreach ($ace in $acl.Access) {
            if ($ace.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
            if (([string]$ace.FileSystemRights) -notmatch $writeRights) { continue }
            $sid = if ($ace.IdentityReference -is [Security.Principal.SecurityIdentifier]) { $ace.IdentityReference.Value }
                   else { $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
            if ($sid -eq 'S-1-3-0') { continue }   # CREATOR OWNER: covered by the owner check above
            if ($trustedSids -notcontains $sid) { return $false }
        }

        return ((Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop).Status -eq 'Valid')
    } catch {
        Write-LauncherLog -Level "DEBUG" -Message ("Rejected an elevation candidate that could not be verified: {0}: {1}" -f $Path, $_.Exception.Message)
        return $false
    }
}

function Get-PreferredPowerShellExe {
    # L-04. Fixed, administrator-owned locations are asked first and PATH only last, because
    # prepending a directory to PATH is something an unprivileged user can do for their own
    # session and this result is what Windows elevates. Every candidate, PATH included, still
    # has to pass Test-TrustedElevationExecutable, so the fallback cannot become a bypass.
    $candidates = New-Object System.Collections.Generic.List[string]

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

    foreach ($name in @("pwsh.exe", "powershell.exe")) {
        try {
            $fromPath = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($fromPath -and $fromPath.Source) {
                $candidates.Add($fromPath.Source) | Out-Null
            }
        } catch {
            Write-LauncherLog -Level "DEBUG" -Message ("Could not resolve {0} from PATH: {1}" -f $name, $_.Exception.Message)
        }
    }

    foreach ($candidate in ($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        if (Test-TrustedElevationExecutable -Path $candidate) {
            return (Get-Item -LiteralPath $candidate).FullName
        }
    }

    throw "No trusted PowerShell executable was found. Install PowerShell 7, or repair Windows PowerShell, so the elevated host can be started from a location only administrators can write to."
}

function Get-WindowsTerminalExe {
    # L-04. The wt.exe PATH offers is normally %LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe: a
    # zero-byte app-execution alias in a directory the interactive user owns outright, and this
    # path is started with -Verb RunAs. Resolve the real package install location first; the
    # alias is gone as a candidate because it can never pass the trust check.
    $candidates = New-Object System.Collections.Generic.List[string]

    try {
        $terminalPackage = Get-AppxPackage -Name "Microsoft.WindowsTerminal" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($terminalPackage -and $terminalPackage.InstallLocation) {
            $candidates.Add((Join-Path $terminalPackage.InstallLocation "wt.exe")) | Out-Null
        }
    } catch {
        Write-LauncherLog -Level "DEBUG" -Message ("Could not resolve the Windows Terminal package location: {0}" -f $_.Exception.Message)
    }

    try {
        $wtFromPath = Get-Command "wt.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($wtFromPath -and $wtFromPath.Source) {
            $candidates.Add($wtFromPath.Source) | Out-Null
        }
    } catch {
        Write-LauncherLog -Level "DEBUG" -Message ("Could not resolve wt.exe from PATH: {0}" -f $_.Exception.Message)
    }

    foreach ($candidate in ($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        if (Test-TrustedElevationExecutable -Path $candidate) {
            return (Get-Item -LiteralPath $candidate).FullName
        }
    }

    return $null
}

function Join-CommandLineArgument {
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value) { return '""' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashCount = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $backslashCount++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashCount * 2) + 1)))
            [void]$builder.Append('"')
        } else {
            if ($backslashCount -gt 0) { [void]$builder.Append(('\' * $backslashCount)) }
            [void]$builder.Append($character)
        }
        $backslashCount = 0
    }
    if ($backslashCount -gt 0) { [void]$builder.Append(('\' * ($backslashCount * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
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

function Wait-LauncherResult {
    # The elevated wrapper creates the result file and then writes the exit code into it, so
    # Test-Path can win the race against that write. An absent, empty, locked or half-written
    # file therefore means "not ready yet" and must keep the poll going, never fail the run.
    param(
        [Parameter(Mandatory)][string]$Path,
        $Process,
        [int]$TimeoutSeconds = 14400,
        [int]$ExitGraceSeconds = 5
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $exitDeadline = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            $text = ""
            try {
                # -Raw emits nothing at all for a zero-byte file, and casting that empty
                # pipeline yields $null rather than an empty string, so test before using it.
                $raw = Get-Content -LiteralPath $Path -Raw -Encoding ASCII
                if ($null -ne $raw) { $text = [string]$raw }
            } catch {
                Write-LauncherLog -Level "DEBUG" -Message ("Delegated result file is not readable yet: {0}" -f $_.Exception.Message)
            }
            $exitCode = 0
            if ([int]::TryParse($text.Trim(), [ref]$exitCode)) { return $exitCode }
        }

        # A child that died without leaving a result must fail fast instead of polling for hours.
        # Only a non-zero exit proves failure here: the Windows Terminal client exits 0 as soon as
        # it hands the tab to an existing window, while the setup keeps running inside that tab.
        if ($null -ne $Process) {
            $failedExitCode = $null
            try {
                if ($Process.HasExited -and $Process.ExitCode -ne 0) { $failedExitCode = [int]$Process.ExitCode }
            } catch {
                Write-LauncherLog -Level "DEBUG" -Message ("Could not query the delegated child state: {0}" -f $_.Exception.Message)
            }
            if ($null -eq $failedExitCode) {
                $exitDeadline = $null
            } elseif ($null -eq $exitDeadline) {
                $exitDeadline = [DateTime]::UtcNow.AddSeconds($ExitGraceSeconds)
            } elseif ([DateTime]::UtcNow -ge $exitDeadline) {
                Write-LauncherLog -Level "ERROR" -Message ("Delegated child exited with code {0} without writing its result file: {1}" -f $failedExitCode, $Path)
                Write-Host ("The elevated WinServerSetup child exited with code {0} before reporting a result." -f $failedExitCode) -ForegroundColor Red
                return $failedExitCode
            }
        }

        Start-Sleep -Milliseconds 200
    }

    throw "Timed out waiting for the delegated WinServerSetup result after $TimeoutSeconds seconds."
}

Initialize-LauncherLog
$launcherResultPath = $null

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
    $isWindowsTerminalSession = Test-IsWindowsTerminalSession
    $launcherRoute = Get-LauncherRoute `
        -WindowsTerminalAvailable ($null -ne $windowsTerminalExe) `
        -IsWindowsTerminalSession $isWindowsTerminalSession `
        -IsElevated $isElevated
    Write-LauncherLog -Level "INFO" -Message ("isElevated={0}" -f $isElevated)
    Write-LauncherLog -Level "INFO" -Message ("isWindowsTerminalSession={0} launcherRoute={1}" -f $isWindowsTerminalSession, $launcherRoute)

    # wt.exe splits its own command line on unescaped semicolons before the delegated shell ever
    # sees it, so a single ';' in any forwarded path would silently truncate the command. Escaping
    # is version-dependent; dropping Windows Terminal for this run is the reliable answer.
    if ($launcherRoute -eq "WindowsTerminal") {
        $semicolonPaths = @(@($scriptRoot, $mainScriptPath, $powerShellExe, $env:TEMP) | Where-Object { $_ -and $_.Contains(";") })
        if ($semicolonPaths.Count -gt 0) {
            Write-LauncherLog -Level "WARNING" -Message ("Windows Terminal was skipped because a required path contains a semicolon: {0}" -f ($semicolonPaths -join " | "))
            Write-Host "A project or temp path contains ';', which Windows Terminal cannot receive; using PowerShell directly." -ForegroundColor Yellow
            $launcherRoute = Get-LauncherRoute `
                -WindowsTerminalAvailable $false `
                -IsWindowsTerminalSession $isWindowsTerminalSession `
                -IsElevated $isElevated
            Write-LauncherLog -Level "INFO" -Message ("launcherRoute downgraded to {0}" -f $launcherRoute)
        }
    }

    if ($launcherRoute -eq "CurrentConsole") {
        Write-LauncherLog -Level "INFO" -Message "Using the current elevated Windows Terminal session, or the current console because Windows Terminal is unavailable."
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
    $launcherResultPath = Join-Path $env:TEMP ("WinServerSetup-launcher-result-{0}.txt" -f ([guid]::NewGuid().ToString('N')))
    $wrapperCommand = @"
`$ErrorActionPreference = 'Stop'
`$resultPath = $(Join-PowerShellLiteral -Value $launcherResultPath)
`$exitCode = 1
Set-Location -LiteralPath $(Join-PowerShellLiteral -Value $scriptRoot)
try {
    & $(Join-PowerShellLiteral -Value $mainScriptPath)$switchInvocation
    `$exitCode = if (`$null -ne `$LASTEXITCODE) { `$LASTEXITCODE } else { 0 }
    if (`$exitCode -ne 0) {
        Write-Host ('WinServerSetup exited with code {0}.' -f `$exitCode) -ForegroundColor Red
        Read-Host 'Press Enter to close this launcher' | Out-Null
    }
} catch {
    Write-Host 'WinServerSetup failed before it could continue.' -ForegroundColor Red
    Write-Host `$_.Exception.Message -ForegroundColor Red
    if (`$_.InvocationInfo) { Write-Host `$_.InvocationInfo.PositionMessage -ForegroundColor DarkYellow }
    Read-Host 'Press Enter to close this launcher' | Out-Null
    `$exitCode = 1
} finally {
    Set-Content -LiteralPath `$resultPath -Value `$exitCode -Encoding ASCII -Force
}
exit `$exitCode
"@
    $elevatedArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $wrapperCommand)
    $elevatedArgumentLine = ($elevatedArgs | ForEach-Object { Join-CommandLineArgument -Value $_ }) -join " "
    Write-LauncherLog -Level "INFO" -Message ("Starting selected child route. launcherRoute={0} elevationRequired={1}" -f $launcherRoute, (-not $isElevated))
    Write-LauncherLog -Level "DEBUG" -Message ("elevatedArgumentLine={0}" -f $elevatedArgumentLine)

    if ($launcherRoute -eq "WindowsTerminal") {
        $terminalArgs = @("-w", "0", "new-tab", "--title", "Administrator: WinServerSetup", "--suppressApplicationTitle", "--startingDirectory", $scriptRoot, $powerShellExe) + $elevatedArgs
        $terminalArgumentLine = ($terminalArgs | ForEach-Object { Join-CommandLineArgument -Value $_ }) -join " "
        Write-LauncherLog -Level "INFO" -Message "Windows Terminal has first priority; starting the selected PowerShell host in an elevated Terminal tab."
        Write-LauncherLog -Level "DEBUG" -Message ("terminalArgumentLine={0}" -f $terminalArgumentLine)

        try {
            $terminal = Start-Process $windowsTerminalExe -ArgumentList $terminalArgumentLine -WorkingDirectory $scriptRoot -Verb RunAs -PassThru
            $terminalExitCode = if ($terminal.HasExited) { $terminal.ExitCode } else { '<delegated>' }
            Write-LauncherLog -Level "INFO" -Message ("Windows Terminal delegation started. processId={0} clientExitCode={1}" -f $terminal.Id, $terminalExitCode)
            $exitCode = Wait-LauncherResult -Path $launcherResultPath -Process $terminal
            Write-LauncherLog -Level "INFO" -Message ("Delegated WinServerSetup completed. exitCode={0}" -f $exitCode)
            exit $exitCode
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
            $elevated = Start-Process $powerShellExe -ArgumentList $elevatedArgumentLine -WorkingDirectory $scriptRoot -Verb RunAs -PassThru
            $exitCode = Wait-LauncherResult -Path $launcherResultPath -Process $elevated
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
    if ($launcherResultPath) { Remove-Item -LiteralPath $launcherResultPath -Force -ErrorAction SilentlyContinue }
    $duration = [DateTime]::UtcNow - $launcherStartedUtc
    Write-LauncherLog -Level "INFO" -Message ("Launcher finished. executionId={0} durationSeconds={1:N2}" -f $executionId, $duration.TotalSeconds)
}
