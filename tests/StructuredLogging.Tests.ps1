<#
    Behavioral tests for the per-run structured log.

    Split out of tests\MenuAndLauncher.Tests.ps1, which had accumulated two subjects: how the
    console and launcher present a run, and what the FILE log records about it. They fail for
    different reasons and are read by different people.

    Once the console window is gone the file log is the only record of what a run did, so it is
    exercised against a real file on disk rather than by grepping source: UTC naming and UTC
    stamps, a header that identifies the run, an automatic [component] that attributes every line
    to the code that produced it, redaction at the single sink every helper routes through, a
    refusal to overwrite an existing log, and honest degradation when the directory is unusable.
#>
# Console stubs mirror the real signatures so the extracted functions bind as in production.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub signatures mirror production collaborators so parameter binding matches.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Console writers are shadowed deliberately so no test output reaches the real host.')]
param([string]$MainScript = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$mainScript = if ([string]::IsNullOrWhiteSpace($MainScript)) { Join-Path $projectRoot "WinServerSetup.ps1" } else { $MainScript }

. (Join-Path $PSScriptRoot '_Common.ps1')

# The logging helpers live across the scripts\ partition, so parse it as one source text the way
# the menu suite does - Get-SetupFunctionText below searches this single AST.
$setupSourceFiles = @(Get-SetupSourceFile -ProjectRoot $projectRoot -MainScript $mainScript)
$main = ($setupSourceFiles | ForEach-Object { Get-Content -LiteralPath $_ -Raw -Encoding UTF8 }) -join "`r`n"
$mainAst = [System.Management.Automation.Language.Parser]::ParseInput($main, [ref]$null, [ref]$null)

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
    # Derived from THIS file's name rather than hardcoded: the component column comes from the
    # call stack, so hardcoding a suite name silently stops testing attribution the moment the
    # assertion moves to another file - which is exactly what happened when it was split out of
    # MenuAndLauncher.Tests.ps1.
    $expectedComponent = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
    Assert-True -Condition ($directLine -match ("\[{0}:\d+\]" -f [regex]::Escape($expectedComponent))) `
        -Message ("A log line must name the source file and line that produced it. Expected [{0}:<line>], got: {1}" -f $expectedComponent, $directLine)

    $routedLine = @($runLines | Where-Object { $_ -like "*routed through the console helper*" })[0]
    Assert-True `
        -Condition ($routedLine -match ("\[{0}:\d+\]" -f [regex]::Escape($expectedComponent))) `
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
        -Condition ($taskLine -match ("\[{0}:\d+\]" -f [regex]::Escape($expectedComponent))) `
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

Write-Host "PASS structured log: UTC filename and UTC stamps, a run header that identifies the run, automatic [component] attribution, redaction at the single sink every helper routes through, a refusal to overwrite an existing log, honest degradation when the directory is unusable, and a shutdown record."
