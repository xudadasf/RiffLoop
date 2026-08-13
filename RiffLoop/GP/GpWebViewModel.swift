import Combine
import Foundation
import UIKit
import WebKit

@MainActor
final class GpWebViewModel: ObservableObject {
    @Published private(set) var rendererReady = false
    @Published private(set) var playerReady = false
    @Published private(set) var score: GpScoreMetadata?
    @Published private(set) var renderMetrics: GpRenderMetrics?
    @Published private(set) var position = GpPlaybackPosition(
        currentTime: 0,
        totalTime: 0,
        currentTick: 0,
        endTick: 0
    )
    @Published private(set) var isPlaying = false
    @Published private(set) var selectedBar: GpBarHit?
    @Published private(set) var loopRange: GpLoopBarRange?
    @Published private(set) var loopPreview: GpLoopBarRange?
    @Published private(set) var playbackSpeed = 1.0
    @Published private(set) var displayedTrack = 0
    @Published private(set) var mutedTracks = Set<Int>()
    @Published private(set) var soloTrack: Int?
    @Published private(set) var trackVolumes: [Int: Double] = [:]
    @Published private(set) var masterVolume = 0.75
    @Published private(set) var backingVolume = 0.75
    @Published private(set) var synthEnabled = true
    @Published private(set) var backingEnabled = true
    @Published private(set) var metronomeVolume = 0.0
    @Published private(set) var countInVolume = 0.0
    @Published private(set) var errorMessage: String?

    private weak var webView: WKWebView?
    private var pendingScoreData: Data?
    private var loopSelection = GpLoopSelectionStateMachine()
    private let settingsStore = FilePracticeSettingsStore()
    private var currentFileName: String?
    private var pendingProfile = GpPracticeProfile()

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    func loadScore(data: Data, fileName: String) {
        currentFileName = fileName
        pendingProfile = (try? settingsStore.load(
            GpPracticeProfile.self,
            kind: .guitarPro,
            fileName: fileName
        )) ?? GpPracticeProfile()
        score = nil
        playerReady = false
        position = GpPlaybackPosition(currentTime: 0, totalTime: 0, currentTick: 0, endTick: 0)
        selectedBar = nil
        errorMessage = nil

        guard rendererReady else {
            pendingScoreData = data
            return
        }
        sendScore(data)
    }

    func togglePlayback() {
        call("playPause")
    }

    func pause() {
        call("pause")
    }

    func stop() {
        call("stop")
    }

    func seek(to tick: Double) {
        call("seekTick", arguments: [tick])
    }

    func setPlaybackSpeed(_ speed: Double) {
        playbackSpeed = min(max(speed, 0.5), 1.5)
        call("setPlaybackSpeed", arguments: [playbackSpeed])
        saveProfile()
    }

    func showTracks(_ indices: [Int]) {
        if let first = indices.first { displayedTrack = first }
        call("showTracks", arguments: [indices])
        saveProfile()
    }

    func setTrackMute(index: Int, muted: Bool) {
        if muted { mutedTracks.insert(index) } else { mutedTracks.remove(index) }
        call("setTrackMute", arguments: [index, muted])
        saveProfile()
    }

    func setTrackSolo(index: Int, solo: Bool) {
        if solo {
            if let previous = soloTrack, previous != index {
                call("setTrackSolo", arguments: [previous, false])
            }
            soloTrack = index
        } else if soloTrack == index {
            soloTrack = nil
        }
        call("setTrackSolo", arguments: [index, solo])
        saveProfile()
    }

    func setTrackVolume(index: Int, volume: Double) {
        trackVolumes[index] = min(max(volume, 0), 1)
        call("setTrackVolume", arguments: [index, trackVolumes[index] ?? 1])
        saveProfile()
    }

    func setMasterVolume(_ volume: Double) {
        masterVolume = min(max(volume, 0), 1)
        call("setMasterVolume", arguments: [masterVolume])
        saveProfile()
    }

    func setBackingVolume(_ volume: Double) {
        backingVolume = min(max(volume, 0), 1)
        call("setBackingVolume", arguments: [backingVolume])
        saveProfile()
    }

    func setSynthEnabled(_ enabled: Bool) {
        synthEnabled = enabled
        call("setSynthEnabled", arguments: [enabled])
        saveProfile()
    }

    func setBackingEnabled(_ enabled: Bool) {
        backingEnabled = enabled
        call("setBackingEnabled", arguments: [enabled])
        saveProfile()
    }

    func setMetronomeVolume(_ volume: Double) {
        metronomeVolume = min(max(volume, 0), 1)
        call("setMetronomeVolume", arguments: [metronomeVolume])
        saveProfile()
    }

    func setCountInVolume(_ volume: Double) {
        countInVolume = min(max(volume, 0), 1)
        call("setCountInVolume", arguments: [countInVolume])
        saveProfile()
    }

    func clearLoop() {
        loopRange = nil
        loopPreview = nil
        call("clearPlaybackRange")
        saveProfile()
    }

    func setSceneActive(_ isActive: Bool) {
        call("lifecycle", arguments: [isActive])
    }

    func dismissError() {
        errorMessage = nil
    }

    func reportImportError(_ error: Error) {
        errorMessage = "GP 导入失败：\(error.localizedDescription)"
    }

    func receive(_ event: GpBridgeEvent) {
        switch event {
        case .ready:
            rendererReady = true
            if let pendingScoreData {
                self.pendingScoreData = nil
                sendScore(pendingScoreData)
            }
        case let .scoreLoaded(metadata):
            score = metadata
            applyPendingProfile(to: metadata)
        case let .renderFinished(metrics):
            renderMetrics = metrics
        case .playerReady:
            playerReady = true
        case let .positionChanged(position):
            self.position = position
        case let .playerStateChanged(state):
            isPlaying = state.state == 1
        case let .barHit(bar):
            selectedBar = bar
        case let .pointerDown(bar):
            handle(loopSelection.pointerDown(on: bar))
        case .longPress:
            handle(loopSelection.longPressActivated())
        case let .pointerMove(bar):
            handle(loopSelection.pointerMoved(to: bar))
        case .pointerUp:
            handle(loopSelection.pointerUp())
        case .pointerCancel:
            handle(loopSelection.cancel())
        case let .error(message):
            errorMessage = message
        }
    }

    func receiveBridgeFailure(_ error: Error) {
        errorMessage = "GP 消息解析失败：\(error.localizedDescription)"
    }

    private func sendScore(_ data: Data) {
        call("loadScore", arguments: [data.base64EncodedString()])
    }

    private func handle(_ action: GpLoopSelectionAction) {
        switch action {
        case .none:
            break
        case let .seek(bar):
            selectedBar = bar
            seek(to: bar.startTick)
        case .pauseForSelection:
            pause()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case let .preview(range):
            loopPreview = range
            call("previewRange", arguments: [range.firstBar, range.lastBar])
            UISelectionFeedbackGenerator().selectionChanged()
        case let .commit(range):
            loopPreview = nil
            loopRange = range
            call(
                "commitRange",
                arguments: [range.firstBar, range.lastBar, range.startTick, range.endTick]
            )
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            saveProfile()
        case .cancelSelection:
            loopPreview = nil
            call("cancelRangePreview")
        }
    }

    private func applyPendingProfile(to metadata: GpScoreMetadata) {
        let validTrackIndices = Set(metadata.tracks.map(\.index))
        displayedTrack = validTrackIndices.contains(pendingProfile.displayedTrack)
            ? pendingProfile.displayedTrack
            : (metadata.tracks.first?.index ?? 0)
        mutedTracks = pendingProfile.mutedTracks.intersection(validTrackIndices)
        soloTrack = pendingProfile.soloTrack.flatMap { validTrackIndices.contains($0) ? $0 : nil }
        trackVolumes = pendingProfile.trackVolumes.filter { validTrackIndices.contains($0.key) }
        playbackSpeed = min(max(pendingProfile.playbackSpeed, 0.5), 1.5)
        masterVolume = min(max(pendingProfile.masterVolume, 0), 1)
        backingVolume = min(max(pendingProfile.backingVolume, 0), 1)
        synthEnabled = pendingProfile.synthEnabled
        backingEnabled = pendingProfile.backingEnabled
        metronomeVolume = min(max(pendingProfile.metronomeVolume, 0), 1)
        countInVolume = min(max(pendingProfile.countInVolume, 0), 1)
        loopRange = pendingProfile.loopRange.flatMap { range in
            range.firstBar >= 0 && range.lastBar < metadata.bars && range.endTick > range.startTick
                ? range
                : nil
        }

        call("showTracks", arguments: [[displayedTrack]])
        call("setPlaybackSpeed", arguments: [playbackSpeed])
        call("setMasterVolume", arguments: [masterVolume])
        call("setBackingVolume", arguments: [backingVolume])
        call("setSynthEnabled", arguments: [synthEnabled])
        call("setBackingEnabled", arguments: [backingEnabled])
        call("setMetronomeVolume", arguments: [metronomeVolume])
        call("setCountInVolume", arguments: [countInVolume])
        for index in mutedTracks { call("setTrackMute", arguments: [index, true]) }
        if let soloTrack { call("setTrackSolo", arguments: [soloTrack, true]) }
        for (index, volume) in trackVolumes {
            call("setTrackVolume", arguments: [index, volume])
        }
        if let range = loopRange {
            call(
                "commitRange",
                arguments: [range.firstBar, range.lastBar, range.startTick, range.endTick]
            )
        }
    }

    private func saveProfile() {
        guard let currentFileName else { return }
        try? settingsStore.save(
            GpPracticeProfile(
                playbackSpeed: playbackSpeed,
                displayedTrack: displayedTrack,
                mutedTracks: mutedTracks,
                soloTrack: soloTrack,
                trackVolumes: trackVolumes,
                loopRange: loopRange,
                masterVolume: masterVolume,
                backingVolume: backingVolume,
                synthEnabled: synthEnabled,
                backingEnabled: backingEnabled,
                metronomeVolume: metronomeVolume,
                countInVolume: countInVolume
            ),
            kind: .guitarPro,
            fileName: currentFileName
        )
    }

    private func call(_ function: String, arguments: [Any] = []) {
        guard let webView else { return }

        do {
            let data = try JSONSerialization.data(withJSONObject: arguments)
            guard let json = String(data: data, encoding: .utf8) else { return }
            let functionData = try JSONSerialization.data(withJSONObject: [function])
            guard let functionJSON = String(data: functionData, encoding: .utf8) else { return }
            let script = """
                (() => {
                    const name = \(functionJSON)[0];
                    try {
                        const bridge = window.riffloop;
                        if (!bridge) {
                            return { ok: false, message: "window.riffloop 尚未加载" };
                        }
                        const command = bridge[name];
                        if (typeof command !== "function") {
                            return { ok: false, message: `命令不存在：${name}` };
                        }
                        command.apply(null, \(json));
                        return { ok: true };
                    } catch (error) {
                        return {
                            ok: false,
                            message: String(error?.stack || error?.message || error)
                        };
                    }
                })()
                """
            webView.evaluateJavaScript(script) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    if let error {
                        self?.errorMessage = "GP 命令 \(function) 执行失败：\(error.localizedDescription)"
                        return
                    }
                    guard
                        let result = result as? [String: Any],
                        result["ok"] as? Bool == false
                    else { return }
                    let message = result["message"] as? String ?? "未知 JavaScript 异常"
                    self?.errorMessage = "GP 命令 \(function) 执行失败：\(message)"
                }
            }
        } catch {
            errorMessage = "GP 命令 \(function) 编码失败：\(error.localizedDescription)"
        }
    }
}
