# Runs a retryable post-reboot SFC scan and preserves one UTC log per execution.

[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [string]$TaskName = "WinServerSetup Post-Reboot SFC",
    [int]$MaxAttempts = 3,
    [int]$RetryDelaySeconds = 60
)

$ErrorActionPreference = "Stop"
$script:ProjectRootOverride = $ProjectRoot

function Resolve-ProjectRoot {
    if (-not [string]::IsNullOrWhiteSpace($script:ProjectRootOverride) -and (Test-Path -LiteralPath $script:ProjectRootOverride)) {
        return (Resolve-Path -LiteralPath $script:ProjectRootOverride).Path
    }
    if ($PSScriptRoot) { return Split-Path -Parent $PSScriptRoot }
    return (Get-Location).Path
}

function Initialize-LogFile {
    param([string]$Root)
    $logDir = Join-Path $Root "logs"
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $baseName = "Run-PostRebootSfc_{0}_UTC" -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd_HH-mm-ss')
    $path = Join-Path $logDir "$baseName.log"
    $suffix = 1
    while (Test-Path -LiteralPath $path) { $path = Join-Path $logDir "$baseName-$suffix.log"; $suffix++ }
    Set-Content -LiteralPath $path -Value "# Post-reboot SFC execution" -Encoding UTF8
    return $path
}

function Write-LogLine {
    param([string]$LogFile, [string]$Message, [string]$Level = "INFO")
    Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value ("[{0}] [{1}] [SFC] {2}" -f (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss 'UTC'"), $Level, $Message)
}

function Read-ProcessOutputFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    foreach ($encoding in @('Unicode', 'UTF8', 'Default')) {
        try {
            $content = @(Get-Content -LiteralPath $Path -Encoding $encoding -ErrorAction Stop)
            if ($content.Count -eq 0 -or ($content -join '') -notmatch "`0") { return $content }
        } catch { $null = $_ }
    }
    return @()
}

if ($MaxAttempts -lt 1 -or $MaxAttempts -gt 10) { throw "MaxAttempts must be between 1 and 10." }
if ($RetryDelaySeconds -lt 0 -or $RetryDelaySeconds -gt 3600) { throw "RetryDelaySeconds must be between 0 and 3600." }

$root = Resolve-ProjectRoot
$log = Initialize-LogFile $root
$succeeded = $false

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $tempOut = [System.IO.Path]::GetTempFileName()
    $tempErr = [System.IO.Path]::GetTempFileName()
    try {
        Write-LogLine $log "Starting sfc /scannow attempt $attempt of $MaxAttempts."
        $proc = Start-Process -FilePath (Join-Path $env:windir "System32\cmd.exe") `
            -ArgumentList @('/u', '/d', '/c', 'sfc /scannow') -PassThru -Wait -WindowStyle Hidden `
            -RedirectStandardOutput $tempOut -RedirectStandardError $tempErr
        foreach ($tempFile in @($tempOut, $tempErr)) {
            Read-ProcessOutputFile $tempFile | ForEach-Object { if ($_ -match '\S') { Write-LogLine $log $_ 'SFC' } }
        }
        Write-LogLine $log "sfc exit code: $($proc.ExitCode)."
        if ($proc.ExitCode -eq 0) { $succeeded = $true; Write-LogLine $log "SFC scan completed successfully." 'OK'; break }
        Write-LogLine $log "SFC scan returned a nonzero exit code." 'WARNING'
    } catch {
        Write-LogLine $log "SFC attempt failed: $($_.Exception.Message)" 'ERROR'
    } finally {
        Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempErr -Force -ErrorAction SilentlyContinue
    }
    if ($attempt -lt $MaxAttempts -and $RetryDelaySeconds -gt 0) {
        Write-LogLine $log "Retrying after $RetryDelaySeconds seconds." 'WARNING'
        Start-Sleep -Seconds $RetryDelaySeconds
    }
}

if ($succeeded) {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop | Out-Null
        Write-LogLine $log "Unregistered scheduled task after successful scan: $TaskName."
    } catch { Write-LogLine $log "Successful scan, but task unregister failed: $($_.Exception.Message)" 'WARNING' }
    exit 0
}

Write-LogLine $log "All SFC attempts failed; the startup task remains registered for a later retry." 'ERROR'
exit 1
