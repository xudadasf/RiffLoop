import Foundation
import SwiftUI

struct GpPracticeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var recentProjects: RecentProjectsStore
    @StateObject private var viewModel = GpWebViewModel()
    @State private var isLibraryPresented = false
    @State private var didOpenInitialURL = false
    @State private var controlsVisible = true

    let initialURL: URL?

    init(initialURL: URL? = nil) {
        self.initialURL = initialURL
    }

    private let speeds = [0.5, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5]

    var body: some View {
        HStack(spacing: 0) {
            GpWebView(viewModel: viewModel)
                .overlay(alignment: .topLeading) {
                    if viewModel.score == nil {
                        ContentUnavailableView(
                            "导入 Guitar Pro 乐谱",
                            systemImage: "music.note.list",
                            description: Text("离线 alphaTab 1.8.4 技术验证支持 .gp、.gpx、.gp3、.gp4、.gp5")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.82))
                    }
                }

                .overlay(alignment: .topTrailing) {
                    if !controlsVisible {
                        compactControls
                            .padding(12)
                    }
                }

                .overlay(alignment: .bottomLeading) {
                    if viewModel.loopRange != nil, !viewModel.isPlaying {
                        Button(action: viewModel.clearLoop) {
                            Label("退出区间循环", systemImage: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .padding(16)
                    }
                }

            if controlsVisible {
                controls
                    .frame(width: 340)
                    .background(Color(white: 0.08))
            }
        }
        .navigationTitle("Guitar Pro 练习")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("选择文件") { isLibraryPresented = true }
            }
        }
        .sheet(isPresented: $isLibraryPresented) {
            DocumentLibraryView(kind: .guitarPro, onSelect: importScore)
        }
        .alert(
            "RiffLoop",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.dismissError() } }
            )
        ) {
            Button("好", role: .cancel) { viewModel.dismissError() }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            viewModel.setSceneActive(phase == .active)
        }
        .onAppear {
            guard !didOpenInitialURL, let initialURL else { return }
            didOpenInitialURL = true
            importScore(from: initialURL)
        }
        .onDisappear(perform: viewModel.pause)
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("控制")
                        .font(.title3.bold())
                    Spacer()
                    Button("收起") { controlsVisible = false }
                }

                status

                HStack {
                    Button(action: viewModel.togglePlayback) {
                        Label(
                            viewModel.isPlaying ? "暂停" : "播放",
                            systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.playerReady)

                    Button("停止", action: viewModel.stop)
                        .buttonStyle(.bordered)
                        .disabled(!viewModel.playerReady)
                }

                speedControls

                Divider()
                loopControls

                Divider()
                metronomeControls

                Divider()
                Text("声音")
                    .font(.headline)

                Text("合成总音量")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { viewModel.masterVolume },
                        set: { viewModel.setMasterVolume($0) }
                    ),
                    in: 0...1
                )
                Toggle("谱面合成声音", isOn: Binding(
                    get: { viewModel.synthEnabled },
                    set: { viewModel.setSynthEnabled($0) }
                ))
                if viewModel.score?.hasBackingTrack == true {
                    Text("内嵌伴奏音量")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { viewModel.backingVolume },
                            set: { viewModel.setBackingVolume($0) }
                        ),
                        in: 0...1
                    )
                    Toggle("内嵌伴奏", isOn: Binding(
                        get: { viewModel.backingEnabled },
                        set: { viewModel.setBackingEnabled($0) }
                    ))

                    if !viewModel.backingDiagnosticLines.isEmpty {
                        Text("临时伴奏诊断 0.25.19")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                        if let probe = viewModel.backingProbeDiagnostic {
                            Text("MIME：\(probe)")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                        Text(viewModel.backingDiagnosticLines.joined(separator: "\n"))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if let score = viewModel.score {
                    Divider()
                    Text("显示乐谱")
                        .font(.headline)
                    Picker("显示轨道", selection: Binding(
                        get: { viewModel.displayedTrack },
                        set: { viewModel.showTracks([$0]) }
                    )) {
                        ForEach(score.tracks, id: \.index) { track in
                            Text(track.name).tag(track.index)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("轨道声音")
                        .font(.headline)
                    ForEach(score.tracks, id: \.index) { track in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(track.name).lineLimit(1)
                                Spacer()
                                Button(viewModel.mutedTracks.contains(track.index) ? "取消静音" : "静音") {
                                    let muted = !viewModel.mutedTracks.contains(track.index)
                                    viewModel.setTrackMute(index: track.index, muted: muted)
                                }
                                .buttonStyle(.bordered)
                                Button(viewModel.soloTrack == track.index ? "取消独奏" : "独奏") {
                                    viewModel.setTrackSolo(
                                        index: track.index,
                                        solo: viewModel.soloTrack != track.index
                                    )
                                }
                                .buttonStyle(.bordered)
                            }
                            Slider(
                                value: Binding(
                                    get: { viewModel.trackVolumes[track.index] ?? Double(track.volume) / 16 },
                                    set: { viewModel.setTrackVolume(index: track.index, volume: $0) }
                                ),
                                in: 0...1
                            )
                        }
                    }
                }

                Divider()
                Text("练习记录")
                    .font(.headline)
                Text(
                    "本次 \(formatDuration(viewModel.sessionPracticeMilliseconds)) · "
                        + "累计 \(formatDuration(viewModel.totalPracticeMilliseconds)) · "
                        + "累计循环 \(viewModel.totalCompletedLoops) 轮 · "
                        + "最高 \(Int((viewModel.highestPracticeSpeed * 100).rounded()))%"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    private var compactControls: some View {
        VStack(spacing: 10) {
            Button("控制") { controlsVisible = true }
                .buttonStyle(.borderedProminent)
            Button(action: viewModel.togglePlayback) {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(!viewModel.playerReady)
        }
        .padding(10)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
    }

    private var speedControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("速度")
                .font(.headline)
            Stepper(
                value: Binding(
                    get: { viewModel.baseBpm },
                    set: { viewModel.setBaseBpm($0) }
                ),
                in: viewModel.customBpmRange,
                step: 1
            ) {
                Text("基准 BPM：\(Int(viewModel.baseBpm.rounded()))")
            }
            .disabled(!viewModel.playerReady || viewModel.customBpmRange.lowerBound == viewModel.customBpmRange.upperBound)
            HStack {
                Text("可调 \(Int(viewModel.customBpmRange.lowerBound))–\(Int(viewModel.customBpmRange.upperBound)) BPM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("恢复导入 BPM", action: viewModel.resetBaseBpm)
                    .font(.caption)
                    .disabled(!viewModel.playerReady || abs(viewModel.baseBpm - viewModel.originalBaseBpm) < 0.5)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(speeds, id: \.self) { value in
                        Button(String(format: "%.2g×", value)) {
                            viewModel.setPlaybackSpeed(value)
                        }
                        .buttonStyle(.bordered)
                        .tint(viewModel.playbackSpeed == value ? .orange : .secondary)
                    }
                }
            }
            .disabled(!viewModel.playerReady)
            Text("1.00× 以当前基准 BPM 为准；变速谱按原 tempo map 等比例缩放。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var loopControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A/B 区间循环")
                .font(.headline)
            Text("长按音符并拖动选择循环范围，松手确认；起点和终点都精确到音符。靠近上下边缘可继续滚动选择。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let message = viewModel.loopSelectionMessage {
                Text(message)
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }
            if let range = viewModel.loopPreview {
                Text("选择中：第 \(range.firstBar + 1)–\(range.lastBar + 1) 小节内音符范围 · 松手确认")
                    .font(.caption)
            } else if let range = viewModel.loopRange {
                Text("A：第 \(range.firstBar + 1) 小节内音符 · B：第 \(range.lastBar + 1) 小节内音符结束")
                    .font(.caption)
            }
            Toggle("A/B 循环", isOn: Binding(
                get: { viewModel.rangeLoopingEnabled },
                set: { viewModel.setRangeLoopingEnabled($0) }
            ))
            .disabled(viewModel.loopRange == nil)
            Toggle("每轮预备 1 小节", isOn: Binding(
                get: { viewModel.loopCountInEnabled },
                set: { viewModel.setLoopCountInEnabled($0) }
            ))
            .disabled(!viewModel.rangeLoopingEnabled)
            Toggle("循环阶梯", isOn: Binding(
                get: { viewModel.speedLadderEnabled },
                set: { viewModel.setSpeedLadderEnabled($0) }
            ))
            .disabled(!viewModel.rangeLoopingEnabled)

            if viewModel.speedLadderEnabled {
                Picker("每几轮提高", selection: Binding(
                    get: { viewModel.loopsPerSpeedStep },
                    set: { viewModel.setLoopsPerSpeedStep($0) }
                )) {
                    ForEach([1, 2, 3, 5], id: \.self) { Text("\($0) 轮").tag($0) }
                }
                Picker("每次提高", selection: Binding(
                    get: { viewModel.speedLadderStep },
                    set: { viewModel.setSpeedLadderStep($0) }
                )) {
                    ForEach([0.02, 0.05, 0.1], id: \.self) {
                        Text("+\(Int(($0 * 100).rounded()))%").tag($0)
                    }
                }
                Picker("目标速度", selection: Binding(
                    get: { viewModel.speedLadderTarget },
                    set: { viewModel.setSpeedLadderTarget($0) }
                )) {
                    ForEach(speeds.filter { $0 >= viewModel.playbackSpeed }, id: \.self) {
                        Text("\(Int(($0 * 100).rounded()))%").tag($0)
                    }
                }
                Text("当前第 \(viewModel.currentSpeedLadderRound)/\(viewModel.loopsPerSpeedStep) 轮 · \(viewModel.playbackSpeed, specifier: "%.2f")×")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("整曲循环", isOn: Binding(
                get: { viewModel.wholeSongLoopingEnabled },
                set: { viewModel.setWholeSongLoopingEnabled($0) }
            ))
            .disabled(viewModel.rangeLoopingEnabled)
        }
    }

    private var metronomeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("节拍器")
                .font(.headline)
            Toggle("开启节拍器", isOn: Binding(
                get: { viewModel.metronomeEnabled },
                set: { viewModel.setMetronomeEnabled($0) }
            ))
            Text("节拍细分（跟随谱面拍号）")
                .font(.subheadline.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach([1, 2, 4, 8], id: \.self) { factor in
                        Button(subdivisionLabel(factor: factor)) {
                            viewModel.setMetronomeSubdivisionFactor(factor)
                        }
                        .buttonStyle(.bordered)
                        .tint(viewModel.metronomeSubdivisionFactor == factor ? .orange : .secondary)
                    }
                }
            }
            Text("每拍强度 · 点击循环切换")
                .font(.subheadline.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(viewModel.beatAccents.indices, id: \.self) { index in
                        Button("\(index + 1) \(viewModel.beatAccents[index].label)") {
                            viewModel.cycleBeatAccent(at: index)
                        }
                        .buttonStyle(.bordered)
                        .tint(viewModel.beatAccents[index] == .normal ? .secondary : .orange)
                    }
                }
            }
            if viewModel.metronomeEnabled {
                Slider(
                    value: Binding(
                        get: { viewModel.metronomeVolume },
                        set: { viewModel.setMetronomeVolume($0) }
                    ),
                    in: 0...1
                )
                Text("节拍音量 \(Int((viewModel.metronomeVolume * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("开始前预备拍", isOn: Binding(
                get: { viewModel.countInEnabled },
                set: { viewModel.setCountInEnabled($0) }
            ))
            if viewModel.countInEnabled || viewModel.loopCountInEnabled {
                Slider(
                    value: Binding(
                        get: { viewModel.countInVolume },
                        set: { viewModel.setCountInVolume($0) }
                    ),
                    in: 0...1
                )
                Text("预备拍音量 \(Int((viewModel.countInVolume * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(viewModel.score?.title ?? "等待乐谱")
                .font(.headline)
                .lineLimit(1)
            if let score = viewModel.score {
                Text([score.artist, "\(score.bars) 小节"]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("\(format(viewModel.position.currentTime)) / \(format(viewModel.position.totalTime))")
                .monospacedDigit()
            if viewModel.score != nil {
                Text(verbatim: String(
                    format: "基准 %.0f BPM · 当前 %.0f BPM · %.2f×",
                    viewModel.baseBpm,
                    viewModel.currentBpm,
                    viewModel.playbackSpeed
                ))
                .font(.caption.bold())
                .foregroundStyle(.orange)
            }
            if let selectedBar = viewModel.selectedBar {
                Text("命中第 \(selectedBar.index + 1) 小节 · \(Int(selectedBar.startTick))–\(Int(selectedBar.endTick)) tick")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let range = viewModel.loopPreview ?? viewModel.loopRange {
                Text("第 \(range.firstBar + 1)–\(range.lastBar + 1) 小节\(viewModel.loopPreview == nil ? "已循环" : "选择中")")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            } else {
                Text("轻点谱面跳转播放位置；长按并拖动选择 A/B 循环范围")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(viewModel.playerReady ? "离线渲染与播放器已就绪" : "正在准备离线渲染/音色…")
                .font(.caption)
                .foregroundStyle(viewModel.playerReady ? .green : .secondary)
        }
    }

    private func importScore(from url: URL) {
        do {
            viewModel.loadScore(data: try Data(contentsOf: url), fileName: url.lastPathComponent)
            recentProjects.opened(kind: .guitarPro, fileName: url.lastPathComponent)
        } catch {
            viewModel.reportImportError(error)
        }
    }

    private func format(_ milliseconds: Double) -> String {
        let totalSeconds = max(0, Int(milliseconds / 1_000))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func formatDuration(_ milliseconds: Int64) -> String {
        let totalMinutes = Int(max(0, milliseconds / 60_000))
        return String(format: "%02d:%02d", totalMinutes / 60, totalMinutes % 60)
    }

    private func subdivisionLabel(factor: Int) -> String {
        let subdivision: Subdivision = switch factor {
        case 2: .eighth
        case 4: .sixteenth
        case 8: .thirtySecond
        default: .quarter
        }
        return subdivision.label(forBeatUnit: viewModel.score?.beatUnit ?? 4)
    }
}
