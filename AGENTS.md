# AGENTS.md

WinServerSetup is a PowerShell provisioning tool for Windows and Windows Server.
It runs elevated (Administrator) against a freshly installed machine and is designed
to be re-runnable and idempotent: `WinServerSetup.ps1` is the orchestrator, the
individual steps live in `scripts\`, and behavior is driven by
`WinServerSetup.config.json`. This file is the technical contract for anyone —
human or agent — changing the code.

## Hard constraints

- **Dual-host compatibility is mandatory.** Every runtime script must load and run
  under **both** Windows PowerShell 5.1 and PowerShell 7. CI parse-checks every
  `.ps1` on both hosts and runs the full test suite twice, once per host.
  `tests\Syntax.Tests.ps1` independently parse-checks every `.ps1` in the repo.
- **English only.** All code, comments, CLI text and log output are in English by
  design, as stated in the `WinServerSetup.ps1` header.
- **No new external runtime dependencies** for production execution. The tool must
  work on a clean Windows install with nothing pre-installed. (PSScriptAnalyzer is a
  CI/development dependency only.)
- **`$Global:` shared state is intentional, not debt.** The setup is one orchestrated
  run whose steps are dot-sourced from `scripts\`, so `$Global:Config`,
  `$Global:RunStats`, `$Global:ProjectRoot` and the colour table are deliberately
  global. `PSAvoidGlobalVars` is suppressed with that justification in
  `PSScriptAnalyzerSettings.psd1`. Do not "fix" this by threading config through
  function signatures.
- **Secrets never go in `WinServerSetup.config.json`.** That file is tracked and
  public; it ships `activation.productKey` and `activation.kmsServer` empty.
  `scripts\Config.ps1` throws `Activation product keys are allowed only in the
  ignored local override` if the tracked config carries a key. The git-ignored
  `WinServerSetup.config.local.json` is the only supported override.

Do not add a rule to `PSScriptAnalyzerSettings.psd1` to silence a finding. Fix the
finding, or suppress it narrowly at the single site with
`[Diagnostics.CodeAnalysis.SuppressMessageAttribute]` plus a justification.

## Local verification

Run all six from the repository root before claiming a change works. This is exactly
what `.github\workflows\powershell-lint.yml` runs on `windows-latest`; if you change
one, change the other.

```powershell
# 1. Config is valid JSON
Get-Content -Raw -Encoding UTF8 .\WinServerSetup.config.json | ConvertFrom-Json | Out-Null

# 2. Parse-check every *.ps1 under PowerShell 7           -> "... 0 failed."
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\.github\parse-check.ps1

# 3. Parse-check every *.ps1 under Windows PowerShell 5.1 -> "... 0 failed."
& 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\.github\parse-check.ps1

# 4. PSScriptAnalyzer at Error + Warning                  -> no output means clean
$targets  = @('WinServerSetup.ps1', 'Run-WinServerSetup.ps1', 'Publish-ToGitHub.ps1')
$targets += (Get-ChildItem .\scripts -Filter *.ps1 -File).FullName
$targets += (Get-ChildItem .\tests   -Filter *.ps1 -File).FullName
$targets | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Settings .\PSScriptAnalyzerSettings.psd1 }

# 5. Tests under PowerShell 7                             -> "FAILED=0"
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Invoke-AllTests.ps1 -TimeoutSeconds 180

# 6. Tests under Windows PowerShell 5.1                   -> "FAILED=0"
& 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Invoke-AllTests.ps1 -TimeoutSeconds 180
```

Every command must exit 0. `Invoke-ScriptAnalyzer -Path` takes a **single string** —
passing an array throws `Cannot convert 'System.Object[]' to the type 'System.String'`,
which is why step 4 loops.

Test suites are discovered from disk by `tests\Invoke-AllTests.ps1`, so a new
`tests\*.Tests.ps1` is picked up automatically and can never be silently left out of
CI. The runner re-invokes **the host it is already running under**, which is why the
same script validates 5.1 or 7 depending on which host launches it.

The runner's summary line reports both a suite count and a failure count
(`HOST=...  SUITES=n  FAILED=0`). Gate on `FAILED=0`; the suite count grows as suites
are added, so do not treat any particular number as the pass condition.

Shared test helpers live in `tests\_Common.ps1` — `Assert-True`, `Assert-Equal`, `Assert-Contains`,
`Get-SetupSourceFile`, `Get-SetupAst` and `Import-FunctionUnderTest`. Dot-source it
**after** `$projectRoot` (and `$mainScript`, where the suite takes a `-MainScript`
override) and **before** the first assertion:

```powershell
. (Join-Path $PSScriptRoot '_Common.ps1')
```

It is not picked up as a suite because discovery filters on `*.Tests.ps1`. A suite that
needs different behaviour just defines its own copy afterwards, which shadows the shared
one. `Import-FunctionUnderTest` takes the parsed ASTs as a second argument —
`Import-FunctionUnderTest $name $setupAsts` — rather than reading the caller's
`$setupAsts` implicitly; reaching across the file boundary works at runtime but is
invisible to PSScriptAnalyzer, which then flags each suite's own `$setupAsts` as
assigned-and-never-used.

A suite that lifts functions out of the setup partition loads it in two lines. Wrap
both in `@()` — PowerShell enumerates a collection on return, so a tree reduced to one
file would otherwise hand back a bare string:

```powershell
$setupSourceFiles = @(Get-SetupSourceFile -ProjectRoot $projectRoot -MainScript $mainScript)
$setupAsts = @(Get-SetupAst -Files $setupSourceFiles -Because 'its download path can be tested')
```

`Get-SetupSourceFile` returns paths rather than ASTs because several suites also join
the raw text for retained source assertions. `-Because` completes the sentence
"`<file>` must parse before …", which is what a suite reports if the partition itself
fails to parse.

**Adding a module to `scripts\` means adding it to `Get-SetupSourceFile`'s list too**,
or every AST-based suite silently stops seeing the functions that moved into it. The
dot-source block in `WinServerSetup.ps1` and the module list inside
`Invoke-SetupStepWaveConcurrently` (the runspace has no session state of its own) need
the same addition. A handful of suites still build the list themselves rather than
calling `Get-SetupSourceFile`; `grep` for the module names before assuming one place
covers it.

## PowerShell 5.1 traps

Each of these caused a real bug in this repository. Check new code against the list —
PowerShell 7 will happily accept all of them.

- **A single-element array returned from a function is unwrapped to a scalar on 5.1**,
  and a scalar has no `.Count` there. Put `@()` around the **call site**, not around
  the `return`.
- **`return $null` writes `$null` to the output stream.** When the function is called
  as a bare statement, that `$null` corrupts the caller's return value. Use a bare
  `return`.
- **In `-replace`, the replacement string treats `$_`, `` $` `` and `$'` as
  substitution tokens** — `$_` expands to the *entire input string*. Use
  `String.Replace()` for literal replacements (see the XML escaping in
  `WinServerSetup.ps1`).
- **`Invoke-WebRequest -OutFile` emits nothing unless `-PassThru` is also passed**, so
  there is no response object to inspect for the final redirected URI.
- **`Get-WinEvent` reports an empty result set as an error.** Detect it via
  `FullyQualifiedErrorId -like 'NoMatchingEventsFound*'`, which is locale-independent
  (see `scripts\Block-RdpBruteforce.ps1`).

Append to this list when a new 5.1-specific bug is found.
