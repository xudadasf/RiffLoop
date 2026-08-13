# iPad 未签名 IPA 与 Sideloadly 安装

RiffLoop iPad 版固定使用 Bundle ID `com.riffloop.prototype`。后续构建、安装和续签都不要改变它，也不要先卸载 App；使用相同 Apple 账号和 Bundle ID 覆盖安装，才能保留 `Documents` 中的 PDF、视频、GP 文件和应用设置。

## 从 GitHub Actions 下载 IPA

1. 打开仓库的 **Actions → iPad Unsigned IPA → Run workflow**。
2. 等待 `build-device-ipa` 通过。
3. 在该次运行的 **Artifacts** 下载 `RiffLoop-iPad-0.24.0-unsigned-arm64`。
4. 解压下载的 artifact，得到 `RiffLoop-iPad-0.24.0-unsigned-arm64.ipa`。

该 IPA 内含 `Payload/RiffLoop.app`，是 `iphoneos/arm64` 真机构建，但没有 Apple 签名。GitHub 不保存 Apple 账号、密码、证书或签名凭据；签名只在 Windows 的 Sideloadly 中完成。

## Windows 与 iPad 首次准备

1. 从 Apple 官网安装独立版 iTunes 和 iCloud；不要安装 Microsoft Store 版。
2. USB 连接 iPad，在 iPad 上选择信任这台电脑。
3. 在 iTunes 的设备摘要中启用“通过 Wi-Fi 与此 iPad 同步”，并完成一次同步。
4. 在 iPad 的“设置 → 隐私与安全性 → 开发者模式”中开启开发者模式，按系统要求重启并确认。
5. 安装并打开 Sideloadly。建议使用一个只用于侧载签名的 Apple 账号；正常 iCloud 账号可以继续留在 iPad 上。

## 首次安装与自动续签

1. 把 IPA 拖入 Sideloadly，选择已连接的 iPad。
2. 输入侧载账号，并启用 **Automatic Refresh** 后开始安装。
3. Apple 账号和密码只交给本机 Sideloadly，不要写入 RiffLoop、Git 仓库或 GitHub Secrets。
4. 安装后允许 Sideloadly Daemon 随 Windows 登录自动运行。
5. 每隔 3～5 天让 Windows 与 iPad 同处一个局域网，关闭两端 VPN/代理，并确保电脑开机联网、iPad 屏幕点亮、Daemon 正在运行。免费签名仍只有 7 天，Daemon 只是自动刷新它。

无线发现失败时，先点亮 iPad 屏幕并打开 iTunes 检查设备是否出现；仍失败则用 USB 连接，在 Sideloadly 中对同一个 App 执行覆盖安装。

## 安装新版或恢复失败的续签

- 新版不会由 Daemon 自动升级。下载新 IPA 后，使用同一侧载账号、同一 Bundle ID 直接覆盖安装，并继续启用 Automatic Refresh。
- 不要先删除旧版。卸载会删除应用沙箱中的文件与设置。
- 若自动刷新未完成，在签名过期前或过期后都可以 USB 连接并用相同配置覆盖安装；只要没有卸载，应用数据应继续保留。
- 免费 Apple 账号的签名期限和可侧载 App 数量受 Apple 限制；开发者模式不会延长签名期限。

## 在 iPad 中查看签名状态并手动续签

RiffLoop 首页显示当前侧载描述文件的到期时间和预计剩余天数。两天内到期时显示橙色提醒；续签后重新打开 App 或点击“重新检测”即可刷新。

“无线续签步骤”按钮会在 iPad 上显示以下操作说明，但 iPad App 无法给自身重新签名，续签仍需在 Windows 完成：

1. 首次无线设置先用 USB 连接，在 iTunes 的设备摘要中开启“通过 Wi-Fi 与此 iPad 同步”，点击“同步/完成”，并让 Sideloadly 成功安装一次。
2. 日常续签时关闭 Windows 与 iPad 上的 VPN/代理，让两者连接同一局域网，保持 iPad 屏幕点亮，再打开 Sideloadly；无线找不到设备时改用 USB。
3. 把最新 RiffLoop IPA 拖入 Sideloadly，选择这台 iPad 和原来使用的 Apple 账号。
4. 不要使用修改 Bundle ID 功能；IPA 内的 Bundle ID 应为 `com.riffloop.prototype`。启用 Automatic Refresh，然后点击 Start。
5. 按 Sideloadly 提示完成 Apple 登录或双重认证。账号、密码和验证码只交给 Sideloadly，不要输入 RiffLoop。
6. 不要卸载 iPad 上的旧 App，直接覆盖安装；等待 Sideloadly 显示完成。
7. 重新打开 RiffLoop，点击“重新检测”，确认到期时间已经延后。

Sideloadly 是第三方工具，“自动续签”属于尽量免手动的本机服务，不是 Apple 官方的永久签名方案。Windows 长期关机、网络隔离、防火墙、Apple 登录失效或 Daemon 故障都可能导致刷新失败。

## iPad mini 6 真机验收

云端 `iOS CI` 会在 iPad mini 尺寸模拟器上运行单元测试并保存首页截图，但模拟器不能证明 Web Audio、worker、触觉和真机音频同步。首次侧载后请在 iPad mini 6 / iPadOS 18.7.3 上检查：

- Files 中出现 `在我的 iPad/RiffLoop/{PDF、视频、GP}`，退出重开仍能恢复最近项目与位置。
- 视频、PDF 伴奏和 GP 连续播放，进入后台再返回后可以明确地暂停并重新播放，没有残留声。
- 使用《此生不换》类 `.gp` 检查每行 2 小节、约 2 行可视区域，以及第 10、33、34 小节同小节延音目标的括号品位。
- GP 普通轻点移动播放光标；长按后正向、反向、跨行、回拖缩小和单小节选择均按完整小节循环；取消手势不覆盖旧范围；靠近上下边缘能继续滚动选择。
- GP 内嵌伴奏与合成声音可独立开关/调音量并同步；显示轨道变化不会隐式改变静音/独奏。
- 视频和 PDF 用扬声器或有线设备做 50 次循环同步测试；第一轮不要使用蓝牙。
- Sideloadly 中 RiffLoop 已登记 Automatic Refresh；之后用相同 Bundle ID 覆盖安装一个新构建，确认 Documents 和设置仍在。
