$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'sideload-install.ps1'), [ref]$tokens, [ref]$errors)
if ($errors) { throw ($errors | Out-String) }
foreach ($name in @('Test-SelectedAppleId', 'Test-SideloadInstallComplete')) {
    $function = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $name
    }, $true)
    if (-not $function) { throw "Required check function not found: $name" }
    . ([scriptblock]::Create($function.Extent.Text))
}

$cases = @(
    @{ Selected='test@example.com'; Expected='test@example.com'; Match=$true },
    @{ Selected='test@example.com [10 App IDs Remaining]'; Expected='test@example.com'; Match=$true },
    @{ Selected='TEST@example.com [1 App ID Remaining]'; Expected='test@example.com'; Match=$true },
    @{ Selected='other@example.com [10 App IDs Remaining]'; Expected='test@example.com'; Match=$false },
    @{ Selected='test@example.com.evil [10 App IDs Remaining]'; Expected='test@example.com'; Match=$false },
    @{ Selected='test@example.com [unexpected]'; Expected='test@example.com'; Match=$false },
    @{ Selected='[+] Add New Apple ID'; Expected='test@example.com'; Match=$false }
)
foreach ($case in $cases) {
    $actual = Test-SelectedAppleId $case.Selected $case.Expected
    if ($actual -ne $case.Match) { throw "Account match failed for test case: $($case.Selected)" }
}
Write-Output "Account matching: $($cases.Count) cases passed."

$completionCases = @(
    @{ Log="Installing 100%: Complete`r`nDone work"; Complete=$true },
    @{ Log="Installing: 100% Complete`r`nDone work"; Complete=$true },
    @{ Log='Installing: 100% InstallComplete'; Complete=$false },
    @{ Log='Done work'; Complete=$false },
    @{ Log='Installing: 100% Complete but failed'; Complete=$false },
    @{ Log=''; Complete=$false }
)
foreach ($case in $completionCases) {
    $actual = Test-SideloadInstallComplete $case.Log
    if ($actual -ne $case.Complete) { throw "Install completion check failed for: $($case.Log)" }
}
Write-Output "Install completion: $($completionCases.Count) cases passed."
