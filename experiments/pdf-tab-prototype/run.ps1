param([string]$PdfPath = '', [string]$Bars = 'all')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../scripts/enter-dev.ps1')
$env:PYTHONUTF8='1'
$env:PYTHONIOENCODING='utf-8'
if (-not $PdfPath) {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [Windows.Forms.OpenFileDialog]::new()
    $dialog.Title = '选择电子六线谱 PDF（实验工具）'
    $dialog.Filter = 'PDF 乐谱 (*.pdf)|*.pdf'
    if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
    $PdfPath = $dialog.FileName
}
$PdfPath = (Resolve-Path -LiteralPath $PdfPath).Path
$destination = Join-Path $PSScriptRoot ('../../output/pdf-tab-prototype/manual-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
Write-Host '这是实验功能：扫描谱、多声部、延音和演奏技巧尚未完整支持。'
Write-Host '将先识别并核对拍数；有未解决的节奏问题时不生成 GP。'
python (Join-Path $PSScriptRoot 'convert.py') $PdfPath --out $destination --bars $Bars
if ($LASTEXITCODE -eq 0) {
    Write-Host '已生成 experimental.gp，仅作对照试听；绿色小节框不代表全部正确。' -ForegroundColor Green
} else {
    Write-Host '未导出整曲。请查看 overlay.pdf 中的红框，以及 recognized.json 中的 issues。' -ForegroundColor Yellow
}
Write-Host "结果目录：$destination"
Invoke-Item -LiteralPath (Resolve-Path -LiteralPath $destination).Path
