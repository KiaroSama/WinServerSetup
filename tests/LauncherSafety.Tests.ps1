param()

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$launcherScript = Join-Path $projectRoot "Run-WinServerSetup.ps1"
$source = Get-Content -LiteralPath $launcherScript -Raw -Encoding UTF8

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }

function Assert-Equal {
    param(
        [Parameter(Mandatory)]$Expected,
        $Actual,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Expected -ne $Actual) { throw ("{0} Expected: <{1}>. Actual: <{2}>." -f $Message, $Expected, $Actual) }
}

Assert-True ($source -match 'backslashCount') "Windows command-line quoting must handle backslashes before quotes and the closing quote."
Assert-True ($source -match 'function\s+Wait-LauncherResult') "Delegated Windows Terminal launch needs an explicit child-result handshake."
Assert-True ($source -match 'launcher-result-') "Each delegated launch needs a unique result file."
Assert-True ($source -match 'Set-Content[^\r\n]*result') "The elevated wrapper must persist the actual setup exit code."
Assert-True ($source -notmatch 'exit \$terminalExitCode') "The short-lived wt.exe client exit code must not be treated as setup completion."
Assert-True ($source -match 'finally[\s\S]{0,400}Remove-Item[^\r\n]*result') "Delegation result artifacts must be cleaned in finally."

# A 24-hour default turns a dead child into a silent all-day spin.
Assert-True ($source -notmatch 'TimeoutSeconds\s*=\s*86400') "The delegated result wait must not default to a 24-hour timeout."

# Both delegated routes must hand their started process to the waiter so its death is observable.
Assert-True `
    ($source -match 'Wait-LauncherResult\s+-Path\s+\$launcherResultPath\s+-Process\s+\$terminal') `
    "The Windows Terminal route must monitor its started process while waiting for the result."
Assert-True `
    ($source -match 'Wait-LauncherResult\s+-Path\s+\$launcherResultPath\s+-Process\s+\$elevated') `
    "The direct elevation route must monitor its started process while waiting for the result."

# wt.exe splits its own command line on ';', so a semicolon in a forwarded path must not reach it.
Assert-True `
    ($source -match 'Windows Terminal was skipped because a required path contains a semicolon') `
    "A semicolon in a forwarded path must drop the Windows Terminal route with a logged warning."
Assert-True `
    ($source -match '(?s)\$semicolonPaths\.Count\s+-gt\s+0[\s\S]{0,600}?-WindowsTerminalAvailable\s+\$false') `
    "The semicolon fallback must re-use the tested route decision with Windows Terminal unavailable."

$tokens = $null
$parseErrors = $null
$launcherAst = [System.Management.Automation.Language.Parser]::ParseFile($launcherScript, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) "Launcher must parse before its helpers can be executed."

function Get-LauncherFunctionText {
    param([Parameter(Mandatory)][string]$Name)

    $functionAst = $launcherAst.FindAll(
        {
            param($node)
            ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq $Name)
        },
        $true
    ) | Select-Object -First 1
    Assert-True ($null -ne $functionAst) ("Launcher must expose a testable {0} function." -f $Name)
    return $functionAst.Extent.Text
}

# ---------------------------------------------------------------------------
# Join-CommandLineArgument must round-trip through the real Windows parser.
# CommandLineToArgvW is the parser the child process itself uses, so quoting is
# verified against Windows instead of against a re-implementation of the rules.
# ---------------------------------------------------------------------------

if (-not ('WinServerSetupNativeCommandLine' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class WinServerSetupNativeCommandLine
{
    [DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string lpCmdLine, out int pNumArgs);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr hMem);

    public static string[] Parse(string commandLine)
    {
        int count;
        IntPtr argv = CommandLineToArgvW(commandLine, out count);
        if (argv == IntPtr.Zero) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
        try
        {
            string[] parsed = new string[count];
            for (int i = 0; i < count; i++)
            {
                parsed[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size));
            }
            return parsed;
        }
        finally
        {
            LocalFree(argv);
        }
    }
}
'@
}

. ([scriptblock]::Create((Get-LauncherFunctionText -Name "Join-CommandLineArgument")))

try {
    $roundTripValues = @(
        '-NoProfile',                                  # bare token, must stay unquoted
        'C:\Program Files\PowerShell\7\pwsh.exe',      # spaces
        'C:\Some Dir\',                                # trailing backslash inside a quoted argument
        'trailing\\',                                  # trailing backslash run that needs no quoting
        'he said "hi"',                                # embedded quotes
        'a\\"b',                                       # backslash run immediately before a quote
        '',                                            # empty argument
        'C:\proj;semi\WinServerSetup.ps1',             # semicolon
        '   ',                                         # whitespace only
        '\\server\share\path with space\'              # UNC path with spaces and a trailing slash
    )

    # CommandLineToArgvW parses argv[0] with program-name rules, so a dummy image name leads.
    $commandLine = 'app.exe ' + (($roundTripValues | ForEach-Object { Join-CommandLineArgument -Value $_ }) -join ' ')
    $parsed = [WinServerSetupNativeCommandLine]::Parse($commandLine)

    Assert-Equal `
        -Expected ($roundTripValues.Count + 1) `
        -Actual $parsed.Length `
        -Message ("Windows parsed a different argument count from: {0}" -f $commandLine)

    for ($index = 0; $index -lt $roundTripValues.Count; $index++) {
        Assert-Equal `
            -Expected $roundTripValues[$index] `
            -Actual $parsed[$index + 1] `
            -Message ("Argument {0} did not survive Windows command-line quoting (encoded as {1})." -f $index, (Join-CommandLineArgument -Value $roundTripValues[$index]))
    }

    Assert-Equal -Expected '-NoProfile' -Actual (Join-CommandLineArgument -Value '-NoProfile') -Message "A token without whitespace or quotes must not be quoted."
    Assert-Equal -Expected '""' -Actual (Join-CommandLineArgument -Value '') -Message "An empty argument must survive as an explicit empty pair of quotes."
} finally {
    Remove-Item -LiteralPath Function:\Join-CommandLineArgument -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Wait-LauncherResult: the result file is created before its content is flushed,
# and the elevated child can die without ever writing it.
# ---------------------------------------------------------------------------

. ([scriptblock]::Create((Get-LauncherFunctionText -Name "Wait-LauncherResult")))

$script:CapturedLauncherLog = New-Object System.Collections.Generic.List[string]
function Write-LauncherLog {
    param([string]$Level, [string]$Message)
    $script:CapturedLauncherLog.Add(("[{0}] {1}" -f $Level, $Message))
}

$resultPath = Join-Path ([IO.Path]::GetTempPath()) ("WinServerSetup-launcher-result-test-{0}.txt" -f ([guid]::NewGuid().ToString('N')))
$missingPath = Join-Path ([IO.Path]::GetTempPath()) ("WinServerSetup-launcher-result-missing-{0}.txt" -f ([guid]::NewGuid().ToString('N')))
$deadChild = $null

try {
    # Test-Path wins the race against the writer's flush: the file exists but is still empty.
    [IO.File]::WriteAllText($resultPath, "")
    $raceError = $null
    try { Wait-LauncherResult -Path $resultPath -TimeoutSeconds 1 | Out-Null } catch { $raceError = $_ }
    Assert-True ($null -ne $raceError) "A one-second wait on an empty result file must end at its deadline."
    Assert-True `
        ($raceError.Exception.Message -match 'Timed out waiting') `
        ("An empty result file must keep polling, not fail. Actual failure: {0}" -f $raceError.Exception.Message)

    # A half-written or garbled file is equally "not ready yet".
    [IO.File]::WriteAllText($resultPath, "  ")
    $partialError = $null
    try { Wait-LauncherResult -Path $resultPath -TimeoutSeconds 1 | Out-Null } catch { $partialError = $_ }
    Assert-True ($null -ne $partialError) "A one-second wait on an unparseable result file must end at its deadline."
    Assert-True `
        ($partialError.Exception.Message -match 'Timed out waiting') `
        ("An unparseable result file must keep polling, not fail. Actual failure: {0}" -f $partialError.Exception.Message)

    # Once the real code lands, it is returned.
    [IO.File]::WriteAllText($resultPath, "7`r`n")
    Assert-Equal `
        -Expected 7 `
        -Actual (Wait-LauncherResult -Path $resultPath -TimeoutSeconds 5) `
        -Message "A completed result file must return the child's exit code."

    # A child that died without a result file must fail fast with its own exit code.
    Assert-True (-not [string]::IsNullOrWhiteSpace($env:ComSpec)) "The dead-child test needs cmd.exe from ComSpec."
    $deadChild = Start-Process -FilePath $env:ComSpec -ArgumentList '/c exit 3' -PassThru -WindowStyle Hidden
    $null = $deadChild.Handle   # cache the handle so ExitCode stays readable on Windows PowerShell 5.1
    Assert-True ($deadChild.WaitForExit(30000)) "The dead-child fixture must exit inside its bounded wait."
    $deadChild.WaitForExit()    # the bounded overload can leave ExitCode unset on 5.1; this settles it
    Assert-Equal -Expected 3 -Actual $deadChild.ExitCode -Message "The dead-child fixture must exit with code 3."

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $deadResult = Wait-LauncherResult -Path $missingPath -Process $deadChild -TimeoutSeconds 300 -ExitGraceSeconds 0
    $stopwatch.Stop()
    Assert-Equal -Expected 3 -Actual $deadResult -Message "A child that died without writing a result must surface its own exit code."
    Assert-True `
        ($stopwatch.Elapsed.TotalSeconds -lt 10) `
        ("A dead child must fail fast, not poll to the timeout. Elapsed: {0:N1}s." -f $stopwatch.Elapsed.TotalSeconds)
    Assert-True `
        (@($script:CapturedLauncherLog | Where-Object { $_ -match 'exited with code 3 without writing its result' }).Count -eq 1) `
        "The fail-fast path must log why the delegated child never reported a result."
} finally {
    if ($deadChild) { $deadChild.Dispose() }
    Remove-Item -LiteralPath $resultPath, $missingPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Wait-LauncherResult -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Write-LauncherLog -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Get-LauncherFunctionText -ErrorAction SilentlyContinue
}

Assert-True (-not (Test-Path -LiteralPath $resultPath)) "Launcher result test artifacts must be cleaned."

Write-Host "PASS launcher quoting round-trips through CommandLineToArgvW, the result handshake survives the write race, a dead child fails fast, and semicolon paths bypass Windows Terminal."
