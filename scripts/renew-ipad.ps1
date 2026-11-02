# Renew the installed version; never select an unrelated/newer/older package.
param([switch]$DryRun, [ValidateSet('Auto', 'Network', 'USB')][string]$Mode = 'Auto',
      [switch]$SetupWifi, [switch]$DiagnoseWifi)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'enter-dev.ps1')

function Get-DeviceSnapshot([string]$Transport, [int]$WaitSeconds = 0, [switch]$EnableWifi) {
    $probeArgs = @((Join-Path $PSScriptRoot 'renew-device.py'), '--transport', $Transport, '--wait-seconds', $WaitSeconds)
    if ($script:renewUdid) { $probeArgs += @('--udid', $script:renewUdid) }
    if ($EnableWifi) { $probeArgs += '--setup-wifi' }
    $raw = @(& python @probeArgs 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ($raw -join [Environment]::NewLine) }
    return ($raw -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable
}

function Show-WifiHelp {
    Write-Host '2.4 GHz 与 5 GHz 可以互通，不要求同频段；需要同一可互通局域网。'
    $bonjour = Get-Service 'Bonjour Service' -ErrorAction SilentlyContinue
    if (-not $bonjour) {
        Write-Host '电脑缺少 Bonjour 无线发现服务。请安装 Apple 官方 Bonjour：https://support.apple.com/106380；安装后重启 Apple Mobile Device Service。'
    } elseif ($bonjour.Status -ne 'Running') {
        Write-Host 'Bonjour 服务未运行；请在 Windows 服务中启动 Bonjour Service，再重试无线连接。'
    }
    Write-Host '首次无线设置：USB 连接并信任电脑，运行“RiffLoop 无线续签设置”。'
    Write-Host 'iTunes 设备摘要 → 选项 → 通过 Wi-Fi 与此 iPad 同步 → 应用。然后拔线、解锁 iPad，再尝试无线续签。'
    Write-Host '若仍未发现：检查访客网络/频段间隔离、VPN 的局域网访问和防火墙中的 Apple 服务；不要关闭整个防火墙。'
}

function Show-TrustHelp {
    Write-Host '如 iPad 提示“未受信任的开发者”：'
    Write-Host '设置 → 通用 → VPN 与设备管理 → 开发者 App → 原安装账号 → 信任/验证 App。'
    Write-Host '验证时请让 iPad 连网，按系统提示操作。此步骤需要在 iPad 上手动完成。'
    Write-Host '不要删除 RiffLoop；删除应用会丢失其中的文件与设置。'
}

function Invoke-RenewAttempt([string]$Transport) {
    Write-Host 'RiffLoop 一键续签'
    if ($Transport -eq 'Network') {
        Write-Host '正在等待无线设备（最多 12 秒）；请亮屏解锁 iPad，电脑与 iPad 保持同一局域网。'
    } else {
        Write-Host '正在尝试 USB 连接；请解锁 iPad 并确认信任此电脑。'
    }
    $waitSeconds = if ($Transport -eq 'Network') { 12 } else { 0 }
    $script:canFallbackToUsb = $true
    $snapshot = Get-DeviceSnapshot $Transport -WaitSeconds $waitSeconds
    $script:canFallbackToUsb = $false
    $udid = $snapshot.Identifier
    $script:renewUdid = $udid
    $apps = $snapshot.Apps
    $appBundles = @($apps.Keys | Where-Object { $_ -eq 'com.riffloop.prototype' -or $_ -like 'com.riffloop.prototype.*' })
    if ($appBundles.Count -ne 1) { throw '未找到唯一的已安装 RiffLoop；已停止，避免装成另一份应用。' }
    $bundle = $appBundles[0]
    $app = $apps[$bundle]
    $version = $app.CFBundleShortVersionString
    $build = $app.CFBundleVersion
    if ($version -notmatch '^\d+(\.\d+)+$' -or $build -notmatch '^\d+$') { throw '设备返回的版本号无效。' }
    # The signer records the original personal Apple ID used by Sideloadly.
    if ($app.SignerIdentity -notmatch ':\s*([^\s]+@[^\s]+)\s*\([^)]+\)\s*$') {
        throw '无法确认原安装账号，已停止自动续签。请在 Sideloadly 中核对原账号后手动操作。'
    }
    $appleId = $Matches[1]
    Write-Host "iPad 当前版本：$version（$build）"
    $release = Get-ChildItem (Join-Path $PSScriptRoot '../output') -Directory -Filter "release-$version-build$build-*" |
        Where-Object { Test-Path (Join-Path $_.FullName 'build-info.json') } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $release) { throw "电脑缺少 $version（$build）的原安装包，请取回同版本安装包；不会自动降级。" }
    $metadata = Get-Content (Join-Path $release.FullName 'build-info.json') -Raw | ConvertFrom-Json
    if ($metadata.head_sha -notmatch '^[a-fA-F0-9]{40}$' -or
        -not $metadata.ipa_file -or $metadata.ipa_file -match '[/\\:]' -or $metadata.ipa_file -notlike '*.ipa') {
        throw '安装包说明文件无效，请重新获取原安装包。'
    }
    $ipa = Join-Path $release.FullName $metadata.ipa_file
    $packageVersion = python -c 'import json,plistlib,sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); p=plistlib.loads(z.read("Payload/RiffLoop.app/Info.plist")); print(json.dumps([p.get("CFBundleShortVersionString"),p.get("CFBundleVersion")]))' $ipa | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $packageVersion[0] -ne $version -or $packageVersion[1] -ne $build) {
        throw '安装包内部版本与 iPad 不一致；已停止，避免升级或降级。'
    }
    & (Join-Path $PSScriptRoot 'sideload-install.ps1') -IpaPath $ipa -ExpectedRef $metadata.head_sha `
        -ExpectedAppleId $appleId -ExpectedUdid $udid -ConnectionType $Transport -TimeoutMinutes 4 -DryRun:$DryRun
    if ($DryRun) {
        Write-Host '检查通过：设备、原账号信息、同版本安装包均可读取。尚未续签，也未操作 Sideloadly。'
    } else {
        $afterSnapshot = Get-DeviceSnapshot $Transport -WaitSeconds 12
        $after = $afterSnapshot.Apps
        if ($LASTEXITCODE -ne 0 -or $after[$bundle].CFBundleShortVersionString -ne $version -or
            $after[$bundle].CFBundleVersion -ne $build) {
            throw '签名工具已结束，但未能从设备确认原应用版本，请检查 iPad。'
        }
        Write-Host "续签安装已完成，设备版本仍为 $version（$build）。请在 iPad 上打开 RiffLoop 确认。"
    }
    Show-TrustHelp
}

$script:renewUdid = ''
if ($SetupWifi -or $DiagnoseWifi) {
    try {
        if ($SetupWifi -and $DiagnoseWifi) { throw '请选择无线设置或连接诊断其中一项。' }
        if ($SetupWifi) {
            if ($DryRun) { throw '无线设置会更改设备连接选项；只读检查请使用 -DiagnoseWifi。' }
            Write-Host '请 USB 连接并解锁 iPad；若出现信任提示，请在 iPad 确认。等待最多 60 秒。'
            $snapshot = Get-DeviceSnapshot 'USB' -WaitSeconds 60 -EnableWifi
            if (-not $snapshot.WifiEnabled) { throw 'iPad 未确认启用无线连接。' }
            Write-Host 'iPad 已确认启用 Wi-Fi 连接。此操作没有重装应用。'
            Write-Host '下一步拔掉 USB、保持 iPad 亮屏，并用“一键续签”验证无线连接。'
        } else {
            $raw = @(& python (Join-Path $PSScriptRoot 'renew-device.py') --diagnose 2>&1)
            if ($LASTEXITCODE -ne 0) { throw ($raw -join [Environment]::NewLine) }
            $state = ($raw -join [Environment]::NewLine) | ConvertFrom-Json
            Write-Host "USB 设备：$($state.USB)；Apple 服务中的无线设备：$($state.Network)；局域网设备广播：$($state.BonjourAdvertisements)。"
            $appleService = Get-Service 'Apple Mobile Device Service' -ErrorAction SilentlyContinue
            Write-Host ('Apple 设备服务：' + $(if ($appleService) { $appleService.Status } else { '未安装' }))
            $bonjour = Get-Service 'Bonjour Service' -ErrorAction SilentlyContinue
            Write-Host ('Bonjour 无线发现服务：' + $(if ($bonjour) { $bonjour.Status } else { '未安装' }))
            if ($state.Network -gt 0) { Write-Host 'Apple 服务已发现无线设备；仍需续签前核对目标设备、原账号和安装包。' }
            elseif ($state.BonjourAdvertisements -gt 0) { Write-Host '有设备广播，但 Apple 服务未提供无线连接；请用 iTunes 检查配对及 Wi-Fi 同步。' }
            else { Write-Host '基础探测未收到设备广播；虚拟网卡可能造成漏检，不能据此认定 Wi-Fi 不通。请先检查 Bonjour、Wi-Fi 同步及亮屏状态。' }
        }
        Show-WifiHelp
        return
    } catch {
        Write-Host "无线检查未完成：$($_.Exception.Message)" -ForegroundColor Yellow
        Show-WifiHelp
        exit 1
    }
}
$transports = if ($Mode -eq 'Auto') { @('Network', 'USB') } else { @($Mode) }
foreach ($transport in $transports) {
    try {
        Invoke-RenewAttempt $transport
        return
    } catch {
        Write-Host "$transport 续签未完成：$($_.Exception.Message)" -ForegroundColor Yellow
        if ($Mode -eq 'Auto' -and $transport -eq 'Network' -and $script:canFallbackToUsb) {
            Show-WifiHelp
            Write-Host '无线尝试失败，转为 USB。请连接同一台 iPad、解锁并确认信任；等待连接最多 60 秒。'
            if (-not $DryRun) {
                $usbDeadline = (Get-Date).AddSeconds(60)
                do {
                    $usbIds = @(pymobiledevice3 usbmux list --usb --simple | ConvertFrom-Json)
                    if ($LASTEXITCODE -eq 0 -and (($script:renewUdid -and $usbIds -contains $script:renewUdid) -or (-not $script:renewUdid -and $usbIds.Count -eq 1))) { break }
                    Start-Sleep -Seconds 3
                } while ((Get-Date) -lt $usbDeadline)
            }
        } else {
            if ($transport -eq 'Network') { Show-WifiHelp }
            Show-TrustHelp
            exit 1
        }
    }
}
