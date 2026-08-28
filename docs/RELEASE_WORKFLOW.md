# iPad 发布与归档（2026-08-29）

只发布明确提交的 iOS 版本。保留用户脏文件；需要发版时使用干净的独立工作树，不要为了通过检查而提交或删除 `需修改记录.md`、Android 文件等无关内容。

## 1. 完整回归

在项目根目录执行：

```powershell
pwsh -File scripts/test-release-workflow.ps1
python scripts/test-verify-ipa.py
node --test scripts/test-video-mode.mjs scripts/test-pdf-mode.mjs scripts/test-gp-display.mjs scripts/test-gp-playback.mjs scripts/test-reported-ios-issues.mjs
git diff --check
```

前两项为离线发布安全测试：不会访问 GitHub、启动 Sideloadly 或操作 iPad。Swift 与真实 AVPlayer 用例由 iOS CI 的 iPad 模拟器执行。

## 2. 提交、推送、构建

逐个暂存本次文件，确认 diff，再提交并推送当前分支：

```powershell
git status --short
git push origin HEAD
pwsh -File scripts/rerun-ci.ps1 -Wait
```

- 默认读取当前分支；分离 HEAD 必须显式给 `-Branch`。
- 工作树不干净、未推送、远端分支与 HEAD 不同：停止，不打包。
- 只接受当前 SHA、当前分支的 CI，不再借用祖先提交。缺少 CI 时触发当前分支 CI；失败则停止。
- CI 无论是否传 `-Wait` 都必须先通过。不传 `-Wait` 时在 IPA 触发后返回；传入时继续等待并下载该次运行。
- 打包前重新检查远端 SHA；工作流也核对 `expected_sha`，阻止检查与打包之间的分支变化。
- 下载产物放在 `output/release-版本-build构建号-短SHA/`，与已验收稳定包分开。

单独下载某个已成功运行的包：

```powershell
pwsh -File scripts/download-ipa.ps1 -Ref v0.25.51 -RunId 33175417399
```

不推荐 `-AllowOlderCommit`；默认严格匹配请求提交。`build-info.json` 必须与 IPA 一起保存。

## 3. 先校验，再覆盖安装

```powershell
pwsh -File scripts/sideload-install.ps1 -IpaPath '<完整IPA路径>' -ExpectedRef v0.25.51 -DryRun
pwsh -File scripts/sideload-install.ps1 -IpaPath '<完整IPA路径>' -ExpectedRef v0.25.51
```

`-ExpectedRef` 默认 HEAD；安装归档稳定版时显式指定标签。校验不只检查文件名，还检查清单提交、SHA256、IPA 内的版本号、build、Bundle ID 和 iPhoneOS 平台。任何不符均在启动侧载前停止。

`-DryRun` 只做校验，不再打开 GUI。正式安装需要可交互的 Sideloadly 窗口；隐藏窗口不能可靠提供 UI 自动化控件。使用原 Apple 账号、自动 Bundle ID 和 Automatic Refresh；密码及验证码由用户在本机窗口填写。

不要卸载旧 App，不要清空应用数据。若安装停在 0%，先结束 RiffLoop 进程再重试，不要删除应用。安装完成后启动 App，运行：

```powershell
pwsh -File scripts/device-check.ps1 -SyslogSeconds 10
```

## 4. 固定稳定版本

用户确认后，标签指向实际验收的应用提交，而非较新的文档提交。不要强制移动已发布标签。

归档 IPA、`build-info.json`、测试及真机记录到主项目的 `output/stable-releases/版本-build构建号/`，核对 SHA256，再更新 `docs/releases/` 和交接文档。仅工具/文档/测试变更不需要重新安装当前稳定 App。
