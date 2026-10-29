# 最新接手状态：2026-10-29，0.25.69（113）安装包已核验，未安装

本轮按用户明确要求继续排查 iPad 的播放/暂停/停止，覆盖 GP、独立节拍器、PDF 和视频；未改 Android。实际工作树仍为 `C:/Users/sadada/.codex/worktrees/riffloop-practice-controls-20261015`，分支 `codex/ipad-practice-controls-20261015`。电脑界面由用户操作。

已复现并修正 GP 等待 worker 回执才停止本地输出、快速重播误用旧播放状态、暂停回执覆盖新跳转位置、迟到的循环边界在手动停止后重启，以及 PDF 伴奏/跟随尚在准备时无法取消。独立节拍器和视频已核查，未复现同类缺陷。USB 断连重连后仍必须手动继续。

最终产品提交 `7f93577d86481611ef9305190af98bd9fd7c6f3a`；首次完整回归 40811581756 的 180 项中 179 项通过，唯一失败的亮屏截图检查在曲谱尚未加载时过早断言。仅测试提交 `15fbe739afb73bde0c3e6261c12346244d69b41d` 改为等待实际谱面渲染，应用代码不变；最终模拟器 CI 40813473034 的 180 项 Swift 测试全部通过，播放策略和发布校验也通过。IPA 构建 40811585478 成功，版本 0.25.69（113）、arm64、SHA-256 及包内 GP 资源与产品提交一致，已在内存核验。包及下载链接见 [发布说明](releases/0.25.69.md) 和 [构建记录](releases/0.25.69-build-info.json)。不要使用本轮中间构建 40811272622，它不含最后的循环边界修复。后续文档提交不是新应用构建。

本轮未检测到 USB iPad，没有新的设备异常日志或真机停止延迟测量，最新已安装版本仍为上次核验的 0.25.68（112）。新版尚未安装，不能将测试通过等同于用户设备验收。用户使用原账号、Remote Anisette、Apple ID Sideload 覆盖安装；不要卸载或清除数据。安装后核对版本、数据和暂停/停止实际效果。

本轮未在本地保存 IPA、ZIP、设备文件副本，临时诊断代码已移除。代码与记录保存到 Git；GitHub Actions 安装包有效期至 2026-11-28T03:23:35Z，可从记录的产品提交重新构建。旧版本本地目录为历史记录，本轮没有声称已删除；此前自动清理被审批阻止，不得绕过。安装后用户可删除自己下载的 ZIP/IPA。

详见 [排查与验证](reviews/2026-10-29-transport-stop.md)。

---

以下为历史状态，以本节最新记录为准。

# 最新接手状态：2026-10-27，0.25.68（112）已安装并核验

用户完成原账号覆盖安装。设备回读确认版本 0.25.68（112）、原 Bundle ID 和签名账号不变、ProfileValidated=true；14 个 Documents 文件（169,785,536 字节）大小和 SHA-256 全部一致，偏好字典所有键值保持不变，包括历史练习记录。证据位于本地忽略目录 `output/install-02568/`。

安装中 Sideloadly 的 -80046 登录认证错误通过用户切换 Remote Anisette 后重试解决；电脑界面继续由用户操作。不得卸载应用或清除数据。最新版包已同步到本工作树与旧 playback 工作树的 `output/release-0.25.68-build112-0e64a1a/`，桌面 `RiffLoop-0.25.68/` 另有同一哈希的便捷副本。

应用提交仍为 `0e64a1a64b9b8bb7e421cc75079736b210ad1c47`，177 项 Swift 测试和发布校验已通过。USB 断连后必须保持暂停、手动继续；跨天归开始日期、音量统一 0–1600% 已随新版安装。真实长时播放、跨天使用和音响听感仍待用户使用反馈。后续文档提交不是新应用构建。

---

以下为历史阶段记录，安装状态以上文为准。

# 最新接手状态：2026-10-27，0.25.68（112）候选已准备，未安装

用户本次明确要求排查 iPad；电脑和设备界面操作由用户自己进行。只读设备确认仍安装 0.25.67（111），三份会话的原始异常记录和偏好保存在本地忽略目录 `output/review-20261027/`。六条暂停事件对应 Spark MINI USB 断连后重连，用户明确要求保持暂停、手动继续，不能加入自动重连播放。另一次 WebContent 终止现场为未播放，不混为同一原因；USB 断开的物理根因尚不明确。

已修正跨午夜练习按首次进入本次练习页面的日期归档，使用单调计时且后台不计；原历史保留。按已存在的最大档统一全部音量范围至 0–1600%，不主动调大现有设置。

工作树仍为 `C:/Users/sadada/.codex/worktrees/riffloop-practice-controls-20261015`。应用提交 `0e64a1a64b9b8bb7e421cc75079736b210ad1c47`，CI 40482450284 全部 177 项测试通过，IPA 40483849404 校验及安装 DryRun 通过。新包在 `output/release-0.25.68-build112-0e64a1a/`，附安装说明。没有启动 Sideloadly、覆盖安装或操作用户 UI；下一步由用户原账号覆盖安装并确认版本和实际体验。文档提交晚于应用提交，不代表新的安装包来源。

详见 [本轮排查与验证](reviews/2026-10-27-ipad-pauses-history-volume.md)。

---

# 最新接手状态：2026-10-16 11:25，0.25.67（111）

已原账号覆盖安装到 iPad。用户确认 iPad 通过 USB 连接 Spark MINI，授权在合理范围内保留较大音量调节范围。本轮保留 0–600%，把原生独立节拍器硬削波改为与 GP 一致的柔和限幅；实际 PCM 测量确认高档增益有效、峰值受控，但不保证外接设备绝不过载。没有自动调大用户音量，也没有执行真机最大音量播放。
首页日期详情改为卡片右上角固定小气泡，只显示 `nh ym`，不显示日期/秒数，不弹系统窗口，选中格子描边。

工作树 `C:/Users/sadada/.codex/worktrees/riffloop-practice-controls-20261015`，分支 `codex/ipad-practice-controls-20261015`。
最终产品提交 `24b1b313cf838dac35f9b87fd4cd7c72ee9a8c7b`；CI 38844209779 的 174 项测试、5 套 Node 回归通过，IPA 38844240021 校验通过。设备版本/原 Bundle ID/签名、自动续签与启动首页核对通过；14 个 Documents 文件（169,785,536 字节）哈希保持一致。
最终续签包在本工作树及旧 playback 工作树的 `output/release-0.25.67-build111-24b1b31`。用户要求后台命令，不抢电脑焦点；沿用已有 Explorer 的 Document.Application 启动签名器。可用后台 WindowPattern.Close 正常关闭已完成安装器，保留续签 daemon。
见 [完整记录与音量测量](reviews/2026-10-16-spark-gain-and-history.md)、[发布说明](releases/0.25.67.md)。未做 Spark MINI 实际声压/安全音量认证或完整真机触控验收。

---
以下为历史状态，以上述版本为准。

# 最新接手状态：2026-10-16

0.25.66（110）已于 2026-10-16 10:46 原账号覆盖安装到 iPad。实际工作树为
`C:/Users/sadada/.codex/worktrees/riffloop-practice-controls-20261015`，分支
`codex/ipad-practice-controls-20261015`；最终产品提交 `8e1ed6e3f87b85000076a3a951acd94ae3bb2cad`。

本轮实现 GP 紧凑独立节拍器设置、实际 0–600% 增益、GP/PDF/视频前台模式计时（暂停计入，后台与首页不计）、首页紧凑时长与点日期查看具体时长。历史记录保留。
最终 CI 38840870956 的 171 项测试通过，5 套本地 Node 回归通过；最终 IPA 38840892296 校验通过。设备版本、原 Bundle ID、签名有效性、自动续签和启动首页均核对通过。安装前后 14 个 Documents 文件（169,785,536 字节）哈希完全一致。

最新续签包位于本工作树以及旧 playback 工作树的 `output/release-0.25.66-build110-8e1ed6e`；不要安装已被替代的 83e60f4 中间包。用户要求后台命令操作，不抢鼠标、键盘或焦点；继续沿用现有 Explorer 的 Document.Application 代理启动方法。
详细记录见 [本轮调整与真机检查](reviews/2026-10-16-practice-settings.md)、[发布说明](releases/0.25.66.md)。真实触控、音响听感和长时间真机练习仍未计为本轮已验收。

---
以下为历史记录，版本状态以上述内容为准。

# 最新接手状态：2026-10-15

本轮继续 iOS，Android 保持不变。实际工作树为
`C:/Users/sadada/.codex/worktrees/riffloop-practice-controls-20261015`，分支
`codex/ipad-practice-controls-20261015`；桌面旧 checkout 不是本轮改动位置。

候选 0.25.65（109）的产品提交为 `7ce769517cddfc33fb8bccf60911c2c1450156e9`。
最终 CI 38702160712 全部 165 项 Swift 测试通过，三模式计时截图已复核。
IPA 38703590025 构建成功；安装包及 build-info.json 位于工作树 output/release-0.25.65-build109-7ce7695，包内信息与 SHA-256 校验、侧载 DryRun 均通过。
2026-10-15 16:36（北京时间）已原账号覆盖安装；设备读取 0.25.65（109）、原 Bundle ID、ProfileValidated=true。
安装前后首次启动前，14 个 Documents 文件（169,785,536 字节）大小和 SHA-256 全部一致。
启动和首页抽查通过，自动续签已登记；长时播放及真实音响验收仍待进行。
当前 Codex MSIX 子进程身份会导致 Sideloadly 的 DLL 加载失败；通过现有 Explorer 窗口的 Document.Application 后台启动，退出应用包环境后正常。不要反复下载 DLL 或安装运行库。
用户要求后台命令操作，不抢鼠标、键盘、焦点。详见 [安装记录](reviews/2026-10-15-device-install.md)。

最终确认：GP 点谱从所选位置继续播放；翻谱后平滑跟随；直接 BPM 输入和独立节拍器；
按条件恢复系统音频中断；PDF 去累计小节数；三个模式进入页面即计时，暂停仍计时。
详细实现、失败修正与验证边界见 [本轮记录](reviews/2026-10-15-practice-controls.md)
和 [发布说明](releases/0.25.65.md)。

---
以下保留历史记录；旧路径、版本及状态不应覆盖以上最新信息。

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

**0.25.56（100）最新状态：2026-09-05 20:18（北京时间）已覆盖安装，数据核对及启动抽查通过。** 用户批准 UI 修复并明确保留 PDF 透明底栏。最终提交 `9db2a99235128b0cc22a0435b264c1a291660b39` 的 CI #130（33964863995）138 项全部通过；IPA #96（33965299812）对应同一提交，下载、校验与 DryRun 通过。52 张有效原图已逐张复核，UI 操作运行 33964135168 五项通过；PDF 进度超过伴奏长度的问题已修正，最后提交仅调整测试音频就绪准备，产品与截图来源 f401cc3 相同。详细原因、修复、验证边界及候选附件见 [0.25.56](releases/0.25.56.md)。

最终 IPA 在 `%TEMP%\riffloop-release-02556\output\release-0.25.56-build100-9db2a99\`，同目录有 build-info.json，SHA-256 为 `D4691436F3E695FB1A788FD7FA215E336CE06A037FDF91F64BB6DBDCC9403E77`。不要安装 7dacd81 中间包。用户切回解锁后，安装器于 20:18:42 完成覆盖安装；设备直接读取 0.25.56（100）、原 Bundle ID、ProfileValidated=true。安装前后、首次启动前核对 12 个 Documents 文件（169,648,008 字节）逐一哈希一致，15 个偏好键值一致，无新增/丢失/变化。Automatic Refresh 已更新（one_off=0、7 天、96 小时刷新阈值），未卸载或清数据。20:20 前台启动成功，10 秒日志未见 RiffLoop 错误或崩溃；实机首页截图确认最近练习预览、统计与签名状态正常。核对快照位于 `%TEMP%\riffloop-preservation-02556`，报告和私人截图位于项目 `output/acceptance-auto/device-check-20260905-202007`，只留本机。用户可切换 Windows 账号，无待处理交互步骤；未新建会话。完整实机触控与长时练习仍不等同于本次启动抽查。

生成目录正常删除再次被自动审批 `blocked by policy` 拒绝，释放 0 字节；不得换工具绕过。保留源码、有效截图、迁移/设备数据快照与续签配置。清理具体状态见 [LOCAL_CLEANUP](LOCAL_CLEANUP.md)。

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

## UI 全页面审查（2026-09-05）

用户先要求逐页切换、全部截图后再评价，随后授权代理全权执行。已保存并逐张检查 53 张有效截图（7 张 iPadOS 27 实机、46 张 iOS 18.5 iPad mini 模拟器），覆盖首页/最近/续签、GP/视频/PDF 主页面和主要设置、文件库/改名/删除确认/系统导入选择器。设备没有可用触控通道，后续操作使用原产品源码的云端模拟器和合成素材；未修改真实 iPad 文件、练习记录或安装。模拟器不能算实机全流程验收，完整范围和未测状态见 [UI 审查](UI_AUDIT_20260905.md)。

主要建议：P1 PDF 底栏对比度、续签说明被截断、PDF 轨迹删除/重录保护；P2 统一设置标签和音量数值、收起 GP 技术诊断、减少底部摘要省略；P3 首页与文件库整理。产品源码仍为 b3c24b3，0.25.55（99）；本轮没有改 UI 或重打包。主开发分支只保存报告和交接；独立 `codex/ui-audit-20260905` 保存采集测试/工作流。合成截图 zip 已归档到 v0.25.55-rc.1，私人实机截图仅在本机 `Documents/RiffLoop-UI-review-20260905`。以后换账号可从 Git 报告和 Release 合成画册接续。用户的“需修改记录.md”保持原状。

## 最近一次本地缓存清理

用户于 2026-09-05 再次要求执行清理。已核对约 1,215.3 MiB、47 个生成目标并补齐旧安装包远端归档；项目 output 和独立临时缓存的正常删除再次被自动审批拒绝，47 个目标仍存在，实际没有释放空间。源码、用户记录、设备快照与自动续签缓存保持原状。详见 [清理记录](LOCAL_CLEANUP.md)。
