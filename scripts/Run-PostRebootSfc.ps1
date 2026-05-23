# Run-PostRebootSfc.ps1
# Scheduled at startup by WinServerSetup -> Register-PostRebootSfcTask.
# Runs sfc /scannow once, writes the result into <project>/logs/sfc-result.log,
# then unregisters its own scheduled task.

[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [string]$TaskName = "WinServerSetup Post-Reboot SFC"
)

$ErrorActionPreference = "Stop"
$script:ProjectRootOverride = $ProjectRoot

function Resolve-ProjectRoot {
    $candidateRoot = $script:ProjectRootOverride
    if (-not [string]::IsNullOrWhiteSpace($candidateRoot) -and (Test-Path $candidateRoot)) {
        return (Resolve-Path -LiteralPath $candidateRoot).Path
    }
    if ($PSScriptRoot) { return (Split-Path -Parent $PSScriptRoot) }
    return (Get-Location).Path
}

function Initialize-LogFile {
    param([Parameter(Mandatory)][string]$Root)
    $logDir = Join-Path $Root "logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $log = Join-Path $logDir "sfc-result.log"
    Set-Content -LiteralPath $log -Value ("# SFC post-reboot run started {0}" -f (Get-Date -Format "u")) -Encoding utf8
    return $log
}

function Write-LogLine {
    param([Parameter(Mandatory)][string]$LogFile, [Parameter(Mandatory)][string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1,-5}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8
}

function Read-ProcessOutputFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return @() }

    foreach ($encoding in @("Unicode", "UTF8", "Default")) {
        try {
            $content = @(Get-Content -LiteralPath $Path -Encoding $encoding -ErrorAction Stop)
            $joined = ($content -join "")
            if ($content.Count -eq 0 -or $joined -notmatch "`0") {
                return $content
            }
        } catch {
            $null = $_
        }
    }
    return @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
}

$root = Resolve-ProjectRoot
$log  = Initialize-LogFile -Root $root
Write-LogLine -LogFile $log -Message "Starting sfc /scannow ..."

$tempOut = $null
$tempErr = $null
try {
    # cmd.exe /u gives the redirected stream a stable Unicode encoding.
    $tempOut = [System.IO.Path]::GetTempFileName()
    $tempErr = [System.IO.Path]::GetTempFileName()
    $proc = Start-Process -FilePath (Join-Path $env:windir "System32\cmd.exe") `
        -ArgumentList @("/u", "/d", "/c", "sfc /scannow") -PassThru -Wait -WindowStyle Hidden `
        -RedirectStandardOutput $tempOut -RedirectStandardError $tempErr

    foreach ($tempFile in @($tempOut, $tempErr)) {
        Read-ProcessOutputFile -Path $tempFile | ForEach-Object {
            if ($_ -and ($_ -match '\S')) { Write-LogLine -LogFile $log -Message $_ -Level "SFC" }
        }
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
    Write-LogLine -LogFile $log -Message ("sfc exit code: {0}" -f $proc.ExitCode) -Level "INFO"
    if ($proc.ExitCode -eq 0) {
        Write-LogLine -LogFile $log -Message "SFC scan completed successfully." -Level "OK"
    } else {
        Write-LogLine -LogFile $log -Message "SFC scan returned non-zero exit code." -Level "WARN"
    }
} catch {
    Write-LogLine -LogFile $log -Message ("SFC scan failed: {0}" -f $_.Exception.Message) -Level "ERROR"
} finally {
    foreach ($tempFile in @($tempOut, $tempErr)) {
        if ($tempFile -and (Test-Path $tempFile)) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
    # Unregister the scheduled task so this only runs once after reboot.
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        Write-LogLine -LogFile $log -Message "Unregistered scheduled task: $TaskName" -Level "INFO"
    } catch {
        Write-LogLine -LogFile $log -Message ("Could not unregister task {0}: {1}" -f $TaskName, $_.Exception.Message) -Level "WARN"
    }
    Write-LogLine -LogFile $log -Message ("# SFC post-reboot run finished {0}" -f (Get-Date -Format "u"))
}
