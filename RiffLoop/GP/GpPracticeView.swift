import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct GpPracticeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = GpWebViewModel()
    @State private var isImporterPresented = false
    @State private var speed = 1.0

    private let supportedExtensions = Set(["gp", "gpx", "gp3", "gp4", "gp5"])
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

            controls
                .frame(width: 300)
                .background(Color(white: 0.08))
        }
        .navigationTitle("Guitar Pro 练习")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("导入") { isImporterPresented = true }
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            importScore(from: url)
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
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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

                Picker("速度", selection: $speed) {
                    ForEach(speeds, id: \.self) { value in
                        Text(String(format: "%.2g×", value)).tag(value)
                    }
                }
                .onChange(of: speed) { _, value in
                    viewModel.setPlaybackSpeed(value)
                }
                .disabled(!viewModel.playerReady)

                if let score = viewModel.score {
                    Divider()
                    Text("轨道")
                        .font(.headline)
                    ForEach(score.tracks, id: \.index) { track in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.name)
                            Text("音量 \(track.volume) · \(track.isMute ? "静音" : "发声")\(track.isSolo ? " · 独奏" : "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(16)
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
            if let selectedBar = viewModel.selectedBar {
                Text("命中第 \(selectedBar.index + 1) 小节 · \(Int(selectedBar.startTick))–\(Int(selectedBar.endTick)) tick")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(viewModel.playerReady ? "离线渲染与播放器已就绪" : "正在准备离线渲染/音色…")
                .font(.caption)
                .foregroundStyle(viewModel.playerReady ? .green : .secondary)
        }
    }

    private func importScore(from url: URL) {
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
            viewModel.reportImportError(ImportError.unsupportedExtension)
            return
        }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        do {
            viewModel.loadScore(data: try Data(contentsOf: url))
        } catch {
            viewModel.reportImportError(error)
        }
    }

    private func format(_ milliseconds: Double) -> String {
        let totalSeconds = max(0, Int(milliseconds / 1_000))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private enum ImportError: LocalizedError {
    case unsupportedExtension

    var errorDescription: String? {
        "请选择 .gp、.gpx、.gp3、.gp4 或 .gp5 文件。"
    }
}
