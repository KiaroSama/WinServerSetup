# Console stubs mirror the real signatures so the extracted functions bind as in production.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub signatures mirror production collaborators so parameter binding matches.')]
param()

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$mainScript = Join-Path $projectRoot "WinServerSetup.ps1"
$launcherScript = Join-Path $projectRoot "Run-WinServerSetup.ps1"

# WinServerSetup.ps1 dot-sources its function library from scripts\; the assertions below cover
# that whole partition, so read and parse it as one source text.
$setupSourceFiles = @($mainScript) + @(
    @('Console', 'Core', 'Download', 'Rdp', 'Install', 'SystemSettings', 'Maintenance') |
        ForEach-Object { Join-Path $projectRoot ("scripts\{0}.ps1" -f $_) } |
        Where-Object { Test-Path -LiteralPath $_ }
)
$main = ($setupSourceFiles | ForEach-Object { Get-Content -LiteralPath $_ -Raw -Encoding UTF8 }) -join "`r`n"
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
    '(?s)Write-Option\s+-Number\s+"1".*?Write-Option\s+-Number\s+"0"\s+-Label\s+"Back / Exit"'
)
Assert-True -Condition $menuBlockMatch.Success -Message "Main menu Write-Option block was not found."

Assert-True `
    -Condition ($menuBlockMatch.Value -notmatch '-Color|-NumberColor') `
    -Message "Menu options must not declare per-option colors; the style is a light-blue number and a plain label."

Assert-Contains `
    -Text $main `
    -Pattern '(?s)function\s+Write-Option.*?-Kind\s+StartupLabel\s+-NoNewline\s+Write-Host\s+\$Label' `
    -Message "Write-Option must render a light-blue option number followed by a plain label."

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
    "Banner\s*=\s*'Magenta'",
    "MenuHeader\s*=\s*'Cyan'",
    "StartupLabel\s*=\s*'Cyan'",
    "StartupValue\s*=\s*'Yellow'",
    "StartupPath\s*=\s*'White'",
    "StartupOk\s*=\s*'Green'",
    "StartupDim\s*=\s*'DarkGray'",
    "StartupNote\s*=\s*'Yellow'"
)) {
    Assert-Contains `
        -Text $main `
        -Pattern $tokenPattern `
        -Message ("Console palette must define a ConsoleColor fallback for the startup token: {0}" -f $tokenPattern)
}

foreach ($ansiPattern in @(
    "Banner\s*=\s*`"\`$\(\[char\]27\)\[1m\`$\(\[char\]27\)\[38;2;255;50;115m`"",
    "BannerRule\s*=\s*`"\`$\(\[char\]27\)\[38;2;255;50;115m`"",
    "MenuHeader\s*=\s*`"\`$\(\[char\]27\)\[1m\`$\(\[char\]27\)\[38;5;117m`""
)) {
    Assert-Contains `
        -Text $main `
        -Pattern $ansiPattern `
        -Message ("Startup output must define its exact true-color ANSI sequence: {0}" -f $ansiPattern)
}

$mainTokens = $null
$mainParseErrors = $null
$mainAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $main,
    [ref]$mainTokens,
    [ref]$mainParseErrors
)
Assert-True -Condition ($mainParseErrors.Count -eq 0) -Message "Main script must parse before its console state renderer can be tested."

Assert-True `
    -Condition ($main -notmatch 'function\s+Write-StateLine') `
    -Message "The bracketed [STATE] startup column must be gone; startup lines now read as plain 'Label: value'."

Assert-True `
    -Condition ($main -notmatch 'Write-Rule|Write-Title') `
    -Message "The boxed '==== title ====' menu header must be replaced by a single bold menu-header line."

Assert-Contains `
    -Text $main `
    -Pattern 'Write-Themed\s+"WinServerSetup Main menu:"\s+-Kind\s+MenuHeader' `
    -Message "Main menu must open with one bold menu-header line instead of rule characters."

$startupFunctionAst = $mainAst.FindAll(
    {
        param($node)
        ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
            ($node.Name -eq "Write-StartupLine")
    },
    $true
) | Select-Object -First 1

Assert-True `
    -Condition ($null -ne $startupFunctionAst) `
    -Message "Console startup output must use a reusable 'Label: value' renderer."

$startupFunctionBlock = [scriptblock]::Create($startupFunctionAst.Extent.Text)
. $startupFunctionBlock

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
    Write-StartupLine -State "RUN" -Label "Relaunch script" -Value "C:\Target\WinServerSetup.ps1" -ValueKind "StartupPath"

    Assert-Equal -Expected 2 -Actual $script:CapturedThemedCalls.Count -Message "A startup line must render label and value as two color segments, with no state column."
    Assert-Equal -Expected "Relaunch script: " -Actual $script:CapturedThemedCalls[0].Message -Message "Startup label must include a readable separator and no bracketed tag."
    Assert-Equal -Expected "StartupLabel" -Actual $script:CapturedThemedCalls[0].Kind -Message "Startup label must use the startup label token."
    Assert-Equal -Expected $true -Actual $script:CapturedThemedCalls[0].NoNewline -Message "Startup label must not end the line."
    Assert-Equal -Expected "C:\Target\WinServerSetup.ps1" -Actual $script:CapturedThemedCalls[1].Message -Message "Startup value must preserve the supplied path."
    Assert-Equal -Expected "StartupPath" -Actual $script:CapturedThemedCalls[1].Kind -Message "Path value must use the startup path token."
    Assert-Equal -Expected $false -Actual $script:CapturedThemedCalls[1].NoNewline -Message "The final startup segment must end the line."
    Assert-Equal -Expected "RUN" -Actual $script:CapturedStructuredCalls[0].Level -Message "The startup renderer must forward the machine-readable state to structured logging."
    Assert-Equal -Expected "Relaunch script: C:\Target\WinServerSetup.ps1" -Actual $script:CapturedStructuredCalls[0].Message -Message "The startup renderer must forward the plain-text content to structured logging."

    # A LOG line prints as one solid note-yellow line, not a split label/value
    # pair, so LOG must render as a single Themed call.
    $script:CapturedThemedCalls = @()
    $script:CapturedStructuredCalls = @()
    Write-StartupLine -State "LOG" -Label "Logging to" -Value "C:\logs\WinServerSetup.log" -ValueKind "StartupPath"
    Assert-Equal -Expected 1 -Actual $script:CapturedThemedCalls.Count -Message "A LOG line must render label and value as one solid-color segment."
    Assert-Equal -Expected "Logging to: C:\logs\WinServerSetup.log" -Actual $script:CapturedThemedCalls[0].Message -Message "A LOG line must keep the label and value joined in a single message."
    Assert-Equal -Expected "StartupNote" -Actual $script:CapturedThemedCalls[0].Kind -Message "A LOG line must use the note-yellow token instead of the label/value split tokens."
    Assert-Equal -Expected "LOG" -Actual $script:CapturedStructuredCalls[0].Level -Message "A LOG line must still forward its state to structured logging."

    foreach ($stateName in @("COPY", "RUN", "SHELL", "LOG", "CLEAN", "NEXT", "SKIP", "VERSION", "OK")) {
        $script:CapturedThemedCalls = @()
        $script:CapturedStructuredCalls = @()
        Write-StartupLine -State $stateName -Label "Startup message"
        Assert-Equal `
            -Expected 1 `
            -Actual $script:CapturedThemedCalls.Count `
            -Message ("{0} without a value must render as one plain line." -f $stateName)
        Assert-Equal `
            -Expected $stateName `
            -Actual $script:CapturedStructuredCalls[0].Level `
            -Message ("{0} must keep its state name in structured logging." -f $stateName)
    }
} finally {
    Remove-Item -LiteralPath Function:\Write-StartupLine -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Write-Themed -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Write-StructuredLog -ErrorAction SilentlyContinue
}

foreach ($state in @("COPY", "RUN", "SHELL", "LOG", "CLEAN", "NEXT", "SKIP", "VERSION", "OK")) {
    Assert-Contains `
        -Text $main `
        -Pattern ('Write-StartupLine\s+-State\s+"{0}"' -f $state) `
        -Message ("Startup output must include the {0} state." -f $state)
}

$bannerFunctionAst = $mainAst.FindAll(
    {
        param($node)
        ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
            ($node.Name -eq "Write-Banner")
    },
    $true
) | Select-Object -First 1

Assert-True -Condition ($null -ne $bannerFunctionAst) -Message "Startup must print a centered banner over a full-width rule."

$widthFunctionAst = $mainAst.FindAll(
    {
        param($node)
        ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
            ($node.Name -eq "Get-ConsoleWidth")
    },
    $true
) | Select-Object -First 1

Assert-True -Condition ($null -ne $widthFunctionAst) -Message "Banner width detection must be isolated so hosts without a console can fall back."

. ([scriptblock]::Create($bannerFunctionAst.Extent.Text))
. ([scriptblock]::Create($widthFunctionAst.Extent.Text))

$script:CapturedThemedCalls = @()
function Write-Themed {
    param([string]$Message, [string]$Kind, [switch]$NoNewline)
    $script:CapturedThemedCalls += [pscustomobject]@{ Message = $Message; Kind = $Kind }
}

try {
    Write-Banner

    Assert-Equal -Expected 2 -Actual $script:CapturedThemedCalls.Count -Message "The banner must render a title line and a rule line."
    Assert-Equal -Expected "Banner" -Actual $script:CapturedThemedCalls[0].Kind -Message "The banner title must use the banner token."
    Assert-Equal -Expected "BannerRule" -Actual $script:CapturedThemedCalls[1].Kind -Message "The banner rule must use the banner rule token."

    # In a real console the detected width must be usable. A bare runspace has no
    # RawUI at all, which is where the 80-column fallback has to hold.
    Assert-True -Condition ((Get-ConsoleWidth) -gt 0) -Message "Width detection must return a usable console width when a console exists."

    $hostlessRunspace = [powershell]::Create()
    try {
        $null = $hostlessRunspace.AddScript(($widthFunctionAst.Extent.Text + "`nGet-ConsoleWidth"))
        $hostlessWidth = $hostlessRunspace.Invoke() | Select-Object -First 1
        Assert-Equal -Expected 0 -Actual $hostlessRunspace.Streams.Error.Count -Message "Width detection must not raise errors in a host without RawUI."
        Assert-Equal -Expected 80 -Actual $hostlessWidth -Message "Width detection must fall back to 80 columns in a host without a console window."
    } finally {
        $hostlessRunspace.Dispose()
    }

    $bannerTitleText = "Windows Server Setup"
    foreach ($requestedWidth in @(120, 80, 40, 20, 1)) {
        $script:CapturedThemedCalls = @()
        Write-Banner -Width $requestedWidth

        $bannerTitle = $script:CapturedThemedCalls[0].Message
        $bannerRule = $script:CapturedThemedCalls[1].Message
        $expectedWidth = [Math]::Max($requestedWidth, $bannerTitleText.Length)

        Assert-Equal -Expected $bannerTitleText -Actual $bannerTitle.TrimStart() -Message ("Banner title must survive centering at width {0}." -f $requestedWidth)
        Assert-True -Condition ($bannerRule -match '^=+$') -Message ("Banner rule must be a solid line at width {0}." -f $requestedWidth)
        Assert-Equal -Expected $expectedWidth -Actual $bannerRule.Length -Message ("Banner rule must never shrink below the title at width {0}." -f $requestedWidth)
        Assert-True `
            -Condition ($bannerTitle.Length -le $bannerRule.Length) `
            -Message ("Centered banner title must not overhang its rule at width {0}." -f $requestedWidth)

        $leadingPadding = $bannerTitle.Length - $bannerTitle.TrimStart().Length
        Assert-Equal `
            -Expected ([Math]::Max(0, [int](($expectedWidth - $bannerTitleText.Length) / 2))) `
            -Actual $leadingPadding `
            -Message ("Banner title must be centered against the rule at width {0}." -f $requestedWidth)
    }
} finally {
    Remove-Item -LiteralPath Function:\Write-Banner -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Get-ConsoleWidth -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Write-Themed -ErrorAction SilentlyContinue
}

Assert-Contains `
    -Text $main `
    -Pattern '(?s)try\s*\{\s*Write-Banner' `
    -Message "The banner must print before any other startup output."

foreach ($standardState in @("INFO", "OK", "WARN", "ERROR")) {
    Assert-Contains `
        -Text $main `
        -Pattern ('\("\[{0}\]"\)\.PadRight\(10\)' -f $standardState) `
        -Message ("Long-running task output must keep the aligned [{0}] severity column." -f $standardState)
}

$ansiFunctionAst = $mainAst.FindAll(
    {
        param($node)
        ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
            ($node.Name -eq "Test-AnsiSupported")
    },
    $true
) | Select-Object -First 1

Assert-True `
    -Condition ($null -ne $ansiFunctionAst) `
    -Message "True-color startup output must be gated behind a virtual-terminal capability probe."

Assert-Contains `
    -Text $main `
    -Pattern '(?s)function\s+Write-Themed.*?\$Global:WinServerSetupAnsiColors\.ContainsKey\(\$Kind\)\s+-and\s+\(Test-AnsiSupported\)' `
    -Message "Write-Themed must fall back to ConsoleColor whenever ANSI is unsupported or the kind has no ANSI sequence."

$capabilityFunctionAst = $mainAst.FindAll(
    {
        param($node)
        ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
            ($node.Name -eq "Get-AnsiCapability")
    },
    $true
) | Select-Object -First 1

Assert-True `
    -Condition ($null -ne $capabilityFunctionAst) `
    -Message "The ANSI decision must be a pure, testable function separate from host probing."

. ([scriptblock]::Create($capabilityFunctionAst.Extent.Text))

try {
    Assert-Equal `
        -Expected $true `
        -Actual (Get-AnsiCapability -IsOutputRedirected $false -PSMajorVersion 7 -SupportsVirtualTerminal $true) `
        -Message "PowerShell 7 on a virtual-terminal console must render the exact true-color banner."

    Assert-Equal `
        -Expected $true `
        -Actual (Get-AnsiCapability -IsOutputRedirected $false -PSMajorVersion 7 -SupportsVirtualTerminal $false -IsWindowsTerminal $true) `
        -Message "Windows Terminal must be trusted for ANSI even when the host reports no virtual-terminal flag."

    Assert-Equal `
        -Expected $false `
        -Actual (Get-AnsiCapability -IsOutputRedirected $false -PSMajorVersion 7 -SupportsVirtualTerminal $false -IsWindowsTerminal $false) `
        -Message "A PowerShell 7 host with no virtual-terminal support must fall back to ConsoleColor."

    Assert-Equal `
        -Expected $false `
        -Actual (Get-AnsiCapability -IsOutputRedirected $true -PSMajorVersion 7 -SupportsVirtualTerminal $true -IsWindowsTerminal $true) `
        -Message "Redirected output is a file or pipe and must never receive escape sequences."

    Assert-Equal `
        -Expected $false `
        -Actual (Get-AnsiCapability -IsOutputRedirected $false -PSMajorVersion 5 -SupportsVirtualTerminal $true -IsWindowsTerminal $true) `
        -Message "Windows PowerShell 5.1 copies raw escape bytes into Start-Transcript logs, so it must keep the ConsoleColor palette."
} finally {
    Remove-Item -LiteralPath Function:\Get-AnsiCapability -ErrorAction SilentlyContinue
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

Write-Host "PASS menu behavior, banner and startup line rendering, ANSI capability fallback, Windows Terminal-first routing, PowerShell fallback order, self-relocation console preservation, and launcher diagnostics are present."
