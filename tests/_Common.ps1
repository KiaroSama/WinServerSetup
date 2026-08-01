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

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw ("{0} Expected={1}; Actual={2}" -f $Message, $Expected, $Actual) }
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
