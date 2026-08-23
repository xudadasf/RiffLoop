import Foundation
import SwiftUI

struct PdfPracticeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var recentProjects: RecentProjectsStore
    @StateObject private var viewModel = PdfPracticeViewModel()
    @State private var pdfLibraryPresented = false
    @State private var audioLibraryPresented = false
    @State private var controlsVisible = true
    @State private var expandedControls = false
    @State private var didOpenInitialURL = false
    @State private var groupingInput = "4"

    let initialURL: URL?

    init(initialURL: URL? = nil) {
        self.initialURL = initialURL
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let document = viewModel.document {
                PdfKitView(
                    document: document,
                    pageIndex: viewModel.pageIndex,
                    scaleFactor: viewModel.scaleFactor,
                    verticalProgress: viewModel.verticalProgress,
                    requestedProgress: viewModel.requestedProgress,
                    onPageChanged: viewModel.setPage,
                    onProgressChanged: viewModel.setVerticalProgress,
                    onScaleChanged: viewModel.setScale,
                    onManualInteraction: {
                        revealControls()
                        viewModel.manualViewportInteraction()
                    }
                )
                .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView {
                    Label("选择 PDF 开始练习", systemImage: "doc.richtext")
                } description: {
                    Text("从 RiffLoop 的 PDF 文件库选择，或从 Files 导入新文件。")
                } actions: {
                    Button("选择或导入 PDF") { pdfLibraryPresented = true }
                        .buttonStyle(.borderedProminent)
                }
            }

            if viewModel.document != nil {
                if controlsVisible {
                    overlayControls
                        .transition(.opacity)
                        .zIndex(2)
                } else {
                    Button("控制", action: openPracticePanel)
                        .buttonStyle(.borderedProminent)
                        .tint(.black.opacity(0.72))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(8)
                        .zIndex(2)
                }
            }

            if expandedControls {
                practicePanel
                    .frame(width: 340)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .background(.black.opacity(0.82))
                    .transition(.move(edge: .trailing))
                    .zIndex(3)
            }
        }
        .navigationTitle(viewModel.pdfFileName ?? "PDF 谱面")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { pdfLibraryPresented = true } label: {
                    Label(viewModel.document == nil ? "选择 PDF" : "更换 PDF", systemImage: "folder")
                }
            }
        }
        .sheet(isPresented: $pdfLibraryPresented) {
            DocumentLibraryView(
                kind: .pdf,
                onSelect: openPdf,
                onDelete: handleDeletedPdf
            )
        }
        .sheet(isPresented: $audioLibraryPresented) {
            PdfAudioLibraryView { viewModel.bindAudio(at: $0) }
        }
        .alert("RiffLoop", isPresented: Binding(
            get: { viewModel.message != nil },
            set: { if !$0 { viewModel.dismissMessage() } }
        )) {
            Button("好", role: .cancel) { viewModel.dismissMessage() }
        } message: {
            Text(viewModel.message ?? "")
        }
        .task(id: controlsVisible) {
            guard controlsVisible, !expandedControls, viewModel.document != nil else { return }
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled, !expandedControls else { return }
            withAnimation { controlsVisible = false }
        }
        .onAppear {
            guard !didOpenInitialURL, let initialURL else { return }
            didOpenInitialURL = true
            openPdf(initialURL)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { viewModel.pause() }
        }
        .onDisappear(perform: viewModel.pause)
    }

    private var overlayControls: some View {
        VStack {
            HStack {
                Button("更换 PDF") { pdfLibraryPresented = true }
                Spacer()
                Button("控制", action: openPracticePanel)
            }
            Spacer()
            HStack(spacing: 10) {
                Button("上一页") {
                    viewModel.manualViewportInteraction()
                    viewModel.setPage(viewModel.pageIndex - 1)
                }
                    .disabled(viewModel.pageIndex == 0)
                Button("−") {
                    viewModel.manualViewportInteraction()
                    viewModel.setScale(viewModel.scaleFactor - 0.25)
                }
                Text("\(viewModel.pageIndex + 1)/\(max(1, viewModel.pageCount)) · \(Int(viewModel.scaleFactor * 100))%")
                    .monospacedDigit()
                Button("+") {
                    viewModel.manualViewportInteraction()
                    viewModel.setScale(viewModel.scaleFactor + 0.25)
                }
                Button("下一页") {
                    viewModel.manualViewportInteraction()
                    viewModel.setPage(viewModel.pageIndex + 1)
                }
                    .disabled(viewModel.pageIndex + 1 >= viewModel.pageCount)
                Spacer()
                Button(readingButtonTitle, action: handleReadingButton)
                if viewModel.audioFileName != nil {
                    Button(viewModel.isAudioPlaying ? "暂停伴奏" : "播放伴奏") {
                        viewModel.toggleAudioPlayback()
                    }
                }
                Button(viewModel.isMetronomePlaying ? "暂停节拍器" : "启动节拍器") {
                    viewModel.toggleMetronomePlayback()
                }
                Button("伴奏") { audioLibraryPresented = true }
                if viewModel.audioFileName != nil {
                    Button("移除", action: viewModel.removeAudio)
                }
            }
            .padding(.bottom, 24)
        }
        .buttonStyle(.borderedProminent)
        .tint(.black.opacity(0.72))
        .padding(8)
    }

    private var practicePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                practiceHeader
                pdfTransportSection
                pdfLoopSection
                pdfMetronomeSection
                pdfAlignmentSection
                pdfSoundAndStatsSection
                Divider()
                autoFollowSection
            }
            .padding(18)
            .onChange(of: viewModel.beatGrouping) { _, grouping in
                groupingInput = grouping.map(String.init).joined(separator: "+")
            }
        }
    }

    private var practiceHeader: some View {
        HStack {
            Text("练习控制").font(.title3.bold())
            Spacer()
            Button("返回 PDF") {
                closePracticePanel()
            }
        }
    }

    private var pdfTransportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("伴奏").font(.headline)
            if let audioFileName = viewModel.audioFileName {
                Text(audioFileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(viewModel.isAudioPlaying ? "暂停伴奏" : "播放伴奏", action: viewModel.toggleAudioPlayback)
                        .buttonStyle(.borderedProminent)
                    Button("停止伴奏", action: viewModel.stopAudio)
                    Button("更换", action: { audioLibraryPresented = true })
                }
                Picker("速度", selection: Binding(
                    get: { viewModel.playbackRate },
                    set: { viewModel.setPlaybackRate($0) }
                )) {
                    ForEach([Float(0.25), 0.5, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5], id: \.self) {
                        Text(String(format: "%.2g×", $0)).tag($0)
                    }
                }
                Slider(
                    value: Binding(
                        get: { viewModel.currentTime },
                        set: { viewModel.seek(to: $0) }
                    ),
                    in: 0...max(viewModel.duration, 0.01)
                )
                Text("\(format(viewModel.currentTime)) / \(format(viewModel.duration))")
                    .monospacedDigit()
                Text("伴奏音量")
                Slider(
                    value: Binding(
                        get: { Double(viewModel.audioVolume) },
                        set: { viewModel.audioVolume = Float($0); viewModel.updateAudioSettings() }
                    ),
                    in: 0...1
                )
            } else {
                Text("未选择伴奏，节拍器仍可独立使用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("选择伴奏") { audioLibraryPresented = true }
            }
        }
    }

    private var pdfLoopSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("设 A", action: viewModel.setPointA)
                Button("设 B", action: viewModel.setPointB)
                Toggle("A/B 循环", isOn: $viewModel.loopEnabled)
                    .onChange(of: viewModel.loopEnabled) { _, _ in viewModel.updateAudioSettings() }
            }
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
                    ForEach(
                        [Float(0.8), 0.9, 1, 1.1, 1.25, 1.5]
                            .filter { $0 >= viewModel.playbackRate },
                        id: \.self
                    ) {
                        Text("\(Int(($0 * 100).rounded()))%").tag($0)
                    }
                }
                Text("已完成 \(viewModel.completedLoops) 轮")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pdfMetronomeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("节拍器").font(.headline)
            Button(
                viewModel.isMetronomePlaying ? "暂停节拍器" : "启动节拍器",
                action: viewModel.toggleMetronomePlayback
            )
            .buttonStyle(.borderedProminent)
            Stepper("BPM \(Int(viewModel.bpm))", value: $viewModel.bpm, in: 30...300)
                .onChange(of: viewModel.bpm) { _, _ in viewModel.updateAudioSettings() }
            Toggle("节拍器", isOn: $viewModel.metronomeEnabled)
                .onChange(of: viewModel.metronomeEnabled) { _, _ in viewModel.updateAudioSettings() }
            Picker("细分", selection: $viewModel.subdivision) {
                ForEach(Subdivision.allCases) { Text($0.label(forBeatUnit: 4)).tag($0) }
            }
            .onChange(of: viewModel.subdivision) { _, _ in viewModel.updateAudioSettings() }
            Picker("训练模式", selection: $viewModel.rhythmMode) {
                ForEach(RhythmMode.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: viewModel.rhythmMode) { _, _ in viewModel.updateAudioSettings() }
            Stepper(
                "每小节 \(viewModel.beatsPerMeasure) 拍",
                value: Binding(
                    get: { viewModel.beatsPerMeasure },
                    set: { viewModel.setMeter(beats: $0) }
                ),
                in: 1...16
            )
            TextField("拍子分组，例如 2+2+3", text: $groupingInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if !viewModel.setBeatGrouping(groupingInput) {
                        groupingInput = viewModel.beatGrouping.map(String.init).joined(separator: "+")
                    }
                }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(viewModel.beatAccents.indices, id: \.self) { index in
                        Button("\(index + 1) \(viewModel.beatAccents[index].label)") {
                            viewModel.cycleAccent(at: index)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            Text("节拍器音量")
            Slider(
                value: Binding(
                    get: { Double(viewModel.metronomeVolume) },
                    set: { viewModel.metronomeVolume = Float($0); viewModel.updateAudioSettings() }
                ),
                in: 0...1
            )
        }
    }

    @ViewBuilder
    private var pdfAlignmentSection: some View {
        if viewModel.audioFileName != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("伴奏与节拍器对齐").font(.headline)
                Text("默认第 1 拍从伴奏开头开始，也可以把当前播放位置设为第 1 拍。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("伴奏开头＝第1拍", action: viewModel.setBeatOneAtAudioStart)
                Button("当前位置＝第1拍", action: viewModel.setBeatOneAtCurrentPosition)
                Text("第 1 拍位置：\(format(viewModel.beatOffset ?? 0))")
                    .monospacedDigit()
                Text("微调 \(Int(viewModel.synchronizationOffset * 1_000)) ms")
                HStack {
                    ForEach([-10, -5, -1, 1, 5, 10], id: \.self) { value in
                        Button(value > 0 ? "+\(value)" : "\(value)") {
                            viewModel.synchronizationOffset += Double(value) / 1_000
                            viewModel.updateAudioSettings()
                        }
                    }
                }
            }
        }
    }

    private var pdfSoundAndStatsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "练习 \(Int(viewModel.accumulatedPracticeTime / 60)) 分钟 · "
                    + "累计循环 \(viewModel.totalCompletedLoops) 轮 · "
                    + "最高 \(Int((viewModel.highestPlaybackRate * 100).rounded()))%"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var autoFollowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("自动跟谱").font(.headline)
            Text("已保存 \(viewModel.readingPoints.count) 个位置点")
                .foregroundStyle(.secondary)
            if viewModel.isRecordingReadingTrack {
                Button("结束并保存记录", action: viewModel.finishReadingTrackRecording)
            } else {
                Button(
                    viewModel.readingPoints.isEmpty ? "开始记录" : "重新记录",
                    action: viewModel.startReadingTrackRecording
                )
            }
            if !viewModel.readingPoints.isEmpty {
                Button(
                    viewModel.isAutoFollowing ? "关闭自动跟谱" : "启动自动跟谱",
                    action: viewModel.toggleAutoFollow
                )
                Button("删除轨迹", role: .destructive, action: viewModel.deleteReadingTrack)
            }
        }
    }

    private var readingButtonTitle: String {
        if viewModel.isRecordingReadingTrack { return "结束记录" }
        if viewModel.autoFollowSuspended { return "继续跟谱" }
        if viewModel.isAutoFollowing { return "跟谱中" }
        return "跟谱"
    }

    private func handleReadingButton() {
        if viewModel.isRecordingReadingTrack {
            viewModel.finishReadingTrackRecording()
        } else if viewModel.autoFollowSuspended {
            viewModel.resumeAutoFollow()
        } else if viewModel.readingPoints.isEmpty {
            viewModel.startReadingTrackRecording()
        } else {
            viewModel.toggleAutoFollow()
        }
    }

    private func openPdf(_ url: URL) {
        if viewModel.openPdf(at: url) {
            recentProjects.opened(kind: .pdf, fileName: url.lastPathComponent)
            revealControls()
        } else {
            recentProjects.remove(kind: .pdf, fileName: url.lastPathComponent)
        }
    }

    private func handleDeletedPdf(_ url: URL) {
        guard viewModel.pdfWasDeleted(at: url) else { return }
        withAnimation {
            expandedControls = false
            controlsVisible = true
        }
    }

    private func revealControls() {
        withAnimation { controlsVisible = true }
    }

    private func openPracticePanel() {
        withAnimation {
            controlsVisible = false
            expandedControls = true
        }
    }

    private func closePracticePanel() {
        withAnimation {
            expandedControls = false
            controlsVisible = true
        }
    }

    private func format(_ seconds: TimeInterval) -> String {
        let safe = max(0, Int(seconds))
        return String(format: "%02d:%02d", safe / 60, safe % 60)
    }
}
