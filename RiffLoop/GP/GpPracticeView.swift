import Foundation
import SwiftUI

struct GpPracticeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var recentProjects: RecentProjectsStore
    @StateObject private var viewModel = GpWebViewModel()
    @State private var isLibraryPresented = false
    @State private var didOpenInitialURL = false

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

            controls
                .frame(width: 300)
                .background(Color(white: 0.08))
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

                Picker("速度", selection: Binding(
                    get: { viewModel.playbackSpeed },
                    set: { viewModel.setPlaybackSpeed($0) }
                )) {
                    ForEach(speeds, id: \.self) { value in
                        Text(String(format: "%.2g×", value)).tag(value)
                    }
                }
                .disabled(!viewModel.playerReady)

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
                }
                Text("随谱节拍器")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { viewModel.metronomeVolume },
                        set: { viewModel.setMetronomeVolume($0) }
                    ),
                    in: 0...1
                )
                Text("预备拍")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { viewModel.countInVolume },
                        set: { viewModel.setCountInVolume($0) }
                    ),
                    in: 0...1
                )

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
            if let range = viewModel.loopPreview ?? viewModel.loopRange {
                Text("第 \(range.firstBar + 1)–\(range.lastBar + 1) 小节\(viewModel.loopPreview == nil ? "已循环" : "选择中")")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                if viewModel.loopPreview == nil {
                    Button("清除循环", action: viewModel.clearLoop)
                        .buttonStyle(.bordered)
                }
            } else {
                Text("长按小节并拖动，松手设置完整小节循环")
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
}
