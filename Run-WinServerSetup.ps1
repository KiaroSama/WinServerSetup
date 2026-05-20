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

Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force | Out-Null

$scriptPath = Join-Path $PSScriptRoot "WinServerSetup.ps1"

function Read-AnyKeyExit {
    param([string]$Prompt = "Press any key to exit...")
    Write-Host $Prompt -ForegroundColor Yellow
    try {
        if ($Host.UI.RawUI -and [Console]::IsInputRedirected -eq $false) {
            [void][Console]::ReadKey($true)
            return
        }
    } catch { }
    Read-Host | Out-Null
}

if (-not (Test-Path $scriptPath)) {
    Write-Host "WinServerSetup.ps1 was not found next to this launcher." -ForegroundColor Red
    Read-AnyKeyExit
    exit 1
}

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$childArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptPath`"")
if ($Full)       { $childArgs += "-Full" }
if ($NoPause)    { $childArgs += "-NoPause" }
if ($NoColor)    { $childArgs += "-NoColor" }
if ($NoReboot)   { $childArgs += "-NoReboot" }
if ($NoRelocate) { $childArgs += "-NoRelocate" }

if (Test-IsElevated) {
    # Already elevated: run in this window so logs are visible inline.
    & powershell.exe @childArgs
    exit $LASTEXITCODE
}

# Not elevated: relaunch elevated. -Verb RunAs triggers UAC.
try {
    Start-Process powershell.exe -ArgumentList $childArgs -Verb RunAs
} catch {
    Write-Host "Failed to elevate. Please right-click PowerShell and choose 'Run as Administrator'." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Read-AnyKeyExit
    exit 1
}
