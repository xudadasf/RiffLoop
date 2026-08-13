import AVKit
import Foundation
import SwiftUI

struct PracticeView: View {
    @EnvironmentObject private var recentProjects: RecentProjectsStore
    @StateObject private var viewModel = PracticeViewModel()
    @State private var isLibraryPresented = false
    @State private var scrubTime: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var didOpenInitialURL = false
    @State private var groupingInput = "4"
    @State private var controlsVisible = true

    let initialURL: URL?

    init(initialURL: URL? = nil) {
        self.initialURL = initialURL
    }

    private let rates: [Float] = [0.25, 0.5, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5]

    var body: some View {
        HStack(spacing: 0) {
            videoArea
                .overlay(alignment: .topTrailing) {
                    if !controlsVisible {
                        compactControls.padding(12)
                    }
                }
            if controlsVisible {
                sideControls
                    .frame(width: 360)
                    .background(Color(white: 0.08))
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("视频练习")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("选择文件") { isLibraryPresented = true }
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
        .onAppear {
            guard !didOpenInitialURL, let initialURL else { return }
            didOpenInitialURL = true
            open(initialURL)
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
            .disabled(!viewModel.hasMedia)
        }
        .padding(10)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
    }

    private var sideControls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sideHeader
                timeline
                compactTransportSection
                Divider()
                compactLoopSection
                Divider()
                compactMetronomeSection
                Divider()
                compactSoundSection
            }
            .padding(16)
            .onChange(of: viewModel.beatGrouping) { _, grouping in
                groupingInput = grouping.map(String.init).joined(separator: "+")
            }
        }
    }

    private var sideHeader: some View {
        HStack {
            Text("控制").font(.title3.bold())
            Spacer()
            Button("收起") { controlsVisible = false }
        }
    }

    private var compactTransportSection: some View {
        HStack(spacing: 10) {
            Button { viewModel.skip(by: -5) } label: { Image(systemName: "gobackward.5") }
            Button(action: viewModel.togglePlayback) {
                Label(
                    viewModel.isPlaying ? "暂停" : "播放",
                    systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button { viewModel.skip(by: 5) } label: { Image(systemName: "goforward.5") }
            Picker("速度", selection: Binding(
                get: { viewModel.playbackRate },
                set: { viewModel.setPlaybackRate($0) }
            )) {
                ForEach(rates, id: \.self) { Text(rateLabel($0)).tag($0) }
            }
            .pickerStyle(.menu)
        }
        .disabled(!viewModel.hasMedia)
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
            Toggle("A/B 吸附最近拍点", isOn: $viewModel.snapLoopPointsToBeat)
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
                        Text("+\(Int(($0 * 100).rounded()))%").tag($0)
                    }
                }
                Picker("目标速度", selection: Binding(
                    get: { viewModel.speedLadderTarget },
                    set: { viewModel.setSpeedLadderTarget($0) }
                )) {
                    ForEach([Float(0.8), 0.9, 1, 1.1, 1.25, 1.5], id: \.self) {
                        Text("\(Int(($0 * 100).rounded()))%").tag($0)
                    }
                }
            }
        }
    }

    private var compactMetronomeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("节拍器").font(.headline)
            Toggle("播放节拍", isOn: $viewModel.metronomeEnabled)
                .onChange(of: viewModel.metronomeEnabled) { _, _ in viewModel.applyTimingSettings() }
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
            Picker("细分", selection: $viewModel.subdivision) {
                ForEach(Subdivision.allCases) {
                    Text($0.label(forBeatUnit: viewModel.beatUnit)).tag($0)
                }
            }
            .onChange(of: viewModel.subdivision) { _, _ in viewModel.applyTimingSettings() }
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
        }
    }

    private var compactSoundSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("声音与同步").font(.headline)
            volumeSlider("视频音量", value: Double(viewModel.mediaVolume)) {
                viewModel.setMediaVolume(Float($0))
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
                VideoPlayer(player: viewModel.player)
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
                .frame(width: 82, alignment: .leading)

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
                .frame(width: 82, alignment: .trailing)
        }
        .font(.headline)
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

            Toggle("拍点吸附", isOn: $viewModel.snapLoopPointsToBeat)
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

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00.000" }
        let totalMilliseconds = Int((seconds * 1_000).rounded())
        let minutes = totalMilliseconds / 60_000
        let wholeSeconds = (totalMilliseconds / 1_000) % 60
        let milliseconds = totalMilliseconds % 1_000
        return String(format: "%02d:%02d.%03d", minutes, wholeSeconds, milliseconds)
    }

    private func rateLabel(_ rate: Float) -> String {
        String(format: "%.2g×", rate)
    }

    private func open(_ url: URL) {
        viewModel.openMedia(at: url)
        recentProjects.opened(kind: .video, fileName: url.lastPathComponent)
    }
}

#Preview("iPad Landscape") {
    PracticeView()
        .environmentObject(RecentProjectsStore())
        .frame(width: 1_180, height: 820)
}
