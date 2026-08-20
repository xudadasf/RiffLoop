# Drive the local Sideloadly GUI to cover-install an unsigned IPA onto the iPad.
#
# This script automates exactly the manual sequence proven on 2026-08-19:
#   1. Load the IPA into Sideloadly via the command-line argument.
#   2. Wait for an iDevice to appear in the device combo (USB or Wi-Fi).
#   3. Keep "Use automatic bundle ID" ON, matching the existing installation.
#      With the same Apple account this preserves the signed bundle ID and sandbox.
#   4. Click Start and wait for "Installing 100%: Complete".
#   5. Verify the daemon registered the install for automatic refresh.
#
# Apple ID credentials are never handled here: Sideloadly reuses its own
# remembered session; if Apple asks for a password or 2FA, the user fills
# that window themselves.
#
# Usage:
#   pwsh -File scripts/sideload-install.ps1                    # newest IPA under output/release-*
#   pwsh -File scripts/sideload-install.ps1 -IpaPath <file.ipa>
#   pwsh -File scripts/sideload-install.ps1 -DryRun            # stage everything, stop before Start
param(
    [string]$IpaPath = "",
    [int]$TimeoutMinutes = 20,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$sideloadlyExe = "$env:LOCALAPPDATA\Sideloadly\Sideloadly.exe"
if (-not (Test-Path $sideloadlyExe)) { throw "未找到 Sideloadly：$sideloadlyExe" }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if (-not $IpaPath) {
    $candidates = Get-ChildItem (Join-Path $repoRoot "output") -Recurse -Filter "*unsigned-arm64*.ipa" -ErrorAction SilentlyContinue
    $newest = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { throw "output/ 下没有 unsigned IPA，先运行 scripts/rerun-ci.ps1 -Wait" }
    $IpaPath = $newest.FullName
}
$IpaPath = (Resolve-Path $IpaPath).Path
Write-Host "IPA: $IpaPath"

$stdoutLog = Join-Path $env:TEMP ("sideloadly-install-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
$stderrLog = "$stdoutLog.err"

# 1. Restart the GUI with the IPA argument. A freshly killed instance can leave
#    the AppleMobileDeviceService session locked for a while, so settle first and
#    retry the launch if the device never shows up.
Get-Process -Name Sideloadly -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 40
$proc = Start-Process -FilePath $sideloadlyExe -ArgumentList "`"$IpaPath`"" -PassThru `
    -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
Write-Host "Sideloadly PID: $($proc.Id), log: $stdoutLog"

function Wait-Until([scriptblock]$Condition, [string]$What) {
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) { return $true }
        if ($proc.HasExited) {
            $tail = Get-Content $stdoutLog -Tail 10 -ErrorAction SilentlyContinue
            throw "Sideloadly 提前退出（exit $($proc.ExitCode)）。日志末尾：`n$tail"
        }
        Start-Sleep -Seconds 5
    }
    throw "等待超时：$What"
}

function Get-MainWindow {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$proc.Id)
    $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
    foreach ($w in $windows) {
        if ($w.Current.Name -like "Sideloadly*") { return $w }
    }
    if ($windows.Count -gt 0) { return $windows[0] }
    return $null
}

# 2. Wait for the GUI to load the IPA (its name gets elided into the header label).
$null = Wait-Until {
    (Get-Content $stdoutLog -ErrorAction SilentlyContinue) -match "Elide result|Could not load ipa"
} "Sideloadly 加载 IPA"
$log = Get-Content $stdoutLog -Raw -ErrorAction SilentlyContinue
if ($log -match "Could not load ipa") { throw "Sideloadly 无法加载 IPA：$IpaPath" }
Write-Host "IPA 已加载"

# 3. Wait for a device to appear in the iDevice combo. After a GUI restart the
#    AppleMobileDeviceService pairing session resets and the iPad shows a
#    "信任此电脑" prompt again: restarting the GUI repeatedly only re-triggers
#    that prompt, so we wait patiently on a single launch instead.
function Find-DeviceName {
    $win = Get-MainWindow
    if (-not $win) { return $null }
    $nameCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, "iDevice:")
    $combo = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $nameCond) |
        Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ComboBox } |
        Select-Object -First 1
    if (-not $combo) { return $null }
    try {
        $value = $combo.GetCurrentPattern(
            [System.Windows.Automation.ValuePattern]::Pattern).Current.Value
        if ($value -and $value -ne "<no devices detected>") { return $value }
    } catch {}
    $items = $combo.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($it in $items) {
        if ($it.Current.Name -and $it.Current.Name -ne "<no devices detected>") {
            return $it.Current.Name
        }
    }
    return $null
}

$deviceName = $null
$hintShown = $false
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
while ((Get-Date) -lt $deadline -and -not $deviceName) {
    $deviceName = Find-DeviceName
    if (-not $deviceName) {
        if (-not $hintShown) {
            Write-Host "等待设备… 若 iPad 屏幕出现“信任此电脑”，请点“信任”。"
            $hintShown = $true
        }
        Start-Sleep -Seconds 10
    }
}
if (-not $deviceName) { throw "等待超时仍未检测到 iPad：请确认 USB 连接并在 iPad 上点「信任」后重试" }
Write-Host "设备：$deviceName"

# 4. Verify an Apple ID is remembered (a non-empty account combo beyond the add option).
$win = Get-MainWindow
$acctCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::NameProperty, "Apple ID:")
$acct = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $acctCond) |
    Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ComboBox } |
    Select-Object -First 1
$acctOk = $false
if ($acct) {
    try {
        $accountValue = $acct.GetCurrentPattern(
            [System.Windows.Automation.ValuePattern]::Pattern).Current.Value
        $acctOk = $accountValue -and $accountValue -ne "[+] Add New Apple ID"
    } catch {}
    foreach ($it in $acct.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)) {
        if ($it.Current.Name -and $it.Current.Name -ne "[+] Add New Apple ID") { $acctOk = $true }
    }
}
if (-not $acctOk) { throw "Sideloadly 没有记住的 Apple 账号，请先在 GUI 中登录一次" }
Write-Host "Apple 账号已记住"

# Sideloadly 0.60 automatically mangles the bundle ID on current iOS versions.
# The daemon log is verified after Start because this setting is no longer exposed
# as a named UI Automation control.

if ($DryRun) {
    Write-Host "DryRun：已就绪，未点击 Start。"
    Write-Host "GUI 日志：$stdoutLog"
    return
}

# 6. Click Start and wait for the install to complete.
$startCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::NameProperty, "Start")
$start = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $startCond)
if (-not $start -or -not $start.Current.IsEnabled) { throw "Start 按钮不可用" }
$start.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
Write-Host "已点击 Start，等待安装完成…"

$null = Wait-Until {
    (Get-Content $stdoutLog -ErrorAction SilentlyContinue) -match "Installing 100%: Complete|Done work"
} "安装完成"
$log = Get-Content $stdoutLog -Raw
if ($log -notmatch "Installing 100%: Complete") { throw "安装未确认完成，请查看日志：$stdoutLog" }
if ($log -notmatch "will mangle bundleID") { throw "未确认自动 Bundle ID，请不要启动应用并检查 Sideloadly 设置" }
if ($log -notmatch "App successfully prepared for auto-refresh") { throw "未确认 Automatic Refresh 已登记" }
Write-Host "安装完成：Installing 100%: Complete"

# 7. Verify the daemon registered the install for auto-refresh.
Start-Sleep -Seconds 5
$dbCopy = Join-Path $env:TEMP ("sdl-verify-{0:yyyyMMdd-HHmmss}.db" -f (Get-Date))
$fs = [IO.File]::Open("$env:LOCALAPPDATA\Sideloadly\installations.db", "Open", "Read", "ReadWrite")
$ms = New-Object IO.MemoryStream
$fs.CopyTo($ms); $fs.Close()
[IO.File]::WriteAllBytes($dbCopy, $ms.ToArray()); $ms.Close()
$pyScript = Join-Path $env:TEMP "sdl-verify.py"
@'
import sqlite3, sys, json
con = sqlite3.connect(sys.argv[1])
con.row_factory = sqlite3.Row
r = con.execute(
    "SELECT name, version, final_bundle_id, one_off, known_ttl, refresh_at_hours, last_updated "
    "FROM installations WHERE deleted_at IS NULL ORDER BY id DESC LIMIT 1").fetchone()
print(json.dumps(dict(r), ensure_ascii=False, default=str))
'@ | Set-Content $pyScript -Encoding UTF8
$verify = python $pyScript $dbCopy
Write-Host "数据库最新记录：$verify"
Write-Host "完成。若 Apple 弹出登录/验证窗口，请由用户在窗口中完成。"
