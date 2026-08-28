# Validate the published HEAD, pass its CI, then build exactly that commit.
# Without -Wait, return after IPA dispatch (CI is always awaited).
param(
    [string]$Branch = '',
    [switch]$Wait,
    [ValidateRange(1, 120)][int]$TimeoutMinutes = 45
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$base = 'https://api.github.com/repos/xudadasf/RiffLoop'
$headSha = (git -C $repoRoot rev-parse --verify HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw '无法读取 HEAD' }
if (git -C $repoRoot status --porcelain --untracked-files=normal) {
    throw '工作区有未提交内容；请只提交本次发布需要的文件，再运行发布脚本。'
}
if (-not $Branch) { $Branch = (git -C $repoRoot branch --show-current | Out-String).Trim() }
if (-not $Branch) { throw '分离 HEAD 状态，请显式指定 -Branch。' }
git check-ref-format --branch $Branch | Out-Null
if ($LASTEXITCODE -ne 0) { throw '分支名称无效' }
function Assert-PublishedHead {
    $remote = git -C $repoRoot ls-remote --exit-code --heads origin "refs/heads/$Branch"
    if ($LASTEXITCODE -ne 0 -or -not $remote -or ($remote -split '\s+')[0] -ne $headSha) {
        throw "远端 $Branch 与本地 HEAD 不一致；未触发 IPA。请核对并推送当前提交。"
    }
}
Assert-PublishedHead
$cred = "protocol=https`nhost=github.com`n`n" | git credential fill 2>$null
$password = @($cred | Select-String '^password=')
if ($password.Count -ne 1) { throw 'git credential 中没有可用的 GitHub token' }
$headers = @{ 'User-Agent' = 'RiffLoop-release'; Authorization = "Bearer $($password[0].ToString().Substring(9))" }
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$encodedBranch = [uri]::EscapeDataString($Branch)
function Find-Run([string]$workflow, [datetime]$since = [datetime]::MinValue) {
    $runs = Invoke-RestMethod "$base/actions/workflows/$workflow/runs?head_sha=$headSha&branch=$encodedBranch&per_page=100" -Headers $headers
    $runs.workflow_runs | Where-Object {
        $_.head_sha -eq $headSha -and $_.head_branch -eq $Branch -and
        ([datetime]$_.created_at).ToUniversalTime() -ge $since
    } | Select-Object -First 1
}
function Dispatch-Run([string]$workflow) {
    Assert-PublishedHead
    # GitHub timestamps have second precision.
    $since = [datetime]::UtcNow.AddSeconds(-1)
    $body = @{ ref = $Branch }
    if ($workflow -eq 'ios-unsigned-ipa.yml') { $body.inputs = @{ expected_sha = $headSha } }
    Invoke-RestMethod -Method Post "$base/actions/workflows/$workflow/dispatches" -Headers $headers `
        -ContentType 'application/json' -Body ($body | ConvertTo-Json) | Out-Null
    for ($attempt = 0; $attempt -lt 24 -and (Get-Date) -lt $deadline; $attempt++) {
        $run = Find-Run $workflow $since
        if ($run) { return $run }
        Start-Sleep -Seconds 5
    }
    throw "未找到本次 $workflow 运行；请检查 Actions，不要重复盲目打包。"
}
function Wait-Run($run, [string]$label) {
    while ((Get-Date) -lt $deadline) {
        $state = Invoke-RestMethod "$base/actions/runs/$($run.id)" -Headers $headers
        if ($state.head_sha -ne $headSha -or $state.head_branch -ne $Branch) { throw "$label 提交或分支不匹配" }
        if ($state.status -eq 'completed') {
            if ($state.conclusion -ne 'success') { throw "$label 未通过：$($state.conclusion)" }
            Write-Host "$label #$($state.run_number) 通过 @ $headSha"
            return $state
        }
        Start-Sleep -Seconds 20
    }
    throw "$label 等待超时；未继续发布。"
}
Write-Host "发布分支：$Branch；提交：$headSha"
$ci = Find-Run 'ios-ci.yml'
if (-not $ci -or ($ci.status -eq 'completed' -and $ci.conclusion -ne 'success')) {
    $ci = Dispatch-Run 'ios-ci.yml'
}
$null = Wait-Run $ci 'iOS CI'
Assert-PublishedHead
if (-not $Wait) {
    Invoke-RestMethod -Method Post "$base/actions/workflows/ios-unsigned-ipa.yml/dispatches" -Headers $headers `
        -ContentType 'application/json' -Body (@{ ref = $Branch; inputs = @{ expected_sha = $headSha } } | ConvertTo-Json) | Out-Null
    Write-Host "CI 已通过，IPA 已触发。使用 download-ipa.ps1 -Ref $headSha 下载，或下次加 -Wait。"
    return
}
$ipa = Dispatch-Run 'ios-unsigned-ipa.yml'
$ipa = Wait-Run $ipa 'iPad Unsigned IPA'
& (Join-Path $PSScriptRoot 'download-ipa.ps1') -Ref $headSha -RunId $ipa.id
