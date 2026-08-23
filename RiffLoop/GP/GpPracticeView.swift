import Foundation
import SwiftUI

private enum GpControlPanel: String, Identifiable {
    case loop
    case metronome
    case sound
    case tracks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loop: "循环"
        case .metronome: "节拍器"
        case .sound: "声音"
        case .tracks: "轨道"
        }
    }

    var systemImage: String {
        switch self {
        case .loop: "repeat"
        case .metronome: "metronome"
        case .sound: "speaker.wave.2.fill"
        case .tracks: "slider.horizontal.3"
        }
    }
}

struct GpPracticeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var recentProjects: RecentProjectsStore
    @StateObject private var viewModel = GpWebViewModel()
    @State private var isLibraryPresented = false
    @State private var didOpenInitialURL = false
    @State private var activePanel: GpControlPanel?

    let initialURL: URL?

    init(initialURL: URL? = nil) {
        self.initialURL = initialURL
    }

    private let speeds = [0.5, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5]
    private let quickSpeeds = [0.5, 0.75, 0.9, 1.0, 1.25]

    var body: some View {
        GpWebView(viewModel: viewModel)
            .overlay {
                if viewModel.score == nil {
                    emptyScoreView
                }
            }
            .overlay(alignment: .topTrailing) {
                if viewModel.score != nil {
                    playbackStateBadge
                        .padding()
                }
            }
            .overlay(alignment: .bottomLeading) {
                if viewModel.loopRange != nil, !viewModel.isPlaying {
                    Button(action: viewModel.clearLoop) {
                        Label("退出区间循环", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .padding()
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                controlDeck
            }
            .navigationTitle(viewModel.score?.title ?? "Guitar Pro 练习")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("选择文件") { isLibraryPresented = true }
                    Menu {
                        if viewModel.loopRange != nil {
                            Button("退出区间循环", role: .destructive, action: viewModel.clearLoop)
                        }
                        Button("循环设置") { activePanel = .loop }
                        Button("练习记录") { activePanel = .loop }
                    } label: {
                        Label("更多", systemImage: "ellipsis")
                    }
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

    private var emptyScoreView: some View {
        ContentUnavailableView(
            "导入 Guitar Pro 乐谱",
            systemImage: "music.note.list",
            description: Text("支持 .gp、.gpx、.gp3、.gp4、.gp5；所有谱面均在本机离线渲染。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.82))
    }

    private var playbackStateBadge: some View {
        let state = playbackState
        return HStack(spacing: 7) {
            Circle()
                .fill(state.color)
                .frame(width: 8, height: 8)
            Text(state.text)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .accessibilityLabel(state.text)
    }

    private var playbackState: (text: String, color: Color) {
        if viewModel.loopPreview != nil {
            return ("正在选择循环范围", .blue)
        }
        if viewModel.isPlaying {
            let loopSuffix = viewModel.rangeLoopingEnabled && viewModel.loopRange != nil
                ? " · 循环第 \(viewModel.currentSpeedLadderRound)/\(viewModel.loopsPerSpeedStep) 轮"
                : ""
            return ("播放中 · \(speedLabel(viewModel.playbackSpeed))\(loopSuffix)", .green)
        }
        if viewModel.playerReady {
            return ("已暂停 · 设置会在下次播放生效", .orange)
        }
        return ("正在准备离线播放器", .secondary)
    }

    private var controlDeck: some View {
        HStack(spacing: 12) {
            transportControls
                .frame(width: 172)

            progressAndSpeed
                .frame(minWidth: 280, maxWidth: .infinity)

            Rectangle()
                .fill(Color(.separator))
                .frame(width: 1, height: 78)

            HStack(spacing: 8) {
                toolButton(.loop, summary: loopSummary, detail: loopDetail)
                toolButton(.metronome, summary: metronomeSummary, detail: metronomeDetail)
                toolButton(.sound, summary: soundSummary, detail: soundDetail)
                toolButton(.tracks, summary: trackSummary, detail: trackDetail)
            }
            .frame(maxWidth: 488)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var transportControls: some View {
        HStack(spacing: 8) {
            Button(action: viewModel.togglePlayback) {
                Label(
                    viewModel.isPlaying ? "暂停" : "播放",
                    systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.playerReady)

            Button(action: viewModel.stop) {
                Label("停止", systemImage: "stop.fill")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 32, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle)
            .disabled(!viewModel.playerReady)
        }
    }

    private var progressAndSpeed: some View {
        VStack(spacing: 8) {
            HStack {
                Text(format(viewModel.position.currentTime))
                    .font(.caption.monospacedDigit().weight(.semibold))
                ProgressView(
                    value: min(viewModel.position.currentTime, max(1, viewModel.position.totalTime)),
                    total: max(1, viewModel.position.totalTime)
                )
                Text(format(viewModel.position.totalTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                ForEach(quickSpeeds, id: \.self) { value in
                    Button(speedLabel(value)) {
                        viewModel.setPlaybackSpeed(value)
                    }
                    .buttonStyle(.bordered)
                    .tint(viewModel.playbackSpeed == value ? .accentColor : .secondary)
                    .disabled(!viewModel.playerReady)
                }
            }
            .controlSize(.small)

            Text(tempoSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func toolButton(
        _ panel: GpControlPanel,
        summary: String,
        detail: String
    ) -> some View {
        Button {
            activePanel = activePanel == panel ? nil : panel
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Label(panel.title, systemImage: panel.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(activePanel == panel ? Color.accentColor : .primary)
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                activePanel == panel ? Color.accentColor.opacity(0.17) : Color(.secondarySystemFill),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(activePanel == panel ? Color.accentColor.opacity(0.8) : Color(.separator))
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .popover(isPresented: panelBinding(for: panel), arrowEdge: .bottom) {
            panelContent(panel)
                .frame(width: 420, height: 540)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityHint("打开\(panel.title)设置")
    }

    @ViewBuilder
    private func panelContent(_ panel: GpControlPanel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label(panel.title, systemImage: panel.systemImage)
                    .font(.title2.bold())
                Spacer()
                Button("完成") { activePanel = nil }
                    .buttonStyle(.bordered)
            }
            .padding()

            switch panel {
            case .loop:
                loopPanel
            case .metronome:
                metronomePanel
            case .sound:
                soundPanel
            case .tracks:
                tracksPanel
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    private var loopPanel: some View {
        Form {
            Section {
                Text(loopRangeDescription)
                if let message = viewModel.loopSelectionMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
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
                Toggle("整曲循环", isOn: Binding(
                    get: { viewModel.wholeSongLoopingEnabled },
                    set: { viewModel.setWholeSongLoopingEnabled($0) }
                ))
                .disabled(viewModel.rangeLoopingEnabled)
            } header: {
                Text("循环范围")
            } footer: {
                Text("轻点谱面跳转；长按音符并拖动选择 A/B，松手确认。")
            }

            Section("速度") {
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

                Picker("播放速度", selection: Binding(
                    get: { viewModel.playbackSpeed },
                    set: { viewModel.setPlaybackSpeed($0) }
                )) {
                    ForEach(speeds, id: \.self) { Text(speedLabel($0)).tag($0) }
                }

                Button("恢复导入 BPM", action: viewModel.resetBaseBpm)
                    .disabled(!viewModel.playerReady || abs(viewModel.baseBpm - viewModel.originalBaseBpm) < 0.5)

                Text("1.00× 以当前基准 BPM 为准；变速谱按原 tempo map 等比例缩放。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("循环阶梯") {
                Toggle("启用循环阶梯", isOn: Binding(
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
            }

            if viewModel.loopRange != nil {
                Section {
                    Button("退出区间循环", role: .destructive, action: viewModel.clearLoop)
                }
            }

            Section("练习记录") {
                Text(practiceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var metronomePanel: some View {
        Form {
            Section("节拍器") {
                Toggle("开启节拍器", isOn: Binding(
                    get: { viewModel.metronomeEnabled },
                    set: { viewModel.setMetronomeEnabled($0) }
                ))
                if viewModel.metronomeEnabled {
                    Slider(
                        value: Binding(
                            get: { viewModel.metronomeVolume },
                            set: { viewModel.setMetronomeVolume($0) }
                        ),
                        in: 0...1
                    ) {
                        Text("节拍音量")
                    }
                    LabeledContent("节拍音量", value: percent(viewModel.metronomeVolume))
                }
            }

            Section {
                Picker("细分", selection: Binding(
                    get: { viewModel.metronomeSubdivisionFactor },
                    set: { viewModel.setMetronomeSubdivisionFactor($0) }
                )) {
                    ForEach([1, 2, 4, 8], id: \.self) { factor in
                        Text(subdivisionLabel(factor: factor)).tag(factor)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("节拍细分")
            } footer: {
                Text("细分跟随当前谱面的拍号。")
            }

            Section {
                ForEach(viewModel.beatAccents.indices, id: \.self) { index in
                    Button {
                        viewModel.cycleBeatAccent(at: index)
                    } label: {
                        LabeledContent("第 \(index + 1) 拍", value: viewModel.beatAccents[index].label)
                    }
                }
            } header: {
                Text("每拍强度")
            } footer: {
                Text("点击每一拍，依次切换强、次强、普通和静音。")
            }

            Section("预备拍") {
                Toggle("开始播放前预备拍", isOn: Binding(
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
                    ) {
                        Text("预备拍音量")
                    }
                    LabeledContent("预备拍音量", value: percent(viewModel.countInVolume))
                }
            }
        }
    }

    private var soundPanel: some View {
        Form {
            Section("谱面合成") {
                Toggle("谱面合成声音", isOn: Binding(
                    get: { viewModel.synthEnabled },
                    set: { viewModel.setSynthEnabled($0) }
                ))
                Slider(
                    value: Binding(
                        get: { viewModel.masterVolume },
                        set: { viewModel.setMasterVolume($0) }
                    ),
                    in: 0...1
                ) {
                    Text("合成总音量")
                }
                LabeledContent("合成总音量", value: percent(viewModel.masterVolume))
            }

            if viewModel.score?.hasBackingTrack == true {
                Section {
                    Toggle("内嵌伴奏", isOn: Binding(
                        get: { viewModel.backingEnabled },
                        set: { viewModel.setBackingEnabled($0) }
                    ))
                    Slider(
                        value: Binding(
                            get: { viewModel.backingVolume },
                            set: { viewModel.setBackingVolume($0) }
                        ),
                        in: 0...1
                    ) {
                        Text("伴奏音量")
                    }
                    LabeledContent("伴奏音量", value: percent(viewModel.backingVolume))
                } header: {
                    Text("内嵌伴奏")
                } footer: {
                    Text("伴奏由 iOS 原生播放器输出，谱面合成器继续负责音符声音。")
                }
            }

            if !viewModel.backingDiagnosticLines.isEmpty {
                Section("伴奏诊断") {
                    if let probe = viewModel.backingProbeDiagnostic {
                        Text("MIME：\(probe)")
                    }
                    Text(viewModel.backingDiagnosticLines.joined(separator: "\n"))
                }
                .font(.caption.monospaced())
                .textSelection(.enabled)
            }
        }
    }

    private var tracksPanel: some View {
        Form {
            if let score = viewModel.score {
                Section("显示乐谱") {
                    Picker("显示轨道", selection: Binding(
                        get: { viewModel.displayedTrack },
                        set: { viewModel.showTracks([$0]) }
                    )) {
                        ForEach(score.tracks, id: \.index) { track in
                            Text(track.name).tag(track.index)
                        }
                    }
                }

                Section("轨道声音") {
                    ForEach(score.tracks, id: \.index) { track in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(track.name)
                                    .font(.headline)
                                    .lineLimit(1)
                                Spacer()
                                Button(viewModel.mutedTracks.contains(track.index) ? "取消静音" : "静音") {
                                    viewModel.setTrackMute(
                                        index: track.index,
                                        muted: !viewModel.mutedTracks.contains(track.index)
                                    )
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
                            ) {
                                Text("\(track.name)音量")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } else {
                ContentUnavailableView("尚未载入轨道", systemImage: "slider.horizontal.3")
            }
        }
    }

    private var loopSummary: String {
        guard let range = viewModel.loopPreview ?? viewModel.loopRange else { return "尚未选择 A/B" }
        return "A 第 \(range.firstBar + 1) 小节 → B 第 \(range.lastBar + 1) 小节"
    }

    private var loopDetail: String {
        if viewModel.loopPreview != nil { return "选择中 · 松手确认" }
        guard viewModel.rangeLoopingEnabled, viewModel.loopRange != nil else { return "循环已关闭" }
        return "第 \(viewModel.currentSpeedLadderRound)/\(viewModel.loopsPerSpeedStep) 轮 · \(viewModel.loopCountInEnabled ? "预备开启" : "无预备")"
    }

    private var metronomeSummary: String {
        "\(Int(viewModel.currentBpm.rounded())) BPM · \(subdivisionLabel(factor: viewModel.metronomeSubdivisionFactor))"
    }

    private var metronomeDetail: String {
        viewModel.metronomeEnabled ? beatAccentSummary : "节拍器已关闭"
    }

    private var soundSummary: String {
        "合成 \(percent(viewModel.masterVolume)) · 伴奏 \(percent(viewModel.backingVolume))"
    }

    private var soundDetail: String {
        let synth = viewModel.synthEnabled ? "合成开启" : "合成关闭"
        guard viewModel.score?.hasBackingTrack == true else { return synth }
        return "\(synth) · 伴奏\(viewModel.backingEnabled ? "开启" : "关闭")"
    }

    private var trackSummary: String {
        guard let score = viewModel.score,
              let track = score.tracks.first(where: { $0.index == viewModel.displayedTrack })
        else { return "尚未载入轨道" }
        return "显示：\(track.name)"
    }

    private var trackDetail: String {
        guard let score = viewModel.score else { return "" }
        return "\(score.tracks.count) 条轨道可混音"
    }

    private var loopRangeDescription: String {
        if let range = viewModel.loopPreview {
            return "选择中：第 \(range.firstBar + 1)–\(range.lastBar + 1) 小节内音符范围"
        }
        if let range = viewModel.loopRange {
            return "A：第 \(range.firstBar + 1) 小节内音符；B：第 \(range.lastBar + 1) 小节内音符结束"
        }
        return "尚未选择循环范围"
    }

    private var beatAccentSummary: String {
        viewModel.beatAccents.map(\.label).joined(separator: " · ")
    }

    private var practiceSummary: String {
        "本次 \(formatDuration(viewModel.sessionPracticeMilliseconds)) · "
            + "累计 \(formatDuration(viewModel.totalPracticeMilliseconds)) · "
            + "累计循环 \(viewModel.totalCompletedLoops) 轮 · "
            + "最高 \(Int((viewModel.highestPracticeSpeed * 100).rounded()))%"
    }

    private var tempoSummary: String {
        String(
            format: "基准 %.0f BPM · 当前 %.0f BPM · %.2f×",
            viewModel.baseBpm,
            viewModel.currentBpm,
            viewModel.playbackSpeed
        )
    }

    private func panelBinding(for panel: GpControlPanel) -> Binding<Bool> {
        Binding(
            get: { activePanel == panel },
            set: { isPresented in
                if isPresented {
                    activePanel = panel
                } else if activePanel == panel {
                    activePanel = nil
                }
            }
        )
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

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func speedLabel(_ speed: Double) -> String {
        String(format: "%.2g×", speed)
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
