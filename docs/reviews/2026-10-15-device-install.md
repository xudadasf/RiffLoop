# 0.25.65（109）真机覆盖安装记录

时间：2026-10-15 16:36–16:37，北京时间。

## 安装与验证

- 产品提交：`7ce769517cddfc33fb8bccf60911c2c1450156e9`；后续文档提交不是 IPA 构建来源。
- 使用原签名账号，原最终 Bundle ID `com.riffloop.prototype.N3N672QNHY`；USB 覆盖安装，无卸载、清数据操作。
- 安装器返回 `Installing: 100% InstallComplete` 与 `Installing: 100% Complete`。
- 通过 pymobiledevice3 独立读取设备：0.25.65、build 109、ProfileValidated=true。
- 首次启动前比对 Documents：14 个文件，169,785,536 字节，路径、大小和 SHA-256 全部一致。容器 UUID 随安装发生改变，但文档内容完整保留。
- DVT 启动成功，首页截图确认最近练习、累计统计和有效期正常；有效期显示至 2026-10-22 16:36。
- Sideloadly 自动续签数据库：version=0.25.65，one_off=0，known_ttl=7，refresh_at_hours=96。
- 最新 IPA 和 build-info.json 已同步到桌面项目与桌面续签快捷方式使用的旧 playback 工作树，均位于 `output/release-0.25.65-build109-7ce7695`。
- 私人截图、设备元数据、文件清单和签名日志仅保留本机 output，不提交 Git。

本次完成安装、数据保留、启动抽查。真实音响输出、长时稳定性和完整触控体验仍需后续真机验收。

## Windows 签名组件弹窗的原因

直接从本次 Codex 执行环境启动 Sideloadly，会继承 `OpenAI.Codex` 的 MSIX 包身份。诊断进程的 `GetCurrentPackageFullName` 返回 122（需要缓冲区），随后可读取包名。该环境的 DLL 搜索规则不同于普通桌面进程，Sideloadly 因而无法找到 Anisette 的间接依赖，报 `libxml2.dll` 加载失败。微软说明：包进程的依赖也使用包应用 DLL 搜索顺序，参见 [DLL search order](https://learn.microsoft.com/en-us/windows/win32/dlls/dynamic-link-library-search-order)。

复现与修复证据：

1. 同一 DLL 用普通 LoadLibraryW 加载失败（126），显式添加依赖目录或预加载依赖后能加载。
2. 重下载官方 Anisette 包仍失败；临时补依赖到程序目录只让错误移至 iTunesCore/CoreFoundation，未作为最终修复。这些临时副本已全部移出程序目录，原文件没有被覆盖。
3. 普通 `Shell.Application.ShellExecute` 仍继承包身份，因此也无效。
4. 从已存在的 Explorer 窗口取得 `Document.Application`，通过其 ShellExecute 后台启动 PowerShell，再启动 Sideloadly。新进程的 `GetCurrentPackageFullName` 返回 15700（APPMODEL_ERROR_NO_PACKAGE）。
5. 同一套原始组件立即返回 `kbsync init done true`，无需修复 C++ 运行库、修改注册表、关闭 VPN 或重装 iTunes。随后签名及安装成功。

因此不要仅根据 DLL 弹窗判断组件损坏；优先核对启动进程是否继承了 MSIX 身份。另一个会话曾正常安装与此诊断一致。

## 后台操作与后续注意事项

用户要求电脑可继续用于其他工作：后续优先后台命令，不操作鼠标、键盘，不激活窗口。此次 Sideloadly 隐藏启动，使用后台控件 Invoke 执行已授权的安装；没有注入键鼠输入。密码或验证码仍必须由用户在官方窗口处理，本次复用了已有会话，无认证交互。

此次可复用的本机诊断辅助文件位于工作树 output：`launch-sideloadly-native.ps1`、`sideloadly-background.ps1`、`device-data-inventory.py`。它们含本机路径，未作为通用发布脚本提交。后台启动的关键是使用已运行 Explorer 的 Document.Application，而非直接新建 Shell.Application 后调用 ShellExecute。

Sideloadly 0.70.1 的账号控件显示可能附带 `[10 App IDs Remaining]`，账号核对时需仅剥除这一明确格式的状态后缀，再与设备原签名账号比较；不可取消账号校验。
