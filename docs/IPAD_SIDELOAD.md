# iPad 未签名 IPA 与 Sideloadly 安装

RiffLoop iPad 版固定使用 Bundle ID `com.riffloop.prototype`。后续构建、安装和续签都不要改变它，也不要先卸载 App；使用相同 Apple 账号和 Bundle ID 覆盖安装，才能保留 `Documents` 中的 PDF、视频、GP 文件和应用设置。

## 从 GitHub Actions 下载 IPA

1. 打开仓库的 **Actions → iPad Unsigned IPA → Run workflow**。
2. 等待 `build-device-ipa` 通过。
3. 在该次运行的 **Artifacts** 下载 `RiffLoop-iPad-0.23.0-unsigned-arm64`。
4. 解压下载的 artifact，得到 `RiffLoop-iPad-0.23.0-unsigned-arm64.ipa`。

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
5. 每隔 3～5 天让 Windows 与 iPad 同处一个局域网，并确保电脑开机联网、Daemon 正在运行。免费签名仍只有 7 天，Daemon 只是自动刷新它。

无线发现失败时，先点亮 iPad 屏幕并打开 iTunes 检查设备是否出现；仍失败则用 USB 连接，在 Sideloadly 中对同一个 App 执行覆盖安装。

## 安装新版或恢复失败的续签

- 新版不会由 Daemon 自动升级。下载新 IPA 后，使用同一侧载账号、同一 Bundle ID 直接覆盖安装，并继续启用 Automatic Refresh。
- 不要先删除旧版。卸载会删除应用沙箱中的文件与设置。
- 若自动刷新未完成，在签名过期前或过期后都可以 USB 连接并用相同配置覆盖安装；只要没有卸载，应用数据应继续保留。
- 免费 Apple 账号的签名期限和可侧载 App 数量受 Apple 限制；开发者模式不会延长签名期限。

Sideloadly 是第三方工具，“自动续签”属于尽量免手动的本机服务，不是 Apple 官方的永久签名方案。Windows 长期关机、网络隔离、防火墙、Apple 登录失效或 Daemon 故障都可能导致刷新失败。
