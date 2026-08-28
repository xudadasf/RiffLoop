import Foundation
import SwiftUI

private enum PdfControlPanel: String, Identifiable {
    case metronome
    case sound
    case follow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .metronome: "节拍器"
        case .sound: "伴奏"
        case .follow: "跟谱"
        }
    }

    var systemImage: String {
        switch self {
        case .metronome: "metronome"
        case .sound: "waveform"
        case .follow: "text.viewfinder"
        }
    }
}

struct PdfPracticeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var displayNames: DocumentDisplayNameStore
    @EnvironmentObject private var recentProjects: RecentProjectsStore
    @StateObject private var viewModel = PdfPracticeViewModel()
    @State private var pdfLibraryPresented = false
    @State private var audioLibraryPresented = false
    @State private var didOpenInitialURL = false
    @State private var groupingInput = "4"
    @State private var activePanel: PdfControlPanel?

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
                    onTap: { activePanel = nil },
                    onManualInteraction: viewModel.manualViewportInteraction
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
                playbackStateBadge
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
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
            if viewModel.document != nil {
                controlDeck
            }
        }
        .animation(.snappy, value: activePanel)
        .navigationTitle(pdfTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
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
        .onChange(of: viewModel.beatGrouping) { _, grouping in
            groupingInput = grouping.map(String.init).joined(separator: "+")
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

    private var playbackStateBadge: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(viewModel.isPlaying ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(viewModel.isPlaying ? "练习中 · \(speedLabel(viewModel.playbackRate))" : "已暂停")
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
                .frame(width: 172)

            pageAndProgressControls
                .frame(minWidth: 300, maxWidth: .infinity)

            Rectangle()
                .fill(Color(.separator))
                .frame(width: 1, height: 78)

            HStack(spacing: 8) {
                toolButton(.metronome, summary: metronomeSummary, detail: metronomeDetail)
                toolButton(.sound, summary: soundSummary, detail: soundDetail)
                toolButton(.follow, summary: followSummary, detail: followDetail)
            }
            .frame(maxWidth: 420)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var deckTransportControls: some View {
        HStack(spacing: 8) {
            Button(action: viewModel.toggleReadingFollowPlayback) {
                Label(
                    viewModel.isFollowingTransportActive ? "暂停跟谱" : "开始跟谱",
                    systemImage: viewModel.isFollowingTransportActive ? "pause.fill" : "play.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.hasUsableReadingTrack)

            Button(action: viewModel.stopReadingFollowPlayback) {
                Label("停止跟谱", systemImage: "stop.fill")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 32, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.hasUsableReadingTrack)
        }
    }

    private var pageAndProgressControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { changePage(by: -1) } label: {
                    Label("上一页", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                }
                .disabled(viewModel.pageIndex == 0)

                Text("第 \(viewModel.pageIndex + 1) / \(max(1, viewModel.pageCount)) 页")
                    .font(.caption.monospacedDigit().weight(.semibold))

                Button { changePage(by: 1) } label: {
                    Label("下一页", systemImage: "chevron.right")
                        .labelStyle(.iconOnly)
                }
                .disabled(viewModel.pageIndex + 1 >= viewModel.pageCount)

                Spacer()

                Button { changeScale(by: -0.25) } label: {
                    Label("缩小", systemImage: "minus.magnifyingglass")
                        .labelStyle(.iconOnly)
                }
                Text("\(Int((viewModel.scaleFactor * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { changeScale(by: 0.25) } label: {
                    Label("放大", systemImage: "plus.magnifyingglass")
                        .labelStyle(.iconOnly)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if viewModel.audioFileName != nil {
                HStack(spacing: 8) {
                    Text(format(viewModel.currentTime))
                        .font(.caption.monospacedDigit().weight(.semibold))
                    Slider(
                        value: Binding(
                            get: { viewModel.currentTime },
                            set: { viewModel.seek(to: $0) }
                        ),
                        in: 0...max(viewModel.duration, 0.01)
                    )
                    Text(format(viewModel.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("未绑定伴奏 · 可单独使用节拍器")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func toolButton(
        _ panel: PdfControlPanel,
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
    private func panelContent(_ panel: PdfControlPanel) -> some View {
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
                VStack(alignment: .leading, spacing: 18) {
                    switch panel {
                    case .metronome:
                        pdfMetronomeSection
                        Divider()
                        pdfAlignmentSection
                    case .sound:
                        pdfTransportSection
                    case .follow:
                        autoFollowSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .bottom])
            }
        }
        .background(Color(.systemGroupedBackground))
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

    private var autoFollowSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自动跟谱").font(.headline)
            Text("先开始记录，再点击下方播放；按演奏进度滚动和翻页，结束后即可按同一时间轴自动跟谱。")
                .font(.callout)
                .foregroundStyle(.secondary)

            if viewModel.isRecordingReadingTrack {
                Label("正在记录 · \(viewModel.readingPoints.count) 个位置点", systemImage: "record.circle")
                    .foregroundStyle(.red)
                Button("结束并保存记录", action: viewModel.finishReadingTrackRecording)
                    .buttonStyle(.borderedProminent)
            } else {
                if viewModel.readingPoints.isEmpty {
                    Button("开始记录", action: viewModel.startReadingTrackRecording)
                        .buttonStyle(.borderedProminent)
                } else {
                    Label(
                        viewModel.hasUsableReadingTrack
                            ? "轨迹已保存 · \(viewModel.readingPoints.count) 个位置点"
                            : "轨迹没有有效的时间变化",
                        systemImage: viewModel.hasUsableReadingTrack
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(viewModel.hasUsableReadingTrack ? Color.green : Color.orange)

                    if viewModel.autoFollowSuspended {
                        Button("继续跟谱", action: viewModel.resumeAutoFollow)
                            .buttonStyle(.borderedProminent)
                    } else if viewModel.isAutoFollowing {
                        Button("关闭自动跟谱", action: viewModel.toggleAutoFollow)
                    } else {
                        Button("从轨迹起点开始", action: viewModel.startAutoFollowFromBeginning)
                            .buttonStyle(.borderedProminent)
                            .disabled(!viewModel.hasUsableReadingTrack)
                    }

                    Toggle("循环跟谱", isOn: Binding(
                        get: { viewModel.followLoopEnabled },
                        set: { viewModel.setFollowLoopEnabled($0) }
                    ))
                    .disabled(!viewModel.hasUsableReadingTrack)

                    Divider()
                    Button("重新记录", action: viewModel.startReadingTrackRecording)
                    Button("删除轨迹", role: .destructive, action: viewModel.deleteReadingTrack)
                }
            }
        }
    }

    private var readingButtonTitle: String {
        if viewModel.isRecordingReadingTrack { return "结束记录" }
        if viewModel.autoFollowSuspended { return "继续跟谱" }
        if viewModel.isAutoFollowing { return "跟谱中" }
        return "跟谱"
    }

    private var pdfTitle: String {
        guard let fileName = viewModel.pdfFileName else { return "PDF 谱面" }
        return displayNames.displayName(for: .pdf, fileName: fileName)
    }

    private func openPdf(_ url: URL) {
        if viewModel.openPdf(at: url) {
            recentProjects.opened(kind: .pdf, fileName: url.lastPathComponent)
        } else {
            recentProjects.remove(kind: .pdf, fileName: url.lastPathComponent)
        }
    }

    private func handleDeletedPdf(_ url: URL) {
        guard viewModel.pdfWasDeleted(at: url) else { return }
        activePanel = nil
    }

    private func changePage(by offset: Int) {
        viewModel.manualViewportInteraction()
        viewModel.setPage(viewModel.pageIndex + offset)
    }

    private func changeScale(by offset: Double) {
        viewModel.manualViewportInteraction()
        viewModel.setScale(viewModel.scaleFactor + offset)
    }

    private var metronomeSummary: String {
        viewModel.metronomeEnabled ? "\(Int(viewModel.bpm.rounded())) BPM" : "节拍器关闭"
    }

    private var metronomeDetail: String {
        "\(viewModel.beatsPerMeasure)/4 · \(viewModel.rhythmMode.label)"
    }

    private var soundSummary: String {
        viewModel.audioFileName ?? "未绑定伴奏"
    }

    private var soundDetail: String {
        viewModel.audioFileName == nil
            ? "节拍器可独立练习"
            : "\(speedLabel(viewModel.playbackRate)) · 音量 \(Int((viewModel.audioVolume * 100).rounded()))%"
    }

    private var followSummary: String { readingButtonTitle }

    private var followDetail: String {
        "已保存 \(viewModel.readingPoints.count) 个位置点"
    }

    private func speedLabel(_ rate: Float) -> String {
        String(format: "%.2f×", rate)
    }

    private func format(_ seconds: TimeInterval) -> String {
        let safe = max(0, Int(seconds))
        return String(format: "%02d:%02d", safe / 60, safe % 60)
    }
}
