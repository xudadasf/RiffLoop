import Foundation
import SwiftUI

struct PdfPracticeView: View {
    @EnvironmentObject private var recentProjects: RecentProjectsStore
    @StateObject private var viewModel = PdfPracticeViewModel()
    @State private var pdfLibraryPresented = false
    @State private var audioLibraryPresented = false
    @State private var controlsVisible = true
    @State private var expandedControls = false
    @State private var didOpenInitialURL = false

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
                    requestedProgress: viewModel.requestedProgress,
                    onPageChanged: viewModel.setPage,
                    onProgressChanged: viewModel.setVerticalProgress,
                    onManualInteraction: {
                        revealControls()
                        viewModel.manualViewportInteraction()
                    }
                )
                .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView(
                    "选择 PDF 开始练习",
                    systemImage: "doc.richtext",
                    description: Text("文件保存在“在我的 iPad/RiffLoop/PDF”中。")
                )
            }

            if controlsVisible {
                overlayControls
                    .transition(.opacity)
            } else {
                Button("控制", action: revealControls)
                    .buttonStyle(.borderedProminent)
                    .tint(.black.opacity(0.72))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(8)
            }

            if expandedControls {
                practicePanel
                    .frame(width: 340)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .background(.black.opacity(0.94))
                    .transition(.move(edge: .trailing))
            }
        }
        .navigationTitle(viewModel.pdfFileName ?? "PDF 谱面")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $pdfLibraryPresented) {
            DocumentLibraryView(kind: .pdf, onSelect: openPdf)
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
        .onDisappear(perform: viewModel.pause)
    }

    private var overlayControls: some View {
        VStack {
            HStack {
                Button("文件") { pdfLibraryPresented = true }
                Spacer()
                Button("节拍器") { expandedControls = true }
            }
            Spacer()
            HStack(spacing: 10) {
                Button("上一页") { viewModel.setPage(viewModel.pageIndex - 1) }
                    .disabled(viewModel.pageIndex == 0)
                Button("−") { viewModel.setScale(viewModel.scaleFactor - 0.25) }
                Text("\(viewModel.pageIndex + 1)/\(max(1, viewModel.pageCount)) · \(Int(viewModel.scaleFactor * 100))%")
                    .monospacedDigit()
                Button("+") { viewModel.setScale(viewModel.scaleFactor + 0.25) }
                Button("下一页") { viewModel.setPage(viewModel.pageIndex + 1) }
                    .disabled(viewModel.pageIndex + 1 >= viewModel.pageCount)
                Spacer()
                Button(readingButtonTitle, action: handleReadingButton)
                Button(viewModel.isPlaying ? "暂停" : (viewModel.audioFileName == nil ? "开始节拍器" : "播放伴奏")) {
                    viewModel.togglePlayback()
                }
                Button("伴奏") { audioLibraryPresented = true }
                if viewModel.audioFileName != nil {
                    Button("移除", action: viewModel.removeAudio)
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(.black.opacity(0.72))
        .padding(8)
    }

    private var practicePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("练习控制").font(.title3.bold())
                    Spacer()
                    Button("关闭") {
                        expandedControls = false
                        revealControls()
                    }
                }

                Button(viewModel.isPlaying ? "暂停" : "播放", action: viewModel.togglePlayback)
                    .buttonStyle(.borderedProminent)
                Button("停止", action: viewModel.stop)

                Slider(
                    value: Binding(
                        get: { viewModel.currentTime },
                        set: { viewModel.seek(to: $0) }
                    ),
                    in: 0...max(viewModel.duration, 0.01)
                )
                Text("\(format(viewModel.currentTime)) / \(format(viewModel.duration))")
                    .monospacedDigit()

                HStack {
                    Button("Set A", action: viewModel.setPointA)
                    Button("Set B", action: viewModel.setPointB)
                    Toggle("Loop", isOn: $viewModel.loopEnabled)
                        .onChange(of: viewModel.loopEnabled) { _, _ in viewModel.updateAudioSettings() }
                }

                Stepper("BPM \(Int(viewModel.bpm))", value: $viewModel.bpm, in: 30...300)
                    .onChange(of: viewModel.bpm) { _, _ in viewModel.updateAudioSettings() }
                Toggle("节拍器", isOn: $viewModel.metronomeEnabled)
                    .onChange(of: viewModel.metronomeEnabled) { _, _ in viewModel.updateAudioSettings() }

                Text("伴奏音量")
                Slider(
                    value: Binding(
                        get: { Double(viewModel.audioVolume) },
                        set: { viewModel.audioVolume = Float($0); viewModel.updateAudioSettings() }
                    ),
                    in: 0...1
                )
                Text("节拍器音量")
                Slider(
                    value: Binding(
                        get: { Double(viewModel.metronomeVolume) },
                        set: { viewModel.metronomeVolume = Float($0); viewModel.updateAudioSettings() }
                    ),
                    in: 0...1
                )

                Text("同步 \(Int(viewModel.synchronizationOffset * 1_000)) ms")
                HStack {
                    ForEach([-10, -1, 1, 10], id: \.self) { value in
                        Button(value > 0 ? "+\(value)" : "\(value)") {
                            viewModel.synchronizationOffset += Double(value) / 1_000
                            viewModel.updateAudioSettings()
                        }
                    }
                }

                Divider()
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
            .padding(18)
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
        viewModel.openPdf(at: url)
        recentProjects.opened(kind: .pdf, fileName: url.lastPathComponent)
        revealControls()
    }

    private func revealControls() {
        withAnimation { controlsVisible = true }
    }

    private func format(_ seconds: TimeInterval) -> String {
        let safe = max(0, Int(seconds))
        return String(format: "%02d:%02d", safe / 60, safe % 60)
    }
}
