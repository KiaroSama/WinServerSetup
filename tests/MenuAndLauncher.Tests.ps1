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

Assert-Contains `
    -Text $main `
    -Pattern 'Read-HostUntimed\s+-Prompt\s+"Select"\s+-DefaultValue\s+"1"' `
    -Message "Main menu must show Select with default [1] and submit option 1 when Enter is pressed."

Assert-Contains `
    -Text $main `
    -Pattern 'Write-Option\s+-Number\s+"10"\s+-Label\s+"Configure RDP port and firewall \(safe\)"\s+-Color\s+"Red"' `
    -Message "RDP menu option should use a red category color for stronger visual separation."

Assert-Contains `
    -Text $main `
    -Pattern 'Write-Option\s+-Number\s+"22"\s+-Label\s+"Clean temp and cache"\s+-Color\s+"Magenta"' `
    -Message "Cleanup menu option should use its own bright category color."

Assert-Contains `
    -Text $launcher `
    -Pattern 'Run-WinServerSetup_\$stamp`?_UTC\.log' `
    -Message "Launcher must create a per-run UTC diagnostic log file."

Assert-Contains `
    -Text $launcher `
    -Pattern 'Start-Process\s+\$powerShellExe\s+-ArgumentList\s+\$elevatedArgumentLine\s+-WorkingDirectory\s+\$scriptRoot\s+-Verb\s+RunAs' `
    -Message "Launcher must start the elevated child from the script directory with a robust quoted argument line."

Assert-Contains `
    -Text $launcher `
    -Pattern 'Press Enter to close this launcher' `
    -Message "Launcher must keep the window open after elevation or child-process failures."

Write-Host "PASS menu defaults, colorful categories, and launcher diagnostics are present."
