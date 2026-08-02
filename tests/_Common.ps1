<#
    Shared test helpers.

    Not discovered as a suite: Invoke-AllTests.ps1 filters on *.Tests.ps1, and this file
    does not match. It is dot-sourced by each suite instead.

    Dot-source it AFTER $projectRoot and (where the suite has one) $mainScript are set, and
    BEFORE the first assertion.

    Import-FunctionUnderTest takes the parsed ASTs as an explicit argument rather than reading
    the caller's $setupAsts implicitly. Reaching across the file boundary works at runtime but
    is invisible to PSScriptAnalyzer, which then reports the suite's $setupAsts as assigned and
    never used - a warning that would have to be suppressed to stay green. Passing it keeps the
    coupling visible to both the reader and the analyzer.

    A suite needing different behaviour simply defines its own copy after dot-sourcing this
    file; a locally defined function shadows the one loaded here.
#>

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Message
    )
    if ($Text -notmatch $Pattern) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw ("{0} Expected={1}; Actual={2}" -f $Message, $Expected, $Actual) }
}

<#
    The setup partition every suite parses to lift functions out of.

    WinServerSetup.ps1 dot-sources its function library from scripts\, so extraction by name has
    to search that whole partition. $MainScript is searched FIRST so a suite replaying against a
    deliberately defective copy still shadows the on-disk original.

    Returns paths, not ASTs, because five suites also join the raw text for their retained source
    assertions. Wrap the call in @() - PowerShell enumerates a collection on return, so a tree
    reduced to one file would otherwise yield a bare string.
#>
function Get-SetupSourceFile {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$MainScript = ""
    )
    $entry = if ([string]::IsNullOrWhiteSpace($MainScript)) { Join-Path $ProjectRoot 'WinServerSetup.ps1' } else { $MainScript }
    $names = @('WinServerSetup.ps1') + @('Console', 'Core', 'Download', 'Rdp', 'RdpBlockerTask', 'Install', 'AppIntegration', 'Runtimes', 'SystemSettings', 'Maintenance' |
            ForEach-Object { "scripts\{0}.ps1" -f $_ })
    return @(@($entry) + @($names | ForEach-Object { Join-Path $ProjectRoot $_ })) |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique
}

<#
    Parses those files and fails the suite before any assertion runs if one of them does not
    parse - otherwise a syntax error surfaces as a confusing "must define <Name>" much later.
    Wrap the call in @() for the same reason as above.
#>
function Get-SetupAst {
    param(
        [Parameter(Mandatory)][string[]]$Files,
        [string]$Because = "its behaviour can be tested"
    )
    return @(foreach ($file in $Files) {
            $tokens = $null
            $parseErrors = $null
            $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$parseErrors)
            Assert-True ($parseErrors.Count -eq 0) "$file must parse before $Because."
            $fileAst
        })
}

function Import-FunctionUnderTest {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Management.Automation.Language.Ast[]]$Asts
    )
    foreach ($fileAst in $Asts) {
        $definition = $fileAst.FindAll({
                param($node)
                ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq $Name)
            }, $true) | Select-Object -First 1
        if ($null -ne $definition) { return $definition.Extent.Text }
    }
    throw "WinServerSetup.ps1 or its scripts\ modules must define $Name."
}
