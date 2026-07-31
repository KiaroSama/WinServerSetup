<#
    Behavioral regression tests for scripts\Prefetch-AppDownloads.ps1.

    Pre-fix defect 1 (log lock namespace): the shared log mutex was created in the 'Global\'
    kernel namespace, which requires SeCreateGlobalPrivilege - a right held by Administrators
    and the service accounts, not by a standard user. The script is documented as directly
    runnable, and the very first Write-PrefetchLog call sits outside any try, so an
    unprivileged run aborted the entire prefetch before a single task started. Every worker is
    a child job of one process tree in the same session, so 'Local\' is sufficient.

    Pre-fix defect 2 (error handler): the job's catch ran `Log $_.Exception.Message; throw`.
    When Log itself failed (lock timeout, unwritable path, full disk) the NEW exception
    replaced the real one, so the job reported "Timed out waiting for the prefetch log lock."
    instead of the actual cause - and nothing was written either way.

    Pre-fix defect 3 (discarded diagnostics): Receive-Job output was piped to Out-Null, so a
    failed job left only "Failed: <name> state=Failed" with no way to diagnose it.

    Pre-fix defect 4 (unbounded phase): the dispatch loop was bounded only by per-job timeouts,
    so the prefetch phase as a whole had no ceiling.

    These tests execute the real extracted functions and drive the real script end to end.
#>
param()

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$prefetchPath = Join-Path $projectRoot "scripts\Prefetch-AppDownloads.ps1"
$source = Get-Content -LiteralPath $prefetchPath -Raw -Encoding UTF8

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw ("{0} Expected={1}; Actual={2}" -f $Message, $Expected, $Actual) }
}

# ---- Import only the functions under test; the script self-executes if dot-sourced. ----
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($prefetchPath, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) "Prefetch-AppDownloads.ps1 must parse before its runtime can be tested."

function Import-FunctionUnderTest {
    param([string]$Name)
    $definition = $ast.FindAll({
            param($node)
            ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq $Name)
        }, $true) | Select-Object -First 1
    if ($null -eq $definition) { throw "Prefetch-AppDownloads.ps1 must define $Name." }
    return $definition.Extent.Text
}

$writeLogText = Import-FunctionUnderTest 'Write-PrefetchLog'
. ([scriptblock]::Create($writeLogText))
. ([scriptblock]::Create((Import-FunctionUnderTest 'Write-JobDiagnostics')))

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isElevated = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$workRoot = Join-Path $env:TEMP ("WinServerSetup-Prefetch-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

try {
    # ================================================================================
    # 1. The shared log lock must not depend on a privilege a standard user lacks.
    # ================================================================================
    # The namespace is asserted directly because the privilege check cannot be reproduced on
    # every machine: 'Create global objects' is a configurable user right, so a box that
    # happens to grant it would silently mask a regression back to 'Global\'.
    Assert-True ($writeLogText -match 'Local\\WinServerSetup-PrefetchLog') `
        "The prefetch log mutex must live in the session-local kernel namespace."
    Assert-True ($source -notmatch 'Global\\WinServerSetup-PrefetchLog') `
        "No prefetch mutex may use the Global\ namespace; it needs SeCreateGlobalPrivilege."

    # And it must actually work in this process's token.
    $script:ResolvedLogPath = Join-Path $workRoot 'single.log'
    Write-PrefetchLog "first line before any task starts" "INFO"
    Assert-True (Test-Path -LiteralPath $script:ResolvedLogPath) `
    ("The first log write must succeed (Elevated={0})." -f $isElevated)

    # ================================================================================
    # 2. Serialization must still hold across two concurrent writers.
    # ================================================================================
    $script:ResolvedLogPath = Join-Path $workRoot 'concurrent.log'
    $perWriter = 120
    $writerScript = {
        param($FunctionText, $LogPath, $Tag, $Count)
        $ErrorActionPreference = 'Stop'
        $script:ResolvedLogPath = $LogPath
        . ([scriptblock]::Create($FunctionText))
        for ($i = 1; $i -le $Count; $i++) { Write-PrefetchLog ("{0}-{1:D4}" -f $Tag, $i) "TEST" }
    }
    $workers = @()
    foreach ($tag in @('AAA', 'BBB')) {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        $null = $shell.AddScript($writerScript).AddArgument($writeLogText).AddArgument($script:ResolvedLogPath).AddArgument($tag).AddArgument($perWriter)
        $workers += [pscustomobject]@{ Shell = $shell; Runspace = $runspace; Async = $shell.BeginInvoke() }
    }
    try {
        foreach ($w in $workers) { $null = $w.Shell.EndInvoke($w.Async) }
        foreach ($w in $workers) {
            Assert-Equal 0 $w.Shell.Streams.Error.Count ("A concurrent writer failed: {0}" -f ($w.Shell.Streams.Error -join ' | '))
        }
    } finally {
        foreach ($w in $workers) { $w.Shell.Dispose(); $w.Runspace.Dispose() }
    }

    $lines = @(Get-Content -LiteralPath $script:ResolvedLogPath -Encoding utf8 | Where-Object { $_ -match '\S' })
    Assert-Equal ($perWriter * 2) $lines.Count "Every serialized write must land exactly once."
    # A torn or interleaved write shows up as a line that no longer matches the record format.
    $malformed = @($lines | Where-Object { $_ -notmatch '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] \[TEST\] (AAA|BBB)-\d{4}$' })
    Assert-Equal 0 $malformed.Count ("The log lock must prevent torn lines. First bad line: {0}" -f ($malformed | Select-Object -First 1))
    Assert-Equal $perWriter @($lines | Where-Object { $_ -match 'AAA-' }).Count "Writer AAA must not lose records."
    Assert-Equal $perWriter @($lines | Where-Object { $_ -match 'BBB-' }).Count "Writer BBB must not lose records."

    # ================================================================================
    # 3. A failing logger must not replace the original job error.
    # ================================================================================
    # The real catch clause is lifted out of the job scriptblock and executed against a Log
    # stub that always throws - exactly the lock-timeout / unwritable-path failure mode.
    $jobFn = $ast.FindAll({
            param($node)
            ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq 'Invoke-TaskJob')
        }, $true) | Select-Object -First 1
    Assert-True ($null -ne $jobFn) "Prefetch-AppDownloads.ps1 must define Invoke-TaskJob."
    $catchClause = $jobFn.FindAll({
            param($node) $node -is [System.Management.Automation.Language.CatchClauseAst]
        }, $true) | Where-Object { $_.Extent.Text -match '\bLog\b' } | Select-Object -First 1
    Assert-True ($null -ne $catchClause) "The prefetch job must log and rethrow its failures."

    $stub = "function Log { param([string]`$Message, [string]`$Level = 'INFO') throw 'Timed out waiting for the prefetch log lock.' }`n"
    $probe = [scriptblock]::Create($stub + "try { throw 'REAL-DOWNLOAD-CAUSE' }`n" + $catchClause.Extent.Text)
    $caught = $null
    try { & $probe } catch { $caught = $_ }
    Assert-True ($null -ne $caught) "The job must still rethrow after a failure."
    Assert-True ($caught.Exception.Message -match 'REAL-DOWNLOAD-CAUSE') `
    ("The original cause must survive a failing logger. Got: {0}" -f $caught.Exception.Message)
    Assert-True ($caught.Exception.Message -notmatch 'prefetch log lock') `
        "A logging failure must never replace the real error."

    # ================================================================================
    # 4. Job diagnostics must reach the log, redacted and bounded.
    # ================================================================================
    $script:ResolvedLogPath = Join-Path $workRoot 'diagnostics.log'
    Write-JobDiagnostics -Name 'v2rayN' -Output @(
        'Downloading https://carol:s3cr3tpw@downloads.example.com/pkg.zip',
        'GET https://downloads.example.com/pkg.zip?token=ABCDEF1234567890&x=1 failed',
        "Invoke-WebRequest : The remote name could not be resolved`nAt line:1"
    )
    $diagnostics = @(Get-Content -LiteralPath $script:ResolvedLogPath -Encoding utf8 | Where-Object { $_ -match '\S' })
    $joined = $diagnostics -join "`n"
    Assert-True ($diagnostics.Count -ge 4) ("Every diagnostic line must be logged. Got {0}." -f $diagnostics.Count)
    Assert-True ($joined -match '\[JOB\] \[v2rayN\]') "Diagnostics must be attributed to the failing task."
    Assert-True ($joined -match 'could not be resolved') "The underlying failure text must survive into the log."
    Assert-True ($joined -notmatch 's3cr3tpw') "URL credentials must be redacted before logging."
    Assert-True ($joined -notmatch 'ABCDEF1234567890') "Token query parameters must be redacted before logging."
    Assert-True ($joined -match 'token=\*\*\*') "Redaction must be visible, not silent truncation."

    # Output volume must stay bounded so one noisy job cannot flood the log.
    $script:ResolvedLogPath = Join-Path $workRoot 'flood.log'
    Write-JobDiagnostics -Name 'Noisy' -Output @(1..500 | ForEach-Object { "line $_" })
    $flood = @(Get-Content -LiteralPath $script:ResolvedLogPath -Encoding utf8 | Where-Object { $_ -match '\S' })
    Assert-True ($flood.Count -le 41) ("Diagnostics must be capped. Got {0} lines." -f $flood.Count)
    Assert-True ((($flood -join "`n")) -match 'output truncated') "A capped dump must say it was truncated."

    # ================================================================================
    # 5. The prefetch phase as a whole must have a deadline.
    # ================================================================================
    Assert-True ($source -match 'PrefetchTotalTimeoutSeconds') "The whole prefetch phase needs an overall deadline."
    Assert-True ($source -match '\$deadline\s*=\s*\(Get-Date\)\.AddSeconds\(\$script:PrefetchTotalTimeoutSeconds\)') `
        "The deadline must be derived from the configured total timeout."
    Assert-True ($source -match '\(Get-Date\)\s*-ge\s*\$deadline') "The dispatch loop must test the overall deadline."
    Assert-True ($source -match 'Never started before the deadline') "Work abandoned at the deadline must be logged."
    Assert-True ($source -match 'Incomplete at deadline') "Jobs still running at the deadline must be logged and stopped."

    # ================================================================================
    # 6. End-to-end: an unreachable download must fail loudly, not silently.
    # ================================================================================
    # Runs the real script in the current host, so Invoke-AllTests covers both 5.1 and 7.
    $runRoot = Join-Path $workRoot 'run'
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
    $configPath = Join-Path $runRoot 'WinServerSetup.config.json'
    $downloadRoot = (Join-Path $runRoot 'cache') -replace '\\', '/'
    # The .invalid TLD is reserved and never resolves, so this fails fast instead of waiting
    # out the 120s request timeout.
    Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (@(
            '{'
            '  "logRoot": "logs",'
            ('  "downloadRoot": "{0}",' -f $downloadRoot)
            '  "directInstallers": ['
            '    { "enabled": true, "name": "UnreachableProbe", "url": "https://prefetch-probe.invalid/probe.exe", "fileName": "probe.exe" }'
            '  ]'
            '}'
        ) -join "`n")

    $runLog = Join-Path $runRoot 'prefetch.log'
    $stdoutPath = Join-Path $runRoot 'stdout.txt'
    $stderrPath = Join-Path $runRoot 'stderr.txt'
    $hostExe = (Get-Process -Id $PID).Path
    Assert-True (-not [string]::IsNullOrWhiteSpace($hostExe)) "Unable to resolve the current PowerShell host executable."

    $process = Start-Process -FilePath $hostExe -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath `
        -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $prefetchPath),
        '-ProjectRoot', ('"{0}"' -f $runRoot),
        '-ConfigPath', ('"{0}"' -f $configPath),
        '-MaxParallel', '1',
        '-LogPath', ('"{0}"' -f $runLog)
    )
    $null = $process.Handle
    try {
        Assert-True ($process.WaitForExit(90000)) "The prefetch run must finish well inside its bounded budget."
        $process.WaitForExit()
    } finally {
        if (-not $process.HasExited) { try { & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null } catch { $null = $_ } }
    }

    Assert-Equal 2 ([int]$process.ExitCode) `
    ("A partial prefetch must exit 2 so sequential installation continues. stderr: {0}" -f (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue))
    Assert-True (Test-Path -LiteralPath $runLog) "The prefetch run must produce its log without elevation."
    $runLines = (Get-Content -LiteralPath $runLog -Encoding utf8) -join "`n"
    Assert-True ($runLines -match 'Failed: UnreachableProbe') "A failed task must be reported by name."
    # The regression: pre-fix this was the ONLY thing recorded, with no cause.
    Assert-True ($runLines -match '\[JOB\] \[UnreachableProbe\]') `
    ("A failed job's own output must be captured for diagnosis. Log:`n{0}" -f $runLines)

    Write-Host ("PASS prefetch logs unprivileged (Elevated={0}), serializes writers, preserves causes, and captures job diagnostics." -f $isElevated)
} finally {
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}
