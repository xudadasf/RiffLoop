# Execute the real release entrypoint with local git/API doubles. Never contacts GitHub.
$ErrorActionPreference = 'Stop'
$global:riffReleaseTest = @{ head = '1111111111111111111111111111111111111111'; old = '2222222222222222222222222222222222222222' }
function global:git {
    $global:LASTEXITCODE = 0
    $command = $args -join ' '
    if ($command -match 'credential fill') { return 'password=offline-test-token' }
    if ($command -match 'status --porcelain') {
        if ($global:riffReleaseTest.scenario -eq 'dirty') { return ' M project.yml' }
        return
    }
    if ($command -match 'branch --show-current') { return 'codex/release-test' }
    if ($command -match 'check-ref-format') { return 'codex/release-test' }
    if ($command -match 'ls-remote') {
        $global:riffReleaseTest.remoteReads++
        $sha = if ($global:riffReleaseTest.scenario -eq 'unpublished' -or
            ($global:riffReleaseTest.scenario -eq 'branch_moves' -and $global:riffReleaseTest.remoteReads -gt 1)) { $global:riffReleaseTest.old } else { $global:riffReleaseTest.head }
        return "$sha`trefs/heads/codex/release-test"
    }
    if ($command -match 'rev-list') { return @($global:riffReleaseTest.head, $global:riffReleaseTest.old) }
    if ($command -match 'rev-parse') { return $global:riffReleaseTest.head }
    throw "Unexpected git invocation: $command"
}
function New-TestRun([string]$sha = $global:riffReleaseTest.head) {
    [pscustomobject]@{ id = 100; run_number = 1; name = 'iOS CI'; head_sha = $sha
        head_branch = 'codex/release-test'; status = 'completed'
        conclusion = $(if ($global:riffReleaseTest.scenario -eq 'failed_ci') { 'failure' } else { 'success' })
        created_at = [datetime]::UtcNow; html_url = 'https://example.invalid/run/100' }
}
function global:Invoke-RestMethod {
    param($Uri, $Method = 'Get', $Headers, $ContentType, $Body)
    if ($Method -eq 'Post') {
        $global:riffReleaseTest.posts.Add([pscustomobject]@{ uri = "$Uri"; body = $Body })
        if ($Uri -like '*/ios-ci.yml/dispatches') { $global:riffReleaseTest.dispatchedCI = $true }
        return
    }
    if ($Uri -match '/actions/runs/100$') {
        return New-TestRun $(if ($global:riffReleaseTest.scenario -eq 'wrong_run') { $global:riffReleaseTest.old } else { $global:riffReleaseTest.head })
    }
    if ($Uri -match '/actions/(workflows/ios-ci.yml/)?runs\?') {
        if ($global:riffReleaseTest.scenario -eq 'ancestor' -and -not $global:riffReleaseTest.dispatchedCI) {
            return @{ workflow_runs = @(New-TestRun $global:riffReleaseTest.old) }
        }
        return @{ workflow_runs = @(New-TestRun) }
    }
    throw "Unexpected API invocation: $Method $Uri"
}
function global:Start-Sleep { param($Seconds) }

$failures = @()
foreach ($scenario in @('success', 'ancestor', 'failed_ci', 'wrong_run', 'unpublished', 'branch_moves', 'dirty')) {
    $global:riffReleaseTest.scenario = $scenario
    $global:riffReleaseTest.posts = [Collections.Generic.List[object]]::new()
    $global:riffReleaseTest.remoteReads = 0
    $global:riffReleaseTest.dispatchedCI = $false
    $caught = $null
    try { & "$PSScriptRoot/rerun-ci.ps1" } catch { $caught = $_ }
    $ipaPosts = @($global:riffReleaseTest.posts | Where-Object uri -like '*/ios-unsigned-ipa.yml/dispatches')
    $expectedSuccess = $scenario -in @('success', 'ancestor')
    $expectedError = @{ failed_ci = 'iOS CI 未通过'; wrong_run = '提交或分支不匹配';
        unpublished = '远端'; branch_moves = '远端'; dirty = '工作区有未提交内容' }
    $passed = if ($expectedSuccess) {
        -not $caught -and $ipaPosts.Count -eq 1 -and
            ($ipaPosts[0].body | ConvertFrom-Json).ref -eq 'codex/release-test' -and
            ($ipaPosts[0].body | ConvertFrom-Json).inputs.expected_sha -eq $global:riffReleaseTest.head -and
            $global:riffReleaseTest.remoteReads -ge 2 -and
            @($global:riffReleaseTest.posts | Where-Object uri -like '*/rerun').Count -eq 0
    } else { $caught -and $caught.ToString().Contains($expectedError[$scenario]) -and $ipaPosts.Count -eq 0 }
    if ($scenario -eq 'ancestor') { $passed = $passed -and $global:riffReleaseTest.dispatchedCI }
    if ($passed) { Write-Host "PASS release workflow: $scenario" }
    else { $failures += $scenario; Write-Host "FAIL release workflow: $scenario ($caught)" }
}
if ($failures.Count) { throw "Release regression failures: $($failures -join ', ')" }
