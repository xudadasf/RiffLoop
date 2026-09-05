# iOS 当前接续入口

更新：2026-09-05。本文件持续记录本轮状态；不要把代码已推送当作真机验收。

## 项目与用户要求

- 仓库：xudadasf/RiffLoop，开发分支 `codex/ipad-home-ui`。
- 这台 Windows 电脑的独立项目入口：`C:\Users\sadadashare\Desktop\RiffLoop-iOS`。禁止使用旧“Codex共享项目”指向 sadada 桌面的链接。
- 仅修改、测试 iPad/iOS，保持 Android 不变。`需修改记录.md` 是用户保留的未提交文件，禁止修改、暂存、提交或清理。
- 用户要求代理负责修改、完整回归、编译、下载、安装及可执行的体验测试。Apple 密码/验证码仍由本人在官方窗口填写。
- 保持原 Apple 账号及最终 Bundle ID `com.riffloop.prototype.N3N672QNHY`；只能覆盖安装，禁止卸载/清数据。
- GP 保持 B → Paused → seek A → A 回执 → 一小节预备拍 → A 到 B；原生内嵌伴奏不退回 WKWebView Blob/data URL。
- 相关需求、诊断和验证写入 Git/GitHub，便于新账号接续。用户要求本地保留源码、测试、脚本和开发文档，验证后清理可再生安装包/构建缓存/日志。不要清理外部迁移备份或 iPad 文件。

## 本轮需求与实现状态

统一跟踪：[Issue #1](https://github.com/xudadasf/RiffLoop/issues/1)。`0.25.53（97）` 已构建、校验并归档，应用提交 `59f23259768f0bccd332afc02c53916f853665d7`；稳定标签仍为 `v0.25.51`。

**接下来：** 安装仍未完成。认证先返回 Apple 登录 HTTP 404，随后用户打开安装器出现 `IPC fail: CoreFP err Could not CoreFP key: Access is denied`。实机重新查询仍为 0.25.52（96），原 Bundle ID，签名有效。当前 Windows 进程不是管理员，CoreFP 的 HKLM 注册表项普通用户仅可读；权限问题是待验证的原因，不能把 404 直接当成密码错误。已对同一已校验 IPA 发起安装器管理员启动，但桌面控制连续返回 `foreground window did not report a process id`，尚未确认新的界面或认证结果。先恢复可操作桌面并处理 Windows 提权确认，再核验认证、安装结果、文件/偏好保留和 Automatic Refresh。禁止卸载/清数据；不要为后续文档提交重新打包。密码、验证码不得记录到 Git。

1. 外部打开：声明 GP/GPX/GP3–5、PDF、MP4/MOV/M4V，接收文件 URL，复制到对应文件库后进入模式。同名文件另存，禁止覆盖原练习文件。微信实际列表显示需真机测试。
2. 文件打开时屏幕常亮：包括暂停看谱；离开页面/进入后台释放，多页面切换不互相取消。
3. 音量：视频/PDF/GP 合成与伴奏、预备拍上限 200%；GP 节拍器上限 300%。默认/已有设置不主动加大。视频/PDF 使用 PCM 增益而非仅扩大 AVPlayer.volume 数值。
4. GP：测试复现了播放被拒绝仍保留播放意图，以及新谱误用旧谱已就绪状态。重置/重发相关参数，等待新就绪回执，预备拍回看 A；普通循环不显示提速轮次分母。
5. PDF：独立节拍器按钮；开始记录自动播放节拍并保存起点小节/拍号；有有效记录才能跟谱；静音跟谱使用独立时钟；在用户选定拍点开启跟谱不重启已运行的节拍器。

## 运行环境

先执行 `. ./scripts/enter-dev.ps1`，使用当前 checkout 路径，不复制历史文档里的旧用户绝对路径。

已确认 GitHub CLI 登录 `xudadasf`、仓库 ADMIN、可读取 Actions。新账号需 `gh auth login --hostname github.com --git-protocol https --web --scopes repo,workflow`，随后 `gh auth setup-git`；密码和验证码在官方窗口自行填写。

共享 Python 的部分依赖存在读取权限/缺包问题。已在当前用户 `%LOCALAPPDATA%\Programs\RiffLoopTools\device-python` 安装独立环境（pymobiledevice3 10.9.0、Pillow 12.2.0），`pip check` 和 USB 查询通过。新 Windows 账号可运行 `scripts/setup-device-tools.ps1` 重新建立自己的环境；不复制其他账号的登录态/密码。

Swift/Xcode 在 GitHub Actions 的 macOS 上编译测试，不在 Windows 安装 Xcode。详见 `docs/RELEASE_WORKFLOW.md`。正式打包从明确提交的干净工作树执行；不要为消除脏状态提交用户记录。

## 当前验证边界

- 本地五套 Node 回归、7 个发布流程安全用例、6 项 IPA 校验器测试通过。
- GP 新回归先失败、修正后通过，使用生产控制器及内置 alphaTab 的拒绝启动分支；这不等于已覆盖用户所有间歇性问题。
- CI [33943999314](https://github.com/xudadasf/RiffLoop/actions/runs/33943999314) 的 126 项 Swift 用例中，真实 GP 换谱/0.9×选区循环、PDF 独立时钟、视频快速跳转及两档各 50 轮循环通过；3 项新页面常亮断言失败，独立 UIHostingController 缺少 SwiftUI Scene 环境桥接，测试改为传入实际 UIWindowScene 前台状态后再验。不能把该失败运行当作发布通过。
- 后续真实 AlphaSynth 回归复现“预备拍缓冲后暂停，已丢弃的样本计数阻塞恢复”。手动恢复前清除计数并回到暂停的谱面位置，20 次中断恢复通过；自动 B→A 握手保持原路径。云端 WebKit 测试增加了预备拍中途暂停再恢复。
- [CI 33945156173](https://github.com/xudadasf/RiffLoop/actions/runs/33945156173)（`5850ee5`）完整通过，126 项 Swift 测试、Node 与发布安全检查成功，含预备拍中断恢复、三页常亮及 SwiftUI 移除页面后释放请求。已查看三模式截图，PDF 按钮文字断行已解决；GP 工具区另加宽度限制后，最终提交仍需匹配 CI 与重新截图。
- 本轮开始时实机读取仍为 0.25.52（96）、原 Bundle ID、ProfileValidated=true；取得 11 个 Documents 文件的清单及 14 个偏好设置键的临时快照。私有快照不提交 Git。
- 最终 [CI #113](https://github.com/xudadasf/RiffLoop/actions/runs/33945792459) / [IPA #90](https://github.com/xudadasf/RiffLoop/actions/runs/33946252956) 对应同一应用提交：127 项 Swift 测试全部通过（含最后的 PDF 静音跟谱拖动进度用例）。三模式截图复核通过；IPA 实际元数据/文档类型及安装 DryRun 通过。
- Sideloadly 已识别 USB 设备，已依据设备原签名填写相同 Apple ID。覆盖安装停在密码认证，新账号实际安装和 Automatic Refresh 尚未完成验证。USB `device-check.ps1` 已增加 `--userspace`，新账号运行检查通过。
- 微信分享、真实触控、主观听感、连续长时间练习不能用静态脚本通过替代；未测项目如实保留。

候选包：[Release v0.25.53-rc.1](https://github.com/xudadasf/RiffLoop/releases/tag/v0.25.53-rc.1)。IPA SHA256：`D8F11DA16878D0AC5F862C5B681BCD7AC97D8EE05C9F1CF9A11ACE1710292C0D`。本机会话选择的包位于 `%LOCALAPPDATA%\Temp\riffloop-release-02553\output\release-0.25.53-build97-59f2325\`，与构建清单同目录；临时包缺失时从 Release 下载并重新校验。

历史 0.25.51/0.25.52 已保存到 GitHub Releases，重新下载哈希一致。本机 `output` 递归清理及缩小范围后的单个测试缓存清理均被自动审批以 `blocked by policy` 拦截，仍保留约 264 MiB 输出；不要声称本地清理已完成。外部迁移备份不清理。详细过程见 [0.25.53 记录](releases/0.25.53.md)。
