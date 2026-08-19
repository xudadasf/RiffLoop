# Re-run the iPad CI and produce a fresh unsigned IPA, then download it.
#
# Usage:
#   pwsh -File scripts/rerun-ci.ps1                 # rerun iOS CI for HEAD + dispatch IPA
#   pwsh -File scripts/rerun-ci.ps1 -Wait           # also poll until finished and download
#   pwsh -File scripts/rerun-ci.ps1 -Wait -TimeoutMinutes 60
param(
    [switch]$Wait,
    [int]$TimeoutMinutes = 45
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$ownerRepo = "xudadasf/RiffLoop"
$branch = "codex/ipad-migration"

$cred = "protocol=https`nhost=github.com`n`n" | git credential fill 2>$null
$tok = ($cred | Select-String '^password=').ToString().Substring(9)
if (-not $tok) { throw "git credential 中没有可用的 GitHub token" }
$headers = @{ "User-Agent" = "riff-loop-downloader"; "Authorization" = "Bearer $tok" }

$headSha = (git -C $repoRoot rev-parse HEAD).Trim()
Write-Host "HEAD: $headSha"

# 1. Rerun the latest iOS CI run for this commit or its nearest ancestor with one
#    (a commit that only touched scripts/docs never triggered iOS CI itself).
$ciRun = $null
$candidates = @(git -C $repoRoot rev-list HEAD -n 30)
foreach ($sha in $candidates) {
    $runs = Invoke-RestMethod -Uri "https://api.github.com/repos/$ownerRepo/actions/runs?per_page=20&head_sha=$sha" -Headers $headers
    $ciRun = $runs.workflow_runs | Where-Object { $_.name -eq "iOS CI" } | Select-Object -First 1
    if ($ciRun) { break }
}
if (-not $ciRun) { throw "HEAD 及其最近 30 个祖先提交都没有 iOS CI 运行记录" }
if ($ciRun.status -eq "in_progress" -or $ciRun.status -eq "queued") {
    Write-Host "iOS CI #$($ciRun.run_number) 已在运行，跳过 rerun"
} else {
    Write-Host "rerun iOS CI #$($ciRun.run_number) @ $($ciRun.head_sha.Substring(0,7)) ($($ciRun.conclusion))"
    Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$ownerRepo/actions/runs/$($ciRun.id)/rerun" -Headers $headers | Out-Null
}

# 2. Dispatch the unsigned IPA workflow for the branch.
$dispatchStarted = (Get-Date).ToUniversalTime()
Write-Host "dispatch iPad Unsigned IPA @ $branch"
Invoke-RestMethod -Method Post `
    -Uri "https://api.github.com/repos/$ownerRepo/actions/workflows/ios-unsigned-ipa.yml/dispatches" `
    -Headers $headers `
    -ContentType "application/json" `
    -Body (@{ ref = $branch } | ConvertTo-Json) | Out-Null

if (-not $Wait) {
    Write-Host "已触发。使用 -Wait 可等待完成并自动下载 IPA。"
    return
}

function Wait-Run([int]$runId, [datetime]$deadline, [string]$label) {
    while ((Get-Date) -lt $deadline) {
        $run = Invoke-RestMethod -Uri "https://api.github.com/repos/$ownerRepo/actions/runs/$runId" -Headers $headers
        if ($run.status -eq "completed") {
            Write-Host "$label #$($run.run_number) => $($run.conclusion)"
            return $run.conclusion
        }
        Start-Sleep -Seconds 20
    }
    Write-Host "$label 等待超时"
    return "timeout"
}

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)

# Find the dispatched IPA run: latest "iPad Unsigned IPA" run created at/after dispatch.
$ipaRun = $null
for ($i = 0; $i -lt 15 -and -not $ipaRun; $i++) {
    $runs = Invoke-RestMethod -Uri "https://api.github.com/repos/$ownerRepo/actions/runs?per_page=10" -Headers $headers
    $ipaRun = $runs.workflow_runs | Where-Object {
        $_.name -eq "iPad Unsigned IPA" -and $_.created_at.ToUniversalTime() -ge $dispatchStarted
    } | Select-Object -First 1
    if (-not $ipaRun) { Start-Sleep -Seconds 5 }
}
if (-not $ipaRun) { throw "未找到刚触发的 iPad Unsigned IPA 运行" }

$ciConclusion = Wait-Run $ciRun.id $deadline "iOS CI"
$ipaConclusion = Wait-Run $ipaRun.id $deadline "iPad Unsigned IPA"

if ($ciConclusion -ne "success") { throw "iOS CI 未通过：$ciConclusion" }
if ($ipaConclusion -ne "success") { throw "iPad Unsigned IPA 未通过：$ipaConclusion" }

Write-Host "两个工作流均通过，下载 IPA…"
& (Join-Path $PSScriptRoot "download-ipa.ps1")
