<#
.SYNOPSIS
    Parse-checks every *.ps1 in the repository with the PowerShell host that runs this script.

.DESCRIPTION
    Invoked once under pwsh and once under Windows PowerShell 5.1 so syntax that only one host
    accepts cannot reach main. Emits GitHub Actions error annotations and exits non-zero on any
    parse failure.
#>
[CmdletBinding()]
param([string]$Path = '.')

$ErrorActionPreference = 'Stop'
$failed = 0
$checked = 0

foreach ($file in Get-ChildItem -Path $Path -Recurse -Filter *.ps1 -File) {
    $checked++
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $failed++
        foreach ($parseError in $errors) {
            Write-Host ("::error file={0},line={1},col={2}::{3}" -f `
                    $file.FullName, $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message)
        }
    }
}

Write-Host ("Parsed {0} file(s) with PowerShell {1}; {2} failed." -f $checked, $PSVersionTable.PSVersion, $failed)
if ($failed -gt 0) { exit 1 }
exit 0
