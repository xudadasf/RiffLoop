# Phase 0 架构与同步方案

## 1. 范围

Phase 0 只回答一个问题：本地媒体和独立节拍声在反复 AB Loop 后，能否维持可接受的同步。

输入：本地 MP4、BPM、Subdivision、Beat Offset、A/B 点、播放速度。

输出：视频播放，以及在正确媒体拍点发声的 click track。

验证：120 BPM 素材连续循环 50 次后，不出现逐轮增加的可闻漂移。

## 2. 时间模型

Beat 1 是媒体时间轴的原点：

```text
eventInterval = 60 / BPM / subdivisionFactor
eventMediaTime(n) = beatOffset + n × eventInterval
```

其中 Quarter、Eighth、16th、Triplet 的 `subdivisionFactor` 分别为 1、2、4、3。

一次播放区间开始时创建不可变锚点：

```text
TransportAnchor
├── mediaTime：锚点对应的媒体时间
├── hostTime：共同启动的系统主机时间
└── mediaRate：当前 AVPlayer 速度

eventHostTime = hostTime + (eventMediaTime - mediaTime) / mediaRate
```

因此在 0.5× 播放时，媒体时间相隔 0.5 秒的两个拍点会在真实时间相隔 1 秒发声。

## 3. 模块职责

```text
PracticeView
    │ 用户命令 / UI 刷新（允许普通 UI 定时观察）
    ▼
PracticeViewModel ────────────────┐
    │                            │
    │ 同一 TransportAnchor       │ A/B boundary
    ├──────────────┐             │
    ▼              ▼             ▼
AVPlayer       MetronomeEngine  Loop state
host time      AVAudioEngine    exact seek + preroll
               │
               └─ AVAudioPlayerNode 提前排程 click buffer
```

- `PracticeViewModel` 是传输状态机的唯一入口。
- `AVPlayer` 通过 `setRate(_:time:atHostTime:)` 在指定 host time 到达指定媒体时间。
- `MetronomeEngine` 把相同锚点换算成 `AVAudioTime(hostTime:)`，提前约 1 秒排程 click。
- 100 ms 的 Dispatch timer 只补充未来已确定的音频事件，不负责“到点发声”。实际发声由音频渲染时钟完成。
- UI 的 periodic time observer 只刷新进度显示，不参与节拍调度。

## 4. Loop 为什么不累计漂移

到达 B 点后执行：

1. 暂停媒体并停止旧 click 排程。
2. 以零容差 Seek 到 A。
3. `preroll` 让本地媒体管线预加载。
4. 选择新的未来 host time。
5. 从 A 点重新创建 `TransportAnchor`，同时启动媒体与 click 排程。

第 N 次循环不会使用第 N-1 次循环的结束时间推算下一轮，所以即便某次 Seek 较慢，也只会改变循环之间的等待长度，不会把相位误差带入后续循环。

## 5. 已知限制与风险

- `AVPlayer` 的精确 Seek 受视频关键帧和解码性能影响；当前方案优先同步正确，不承诺画面无缝 Loop。
- `preroll` 后仍可能受设备负载影响。必须在真机上测试，模拟器不能证明音频同步质量。
- 蓝牙输出有显著且可能变化的系统延迟，Phase 0 应先用 iPad 扬声器或有线设备验证。
- 当前 click 使用代码生成的短正弦波，仅用于技术验证。
- 如果真机录音显示每次循环都有固定偏差，可增加输出延迟补偿；若偏差逐轮增大，则当前时钟映射或 Loop 状态机仍有错误，不能进入 MVP。

## 6. 进入 MVP 前的硬门槛

- 云端编译和单元测试通过。
- 真机可导入、播放并设置 Beat 1/A/B。
- 1.0× 与至少一个非 1.0× 速度完成 50 次循环。
- 无逐轮增大的漂移。
- Seek、暂停恢复、切换细分后都能重新对齐。

