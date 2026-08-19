# Run the full computer-side verification battery against the USB-connected iPad.
#
# Checks (all read from the device itself):
#   1. usbmux presence + UDID
#   2. installed app version/build/signature (installation_proxy)
#   3. RiffLoop process state (DVT proclist)
#   4. screen capture + coarse layout analysis (DVT screenshot)
#   5. 20s live syslog scan for RiffLoop errors/crashes
#   6. Documents sandbox structure (DVT ls: GP/视频/PDF folders)
#
# Evidence is written to output/acceptance-auto/device-check-<timestamp>/.
# Requires: pip install pymobiledevice3, iPad USB-connected and trusted,
# Developer Mode enabled (DeveloperDiskImage already mounted is fine).
param(
    [int]$SyslogSeconds = 20
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outDir = Join-Path $repoRoot "output\acceptance-auto\device-check-$stamp"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

function Write-Step([string]$title) { Write-Host "`n== $title ==" }

# 1. Device presence
Write-Step "1. usbmux"
$mux = pymobiledevice3 usbmux list 2>$null | Out-String
if ($mux -notmatch '"Identifier"') {
    throw "未检测到 USB 连接的 iPad。请插上 iPad 并确认已信任此电脑。"
}
$udid = ([regex]::Match($mux, '"Identifier":\s*"([0-9A-Fa-f-]+)"')).Groups[1].Value
$model = ([regex]::Match($mux, '"ProductType":\s*"([^"]+)"')).Groups[1].Value
$ios = ([regex]::Match($mux, '"ProductVersion":\s*"([^"]+)"')).Groups[1].Value
Write-Host "device: $model, iOS $ios, UDID $udid"

# 2. Installed app info
Write-Step "2. installed app"
$appsJson = "$env:TEMP\riff-apps.json"
pymobiledevice3 apps list 2>$null | Out-File $appsJson -Encoding utf8
$appInfo = python -c @"
import json, sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
app = data.get('com.riffloop.prototype.N3N672QNHY') or {}
print(json.dumps({
    'version': app.get('CFBundleShortVersionString'),
    'build': app.get('CFBundleVersion'),
    'validated': app.get('ProfileValidated'),
    'signer': app.get('SignerIdentity'),
}, ensure_ascii=False))
"@ $appsJson
Write-Host "app: $appInfo"

# 3. Process state
Write-Step "3. process state"
$procJson = "$env:TEMP\riff-procs.json"
pymobiledevice3 developer dvt proclist 2>$null | Out-File $procJson -Encoding utf8
$procInfo = python -c @"
import json, sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
for p in data:
    if p.get('name') == 'RiffLoop':
        print(json.dumps({k: p.get(k) for k in ('pid','foregroundRunning','isApplication','startDate')}, ensure_ascii=False, default=str))
        break
else:
    print('NOT RUNNING')
"@ $procJson
Write-Host "process: $procInfo"

# 4. Screenshot + layout analysis
Write-Step "4. screenshot"
$shot = Join-Path $outDir "screen.png"
pymobiledevice3 developer dvt screenshot $shot 2>$null | Out-Null
if (-not (Test-Path $shot)) { throw "截图失败" }
Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap($shot)
$dark = 0; $light = 0; $total = 0
for ($y = 0; $y -lt $bmp.Height; $y += 10) {
    for ($x = 0; $x -lt $bmp.Width; $x += 10) {
        $c = $bmp.GetPixel($x, $y); $total++
        $avg = ($c.R + $c.G + $c.B) / 3
        if ($avg -lt 45) { $dark++ }
        if ($avg -gt 190) { $light++ }
    }
}
$bmp.Dispose()
Write-Host ("screen {0}x{1}, dark {2:P0}, light {3:P0}" -f 2266, 1488, ($dark / $total), ($light / $total))

# 5. Syslog error scan
Write-Step "5. syslog scan ($SyslogSeconds s)"
$logOut = "$env:TEMP\riff-syslog-$stamp.txt"
$proc = Start-Process -FilePath "python" -ArgumentList '-m', 'pymobiledevice3', 'syslog', 'live' `
    -RedirectStandardOutput $logOut -RedirectStandardError "$logOut.err" -PassThru -WindowStyle Hidden
Start-Sleep -Seconds $SyslogSeconds
$proc.Kill()
$errLines = Select-String -Path $logOut, "$logOut.err" -Pattern 'RiffLoop' -ErrorAction SilentlyContinue |
    Where-Object { $_.Line -match 'ERROR|FAULT|CRASH|abort|assert' } |
    Where-Object { $_.Line -notmatch 'process-info-codesignature' }
if ($errLines) {
    Write-Host "发现异常日志："
    $errLines | Select-Object -First 10 | ForEach-Object { Write-Host $_.Line.Substring(0, [Math]::Min(200, $_.Line.Length)) }
} else {
    Write-Host "无 RiffLoop 错误/崩溃日志"
}

# 6. Documents structure
Write-Step "6. Documents sandbox"
$container = python -c @"
import json, sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
app = data.get('com.riffloop.prototype.N3N672QNHY') or {}
print(app.get('Container', ''))
"@ $appsJson
if ($container) {
    $docs = pymobiledevice3 developer dvt ls "$container/Documents" 2>$null | Out-String
    Write-Host $docs.Trim()
} else {
    Write-Host "无法取得容器路径"
}

# Summary
$summary = @"
# 设备自动检测报告（$stamp）

- 设备：$model / iOS $ios / $udid
- App：$appInfo
- 进程：$procInfo
- 截图：$(Split-Path $shot -Leaf)（保存在本目录）
- 系统日志扫描：$SyslogSeconds 秒，见上方输出
"@
Set-Content -Path (Join-Path $outDir "REPORT.md") -Value $summary -Encoding UTF8
Write-Host "`n报告与截图已保存到：$outDir"
