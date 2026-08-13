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
    @Published private(set) var metronomeEnabled = false
    @Published private(set) var metronomeVolume = 0.0
    @Published private(set) var countInEnabled = false
    @Published private(set) var countInVolume = 0.0
    @Published private(set) var metronomeSubdivisionFactor = 1
    @Published private(set) var beatAccents = defaultGpBeatAccents(beatsPerMeasure: 4)
    @Published private(set) var rangeLoopingEnabled = true
    @Published private(set) var wholeSongLoopingEnabled = false
    @Published private(set) var loopCountInEnabled = false
    @Published private(set) var speedLadderEnabled = false
    @Published private(set) var speedLadderTarget = 1.0
    @Published private(set) var loopsPerSpeedStep = 3
    @Published private(set) var speedLadderStep = 0.05
    @Published private(set) var completedLoops = 0
    @Published private(set) var sessionPracticeMilliseconds: Int64 = 0
    @Published private(set) var totalPracticeMilliseconds: Int64 = 0
    @Published private(set) var totalCompletedLoops = 0
    @Published private(set) var highestPracticeSpeed = 1.0
    @Published private(set) var errorMessage: String?

    private weak var webView: WKWebView?
    private var pendingScoreData: Data?
    private var didSendSoundFont = false
    private var loopSelection = GpLoopSelectionStateMachine()
    private let settingsStore = FilePracticeSettingsStore()
    private var currentFileName: String?
    private var pendingProfile = GpPracticeProfile()
    private var didApplyPendingProfile = false
    private var previousPositionTick: Double?
    private var playbackStartedAt: Date?

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
        metronomeSubdivisionFactor = [1, 2, 4, 8].contains(pendingProfile.metronomeSubdivisionFactor)
            ? pendingProfile.metronomeSubdivisionFactor
            : 1
        beatAccents = pendingProfile.beatAccents.isEmpty
            ? defaultGpBeatAccents(beatsPerMeasure: 4)
            : pendingProfile.beatAccents
        didApplyPendingProfile = false
        score = nil
        playerReady = false
        position = GpPlaybackPosition(currentTime: 0, totalTime: 0, currentTick: 0, endTick: 0)
        previousPositionTick = nil
        completedLoops = 0
        sessionPracticeMilliseconds = 0
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
        highestPracticeSpeed = max(highestPracticeSpeed, playbackSpeed)
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
        call("setMetronomeVolume", arguments: [metronomeEnabled ? metronomeVolume : 0])
        saveProfile()
    }

    func setMetronomeEnabled(_ enabled: Bool) {
        metronomeEnabled = enabled
        if enabled, metronomeVolume == 0 { metronomeVolume = 0.85 }
        call("setMetronomeVolume", arguments: [enabled ? metronomeVolume : 0])
        saveProfile()
    }

    func setCountInVolume(_ volume: Double) {
        countInVolume = min(max(volume, 0), 1)
        call("setCountInVolume", arguments: [effectiveCountInVolume])
        saveProfile()
    }

    func setCountInEnabled(_ enabled: Bool) {
        countInEnabled = enabled
        if enabled, countInVolume == 0 { countInVolume = 0.85 }
        call("setCountInVolume", arguments: [effectiveCountInVolume])
        saveProfile()
    }

    func setMetronomeSubdivisionFactor(_ factor: Int) {
        guard [1, 2, 4, 8].contains(factor), factor != metronomeSubdivisionFactor else { return }
        metronomeSubdivisionFactor = factor
        playerReady = false
        call("setMetronomeSubdivision", arguments: [factor])
        saveProfile()
    }

    func cycleBeatAccent(at index: Int) {
        guard beatAccents.indices.contains(index) else { return }
        beatAccents[index] = beatAccents[index].next
        call("setBeatAccents", arguments: [beatAccents.map(\.rawValue)])
        saveProfile()
    }

    func setRangeLoopingEnabled(_ enabled: Bool) {
        guard loopRange != nil else { return }
        rangeLoopingEnabled = enabled
        if enabled { wholeSongLoopingEnabled = false }
        completedLoops = 0
        call("setRangeLoopingEnabled", arguments: [enabled])
        saveProfile()
    }

    func setWholeSongLoopingEnabled(_ enabled: Bool) {
        wholeSongLoopingEnabled = enabled
        if enabled { rangeLoopingEnabled = false }
        completedLoops = 0
        call("setWholeSongLoopingEnabled", arguments: [enabled])
        saveProfile()
    }

    func setLoopCountInEnabled(_ enabled: Bool) {
        loopCountInEnabled = enabled
        call("setCountInVolume", arguments: [effectiveCountInVolume])
        saveProfile()
    }

    func setSpeedLadderEnabled(_ enabled: Bool) {
        speedLadderEnabled = enabled
        completedLoops = 0
        saveProfile()
    }

    func setSpeedLadderTarget(_ target: Double) {
        speedLadderTarget = min(max(target, 0.5), 1.5)
        completedLoops = 0
        saveProfile()
    }

    func setLoopsPerSpeedStep(_ loops: Int) {
        loopsPerSpeedStep = min(max(loops, 1), 10)
        completedLoops = 0
        saveProfile()
    }

    func setSpeedLadderStep(_ step: Double) {
        speedLadderStep = min(max(step, 0.01), 0.25)
        completedLoops = 0
        saveProfile()
    }

    func clearLoop() {
        loopRange = nil
        loopPreview = nil
        rangeLoopingEnabled = false
        completedLoops = 0
        call("clearPlaybackRange")
        saveProfile()
    }

    func setSceneActive(_ isActive: Bool) {
        if !isActive { updatePracticeClock(isPlaying: false) }
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
            guard sendBundledSoundFont() else { return }
            if let pendingScoreData {
                self.pendingScoreData = nil
                sendScore(pendingScoreData)
            }
        case let .scoreLoaded(metadata):
            score = metadata
            if didApplyPendingProfile {
                applyCurrentSettings(to: metadata)
            } else {
                didApplyPendingProfile = true
                applyPendingProfile(to: metadata)
            }
        case let .renderFinished(metrics):
            renderMetrics = metrics
        case .playerReady:
            playerReady = true
        case let .positionChanged(position):
            recordLoopCompletionIfNeeded(position)
            self.position = position
            previousPositionTick = position.currentTick
        case let .playerStateChanged(state):
            isPlaying = state.state == 1
            updatePracticeClock(isPlaying: isPlaying)
        case .playerFinished:
            isPlaying = false
            updatePracticeClock(isPlaying: false)
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
        call("setMetronomeSubdivision", arguments: [metronomeSubdivisionFactor])
        call("setBeatAccents", arguments: [beatAccents.map(\.rawValue)])
        call("loadScore", arguments: [data.base64EncodedString()])
    }

    @discardableResult
    private func sendBundledSoundFont() -> Bool {
        guard !didSendSoundFont else { return true }
        guard
            let url = Bundle.main.url(
                forResource: "sonivox",
                withExtension: "sf3",
                subdirectory: "GpWeb/soundfont"
            ),
            let data = try? Data(contentsOf: url)
        else {
            errorMessage = "GP 音色资源缺失，请重新安装应用。"
            return false
        }

        didSendSoundFont = true
        call("loadSoundFont", arguments: [data.base64EncodedString()])
        return true
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
            rangeLoopingEnabled = true
            wholeSongLoopingEnabled = false
            completedLoops = 0
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
        metronomeEnabled = pendingProfile.metronomeEnabled
        metronomeVolume = min(max(pendingProfile.metronomeVolume, 0), 1)
        countInEnabled = pendingProfile.countInEnabled
        countInVolume = min(max(pendingProfile.countInVolume, 0), 1)
        metronomeSubdivisionFactor = [1, 2, 4, 8].contains(pendingProfile.metronomeSubdivisionFactor)
            ? pendingProfile.metronomeSubdivisionFactor
            : 1
        beatAccents = pendingProfile.beatAccents.isEmpty
            ? defaultGpBeatAccents(beatsPerMeasure: metadata.beatsPerMeasure ?? 4)
            : pendingProfile.beatAccents
        wholeSongLoopingEnabled = pendingProfile.wholeSongLoopingEnabled
        loopCountInEnabled = pendingProfile.loopCountInEnabled
        speedLadderEnabled = pendingProfile.speedLadderEnabled
        speedLadderTarget = min(max(pendingProfile.speedLadderTarget, 0.5), 1.5)
        loopsPerSpeedStep = min(max(pendingProfile.loopsPerSpeedStep, 1), 10)
        speedLadderStep = min(max(pendingProfile.speedLadderStep, 0.01), 0.25)
        totalPracticeMilliseconds = max(0, pendingProfile.totalPracticeMilliseconds)
        totalCompletedLoops = max(0, pendingProfile.totalCompletedLoops)
        highestPracticeSpeed = max(playbackSpeed, pendingProfile.highestPracticeSpeed)
        loopRange = pendingProfile.loopRange.flatMap { range in
            range.firstBar >= 0 && range.lastBar < metadata.bars && range.endTick > range.startTick
                ? range
                : nil
        }
        rangeLoopingEnabled = loopRange != nil
            && pendingProfile.rangeLoopingEnabled
            && !wholeSongLoopingEnabled

        applyCurrentSettings(to: metadata)
    }

    private func applyCurrentSettings(to metadata: GpScoreMetadata) {
        if beatAccents.isEmpty {
            beatAccents = defaultGpBeatAccents(beatsPerMeasure: metadata.beatsPerMeasure ?? 4)
        }
        call("showTracks", arguments: [[displayedTrack]])
        call("setBeatAccents", arguments: [beatAccents.map(\.rawValue)])
        call("setPlaybackSpeed", arguments: [playbackSpeed])
        call("setMasterVolume", arguments: [masterVolume])
        call("setBackingVolume", arguments: [backingVolume])
        call("setSynthEnabled", arguments: [synthEnabled])
        call("setBackingEnabled", arguments: [backingEnabled])
        call("setMetronomeVolume", arguments: [metronomeEnabled ? metronomeVolume : 0])
        call("setCountInVolume", arguments: [effectiveCountInVolume])
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
            call("setRangeLoopingEnabled", arguments: [rangeLoopingEnabled])
        } else {
            rangeLoopingEnabled = false
        }
        call("setWholeSongLoopingEnabled", arguments: [wholeSongLoopingEnabled])
    }

    private var effectiveCountInVolume: Double {
        countInEnabled || (rangeLoopingEnabled && loopCountInEnabled) ? countInVolume : 0
    }

    private func recordLoopCompletionIfNeeded(_ newPosition: GpPlaybackPosition) {
        guard
            newPosition.isSeek != true,
            rangeLoopingEnabled,
            let range = loopRange,
            let previousPositionTick
        else { return }

        let loopLength = range.endTick - range.startTick
        guard
            loopLength > 0,
            previousPositionTick >= range.startTick + loopLength * 0.75,
            newPosition.currentTick <= range.startTick + loopLength * 0.25
        else { return }

        let update = speedAfterCompletedLoop(
            currentSpeed: playbackSpeed,
            targetSpeed: speedLadderTarget,
            previousCompletedLoops: completedLoops,
            enabled: speedLadderEnabled,
            loopsPerStep: loopsPerSpeedStep,
            speedStep: speedLadderStep
        )
        completedLoops = update.completedLoops
        totalCompletedLoops += 1
        if update.playbackSpeed != playbackSpeed {
            playbackSpeed = update.playbackSpeed
            highestPracticeSpeed = max(highestPracticeSpeed, playbackSpeed)
            call("setPlaybackSpeed", arguments: [playbackSpeed])
        }
        if loopCountInEnabled {
            call("restartRangeWithCountIn")
        }
        saveProfile()
    }

    private func updatePracticeClock(isPlaying: Bool) {
        if isPlaying {
            if playbackStartedAt == nil { playbackStartedAt = Date() }
            return
        }
        guard let playbackStartedAt else { return }
        let elapsed = Int64(max(0, Date().timeIntervalSince(playbackStartedAt) * 1_000))
        self.playbackStartedAt = nil
        sessionPracticeMilliseconds += elapsed
        totalPracticeMilliseconds += elapsed
        saveProfile()
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
                metronomeEnabled: metronomeEnabled,
                metronomeVolume: metronomeVolume,
                countInEnabled: countInEnabled,
                countInVolume: countInVolume,
                metronomeSubdivisionFactor: metronomeSubdivisionFactor,
                beatAccents: beatAccents,
                rangeLoopingEnabled: rangeLoopingEnabled,
                wholeSongLoopingEnabled: wholeSongLoopingEnabled,
                loopCountInEnabled: loopCountInEnabled,
                speedLadderEnabled: speedLadderEnabled,
                speedLadderTarget: speedLadderTarget,
                loopsPerSpeedStep: loopsPerSpeedStep,
                speedLadderStep: speedLadderStep,
                totalPracticeMilliseconds: totalPracticeMilliseconds,
                totalCompletedLoops: totalCompletedLoops,
                highestPracticeSpeed: highestPracticeSpeed
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
