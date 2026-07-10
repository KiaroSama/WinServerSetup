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

function Assert-Equal {
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Expected -ne $Actual) {
        throw ("{0} Expected: {1}. Actual: {2}." -f $Message, $Expected, $Actual)
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

$tokens = $null
$parseErrors = $null
$launcherAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $launcherScript,
    [ref]$tokens,
    [ref]$parseErrors
)
Assert-True -Condition ($parseErrors.Count -eq 0) -Message "Launcher must parse before its route selection can be tested."

$routeFunctionAst = $launcherAst.FindAll(
    {
        param($node)
        ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
            ($node.Name -eq "Get-LauncherRoute")
    },
    $true
) | Select-Object -First 1

Assert-True `
    -Condition ($null -ne $routeFunctionAst) `
    -Message "Launcher must expose a testable route decision that prioritizes Windows Terminal before PowerShell hosts."

$routeFunctionText = $routeFunctionAst.Extent.Text
$routeFunctionBlock = [scriptblock]::Create($routeFunctionText)
. $routeFunctionBlock

Assert-Equal `
    -Expected "WindowsTerminal" `
    -Actual (Get-LauncherRoute -WindowsTerminalAvailable $true -IsWindowsTerminalSession $false -IsElevated $true) `
    -Message "An elevated ConsoleHost launch must still move into Windows Terminal when it is available."

Assert-Equal `
    -Expected "WindowsTerminal" `
    -Actual (Get-LauncherRoute -WindowsTerminalAvailable $true -IsWindowsTerminalSession $true -IsElevated $false) `
    -Message "A non-elevated Windows Terminal session must open an elevated Windows Terminal child."

Assert-Equal `
    -Expected "CurrentConsole" `
    -Actual (Get-LauncherRoute -WindowsTerminalAvailable $true -IsWindowsTerminalSession $true -IsElevated $true) `
    -Message "An already elevated Windows Terminal session should remain in its current terminal."

Assert-Equal `
    -Expected "CurrentConsole" `
    -Actual (Get-LauncherRoute -WindowsTerminalAvailable $false -IsWindowsTerminalSession $false -IsElevated $true) `
    -Message "Without Windows Terminal, an elevated session should use the preferred PowerShell host in the current console."

Assert-Equal `
    -Expected "ElevatedPowerShell" `
    -Actual (Get-LauncherRoute -WindowsTerminalAvailable $false -IsWindowsTerminalSession $false -IsElevated $false) `
    -Message "Without Windows Terminal, a non-elevated session should elevate the preferred PowerShell host."

Assert-Contains `
    -Text $launcher `
    -Pattern '\$launcherRoute\s*=\s*Get-LauncherRoute' `
    -Message "Launcher runtime must use the tested route decision."

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

Assert-Contains `
    -Text $main `
    -Pattern 'Start-Process\s+\$relaunchPowerShellExe\s+-ArgumentList\s+\$childArgs\s+-NoNewWindow\s+-PassThru' `
    -Message "Self-relocation relaunch must remain in the current Windows Terminal console instead of opening a separate PowerShell window."

Assert-True `
    -Condition ($main -notmatch 'Start-Transcript[^\r\n]*-Encoding') `
    -Message "Start-Transcript must not use -Encoding because Windows PowerShell 5.1 does not support that parameter."

foreach ($tokenPattern in @(
    "Action\s*=\s*'Magenta'",
    "Label\s*=\s*'Gray'",
    "Value\s*=\s*'Yellow'",
    "Path\s*=\s*'Cyan'"
)) {
    Assert-Contains `
        -Text $main `
        -Pattern $tokenPattern `
        -Message ("Console palette must define the extracted semantic token: {0}" -f $tokenPattern)
}

$mainTokens = $null
$mainParseErrors = $null
$mainAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $mainScript,
    [ref]$mainTokens,
    [ref]$mainParseErrors
)
Assert-True -Condition ($mainParseErrors.Count -eq 0) -Message "Main script must parse before its console state renderer can be tested."

$stateFunctionAst = $mainAst.FindAll(
    {
        param($node)
        ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
            ($node.Name -eq "Write-StateLine")
    },
    $true
) | Select-Object -First 1

Assert-True `
    -Condition ($null -ne $stateFunctionAst) `
    -Message "Console startup output must use a reusable semantic state-line renderer."

$stateFunctionText = $stateFunctionAst.Extent.Text
$stateFunctionBlock = [scriptblock]::Create($stateFunctionText)
. $stateFunctionBlock

$script:CapturedThemedCalls = @()
$script:CapturedStructuredCalls = @()
function Write-Themed {
    param([string]$Message, [string]$Kind, [switch]$NoNewline)
    $script:CapturedThemedCalls += [pscustomobject]@{
        Message = $Message
        Kind = $Kind
        NoNewline = $NoNewline.IsPresent
    }
}
function Write-StructuredLog {
    param([string]$Level, [string]$Message)
    $script:CapturedStructuredCalls += [pscustomobject]@{
        Level = $Level
        Message = $Message
    }
}

try {
    Write-StateLine -State "RUN" -Label "Relaunch script" -Value "C:\Target\WinServerSetup.ps1" -ValueKind "Path"

    Assert-Equal -Expected 3 -Actual $script:CapturedThemedCalls.Count -Message "A value state line must render state, label, and value as separate color segments."
    Assert-Equal -Expected "[RUN]     " -Actual $script:CapturedThemedCalls[0].Message -Message "State tag must use a stable ten-character column."
    Assert-Equal -Expected "Action" -Actual $script:CapturedThemedCalls[0].Kind -Message "RUN state must use the action token."
    Assert-Equal -Expected "Relaunch script: " -Actual $script:CapturedThemedCalls[1].Message -Message "State label must include a readable separator."
    Assert-Equal -Expected "Label" -Actual $script:CapturedThemedCalls[1].Kind -Message "State label must use the neutral label token."
    Assert-Equal -Expected "C:\Target\WinServerSetup.ps1" -Actual $script:CapturedThemedCalls[2].Message -Message "State value must preserve the supplied path."
    Assert-Equal -Expected "Path" -Actual $script:CapturedThemedCalls[2].Kind -Message "Path value must use the path token."
    Assert-Equal -Expected $false -Actual $script:CapturedThemedCalls[2].NoNewline -Message "The final state segment must end the line."
    Assert-Equal -Expected "RUN" -Actual $script:CapturedStructuredCalls[0].Level -Message "The state renderer must forward the visible state to structured logging."
    Assert-Equal -Expected "Relaunch script: C:\Target\WinServerSetup.ps1" -Actual $script:CapturedStructuredCalls[0].Message -Message "The state renderer must forward the plain-text state content to structured logging."

    $expectedStateKinds = @{
        COPY = "Action"
        RUN = "Action"
        SHELL = "Prompt"
        LOG = "Info"
        CLEAN = "Action"
        NEXT = "Prompt"
        SKIP = "SummaryDim"
        VERSION = "Prompt"
    }
    foreach ($stateName in $expectedStateKinds.Keys) {
        $script:CapturedThemedCalls = @()
        $script:CapturedStructuredCalls = @()
        Write-StateLine -State $stateName -Label "State message"
        Assert-Equal `
            -Expected $expectedStateKinds[$stateName] `
            -Actual $script:CapturedThemedCalls[0].Kind `
            -Message ("{0} must use its semantic state color token." -f $stateName)
        Assert-Equal `
            -Expected $stateName `
            -Actual $script:CapturedStructuredCalls[0].Level `
            -Message ("{0} must keep its state name in structured logging." -f $stateName)
    }
} finally {
    Remove-Item -LiteralPath Function:\Write-StateLine -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Write-Themed -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Write-StructuredLog -ErrorAction SilentlyContinue
}

foreach ($state in @("COPY", "RUN", "SHELL", "LOG", "CLEAN", "NEXT", "SKIP", "VERSION")) {
    Assert-Contains `
        -Text $main `
        -Pattern ('Write-StateLine\s+-State\s+"{0}"' -f $state) `
        -Message ("Startup output must include the {0} semantic state." -f $state)
}

foreach ($standardState in @("INFO", "OK", "WARN", "ERROR")) {
    Assert-Contains `
        -Text $main `
        -Pattern ('\("\[{0}\]"\)\.PadRight\(10\)' -f $standardState) `
        -Message ("Standard {0} messages must align with the ten-character startup state column." -f $standardState)
}

foreach ($standardHelper in @("Write-Info", "Write-Ok", "Write-Warn", "Write-Fail")) {
    $helperAst = $mainAst.FindAll(
        {
            param($node)
            ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
                ($node.Name -eq $standardHelper)
        },
        $true
    ) | Select-Object -First 1
    Assert-True -Condition ($null -ne $helperAst) -Message ("{0} must exist." -f $standardHelper)
    $themedWriteCount = ([regex]::Matches($helperAst.Extent.Text, 'Write-Themed')).Count
    Assert-Equal -Expected 1 -Actual $themedWriteCount -Message ("{0} must render each console line atomically." -f $standardHelper)
    Assert-True `
        -Condition ($helperAst.Extent.Text -notmatch '-NoNewline') `
        -Message ("{0} must not split a standard status line across multiple writes." -f $standardHelper)
}

$relocationLogFunctionAst = $mainAst.FindAll(
    {
        param($node)
        ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
            ($node.Name -eq "Add-RelocationLog")
    },
    $true
) | Select-Object -First 1

Assert-True `
    -Condition ($null -ne $relocationLogFunctionAst) `
    -Message "Early self-relocation states must have a dedicated persistent log writer."

$relocationLogFunctionText = $relocationLogFunctionAst.Extent.Text
$relocationLogFunctionBlock = [scriptblock]::Create($relocationLogFunctionText)
. $relocationLogFunctionBlock
$relocationTestLog = Join-Path ([IO.Path]::GetTempPath()) ("WinServerSetup-RelocationLogTest-{0}.log" -f ([guid]::NewGuid().ToString("N")))

try {
    Add-RelocationLog -Path $relocationTestLog -Level "RUN" -Message "Relaunch script: C:\Target\WinServerSetup.ps1"
    Assert-True -Condition (Test-Path -LiteralPath $relocationTestLog) -Message "Relocation log writer must create the requested log file."
    $relocationTestContent = Get-Content -LiteralPath $relocationTestLog -Raw -Encoding UTF8
    Assert-True `
        -Condition ($relocationTestContent -match '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] \[RUN\] Relaunch script: C:\\Target\\WinServerSetup\.ps1') `
        -Message "Relocation log writer must persist timestamp, state, and plain-text content."
} finally {
    if (Test-Path -LiteralPath $relocationTestLog) {
        Remove-Item -LiteralPath $relocationTestLog -Force
    }
    Assert-True -Condition (-not (Test-Path -LiteralPath $relocationTestLog)) -Message "Relocation log test artifact must be cleaned."
    Remove-Item -LiteralPath Function:\Add-RelocationLog -ErrorAction SilentlyContinue
}

foreach ($relocationLevel in @("OK", "RUN", "SHELL", "CLEAN", "NEXT")) {
    Assert-Contains `
        -Text $main `
        -Pattern ('Add-RelocationLog\s+-Path\s+\$relocateLog\s+-Level\s+"{0}"' -f $relocationLevel) `
        -Message ("Relocation log must persist the {0} state before the normal structured log starts." -f $relocationLevel)
}

Write-Host "PASS menu behavior, semantic startup colors, Windows Terminal-first routing, PowerShell fallback order, self-relocation console preservation, and launcher diagnostics are present."
