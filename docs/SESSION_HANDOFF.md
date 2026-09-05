# iOS 当前接续入口

更新：2026-09-05。本文件持续记录本轮状态；不要把代码已推送当作真机验收。

## 项目与用户要求

- 仓库：xudadasf/RiffLoop，开发分支 `codex/ipad-home-ui`。
- 这台 Windows 电脑的独立项目入口：`C:\Users\sadadashare\Desktop\RiffLoop-iOS`。禁止使用旧“Codex共享项目”指向 sadada 桌面的链接。
- 仅修改、测试 iPad/iOS，保持 Android 不变。`需修改记录.md` 是用户保留的未提交文件，禁止修改、暂存、提交或清理。
- 用户要求代理负责修改、完整回归、编译、下载、安装及可执行的体验测试。认证只在相应官方登录窗口完成；密码、验证码不写入脚本、日志或 Git。
- 保持原 Apple 账号及最终 Bundle ID `com.riffloop.prototype.N3N672QNHY`；只能覆盖安装，禁止卸载/清数据。
- GP 保持 B → Paused → seek A → A 回执 → 一小节预备拍 → A 到 B；原生内嵌伴奏不退回 WKWebView Blob/data URL。
- 相关需求、诊断和验证写入 Git/GitHub，便于新账号接续。用户要求本地保留源码、测试、脚本和开发文档，验证后清理可再生安装包/构建缓存/日志。不要清理外部迁移备份或 iPad 文件。

## 本轮需求与实现状态

新增 [Issue #3](https://github.com/xudadasf/RiffLoop/issues/3)：0.25.55（99）继续改进 GP 自动分行/80%–150% 缩放、PDF/视频合法 BPM 数字小键盘、首页单一谱表预览；合并已通过回归的 0.25.54 修复后一次覆盖安装，不先安装 98。当前官方 alphaTab 最新稳定版仍为已用的 1.8.4。最终提交 `b3c24b3113bdadbd61704523a42782870cc48a21` 的 CI #120 全部 133 项 Swift 测试及 IPA #94 已通过，实际预览/数字键盘/三模式截图、包校验和 DryRun 已复核。候选 `v0.25.55-rc.1` 归档；用户切回后已于 17:12 覆盖安装 99，原 Bundle ID/签名有效，11 个文件（108,827,410 字节）与 14 项偏好安装前后全部一致，自动续签登记已更新。实机首页预览和启动检查通过；用户打开原问题谱后，直接截图确认第 5～7 小节 H/P 与横线分离，100%/150% 谱面与半透明提示正常。视频/PDF 实机数字面板显示正确，视频输入 301 禁用应用且原速度不变；PDF 原 33 个跟谱位置点仍可见。辅助功能激活按钮无效，未将发送动作计为触控通过。后续可切换 Windows 账号，只有需要交互桌面时再通知。详见 [0.25.55 记录](releases/0.25.55.md)。

新增 [Issue #2](https://github.com/xudadasf/RiffLoop/issues/2)：用户确认当前 GP 谱第 5～7 小节 H/P 与节奏横线重叠，状态提示希望半透明。已复现并最小调整节奏区高度为 50、提示为 55% 黑色背景并允许触控穿透。0.25.54（98）应用提交 `1d47a4b1c927c520b833392b19f5f4d4fb4676e8` 的 CI #115（128 项 Swift 测试）及 IPA #91 均通过，包校验/DryRun 通过，截图已复核；[候选 Release](https://github.com/xudadasf/RiffLoop/releases/tag/v0.25.54-rc.1) 归档。**尚未覆盖安装 98**：Windows 截图/点击报 0x80070057 / 0x80070005，重建工具连接仍失败，需要恢复当前 Windows 账号交互桌面后继续。安装前重做数据快照；安装后检查原 Bundle ID、文件与偏好完整性、自动续签及真实 GP 第 5～7 小节。详见 [0.25.54 记录](releases/0.25.54.md)；私人谱子仅在本机临时目录，不上传 Git。

统一跟踪：[Issue #1](https://github.com/xudadasf/RiffLoop/issues/1)。`0.25.53（97）` 已构建、校验并归档，应用提交 `59f23259768f0bccd332afc02c53916f853665d7`；稳定标签仍为 `v0.25.51`。

**0.25.53 安装历史（当前已更新至上文 0.25.55）：** 2026-09-05 15:22 已成功覆盖安装 0.25.53（97），设备读取原 Bundle ID、签名有效。安装前后 11 个 Documents 文件（108,822,138 字节）逐一 SHA-256 一致，14 个偏好键值全部一致。新账号的 Automatic Refresh 已登记（one_off=0、有效期 7 天、96 小时刷新阈值）。已观察到新版本 GP 页面正常显示；微信分享、主观听感和长时实机练习仍待体验验收，不能标为已完成。不要卸载/清数据，也不要为文档及电脑检查脚本提交重新打包。

**权限问题已解决：** 新账号原本不在管理员组，电脑 EnableLUA=0；此前 RunAs 返回进程并不代表已提权。用户从原管理员账号将当前账号加入管理员组并重新登录后，当前令牌 IsInRole(Administrator)=true，CoreFP 初始化、Apple 登录/验证码、签名及覆盖安装均通过。另将 `HKLM\SOFTWARE\Apple Inc.\CoreFP` 的 `LibSidePath` 从旧账号组件改为当前账号 `%LOCALAPPDATA%\Sideloadly\an\CoreFP.dll`；修改前两份 DLL 的 SHA-256 一致且 Apple 数字签名有效，旧值备份在本机临时目录，重启当前账号安装器后确认从新路径初始化。未修改其他注册表值/权限，未操作旧账号后台进程。

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
- Sideloadly 已完成同账号覆盖安装、安装结果与 Automatic Refresh 数据库登记核验。USB 检查支持 `--userspace`；安装后进程启动、文件读取和截图成功。8 秒启动日志未见实际错误；脚本原先将 `-default` 中的 `fault` 误判为 FAULT，现按日志级别和明确崩溃标记匹配，原日志及正反例复核通过。独立 CoreDevice 前台启动服务不可用，不将其计为通过。
- 微信分享、真实触控、主观听感、连续长时间练习不能用静态脚本通过替代；未测项目如实保留。

候选包：[Release v0.25.53-rc.1](https://github.com/xudadasf/RiffLoop/releases/tag/v0.25.53-rc.1)。IPA SHA256：`D8F11DA16878D0AC5F862C5B681BCD7AC97D8EE05C9F1CF9A11ACE1710292C0D`。本机会话选择的包位于 `%LOCALAPPDATA%\Temp\riffloop-release-02553\output\release-0.25.53-build97-59f2325\`，与构建清单同目录；临时包缺失时从 Release 下载并重新校验。

历史 0.25.51/0.25.52 已保存到 GitHub Releases，重新下载哈希一致。本机 `output` 递归清理及缩小范围后的单个测试缓存清理均被自动审批以 `blocked by policy` 拦截，仍保留约 264 MiB 输出；不要声称本地清理已完成。外部迁移备份不清理。详细过程见 [0.25.53 记录](releases/0.25.53.md)。
