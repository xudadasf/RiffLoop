import AVKit
import Foundation
import SwiftUI

private enum VideoControlPanel: String, Identifiable {
    case loop
    case metronome
    case sound

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loop: "循环"
        case .metronome: "节拍器"
        case .sound: "声音"
        }
    }

    var systemImage: String {
        switch self {
        case .loop: "repeat"
        case .metronome: "metronome"
        case .sound: "speaker.wave.2.fill"
        }
    }
}

struct PracticeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var displayNames: DocumentDisplayNameStore
    @EnvironmentObject private var recentProjects: RecentProjectsStore
    @StateObject private var viewModel = PracticeViewModel()
    @State private var isLibraryPresented = false
    @State private var scrubTime: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var didOpenInitialURL = false
    @State private var groupingInput = "4"
    @State private var activePanel: VideoControlPanel?
    @State private var currentFileName: String?

    let initialURL: URL?

    init(initialURL: URL? = nil) {
        self.initialURL = initialURL
    }

    private let rates: [Float] = [0.25, 0.5, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5]
    private let quickRates: [Float] = [0.5, 0.75, 0.9, 1.0, 1.25]

    var body: some View {
        videoArea
            .simultaneousGesture(
                TapGesture().onEnded { activePanel = nil }
            )
            .overlay(alignment: .topTrailing) {
                if viewModel.hasMedia {
                    playbackStateBadge
                        .padding()
                }
            }
            .overlay(alignment: .bottomLeading) {
                if viewModel.loopEnabled {
                    Button(action: viewModel.clearLoop) {
                        Label("退出 A/B 循环", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .padding()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let panel = activePanel {
                    panelContent(panel)
                        .frame(width: 420, height: 540)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.24), radius: 20, y: 8)
                        .padding(16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                controlDeck
            }
            .animation(.snappy, value: activePanel)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(videoTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("选择文件") { isLibraryPresented = true }
                    Menu {
                        if viewModel.loopEnabled {
                            Button("退出 A/B 循环", role: .destructive, action: viewModel.clearLoop)
                        }
                        Button("循环设置") { activePanel = .loop }
                        Button("节拍器设置") { activePanel = .metronome }
                        Button("声音与记录") { activePanel = .sound }
                    } label: {
                        Label("更多", systemImage: "ellipsis")
                    }
                }
            }
            .sheet(isPresented: $isLibraryPresented) {
                DocumentLibraryView(kind: .video) { url in
                    open(url)
                }
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
            .onChange(of: viewModel.currentTime) { _, newValue in
                if !isScrubbing {
                    scrubTime = newValue
                }
            }
            .onChange(of: viewModel.beatGrouping) { _, grouping in
                groupingInput = grouping.map(String.init).joined(separator: "+")
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { viewModel.pause() }
            }
            .onAppear {
                guard !didOpenInitialURL, let initialURL else { return }
                didOpenInitialURL = true
                open(initialURL)
            }
            .onDisappear(perform: viewModel.pause)
    }

    private var playbackStateBadge: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(viewModel.isPlaying ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(viewModel.isPlaying ? "播放中 · \(rateLabel(viewModel.playbackRate))" : "已暂停")
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }

    private var controlDeck: some View {
        HStack(spacing: 12) {
            deckTransportControls
                .frame(width: 212)

            VStack(spacing: 8) {
                timeline
                HStack(spacing: 6) {
                    ForEach(quickRates, id: \.self) { rate in
                        Button("手动 \(rateLabel(rate))") { viewModel.setPlaybackRate(rate) }
                            .buttonStyle(.bordered)
                            .tint(viewModel.playbackRate == rate ? .accentColor : .secondary)
                    }
                }
                .controlSize(.small)
            }
            .frame(minWidth: 340, maxWidth: .infinity)

            Rectangle()
                .fill(Color(.separator))
                .frame(width: 1, height: 78)

            HStack(spacing: 8) {
                toolButton(.loop, summary: loopSummary, detail: loopDetail)
                toolButton(.metronome, summary: metronomeSummary, detail: metronomeDetail)
                toolButton(.sound, summary: soundSummary, detail: soundDetail)
            }
            .frame(maxWidth: 390)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var deckTransportControls: some View {
        HStack(spacing: 8) {
            Button { viewModel.skip(by: -5) } label: {
                Label("后退 5 秒", systemImage: "gobackward.5")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 30, minHeight: 44)
            }
            .buttonStyle(.bordered)

            Button(action: viewModel.togglePlayback) {
                Label(
                    viewModel.isPlaying ? "暂停" : "播放",
                    systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)

            Button { viewModel.skip(by: 5) } label: {
                Label("前进 5 秒", systemImage: "goforward.5")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 30, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
        .disabled(!viewModel.hasMedia)
    }

    private func toolButton(
        _ panel: VideoControlPanel,
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
    }

    @ViewBuilder
    private func panelContent(_ panel: VideoControlPanel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label(panel.title, systemImage: panel.systemImage)
                    .font(.title2.bold())
                Spacer()
                Button("完成") { activePanel = nil }
                    .buttonStyle(.bordered)
            }
            .padding()

            ScrollView {
                Group {
                    switch panel {
                    case .loop: compactLoopSection
                    case .metronome: compactMetronomeSection
                    case .sound: compactSoundSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .bottom])
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    private var compactLoopSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A/B 循环").font(.headline)
            HStack {
                Button("设 A") { viewModel.setPointA() }
                Text(viewModel.pointA.map(formatTime) ?? "--:--.---").monospacedDigit()
                Button("设 B") { viewModel.setPointB() }
                Text(viewModel.pointB.map(formatTime) ?? "--:--.---").monospacedDigit()
            }
            .font(.caption)
            Toggle("A/B 循环", isOn: Binding(
                get: { viewModel.loopEnabled },
                set: { viewModel.setLoopEnabled($0) }
            ))
            Toggle("A/B 吸附最近拍点", isOn: Binding(
                get: { viewModel.snapLoopPointsToBeat },
                set: { viewModel.setSnapLoopPointsToBeat($0) }
            ))
            Toggle("每轮预备 1 小节", isOn: Binding(
                get: { viewModel.loopCountInEnabled },
                set: { viewModel.setLoopCountInEnabled($0) }
            ))
            Toggle("循环阶梯", isOn: Binding(
                get: { viewModel.speedLadderEnabled },
                set: { viewModel.setSpeedLadderEnabled($0) }
            ))
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
                    ForEach([Float(0.02), 0.05, 0.1], id: \.self) {
                        Text("每次 +\(Int(($0 * 100).rounded())) 个百分点").tag($0)
                    }
                }
                Picker("目标速度", selection: Binding(
                    get: { viewModel.speedLadderTarget },
                    set: { viewModel.setSpeedLadderTarget($0) }
                )) {
                    ForEach(
                        [Float(0.8), 0.9, 1, 1.1, 1.25, 1.5]
                            .filter { $0 >= viewModel.minimumSpeedLadderTarget },
                        id: \.self
                    ) {
                        Text("目标 \(Int(($0 * 100).rounded()))%（\(rateLabel($0))）").tag($0)
                    }
                }
                Text(
                    "阶梯说明：从当前手动速度开始，每完成 \(viewModel.loopsPerSpeedStep) 轮，"
                        + "增加 \(Int((viewModel.speedLadderStep * 100).rounded())) 个百分点，"
                        + "直到 \(Int((viewModel.speedLadderTarget * 100).rounded()))%；"
                        + "当前已达到目标时不会改变速度；"
                        + "目标速度不会低于手动起始速度，阶梯只递增；"
                        + "关闭阶梯时恢复到最后一次手动选择的速度。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var compactMetronomeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("节拍器").font(.headline)
            Toggle("开启节拍器", isOn: $viewModel.metronomeEnabled)
                .onChange(of: viewModel.metronomeEnabled) { _, _ in
                    viewModel.applyTimingSettings()
                }

            Group {
                HStack {
                    Text("BPM")
                    TextField("120", value: $viewModel.bpm, format: .number.precision(.fractionLength(0)))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .onSubmit { viewModel.applyTimingSettings() }
                    Stepper("", value: $viewModel.bpm, in: 30...300, step: 1).labelsHidden()
                    Button("Tap", action: viewModel.recordTap)
                    Button("设第 1 拍", action: viewModel.setBeatOne)
                }
                Text("节拍细分")
                    .font(.subheadline.weight(.semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Subdivision.allCases) { subdivision in
                            Button(subdivision.label(forBeatUnit: viewModel.beatUnit)) {
                                viewModel.subdivision = subdivision
                                viewModel.applyTimingSettings()
                            }
                            .buttonStyle(.bordered)
                            .tint(viewModel.subdivision == subdivision ? .orange : .secondary)
                        }
                    }
                }
                HStack {
                    Stepper(
                        "\(viewModel.beatsPerMeasure)/\(viewModel.beatUnit)",
                        value: Binding(
                            get: { viewModel.beatsPerMeasure },
                            set: { viewModel.setMeter(beats: $0, unit: viewModel.beatUnit) }
                        ),
                        in: 1...16
                    )
                    Picker("拍值", selection: Binding(
                        get: { viewModel.beatUnit },
                        set: { viewModel.setMeter(beats: viewModel.beatsPerMeasure, unit: $0) }
                    )) {
                        ForEach([2, 4, 8, 16], id: \.self) { Text("/\($0)").tag($0) }
                    }
                }
                TextField("拍子分组，例如 2+2+3", text: $groupingInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if !viewModel.setBeatGrouping(groupingInput) {
                            groupingInput = viewModel.beatGrouping.map(String.init).joined(separator: "+")
                        }
                    }
                Picker("训练模式", selection: $viewModel.rhythmMode) {
                    ForEach(RhythmMode.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: viewModel.rhythmMode) { _, _ in viewModel.applyTimingSettings() }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(viewModel.beatAccents.indices, id: \.self) { index in
                            Button("\(index + 1) \(viewModel.beatAccents[index].label)") {
                                viewModel.cycleAccent(at: index)
                            }
                            .buttonStyle(.bordered)
                            .tint(index == viewModel.currentBeatIndex ? .orange : .secondary)
                        }
                    }
                }
                volumeSlider("节拍音量", value: Double(viewModel.metronomeVolume)) {
                    viewModel.setMetronomeVolume(Float($0))
                }
                Text("节拍微调 \(Int((viewModel.synchronizationOffset * 1_000).rounded())) ms")
                    .font(.caption)
                HStack {
                    ForEach([-10, -5, -1, 1, 5, 10], id: \.self) { milliseconds in
                        Button(milliseconds > 0 ? "+\(milliseconds)" : "\(milliseconds)") {
                            viewModel.adjustSynchronization(by: Double(milliseconds) / 1_000)
                        }
                    }
                }
            }
        }
    }

    private var compactSoundSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("视频声音与练习记录").font(.headline)
            Picker("手动速度", selection: Binding(
                get: { viewModel.playbackRate },
                set: { viewModel.setPlaybackRate($0) }
            )) {
                ForEach(rates, id: \.self) { rate in
                    Text("手动 \(rateLabel(rate))").tag(rate)
                }
            }
            volumeSlider("视频音量", value: Double(viewModel.mediaVolume)) {
                viewModel.setMediaVolume(Float($0))
            }
            Text(
                "本次循环 \(viewModel.completedLoops) 轮 · "
                    + "练习 \(Int(viewModel.accumulatedPracticeTime / 60)) 分钟 · "
                    + "最高 \(Int((viewModel.highestPlaybackRate * 100).rounded()))%"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func volumeSlider(
        _ title: String,
        value: Double,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) \(Int((value * 100).rounded()))%")
                .font(.caption)
            Slider(value: Binding(get: { value }, set: onChange), in: 0...1)
        }
    }

    private var videoArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.08))

            if viewModel.hasMedia {
                VideoSurface(player: viewModel.player)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 48))
                    Text("导入一个 MP4 开始技术验证")
                        .font(.title2.weight(.semibold))
                    Button("选择视频") {
                        isLibraryPresented = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
    }

    private var timeline: some View {
        HStack(spacing: 12) {
            Text(formatTime(isScrubbing ? scrubTime : viewModel.currentTime))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 96, alignment: .leading)

            Slider(
                value: $scrubTime,
                in: 0...max(viewModel.duration, 0.01),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        viewModel.seek(to: scrubTime)
                    }
                }
            )
            .disabled(!viewModel.hasMedia)

            Text(formatTime(viewModel.duration))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 96, alignment: .trailing)
        }
        .font(.subheadline.weight(.semibold))
    }

    private var transportControls: some View {
        HStack(spacing: 16) {
            Button("选择文件") { isLibraryPresented = true }
                .buttonStyle(.bordered)

            Button { viewModel.skip(by: -10) } label: {
                Label("后退 10 秒", systemImage: "gobackward.10")
                    .labelStyle(.iconOnly)
            }

            Button { viewModel.skip(by: -5) } label: {
                Label("后退 5 秒", systemImage: "gobackward.5")
                    .labelStyle(.iconOnly)
            }

            Button(action: viewModel.togglePlayback) {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 58, height: 34)
            }
            .buttonStyle(.borderedProminent)

            Button { viewModel.skip(by: 5) } label: {
                Label("前进 5 秒", systemImage: "goforward.5")
                    .labelStyle(.iconOnly)
            }

            Button { viewModel.skip(by: 10) } label: {
                Label("前进 10 秒", systemImage: "goforward.10")
                    .labelStyle(.iconOnly)
            }

            Picker("速度", selection: Binding(
                get: { viewModel.playbackRate },
                set: { viewModel.setPlaybackRate($0) }
            )) {
                ForEach(rates, id: \.self) { rate in
                    Text(rateLabel(rate)).tag(rate)
                }
            }
            .pickerStyle(.menu)
        }
        .font(.title3.weight(.semibold))
        .disabled(!viewModel.hasMedia)
    }

    private var loopControls: some View {
        HStack(spacing: 14) {
            valueCard(title: "A", value: viewModel.pointA)
            Button("Set A") { viewModel.setPointA() }
                .buttonStyle(.bordered)

            valueCard(title: "B", value: viewModel.pointB)
            Button("Set B") { viewModel.setPointB() }
                .buttonStyle(.bordered)

            Toggle("Loop", isOn: Binding(
                get: { viewModel.loopEnabled },
                set: { viewModel.setLoopEnabled($0) }
            ))
            .toggleStyle(.button)
            .tint(.orange)
        }
        .controlSize(.large)
        .disabled(!viewModel.hasMedia)
    }

    private var metronomeControls: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Text("BPM")
                TextField("120", value: $viewModel.bpm, format: .number.precision(.fractionLength(0)))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit { viewModel.applyTimingSettings() }

                Stepper("", value: $viewModel.bpm, in: 30...300, step: 1)
                    .labelsHidden()
                    .onChange(of: viewModel.bpm) { _, _ in
                        viewModel.applyTimingSettings()
                    }
            }

            Picker("细分", selection: $viewModel.subdivision) {
                ForEach(Subdivision.allCases) { subdivision in
                    Text(subdivision.label(forBeatUnit: viewModel.beatUnit)).tag(subdivision)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: viewModel.subdivision) { _, _ in
                viewModel.applyTimingSettings()
            }

            Toggle("Metronome", isOn: $viewModel.metronomeEnabled)
                .toggleStyle(.button)
                .tint(.green)
                .onChange(of: viewModel.metronomeEnabled) { _, _ in
                    viewModel.applyTimingSettings()
                }

            Button("Set Beat 1") { viewModel.setBeatOne() }
                .buttonStyle(.borderedProminent)

            VStack(alignment: .leading, spacing: 2) {
                Text("Beat 1")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(viewModel.beatOffset.map(formatTime) ?? "未设置")
                    .monospacedDigit()
            }
            .frame(minWidth: 100, alignment: .leading)
        }
        .font(.headline)
        .controlSize(.large)
        .disabled(!viewModel.hasMedia)
    }

    private var meterAndRhythmControls: some View {
        HStack(spacing: 12) {
            Stepper(
                "\(viewModel.beatsPerMeasure)/\(viewModel.beatUnit)",
                value: Binding(
                    get: { viewModel.beatsPerMeasure },
                    set: { viewModel.setMeter(beats: $0, unit: viewModel.beatUnit) }
                ),
                in: 1...16
            )
            .frame(width: 150)

            Picker("拍值", selection: Binding(
                get: { viewModel.beatUnit },
                set: { viewModel.setMeter(beats: viewModel.beatsPerMeasure, unit: $0) }
            )) {
                ForEach([2, 4, 8, 16], id: \.self) { Text("/\($0)").tag($0) }
            }
            .pickerStyle(.menu)

            TextField("分组 2+2+3", text: $groupingInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .onSubmit {
                    if !viewModel.setBeatGrouping(groupingInput) {
                        groupingInput = viewModel.beatGrouping.map(String.init).joined(separator: "+")
                    }
                }

            Picker("训练", selection: $viewModel.rhythmMode) {
                ForEach(RhythmMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: viewModel.rhythmMode) { _, _ in viewModel.applyTimingSettings() }

            HStack(spacing: 4) {
                ForEach(viewModel.beatAccents.indices, id: \.self) { index in
                    Button("\(index + 1)\n\(viewModel.beatAccents[index].label)") {
                        viewModel.cycleAccent(at: index)
                    }
                    .buttonStyle(.bordered)
                    .tint(index == viewModel.currentBeatIndex ? .orange : .gray)
                }
            }
        }
        .font(.subheadline)
    }

    private var volumeAndTrainingControls: some View {
        HStack(spacing: 14) {
            Text("视频")
            Slider(
                value: Binding(
                    get: { Double(viewModel.mediaVolume) },
                    set: { viewModel.setMediaVolume(Float($0)) }
                ),
                in: 0...1
            )
            .frame(width: 100)

            Text("节拍")
            Slider(
                value: Binding(
                    get: { Double(viewModel.metronomeVolume) },
                    set: { viewModel.setMetronomeVolume(Float($0)) }
                ),
                in: 0...1
            )
            .frame(width: 100)

            Button("Tap Tempo", action: viewModel.recordTap)
                .buttonStyle(.borderedProminent)

            Toggle("拍点吸附", isOn: Binding(
                get: { viewModel.snapLoopPointsToBeat },
                set: { viewModel.setSnapLoopPointsToBeat($0) }
            ))
                .toggleStyle(.button)
            Toggle("预备 1 小节", isOn: $viewModel.loopCountInEnabled)
                .toggleStyle(.button)
            Toggle("循环阶梯", isOn: $viewModel.speedLadderEnabled)
                .toggleStyle(.button)

            HStack(spacing: 4) {
                Text("同步 \(Int((viewModel.synchronizationOffset * 1_000).rounded())) ms")
                ForEach([-10, -1, 1, 10], id: \.self) { milliseconds in
                    Button(milliseconds > 0 ? "+\(milliseconds)" : "\(milliseconds)") {
                        viewModel.adjustSynchronization(by: Double(milliseconds) / 1_000)
                    }
                }
            }

            Text("循环 \(viewModel.completedLoops) · 练习 \(Int(viewModel.accumulatedPracticeTime / 60)) 分钟")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .onChange(of: viewModel.beatGrouping) { _, grouping in
            groupingInput = grouping.map(String.init).joined(separator: "+")
        }
    }

    private func valueCard(title: String, value: TimeInterval?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.map(formatTime) ?? "--:--.---")
                .monospacedDigit()
        }
        .frame(minWidth: 108, alignment: .leading)
    }

    private var loopSummary: String {
        viewModel.loopEnabled ? "A/B 循环已开启" : "A/B 循环关闭"
    }

    private var loopDetail: String {
        let a = viewModel.pointA.map(formatTime) ?? "未设 A"
        let b = viewModel.pointB.map(formatTime) ?? "未设 B"
        return "\(a) → \(b)"
    }

    private var metronomeSummary: String {
        viewModel.metronomeEnabled ? "\(Int(viewModel.bpm.rounded())) BPM" : "节拍器关闭"
    }

    private var metronomeDetail: String {
        "\(viewModel.beatsPerMeasure)/\(viewModel.beatUnit) · \(viewModel.rhythmMode.label)"
    }

    private var soundSummary: String {
        "视频 \(Int((viewModel.mediaVolume * 100).rounded()))%"
    }

    private var soundDetail: String {
        "循环 \(viewModel.completedLoops) 轮 · 最高 \(Int((viewModel.highestPlaybackRate * 100).rounded()))%"
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00.000" }
        let totalMilliseconds = Int((seconds * 1_000).rounded())
        let minutes = totalMilliseconds / 60_000
        let wholeSeconds = (totalMilliseconds / 1_000) % 60
        let milliseconds = totalMilliseconds % 1_000
        return String(format: "%02d:%02d.%03d", minutes, wholeSeconds, milliseconds)
    }

    private func rateLabel(_ rate: Float) -> String {
        String(format: "%.2f×", rate)
    }

    private func open(_ url: URL) {
        currentFileName = url.lastPathComponent
        viewModel.openMedia(at: url)
        recentProjects.opened(kind: .video, fileName: url.lastPathComponent)
    }

    private var videoTitle: String {
        guard let currentFileName else { return "视频练习" }
        return displayNames.displayName(for: .video, fileName: currentFileName)
    }
}

private struct VideoSurface: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspect
        return controller
    }

    func updateUIViewController(
        _ controller: AVPlayerViewController,
        context: Context
    ) {
        controller.player = player
        controller.showsPlaybackControls = false
    }
}

#Preview("iPad Landscape") {
    PracticeView()
        .environmentObject(DocumentDisplayNameStore())
        .environmentObject(RecentProjectsStore())
        .frame(width: 1_180, height: 820)
}
