param()

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$mainScript = Join-Path $projectRoot "WinServerSetup.ps1"
$launcherScript = Join-Path $projectRoot "Run-WinServerSetup.ps1"

$main = Get-Content -LiteralPath $mainScript -Raw -Encoding UTF8
$launcher = Get-Content -LiteralPath $launcherScript -Raw -Encoding UTF8

function Assert-Contains {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Text -notmatch $Pattern) {
        throw $Message
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

Assert-Contains `
    -Text $main `
    -Pattern 'Read-HostUntimed\s+-Prompt\s+"Select"\s+-DefaultValue\s+"1"' `
    -Message "Main menu must show Select with default [1] and submit option 1 when Enter is pressed."

$menuBlockMatch = [regex]::Match(
    $main,
    '(?s)Write-Option\s+-Number\s+"1".*?Write-Option\s+-Number\s+"0"\s+-Label\s+"Back / Exit"\s+-Color\s+"[^"]+"'
)
Assert-True -Condition $menuBlockMatch.Success -Message "Main menu Write-Option block was not found."

$menuColors = [regex]::Matches($menuBlockMatch.Value, '-Color\s+"([^"]+)"') |
    ForEach-Object { $_.Groups[1].Value }
$uniqueMenuColors = @($menuColors | Sort-Object -Unique)

Assert-True `
    -Condition ($menuColors.Count -ge 27) `
    -Message "Every main menu option should declare the unified menu label color."

Assert-True `
    -Condition (($uniqueMenuColors.Count -eq 1) -and ($uniqueMenuColors[0] -eq "Cyan")) `
    -Message ("Main menu labels must use one unified bright color. Actual colors: {0}" -f ($uniqueMenuColors -join ", "))

Assert-True `
    -Condition ($menuBlockMatch.Value -notmatch '-Color\s+"(Red|Magenta|Dark[^"]*)"') `
    -Message "Main menu labels must not use dark-looking red, purple, or Dark* colors."

Assert-Contains `
    -Text $launcher `
    -Pattern 'Run-WinServerSetup_\$stamp`?_UTC\.log' `
    -Message "Launcher must create a per-run UTC diagnostic log file."

Assert-Contains `
    -Text $launcher `
    -Pattern 'function\s+Get-PreferredPowerShellExe' `
    -Message "Launcher must resolve a preferred PowerShell executable instead of hard-coding Windows PowerShell 5."

$pwshIndex = $launcher.IndexOf('Get-Command "pwsh.exe"')
$winPsIndex = $launcher.IndexOf('WindowsPowerShell\v1.0\powershell.exe')
Assert-True `
    -Condition (($pwshIndex -ge 0) -and ($winPsIndex -gt $pwshIndex)) `
    -Message "Launcher must prefer PowerShell 7 (pwsh.exe) before falling back to Windows PowerShell 5."

Assert-Contains `
    -Text $launcher `
    -Pattern 'function\s+Get-WindowsTerminalExe' `
    -Message "Launcher must resolve Windows Terminal when available."

Assert-Contains `
    -Text $launcher `
    -Pattern '@\("-w",\s*"0",\s*"new-tab"' `
    -Message "Launcher must prefer a Windows Terminal tab in the most recent window."

Assert-Contains `
    -Text $launcher `
    -Pattern 'Start-Process\s+\$windowsTerminalExe\s+-ArgumentList\s+\$terminalArgumentLine\s+-WorkingDirectory\s+\$scriptRoot\s+-Verb\s+RunAs' `
    -Message "Launcher must start elevated runs through Windows Terminal when available."

Assert-Contains `
    -Text $launcher `
    -Pattern 'Start-Process\s+\$powerShellExe\s+-ArgumentList\s+\$elevatedArgumentLine\s+-WorkingDirectory\s+\$scriptRoot\s+-Verb\s+RunAs' `
    -Message "Launcher must keep a direct PowerShell elevation fallback with a robust quoted argument line."

Assert-Contains `
    -Text $launcher `
    -Pattern 'Press Enter to close this launcher' `
    -Message "Launcher must keep the window open after elevation or child-process failures."

Assert-Contains `
    -Text $main `
    -Pattern 'function\s+Get-PreferredPowerShellForRelaunch' `
    -Message "Main script must resolve a preferred PowerShell executable before self-relocation relaunches."

Assert-Contains `
    -Text $main `
    -Pattern 'Start-Process\s+\$relaunchPowerShellExe\s+-ArgumentList\s+\$childArgs' `
    -Message "Self-relocation relaunch must use the preferred PowerShell executable instead of hard-coded powershell.exe."

Assert-True `
    -Condition ($main -notmatch 'Start-Transcript[^\r\n]*-Encoding') `
    -Message "Start-Transcript must not use -Encoding because Windows PowerShell 5.1 does not support that parameter."

Write-Host "PASS menu default, unified bright menu color, PowerShell 7 priority, Windows Terminal priority, and launcher diagnostics are present."
