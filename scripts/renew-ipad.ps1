# Renew the installed version; never select an unrelated/newer/older package.
param([switch]$DryRun)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'enter-dev.ps1')

function Show-TrustHelp {
    Write-Host '如 iPad 提示“未受信任的开发者”：'
    Write-Host '设置 → 通用 → VPN 与设备管理 → 开发者 App → 原安装账号 → 信任/验证 App。'
    Write-Host '验证时请让 iPad 连网，按系统提示操作。此步骤需要在 iPad 上手动完成。'
    Write-Host '不要删除 RiffLoop；删除应用会丢失其中的文件与设置。'
}

try {
    Write-Host 'RiffLoop 一键续签'
    Write-Host '请用 USB 连接并解锁 iPad，电脑保持联网；如出现“信任此电脑”请确认。'
    Write-Host '本工具使用原账号覆盖安装当前版本；Apple 密码或验证码只在 Sideloadly 窗口输入。'
    $devices = @(pymobiledevice3 usbmux list | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0) { throw '读取设备失败，请检查 USB 连接与信任状态。' }
    if ($devices.Count -ne 1 -or $devices[0].DeviceClass -ne 'iPad' -or $devices[0].ConnectionType -ne 'USB') {
        throw '请只连接一台 iPad，并使用 USB 数据线；连接并解锁后再次双击续签入口。'
    }
    $udid = $devices[0].Identifier
    $apps = pymobiledevice3 apps list --udid $udid | ConvertFrom-Json -AsHashtable
    if ($LASTEXITCODE -ne 0) { throw '无法读取 iPad 上的软件，请解锁并确认信任此电脑。' }
    $appBundles = @($apps.Keys | Where-Object { $_ -like 'com.riffloop.prototype.*' })
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
        -ExpectedAppleId $appleId -ExpectedUdid $udid -DryRun:$DryRun
    if ($DryRun) {
        Write-Host '检查通过：设备、原账号信息、同版本安装包均可读取。尚未续签，也未操作 Sideloadly。'
    } else {
        $after = pymobiledevice3 apps list --udid $udid | ConvertFrom-Json -AsHashtable
        if ($LASTEXITCODE -ne 0 -or $after[$bundle].CFBundleShortVersionString -ne $version -or
            $after[$bundle].CFBundleVersion -ne $build) {
            throw '签名工具已结束，但未能从设备确认原应用版本，请检查 iPad。'
        }
        Write-Host "续签安装已完成，设备版本仍为 $version（$build）。请在 iPad 上打开 RiffLoop 确认。"
    }
    Show-TrustHelp
} catch {
    Write-Host "续签未完成：$($_.Exception.Message)" -ForegroundColor Red
    Show-TrustHelp
    exit 1
}
