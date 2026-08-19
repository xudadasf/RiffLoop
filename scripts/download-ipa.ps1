# Download the latest successful "iPad Unsigned IPA" artifact and extract the IPA.
#
# Usage:
#   pwsh -File scripts/download-ipa.ps1                  # latest run for current HEAD
#   pwsh -File scripts/download-ipa.ps1 -Ref <ref>       # latest run for another commit/ref
#   pwsh -File scripts/download-ipa.ps1 -AllowOlderCommit # any recent successful run
#
# The extracted IPA is placed under output/release-<version>-build<build>/
# together with a build-info.json describing the run it came from.
param(
    [string]$Ref = "",
    [switch]$AllowOlderCommit
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$ownerRepo = "xudadasf/RiffLoop"

$cred = "protocol=https`nhost=github.com`n`n" | git credential fill 2>$null
$tok = ($cred | Select-String '^password=').ToString().Substring(9)
if (-not $tok) { throw "git credential 中没有可用的 GitHub token" }
$headers = @{ "User-Agent" = "riff-loop-downloader"; "Authorization" = "Bearer $tok" }

$targetSha = if ($Ref) {
    (git -C $repoRoot rev-parse "$Ref").Trim()
} else {
    (git -C $repoRoot rev-parse HEAD).Trim()
}
Write-Host "target commit: $targetSha"

function Find-SuccessfulRun {
    $page = 1
    $checked = 0
    while ($page -le 10 -and $checked -lt 500) {
        $url = "https://api.github.com/repos/$ownerRepo/actions/runs?per_page=100&page=$page"
        $runs = Invoke-RestMethod -Uri $url -Headers $headers
        if ($runs.workflow_runs.Count -eq 0) { break }
        foreach ($run in $runs.workflow_runs) {
            $checked += 1
            if ($run.name -ne "iPad Unsigned IPA") { continue }
            if ($run.status -ne "completed" -or $run.conclusion -ne "success") { continue }
            if (-not $AllowOlderCommit -and $run.head_sha -ne $targetSha) { continue }
            return $run
        }
        $page += 1
    }
    return $null
}

$run = Find-SuccessfulRun
if (-not $run) {
    $hint = if ($AllowOlderCommit) { "" } else { " 使用 -AllowOlderCommit 可取最近一次成功构建。" }
    throw "未找到 iPad Unsigned IPA 的成功构建（commit $targetSha）。$hint"
}

Write-Host ("run: #{0} {1} ({2})" -f $run.run_number, $run.head_sha.Substring(0, 7), $run.created_at.ToString("yyyy-MM-dd HH:mm"))

$artifacts = Invoke-RestMethod -Uri "https://api.github.com/repos/$ownerRepo/actions/runs/$($run.id)/artifacts" -Headers $headers
$artifact = $artifacts.artifacts | Where-Object { $_.name -like "RiffLoop-iPad-*" } | Select-Object -First 1
if (-not $artifact) {
    throw "构建 #$($run.run_number) 没有可下载的 IPA artifact"
}

$zipPath = Join-Path $env:TEMP ("{0}-{1}.zip" -f $artifact.name, $run.id)
Write-Host "downloading: $($artifact.name) ($([math]::Round($artifact.size_in_bytes / 1MB, 2)) MB)"
Invoke-WebRequest -Uri $artifact.archive_download_url -Headers $headers -OutFile $zipPath -UseBasicParsing

$projectYml = git -C $repoRoot show "$($run.head_sha):project.yml"
$version = ([regex]::Match($projectYml, 'MARKETING_VERSION:\s*([0-9.]+)')).Groups[1].Value
$build = ([regex]::Match($projectYml, 'CURRENT_PROJECT_VERSION:\s*(\d+)')).Groups[1].Value
$outDir = Join-Path $repoRoot "output\release-$version-build$build"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $ipaEntry = $zip.Entries | Where-Object { $_.Name -like "*.ipa" } | Select-Object -First 1
    if (-not $ipaEntry) { throw "artifact 中没有 IPA 文件" }
    $ipaPath = Join-Path $outDir $ipaEntry.Name
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($ipaEntry, $ipaPath, $true)
} finally {
    $zip.Dispose()
    Remove-Item $zipPath -ErrorAction SilentlyContinue
}

$info = [ordered]@{
    run_id          = $run.id
    run_number      = $run.run_number
    head_sha        = $run.head_sha
    created_at      = $run.created_at.ToString("o")
    html_url        = $run.html_url
    artifact_name   = $artifact.name
    ipa_file        = (Split-Path $ipaPath -Leaf)
    sha256          = (Get-FileHash $ipaPath -Algorithm SHA256).Hash
}
$info | ConvertTo-Json | Set-Content -Path (Join-Path $outDir "build-info.json") -Encoding UTF8

Write-Host ""
Write-Host "IPA: $ipaPath"
Write-Host "SHA256: $($info.sha256)"
Write-Host "来自构建 #$($run.run_number)（$($run.head_sha.Substring(0,7))）"
