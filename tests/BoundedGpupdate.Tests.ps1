<#
    M-07: every gpupdate execution path must be bounded.

    gpupdate.exe blocks for as long as a domain controller keeps it waiting. An unbounded
    wait on any call site hangs the whole setup run, so there is exactly one runner -
    Invoke-BoundedGpupdate in scripts\AccountSecurity.ps1 - and every caller routes through it.

    The behavioural tests below run the *real* helper. Only Start-Process is shadowed, and it
    swaps the gpupdate.exe target for a harmless stand-in: `cmd.exe /c exit N` for the exit-code
    paths and `cmd.exe /c ping -n 60 127.0.0.1` for the hang. gpupdate.exe itself is never
    executed and no domain is ever contacted. The stand-in is a two-level tree (cmd.exe parent,
    ping.exe child) precisely so that terminating only the parent leaves a provable orphan -
    that is what separates a tree kill from a parent kill.

    Every wait in this file is deadline-bounded and the timeout case uses a 3-second budget, so
    the whole suite finishes in seconds rather than proving a timeout by sitting through one.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Start-Process is shadowed deliberately so the real helper runs against a harmless stand-in instead of gpupdate.exe.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The mock signature mirrors the real cmdlet so parameter binding matches production.')]
# -AccountScriptPath / -SystemScriptPath target alternate copies so these tests can be replayed
# against a deliberately defective build to prove they still fail. CI and local runs use the defaults.
param([string]$AccountScriptPath = "", [string]$SystemScriptPath = "")

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$accountScript = if ([string]::IsNullOrWhiteSpace($AccountScriptPath)) { Join-Path $projectRoot "scripts\AccountSecurity.ps1" } else { $AccountScriptPath }
$systemScript = if ([string]::IsNullOrWhiteSpace($SystemScriptPath)) { Join-Path $projectRoot "scripts\SystemSettings.ps1" } else { $SystemScriptPath }
foreach ($required in @($accountScript, $systemScript)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing implementation under test: $required" }
}

. (Join-Path $PSScriptRoot '_Common.ps1')

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    try { & $Action } catch { return [string]$_.Exception.Message }
    throw $Message
}

$accountSource = Get-Content -LiteralPath $accountScript -Raw -Encoding UTF8
$systemSource = Get-Content -LiteralPath $systemScript -Raw -Encoding UTF8
$mainSource = Get-Content -LiteralPath (Join-Path $projectRoot "WinServerSetup.ps1") -Raw -Encoding UTF8

# ---------------------------------------------------------------------------
# One bounded runner, and nothing that can outflank it
# ---------------------------------------------------------------------------
Assert-Equal 1 ([regex]::Matches($accountSource, '(?m)^function\s+Invoke-BoundedGpupdate\b').Count) `
    "M-07: scripts\AccountSecurity.ps1 must hold exactly one definition of the bounded gpupdate runner."
Assert-True ($accountSource -match 'WaitForExit\(\s*\$TimeoutSeconds\s*\*\s*1000\s*\)') `
    "M-07: the bounded runner must wait on a wall-clock millisecond budget, not on an unbounded WaitForExit()."
Assert-True ($accountSource -match 'taskkill\.exe[^\r\n]*/T') `
    "M-07: an expired gpupdate must have its whole process tree terminated, not just its parent."

# The system-settings step used to launch gpupdate.exe through the progress runner, whose wait
# loop spins on HasExited with no deadline at all. Owning no gpupdate.exe literal is the cheapest
# way to state that it may only reach gpupdate through the bounded runner.
Assert-True ($systemSource -notmatch 'gpupdate\.exe') `
    "M-07: scripts\SystemSettings.ps1 must not launch gpupdate.exe itself; it must route through the bounded runner."
Assert-True ($systemSource -match 'Invoke-BoundedGpupdate') `
    "M-07: the SystemSettings policy refresh must call Invoke-BoundedGpupdate."
foreach ($file in @(@{ Name = 'AccountSecurity'; Text = $accountSource }, @{ Name = 'SystemSettings'; Text = $systemSource })) {
    Assert-True ($file.Text -notmatch '(?m)^\s*[^#\r\n]*Start-Process[^\r\n]*\s-Wait\b') `
        ("M-07: scripts\{0}.ps1 must not block on Start-Process -Wait, which has no timeout." -f $file.Name)
    Assert-True ($file.Text -notmatch 'Wait-ProcessWithStatus') `
        ("M-07: scripts\{0}.ps1 must not wait through Wait-ProcessWithStatus, whose HasExited loop has no deadline." -f $file.Name)
}

# SystemSettings calls a function defined in AccountSecurity, so the load order is load-bearing.
$accountLoad = $mainSource.IndexOf('scripts\AccountSecurity.ps1')
$systemLoad = $mainSource.IndexOf('scripts\SystemSettings.ps1')
Assert-True ($accountLoad -ge 0 -and $systemLoad -gt $accountLoad) `
    "M-07: WinServerSetup.ps1 must dot-source AccountSecurity.ps1 before SystemSettings.ps1 so the bounded runner is defined when SystemSettings calls it."

# ---------------------------------------------------------------------------
# Behavioural harness: the real helper, a harmless stand-in process
# ---------------------------------------------------------------------------
$tokens = $null
$parseErrors = $null
$accountAst = [System.Management.Automation.Language.Parser]::ParseFile($accountScript, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) "M-07: scripts\AccountSecurity.ps1 must parse before the bounded runner can be exercised."

$script:StandInArgs = @('/c', 'exit 0')
$script:TrackChild = $false
$script:Launched = ''
$script:LogLines = New-Object System.Collections.Generic.List[string]
$script:SpawnedPids = New-Object System.Collections.Generic.List[int]
$script:ChildPids = New-Object System.Collections.Generic.List[int]

function Write-StructuredLog { param([string]$Level = 'INFO', [string]$Message = '', [string]$Section = '') $script:LogLines.Add("$Level $Message") | Out-Null }

# Bounded poll, never a blind sleep: the child appears within milliseconds, the deadline only
# exists so a scheduling hiccup fails the assertion instead of wedging the suite.
function Wait-ForStandInChild {
    param([int]$ParentId, [int]$TimeoutSeconds = 10)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $child = @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$ParentId AND Name='ping.exe'" -ErrorAction SilentlyContinue) | Select-Object -First 1
        if ($child) { return [int]$child.ProcessId }
        Start-Sleep -Milliseconds 100
    }
    return 0
}

# Name-matched so a recycled PID cannot be mistaken for a survivor.
function Test-ProcessAlive {
    param([int]$ProcessId, [string]$Name)
    if ($ProcessId -le 0) { return $false }
    $found = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    return ($null -ne $found -and $found.ProcessName -eq $Name)
}

function Wait-ForProcessGone {
    param([int]$ProcessId, [string]$Name, [int]$TimeoutSeconds = 15)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-ProcessAlive -ProcessId $ProcessId -Name $Name)) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

# The single seam: the helper still asks for gpupdate.exe (recorded and asserted below), but a
# stand-in is what actually runs. The module-qualified call reaches the real cmdlet rather than
# recursing into this shim.
function Start-Process {
    param([string]$FilePath, [string[]]$ArgumentList, [string]$WindowStyle, [switch]$PassThru, $ErrorAction)
    $script:Launched = "{0} {1}" -f $FilePath, ($ArgumentList -join ' ')
    $process = Microsoft.PowerShell.Management\Start-Process -FilePath 'cmd.exe' -ArgumentList $script:StandInArgs -WindowStyle Hidden -PassThru
    $script:SpawnedPids.Add([int]$process.Id) | Out-Null
    if ($script:TrackChild) { $script:ChildPids.Add((Wait-ForStandInChild -ParentId ([int]$process.Id))) | Out-Null }
    return $process
}

# The real implementation, lifted straight out of the file under test.
. ([scriptblock]::Create((Import-FunctionUnderTest 'Invoke-BoundedGpupdate' @($accountAst))))

try {
    # --- success ------------------------------------------------------------
    $script:StandInArgs = @('/c', 'exit 0')
    Invoke-BoundedGpupdate -TimeoutSeconds 30
    Assert-Equal 'gpupdate.exe /target:computer /force' $script:Launched `
        "M-07: the bounded runner must be what launches the computer policy refresh."
    Assert-True (($script:LogLines -join "`n") -match 'exit code: 0') `
        "M-07: a completed policy refresh must log its exit code. Logged: $($script:LogLines -join ' | ')"

    # --- non-zero exit ------------------------------------------------------
    $script:LogLines.Clear()
    $script:StandInArgs = @('/c', 'exit 3')
    $message = Assert-Throws { Invoke-BoundedGpupdate -TimeoutSeconds 30 } `
        "M-07: a failing policy refresh must surface instead of being swallowed."
    Assert-True ($message -match 'exit code 3') `
        "M-07: the captured gpupdate exit code must be reported. Got: $message"

    # --- timeout, and the process tree it leaves behind ---------------------
    # A 3-second budget: long enough to be a real wait, short enough that the suite never
    # spends a minute proving that a 60-second stand-in would have outlasted it.
    $script:LogLines.Clear()
    $script:StandInArgs = @('/c', 'ping -n 60 127.0.0.1')
    $script:TrackChild = $true
    $elapsed = [System.Diagnostics.Stopwatch]::StartNew()
    $message = Assert-Throws { Invoke-BoundedGpupdate -TimeoutSeconds 3 } `
        "M-07: an unresponsive gpupdate must be terminated on expiry, not waited on forever."
    $elapsed.Stop()
    $script:TrackChild = $false
    Assert-True ($message -match 'did not complete within 3 seconds') `
        "M-07: the timeout must be reported with its budget. Got: $message"
    Assert-True ($elapsed.Elapsed.TotalSeconds -lt 30) `
        ("M-07: the wait must end on the timeout, not on the child. Took {0:N1}s against a 3s budget." -f $elapsed.Elapsed.TotalSeconds)

    # --- child-process cleanup ----------------------------------------------
    $timedOutParent = $script:SpawnedPids[-1]
    $timedOutChild = $script:ChildPids[-1]
    Assert-True ($timedOutChild -gt 0) `
        "M-07: the timeout case needs a real grandchild process, otherwise tree termination is untested."
    Assert-True (Wait-ForProcessGone -ProcessId $timedOutParent -Name 'cmd') `
        "M-07: the expired gpupdate process must not survive its own timeout (pid $timedOutParent)."
    Assert-True (Wait-ForProcessGone -ProcessId $timedOutChild -Name 'ping') `
        "M-07: the child of an expired gpupdate must be terminated with it, not left running as an orphan (pid $timedOutChild)."

    # --- nothing this suite started is still running ------------------------
    foreach ($leaked in $script:SpawnedPids) {
        Assert-True (-not (Test-ProcessAlive -ProcessId $leaked -Name 'cmd')) "M-07: the suite leaked a stand-in process (pid $leaked)."
    }
    foreach ($leaked in $script:ChildPids) {
        Assert-True (-not (Test-ProcessAlive -ProcessId $leaked -Name 'ping')) "M-07: the suite leaked a stand-in child process (pid $leaked)."
    }

    Write-Host "PASS Bounded gpupdate: single runner, routed callers, success and failure exit codes captured, expiry terminates the whole process tree."
} finally {
    # Cleanup must never throw over an already-dead PID, and on 5.1 taskkill's "not found" on
    # stderr is a terminating NativeCommandError under -ErrorAction Stop.
    foreach ($stray in @($script:ChildPids + $script:SpawnedPids)) {
        if ($stray -gt 0) { try { & taskkill.exe /PID $stray /T /F 2>$null | Out-Null } catch { $null = $_ } }
    }
}
