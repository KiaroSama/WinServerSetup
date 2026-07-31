param()

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]
foreach ($path in Get-ChildItem -LiteralPath $projectRoot -Filter *.ps1 -Recurse -File) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path.FullName, [ref]$tokens, [ref]$errors)
    foreach ($parseError in @($errors)) { $failures.Add("$($path.FullName): $($parseError.Message)") }
}
if ($failures.Count -gt 0) { throw ($failures -join "`n") }
Write-Host "PASS all PowerShell files parse in PowerShell $($PSVersionTable.PSVersion)."
