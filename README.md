# RiffLoop Technical Prototype 0.1

RiffLoop 是一个面向 iPad 横屏练习场景的乐器练习助手。本仓库当前只验证最关键的技术链路：

`本地 MP4 → AVPlayer → BPM / Subdivision → Beat Offset → AB Loop → 节拍器重新同步`

## 当前实现

- 从 Files 导入 MP4，并复制到 App 沙盒后播放。
- 播放、暂停、拖动、前后 5/10 秒、0.25×–1.5× 速度。
- BPM 30–300，Quarter / Eighth / 16th / Triplet。
- `Set Beat 1` 记录当前媒体时间作为节拍时间轴原点。
- `Set A`、`Set B` 和 Loop 开关。
- 每次播放、Seek、速度变化或 Loop 回跳后，把 `AVPlayer` 和 `AVAudioEngine` 重新绑定到同一 host time。
- 纯时间数学单元测试，以及 GitHub macOS 云端构建工作流。
- 手动触发的签名、Archive 和 TestFlight 上传工作流骨架。

当前明确不包含项目保存、Marker、Count-in、自动提速、GP、PDF 和 AI 功能。

## 工程生成与构建

仓库使用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `project.yml` 生成 Xcode 工程，避免在没有 Mac 的 Windows 环境手工维护易损坏的 `.pbxproj`。

在 macOS 上：

```bash
brew install xcodegen
xcodegen generate
xcodebuild test \
  -project RiffLoop.xcodeproj \
  -scheme RiffLoop \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,OS=18.5,name=iPad Pro 13-inch (M4)' \
  CODE_SIGNING_ALLOWED=NO
```

没有 Mac 时，把仓库推送到 GitHub；`.github/workflows/ios-ci.yml` 会执行相同的工程生成、编译和单元测试。

## 下一步

1. 先让 `iOS CI` 变绿。
2. 配置 Apple Developer 和 TestFlight secrets，手动运行 `Upload TestFlight`。
3. 在真实 iPad 上按 [测试清单](docs/PHASE0_TEST_PLAN.md)完成 50 次循环听感与录音验证。
4. 只有 Phase 0 达标后，再进入完整 MVP。

更详细的同步原理见 [架构说明](docs/ARCHITECTURE.md)，无 Mac 的发布步骤见 [云构建与 TestFlight](docs/CLOUD_BUILD_AND_TESTFLIGHT.md)。

