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
    -Pattern 'Read-HostThemed\s+-Prompt\s+"Select"\s+-DefaultValue\s+"1"' `
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

# PowerShell 7 must still be preferred over Windows PowerShell 5 - but the ordering is now
# between two FIXED install locations, because L-04 moved the PATH lookup to a last resort.
$pwshIndex = $launcher.IndexOf('PowerShell\7\pwsh.exe')
$winPsIndex = $launcher.IndexOf('WindowsPowerShell\v1.0\powershell.exe')
$pathLookupIndex = $launcher.IndexOf('Get-Command $name -CommandType Application')
Assert-True `
    -Condition (($pwshIndex -ge 0) -and ($winPsIndex -gt $pwshIndex)) `
    -Message "Launcher must prefer PowerShell 7 (pwsh.exe) before falling back to Windows PowerShell 5."
Assert-True `
    -Condition (($pathLookupIndex -gt $winPsIndex) -and ($winPsIndex -ge 0)) `
    -Message "L-04: the launcher must consult PATH only after every fixed trusted location has been offered."

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

# =============================================================================
# STRUCTURED LOGGING
# =============================================================================
# Once the console window is gone the file log is the only record of what a run did, so it is
# exercised against a real file on disk rather than by grepping source: UTC naming and UTC
# stamps, a header that identifies the run, an automatic [component] that attributes every line
# to the code that produced it, redaction at the single sink every helper routes through, a
# refusal to overwrite an existing log, and honest degradation when the directory is unusable.

function Get-SetupFunctionText {
    param([Parameter(Mandatory)][string]$Name)
    $definition = $mainAst.FindAll(
        {
            param($node)
            ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq $Name)
        },
        $true
    ) | Select-Object -First 1
    Assert-True -Condition ($null -ne $definition) -Message ("WinServerSetup.ps1 or its scripts\ modules must define {0}." -f $Name)
    return $definition.Extent.Text
}

$logTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("WinServerSetup-LogTest-{0}" -f ([guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Path $logTestRoot -Force | Out-Null

# The logging functions are written to a real file and dot-sourced from it rather than created
# from a scriptblock. The component walk has to skip the logging module's OWN wrappers by name,
# and a scriptblock frame carries no ScriptName at all - which would let an implementation that
# skips nothing pass by accident.
$logModulePath = Join-Path $logTestRoot "WinServerSetupLogging.ps1"
Set-Content -LiteralPath $logModulePath -Encoding UTF8 -Value ((@(
            "Protect-SensitiveLogText"
            "Get-LogComponent"
            "Initialize-StructuredLog"
            "Write-StructuredLog"
            "Complete-StructuredLog"
            "Write-Info"
            "Invoke-RecordedSetupStep"
        ) | ForEach-Object { Get-SetupFunctionText $_ }) -join "`r`n")

$script:LogTestWarnings = New-Object System.Collections.Generic.List[string]
$script:LogTestConsole = New-Object System.Collections.Generic.List[string]
function Write-Fail { param([string]$Message) $script:LogTestConsole.Add($Message) | Out-Null }
function Write-Warn { param([string]$Message) $script:LogTestWarnings.Add($Message) | Out-Null }
function Write-Themed { param([string]$Message, [string]$Kind, [switch]$NoNewline) $script:LogTestConsole.Add($Message) | Out-Null }
. $logModulePath

$previousStructuredLog = $Global:StructuredLog
$previousConfig = $Global:Config
$previousRunStats = $Global:RunStats
$previousScriptVersion = $Global:ScriptVersion
$previousProjectRoot = $Global:ProjectRoot
$fakeProductKey = "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE"

try {
    $Global:ScriptVersion = "9.9.9-test"
    $Global:ProjectRoot = $logTestRoot
    $Global:ConfigPath = Join-Path $logTestRoot "WinServerSetup.config.json"
    $Global:RunStats = [pscustomobject]@{
        StartedTasks   = New-Object System.Collections.Generic.List[string]
        CompletedTasks = New-Object System.Collections.Generic.List[string]
        FailedTasks    = New-Object System.Collections.Generic.List[string]
        SkippedTasks   = New-Object System.Collections.Generic.List[string]
        Warnings       = New-Object System.Collections.Generic.List[string]
        InstalledApps  = New-Object System.Collections.Generic.List[string]
        FailedApps     = New-Object System.Collections.Generic.List[string]
        RebootRequired = $false
    }
    # A real product key only ever reaches the local override, and it must not survive into the
    # log even though the effective configuration is recorded there.
    $Global:Config = [pscustomobject]@{
        logRoot    = "logs"
        parallel   = [pscustomobject]@{ enabled = $true; maxParallel = 4 }
        activation = [pscustomobject]@{ enabled = $true; productKey = $fakeProductKey; kmsServer = "kms.invalid.test:1688" }
    }

    $runDirectory = Join-Path $logTestRoot "run"
    Initialize-StructuredLog -LogDirectory $runDirectory
    $runLog = $Global:StructuredLog

    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$runLog)) -Message "Initialising the structured log must record the file it created."
    Assert-True -Condition (Test-Path -LiteralPath $runLog) -Message "The recorded structured log path must be a file that actually exists."
    Assert-True `
        -Condition ((Split-Path -Leaf $runLog) -match '^WinServerSetup_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_UTC(-\d+)?\.log$') `
        -Message "Each run must open its own <name>_YYYY-MM-DD_HH-mm-ss_UTC.log."

    # ---- Every line is structured: UTC stamp, level, component, message. ----
    foreach ($line in @(Get-Content -LiteralPath $runLog -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        Assert-True `
            -Condition ($line -match '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC\] \[[A-Z]+\s*\] \[[^\]]+\] \S') `
            -Message ("Every log line must read [timestamp UTC] [LEVEL] [COMPONENT] message. Offending line: {0}" -f $line)
    }

    # The literal ' UTC' pins the format; the delta pins the value, which is what fails when a
    # local-time stamp is written on a machine whose offset is not zero.
    $headerText = Get-Content -LiteralPath $runLog -Raw -Encoding UTF8
    $firstStampText = ([regex]::Match($headerText, '^\[([\d\-]{10} [\d:]{8}) UTC\]')).Groups[1].Value
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($firstStampText)) -Message "The first log line must carry a parseable UTC timestamp."
    $firstStamp = [datetime]::ParseExact($firstStampText, "yyyy-MM-dd HH:mm:ss", [Globalization.CultureInfo]::InvariantCulture)
    Assert-True `
        -Condition ([Math]::Abs(([DateTime]::UtcNow - $firstStamp).TotalMinutes) -lt 5) `
        -Message "Log timestamps must be UTC, not the machine's local time."

    # ---- The header has to identify the run well enough to reconstruct it later. ----
    foreach ($headerFact in @(
            'version=9\.9\.9-test',
            'executionId=[0-9a-f]{8}',
            'pid=\d+',
            'host=PowerShell \d+\.',
            'os=',
            'elevated=(True|False)',
            'user=',
            'projectRoot=',
            'logFile=',
            'commandLine=',
            'config='
        )) {
        Assert-Contains -Text $headerText -Pattern $headerFact -Message ("The log header must record {0}" -f $headerFact)
    }
    Assert-True -Condition ($headerText -match 'activation') -Message "The header must record the effective configuration that drove the run."
    Assert-True -Condition (-not $headerText.Contains($fakeProductKey)) -Message "The configuration snapshot must never carry the activation product key into the log."

    # ---- Component attribution. ----
    Write-StructuredLog -Level INFO -Message "direct call from the suite"
    Write-Info "routed through the console helper"
    Write-StructuredLog -Level INFO -Message "explicit component" -Section "RELOCATION"

    $runLines = @(Get-Content -LiteralPath $runLog -Encoding UTF8)
    $directLine = @($runLines | Where-Object { $_ -like "*direct call from the suite*" })[0]
    Assert-True -Condition ($directLine -match '\[MenuAndLauncher\.Tests:\d+\]') -Message "A log line must name the source file and line that produced it."

    $routedLine = @($runLines | Where-Object { $_ -like "*routed through the console helper*" })[0]
    Assert-True `
        -Condition ($routedLine -match '\[MenuAndLauncher\.Tests:\d+\]') `
        -Message "A console helper must attribute its line to ITS caller; attributing every line to the logging module tells an operator nothing."
    Assert-True `
        -Condition ($routedLine -notmatch 'WinServerSetupLogging') `
        -Message "The logging module's own frames must be skipped when the component is derived."

    $explicitLine = @($runLines | Where-Object { $_ -like "*explicit component*" })[0]
    Assert-True -Condition ($explicitLine -match '\[RELOCATION\]') -Message "An explicitly supplied section must win over the derived component."

    # A step's TASK lines are the most common lines in the whole log. Naming the recorder there
    # would say nothing the message does not already say; the useful frame is the orchestration
    # line that declared the step.
    $Global:CurrentStepSkipReason = $null
    $null = Invoke-RecordedSetupStep -Name "attributed step" -Action { }
    $taskLine = @(@(Get-Content -LiteralPath $runLog -Encoding UTF8) | Where-Object { $_ -like "*Started: attributed step*" })[0]
    Assert-True `
        -Condition ($taskLine -match '\[MenuAndLauncher\.Tests:\d+\]') `
        -Message "A recorded step must be attributed to the code that declared it, not to the step recorder itself."

    # ---- Redaction at the sink. There is one file-writing path, so no level and no caller can
    #      route around it - including DEBUG, which must still be written in full detail. ----
    Write-StructuredLog -Level DEBUG -Message ("key {0}; url https://svc:s3cr3tpw@host/p?token=abc123def; password=hunter2; Authorization: Bearer eyJhbGciOiJIUzI1NiJ9xx" -f $fakeProductKey)
    Write-Info ("activation key {0} was installed" -f $fakeProductKey)
    $redactedText = Get-Content -LiteralPath $runLog -Raw -Encoding UTF8

    Assert-True -Condition (-not $redactedText.Contains($fakeProductKey)) -Message "A product key must never reach the log file, whatever helper wrote it."
    # The shape a real key has, which is also the shape the redactor matches. A looser three-group
    # pattern reads as stricter but is not: it also matches ordinary hyphenated paths such as
    # ...\Program-Files-Portable\..., so it fails on the directory a run happens to live in rather
    # than on a leak. The fragment check below covers a partially masked key without that flaw.
    Assert-True -Condition ($redactedText -notmatch '[A-Z0-9]{5}(-[A-Z0-9]{5}){4}') -Message "Nothing shaped like a product key may survive into the log."
    Assert-True -Condition ($redactedText -notmatch 'BBBBB-CCCCC') -Message "No fragment of a product key may survive either, including a partially masked one."
    Assert-True -Condition ($redactedText -notmatch 's3cr3tpw') -Message "Credentials embedded in a URL must be redacted."
    Assert-True -Condition ($redactedText -notmatch 'abc123def') -Message "A token-bearing query parameter must be redacted."
    Assert-True -Condition ($redactedText -notmatch 'hunter2') -Message "A password in free text must be redacted."
    Assert-True -Condition ($redactedText -notmatch 'eyJhbGciOiJIUzI1NiJ9xx') -Message "A bearer token must be redacted."
    Assert-True -Condition ($redactedText -match '\[DEBUG') -Message "A DEBUG line must still be written; the file log is the diagnostic record, and dropping it would hide detail rather than protect it."
    Assert-True -Condition ($redactedText -match 'url https://\*\*\*:\*\*\*@host/p') -Message "Redaction must remove the secret and keep the diagnostic context around it."
    Assert-True -Condition ($redactedText -match 'activation key .* was installed') -Message "A redacted message must keep the rest of its text."

    # ---- An existing log is never overwritten. The file name carries a UTC second, so the name
    #      the next run will pick cannot be known exactly in advance: sentinels are laid down for
    #      a 20-second window instead, written with a raw .NET call so the fixture itself costs
    #      milliseconds and the window cannot be outrun even on a loaded machine. ----
    $collisionDirectory = Join-Path $logTestRoot "collision"
    New-Item -ItemType Directory -Path $collisionDirectory -Force | Out-Null
    $sentinelEncoding = New-Object System.Text.UTF8Encoding($false)
    $collisionBase = [DateTime]::UtcNow
    $sentinelPaths = @()
    foreach ($offsetSeconds in 0..20) {
        $sentinelStamp = ($collisionBase.AddSeconds($offsetSeconds)).ToString("yyyy-MM-dd_HH-mm-ss")
        $sentinelPath = Join-Path $collisionDirectory ("WinServerSetup_{0}_UTC.log" -f $sentinelStamp)
        [System.IO.File]::WriteAllText($sentinelPath, "PREVIOUS RUN MUST SURVIVE", $sentinelEncoding)
        $sentinelPaths += $sentinelPath
    }
    Initialize-StructuredLog -LogDirectory $collisionDirectory
    Assert-True -Condition ($sentinelPaths -notcontains $Global:StructuredLog) -Message "A new run must never take the file name of an existing log."
    Assert-True `
        -Condition ((Split-Path -Leaf $Global:StructuredLog) -match '_UTC-\d+\.log$') `
        -Message "A name collision must be resolved with a numeric suffix instead of an overwrite (if this fails, check that the new log's stamp is still inside the 20-second sentinel window - outside it the collision path was never reached and the case would be vacuous)."
    foreach ($sentinelPath in $sentinelPaths) {
        Assert-Equal `
            -Expected "PREVIOUS RUN MUST SURVIVE" `
            -Actual (Get-Content -LiteralPath $sentinelPath -Raw -Encoding UTF8).Trim() `
            -Message "An existing log must be left intact when a new run starts in the same directory."
    }

    # ---- Degradation: a log that cannot be opened must be reported, not faked. ----
    $blockingFile = Join-Path $logTestRoot "not-a-directory.txt"
    Set-Content -LiteralPath $blockingFile -Value "x" -Encoding UTF8
    $script:LogTestWarnings.Clear()
    Initialize-StructuredLog -LogDirectory (Join-Path $blockingFile "logs")
    Assert-True -Condition ($null -eq $Global:StructuredLog) -Message "A log that could not be created must not be recorded as if it had been."
    Assert-True -Condition ($script:LogTestWarnings.Count -ge 1) -Message "Failing to open the log must degrade to a clear console warning."
    Assert-True -Condition ((($script:LogTestWarnings) -join " ") -match '(?i)log') -Message "The degradation warning must say that file logging is what failed."
    Write-StructuredLog -Level INFO -Message "must not throw once logging is degraded"

    # ---- The run must close its own log, from a real process exit, in a real child. ----
    $childLogDirectory = Join-Path $logTestRoot "child"
    $childScriptPath = Join-Path $logTestRoot "child.ps1"
    $childBody = @"
`$ErrorActionPreference = 'Stop'
. '$logModulePath'
function Write-Warn { param([string]`$Message) }
function Write-Themed { param([string]`$Message, [string]`$Kind, [switch]`$NoNewline) }
`$Global:ScriptVersion = '9.9.9-test'
`$Global:ProjectRoot = '$logTestRoot'
`$Global:Config = [pscustomobject]@{ logRoot = 'logs' }
`$Global:RunStats = [pscustomobject]@{
    StartedTasks   = New-Object System.Collections.Generic.List[string]
    CompletedTasks = New-Object System.Collections.Generic.List[string]
    FailedTasks    = New-Object System.Collections.Generic.List[string]
    SkippedTasks   = New-Object System.Collections.Generic.List[string]
    Warnings       = New-Object System.Collections.Generic.List[string]
    InstalledApps  = New-Object System.Collections.Generic.List[string]
    FailedApps     = New-Object System.Collections.Generic.List[string]
    RebootRequired = `$false
}
Initialize-StructuredLog -LogDirectory '$childLogDirectory'
`$Global:RunStats.CompletedTasks.Add('a completed step')
`$Global:RunStats.FailedTasks.Add('a failed step')
Write-StructuredLog -Level INFO -Message 'child body ran'
exit 3
"@
    Set-Content -LiteralPath $childScriptPath -Value $childBody -Encoding UTF8
    $childHostExe = (Get-Process -Id $PID).Path
    & $childHostExe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $childScriptPath
    Assert-Equal -Expected 3 -Actual $LASTEXITCODE -Message "The child must exit with its own code; closing the log must not disturb it."

    $childLogFiles = @(Get-ChildItem -LiteralPath $childLogDirectory -Filter "WinServerSetup_*_UTC*.log" -File)
    Assert-Equal -Expected 1 -Actual $childLogFiles.Count -Message "The child run must leave exactly one log file."
    $childText = Get-Content -LiteralPath $childLogFiles[0].FullName -Raw -Encoding UTF8
    Assert-True -Condition ($childText -match 'child body ran') -Message "The child's own log line must be present."
    Assert-True `
        -Condition ($childText -match '(?i)Run ended') `
        -Message "A run must close its log on exit; a log that simply stops cannot be told apart from a crash."
    Assert-True -Condition ($childText -match 'failed=1') -Message "The closing record must carry the outcome the exit code is derived from."
    Assert-True -Condition ($childText -match 'completed=1') -Message "The closing record must carry the completed-step count."
    Assert-True -Condition ($childText -match 'elapsedSeconds=') -Message "The closing record must carry how long the run took."
} finally {
    $Global:StructuredLog = $previousStructuredLog
    $Global:Config = $previousConfig
    $Global:RunStats = $previousRunStats
    $Global:ScriptVersion = $previousScriptVersion
    $Global:ProjectRoot = $previousProjectRoot
    foreach ($subscriber in @(Get-EventSubscriber -SourceIdentifier PowerShell.Exiting -ErrorAction SilentlyContinue)) {
        Unregister-Event -SubscriptionId $subscriber.SubscriptionId -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath Function:\Write-Warn -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Write-Themed -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Write-Info -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $logTestRoot) { Remove-Item -LiteralPath $logTestRoot -Recurse -Force -ErrorAction SilentlyContinue }
    Assert-True -Condition (-not (Test-Path -LiteralPath $logTestRoot)) -Message "Structured log test artifacts must be cleaned up."
}

Write-Host "PASS menu behavior, banner and startup line rendering, ANSI capability fallback, Windows Terminal-first routing, PowerShell fallback order, self-relocation console preservation, launcher diagnostics, and the structured log's UTC naming, run header, component attribution, sink-level redaction, overwrite refusal, degradation and shutdown record are present."
