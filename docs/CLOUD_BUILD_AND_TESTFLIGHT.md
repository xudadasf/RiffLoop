# 无 Mac：GitHub 云构建与 TestFlight

## A. 先打通不签名的云编译

这一阶段不需要 Apple Developer 付费账号。

1. 在 GitHub 新建空仓库。
2. 从当前目录初始化 Git，并把代码推送到 `main`。
3. 打开仓库的 **Actions** 页面。
4. 查看 `iOS CI`；它会在 GitHub 的 `macos-15` runner 上选择 Xcode 16.4、生成工程、构建并运行测试。

成功标准是工作流绿色通过。Windows 本机没有 Apple SDK，不能代替这一步。

当前目录已经初始化为 `main` 分支。在 PowerShell 中执行以下命令（把 URL 换成自己的仓库地址）：

```powershell
git add .
git commit -m "Build RiffLoop technical prototype 0.1"
git remote add origin https://github.com/<用户名>/<仓库名>.git
git push -u origin main
```

这些命令依次暂存文件、创建本地提交、关联远程仓库并推送。推送属于外部写操作，请先确认仓库地址和可见性设置正确。

## B. 真机安装的最短稳定链路

推荐链路是：

```text
手动运行 GitHub Action
→ 签名 Archive
→ 导出 IPA
→ 上传 App Store Connect
→ TestFlight 安装到 iPad
```

需要：

- 有效的 Apple Developer Program 会员资格。
- 一个与 App Store Connect App 对应的显式 Bundle ID。
- Apple Distribution 证书及其私钥（`.p12`）。
- App Store Distribution provisioning profile（`.mobileprovision`）。
- App Store Connect API key（`.p8`、Key ID、Issuer ID）。

不要把证书、私钥、密码或 API key 提交到仓库，也不要发送到聊天中。

## C. GitHub Environment 与 Secrets

在仓库 **Settings → Environments** 新建 `testflight`。建议启用 required reviewers，避免误触上传。然后配置这些 secrets：

| Secret | 内容 |
|---|---|
| `APP_BUNDLE_ID` | App Store Connect 中的 Bundle ID，例如 `com.yourname.riffloop` |
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `APPLE_CERTIFICATE_BASE64` | `.p12` 文件的 Base64 文本 |
| `APPLE_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设置的密码 |
| `APPLE_PROVISIONING_PROFILE_BASE64` | `.mobileprovision` 的 Base64 文本 |
| `APPLE_PROVISIONING_PROFILE_NAME` | profile 内的 Name，不是文件名 |
| `APP_STORE_CONNECT_API_KEY_ID` | API Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | API Issuer ID |
| `APP_STORE_CONNECT_API_KEY_BASE64` | `.p8` 文件的 Base64 文本 |

在 Windows PowerShell 中，把二进制文件转换为 Base64 并直接复制到剪贴板：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\path\distribution.p12')) | Set-Clipboard
[Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\path\profile.mobileprovision')) | Set-Clipboard
[Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\path\AuthKey_XXXX.p8')) | Set-Clipboard
```

每次只执行一行，并立刻粘贴到对应 GitHub secret。

## D. 上传与安装

1. 进入 **Actions → Upload TestFlight → Run workflow**。
2. 工作流会在临时 keychain 中导入证书，签名 Archive，导出 IPA，并使用 API key 上传。
3. 等待 App Store Connect 处理构建。
4. 在 App Store Connect 的 TestFlight 页面把构建加入内部测试组。
5. iPad 安装 TestFlight App，接受邀请并安装 RiffLoop。

工作流结束时会删除 runner 上的临时 keychain；GitHub 托管 runner 本身也是一次性的。

## E. 当前需要人工完成的 Apple 侧步骤

首次配置仍需在 Apple Developer/App Store Connect 网页完成会员、App ID、App 记录、证书、profile 和 API key。完成一次后，日常代码测试可以只靠 Push 和手动 TestFlight workflow。
