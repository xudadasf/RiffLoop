import Combine
import Foundation
import AVFoundation
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
    @Published private(set) var isStandaloneMetronomePlaying = false
    @Published private(set) var standaloneBpm = 120.0
    @Published private(set) var standaloneBeatsPerMeasure = 4
    @Published private(set) var standaloneVolume = 1.0
    @Published private(set) var standaloneSubdivisionFactor = 1
    @Published private(set) var standaloneBeatAccents: [GpBeatAccent] = [.strong, .normal, .normal, .normal]
    private let standaloneMetronome = MetronomeEngine()
    @Published private(set) var selectedBar: GpBarHit?
    @Published private(set) var loopRange: GpLoopBarRange?
    @Published private(set) var loopPreview: GpLoopBarRange?
    @Published private(set) var loopSelectionMessage: String?
    @Published private(set) var scoreZoom = 1.0
    @Published private(set) var playbackSpeed = 1.0
    @Published private(set) var baseBpm = 120.0
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
    @Published private(set) var countInAccents = defaultGpBeatAccents(beatsPerMeasure: 4)
    @Published private(set) var countInEnabled = false
    var countInVolume: Double { metronomeVolume }
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
    @Published private(set) var backingDiagnosticLines: [String] = []
    @Published private(set) var backingProbeDiagnostic: String?

    var currentSpeedLadderRound: Int {
        speedLadderRoundInProgress(
            completedLoops: completedLoops,
            loopsPerStep: loopsPerSpeedStep
        )
    }

    var originalBaseBpm: Double {
        guard let bpm = score?.initialBpm, bpm.isFinite, bpm > 0 else { return 120 }
        return bpm
    }

    var customBpmRange: ClosedRange<Double> {
        gpCustomBaseBpmRange(originalBpm: originalBaseBpm)
    }

    var practiceSpeedRange: ClosedRange<Double> {
        gpPracticeSpeedRange(originalBpm: originalBaseBpm, baseBpm: baseBpm)
    }

    var practiceStartBpm: Double { baseBpm * playbackSpeed }

    func setPracticeStartBpm(_ bpm: Double) {
        guard bpm.isFinite else { return }
        playbackSpeed = 1
        setBaseBpm(bpm)
        if speedLadderEnabled { speedLadderBaseSpeed = 1 }
        speedLadderTarget = min(practiceSpeedRange.upperBound, max(speedLadderTarget, 1))
        saveProfile()
    }

    var currentBpm: Double {
        gpScaledCurrentBpm(
            originalTempo: position.originalTempo ?? originalBaseBpm,
            originalBaseBpm: originalBaseBpm,
            baseBpm: baseBpm,
            practiceMultiplier: playbackSpeed
        )
    }

    private var effectivePlaybackSpeed: Double {
        gpEffectivePlaybackSpeed(
            originalBaseBpm: originalBaseBpm,
            baseBpm: baseBpm,
            practiceMultiplier: playbackSpeed
        )
    }

    private var reproductionLoad: String?
    private weak var webView: WKWebView?
    private var pendingScoreData: Data?
    private var didSendSoundFont = false
    private var loopSelection = GpLoopSelectionStateMachine()
    private let settingsStore: FilePracticeSettingsStore
    private var currentFileName: String?
    private var pendingProfile = GpPracticeProfile()
    private var didApplyPendingProfile = false
    private var playbackStartedAt: Date?
    private var pendingResumeTick: Double?
    private var lastProfileSaveDate = Date.distantPast
    private let nativeBackingPlayer = GpNativeBackingPlayer()
    private var nativeBackingPlaybackRequested = false
    private var nativeBackingStarted = false
    private var nativeBackingAnchorMilliseconds = 0.0
    private var nativeBackingSyncPoints: [GpBackingSyncPoint] = []
    private var speedLadderBaseSpeed: Double?
    private let interruptionRecovery = AudioInterruptionRecovery()
    private var audioObservers = Set<AnyCancellable>()
    private var recoveryAttempts = 0
    private var recoveryTask: Task<Void, Never>?
    private var webContentRequiresReloadOnNextScore = false
    private var sceneActive = true

    init(settingsStore: FilePracticeSettingsStore = FilePracticeSettingsStore()) {
        self.settingsStore = settingsStore
        interruptionRecovery.onBegan = { [weak self] in
            guard let self, self.isPlaying || self.isStandaloneMetronomePlaying else { return nil }
            let standalone = self.isStandaloneMetronomePlaying
            ReproductionStore.shared.record("incident", "gp.audio_interrupted", ["reason": "session_interruption"])
            self.pause()
            return { [weak self] in
                guard let self, self.sceneActive, self.playerReady else { return }
                if standalone { self.startStandaloneMetronome() } else { self.togglePlayback() }
            }
        }
        interruptionRecovery.onDisconnect = { [weak self] in
            self?.handleAudioRouteChange(reason: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue)
        }
        NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recoverWebContent() }
            .store(in: &audioObservers)
    }

    func handleAudioRouteChange(reason: UInt) {
        if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
            interruptionRecovery.cancel()
            interruptPlayback(reason: "output_disconnected")
        }
    }

    private func interruptPlayback(reason: String) {
        guard isPlaying || isStandaloneMetronomePlaying else { return }
        ReproductionStore.shared.record("incident", "gp.audio_interrupted", ["reason": reason])
        pause()
    }

    func recoverWebContent() {
        interruptionRecovery.cancel()
        stopStandaloneMetronome()
        recoveryTask?.cancel()
        recoveryTask = nil
        updatePracticeClock(isPlaying: false)
        nativeBackingPlayer.reset()
        nativeBackingPlaybackRequested = false
        nativeBackingStarted = false
        isPlaying = false
        playerReady = false
        rendererReady = false
        didSendSoundFont = false
        webContentRequiresReloadOnNextScore = true
        guard recoveryAttempts < 1 else {
            errorMessage = "谱面进程再次中断，请重新打开文件。"
            return
        }
        recoveryAttempts += 1
        guard let currentFileName, webView != nil else { return }
        let url = RiffLoopDocumentStore().folderURL(for: .guitarPro).appendingPathComponent(currentFileName)
        recoveryTask = Task { [weak self] in
            do {
                let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
                guard !Task.isCancelled, let self, self.currentFileName == currentFileName else { return }
                self.recoveryTask = nil
                self.loadScore(data: data, fileName: currentFileName)
                self.recoveryAttempts = 1
            } catch {
                guard !Task.isCancelled else { return }
                self?.recoveryTask = nil
                self?.errorMessage = "谱面进程已中断，重新读取失败：\(error.localizedDescription)"
            }
        }
    }

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    func loadScore(data: Data, fileName: String) {
        interruptionRecovery.cancel()
        stopStandaloneMetronome()
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryAttempts = 0
        if let previous = reproductionLoad { ReproductionRecorder.shared.end(previous, result: "superseded_by_file_switch") }
        reproductionLoad = ReproductionRecorder.shared.begin("gp.load_until_player_ready", details: ["file": fileName])
        ReproductionStore.shared.update(["gp.loadID": reproductionLoad ?? ""])
        let input = RiffLoopDocumentStore().folderURL(for: .guitarPro).appendingPathComponent(fileName)
        ReproductionStore.shared.capture(input, role: "gp", loadedData: data)
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.loadScore", details: ["data": String(describing: data.count), "fileName": String(describing: fileName)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        if rendererReady { pause() }
        updatePracticeClock(isPlaying: false)
        saveProfile()
        isPlaying = false
        loopSelection = GpLoopSelectionStateMachine()
        nativeBackingPlayer.reset()
        nativeBackingPlaybackRequested = false
        nativeBackingStarted = false
        nativeBackingSyncPoints = []
        speedLadderBaseSpeed = nil
        currentFileName = fileName
        pendingProfile = (try? settingsStore.load(
            GpPracticeProfile.self,
            kind: .guitarPro,
            fileName: fileName
        )) ?? GpPracticeProfile()
        pendingResumeTick = pendingProfile.lastPositionTick.isFinite
            && pendingProfile.lastPositionTick > 0
            ? pendingProfile.lastPositionTick
            : nil
        lastProfileSaveDate = Date()
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
        baseBpm = 120
        completedLoops = 0
        sessionPracticeMilliseconds = 0
        selectedBar = nil
        loopRange = nil
        loopPreview = nil
        loopSelectionMessage = nil
        errorMessage = nil
        backingDiagnosticLines = []
        backingProbeDiagnostic = nil

        if webContentRequiresReloadOnNextScore, let webView {
            pendingScoreData = data
            webView.reload()
            return
        }
        guard rendererReady else {
            pendingScoreData = data
            return
        }
        sendScore(data)
    }

    func togglePlayback() {
        interruptionRecovery.cancel()
        stopStandaloneMetronome()
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.togglePlayback", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        guard playerReady else { return }
        if !isPlaying {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
                call("setOutputLatency", arguments: [session.outputLatency + session.ioBufferDuration])
            } catch {
                errorMessage = "音频输出暂不可用：\(error.localizedDescription)"
                return
            }
        }
        call("playPause")
    }

    func toggleStandaloneMetronome() {
        interruptionRecovery.cancel()
        if isStandaloneMetronomePlaying { stopStandaloneMetronome(); return }
        guard playerReady else { return }
        pause()
        startStandaloneMetronome()
    }

    private func startStandaloneMetronome() {
        do {
            let subdivision: Subdivision = switch standaloneSubdivisionFactor {
            case 2: .eighth
            case 4: .sixteenth
            case 8: .thirtySecond
            default: .quarter
            }
            let accents = (0..<standaloneBeatsPerMeasure).map { index in
                index < standaloneBeatAccents.count ? BeatAccent(rawValue: standaloneBeatAccents[index].rawValue) ?? .normal
                    : (index == 0 ? .strong : .normal)
            }
            try standaloneMetronome.synchronize(
                timeline: BeatTimeline(bpm: standaloneBpm, beatOffset: 0, subdivision: subdivision,
                    quarterNotesPerMeasure: standaloneBeatsPerMeasure, beatAccents: accents),
                anchor: TransportAnchor(mediaTime: 0,
                    hostTime: CMClockGetTime(CMClockGetHostTimeClock()).seconds + 0.1, mediaRate: 1),
                volume: Float(standaloneVolume))
            isStandaloneMetronomePlaying = true
            updatePracticeClock(isPlaying: true)
        } catch {
            standaloneMetronome.stop()
            updatePracticeClock(isPlaying: false)
            isStandaloneMetronomePlaying = false
            errorMessage = "独立节拍器启动失败：\(error.localizedDescription)"
        }
    }

    private func stopStandaloneMetronome() {
        guard isStandaloneMetronomePlaying else { return }
        standaloneMetronome.stop()
        isStandaloneMetronomePlaying = false
        updatePracticeClock(isPlaying: false)
    }

    func setStandaloneBpm(_ value: Double) {
        guard value.isFinite else { return }
        standaloneBpm = min(300, max(30, value.rounded()))
        if isStandaloneMetronomePlaying { startStandaloneMetronome() }
        saveProfile()
    }

    func setStandaloneBeats(_ value: Int) {
        standaloneBeatsPerMeasure = min(16, max(1, value))
        standaloneBeatAccents = (0..<standaloneBeatsPerMeasure).map { index in
            standaloneBeatAccents.indices.contains(index) ? standaloneBeatAccents[index] : (index == 0 ? .strong : .normal)
        }
        if isStandaloneMetronomePlaying { startStandaloneMetronome() }
        saveProfile()
    }

    func setStandaloneVolume(_ value: Double) {
        guard value.isFinite else { return }
        standaloneVolume = min(6, max(0, value))
        if isStandaloneMetronomePlaying { startStandaloneMetronome() }
        saveProfile()
    }

    func setStandaloneSubdivision(_ factor: Int) {
        guard [1, 2, 4, 8].contains(factor) else { return }
        standaloneSubdivisionFactor = factor
        if isStandaloneMetronomePlaying { startStandaloneMetronome() }
        saveProfile()
    }

    func cycleStandaloneAccent(at index: Int) {
        guard standaloneBeatAccents.indices.contains(index) else { return }
        standaloneBeatAccents[index] = standaloneBeatAccents[index].next
        if isStandaloneMetronomePlaying { startStandaloneMetronome() }
        saveProfile()
    }

    func leaveMode() {
        recoveryTask?.cancel()
        recoveryTask = nil
        pendingScoreData = nil
        if let operation = reproductionLoad {
            ReproductionRecorder.shared.end(operation, result: "cancelled: left_gp_mode")
            reproductionLoad = nil
        }
        pause()
        clearLoop()
        setWholeSongLoopingEnabled(false)
    }

    func pause() {
        interruptionRecovery.cancel()
        stopStandaloneMetronome()
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.pause", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        nativeBackingPlayer.pause()
        nativeBackingPlaybackRequested = false
        nativeBackingStarted = false
        isPlaying = false
        updatePracticeClock(isPlaying: false)
        call("pause")
    }

    func stop() {
        interruptionRecovery.cancel()
        stopStandaloneMetronome()
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.stop", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        nativeBackingPlayer.pause()
        nativeBackingPlaybackRequested = false
        nativeBackingStarted = false
        call("stop")
    }

    func seek(to tick: Double, userInitiated: Bool = false) {
        if userInitiated { interruptionRecovery.cancel() }
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.seek", details: ["tick": String(describing: tick)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        call("seekTick", arguments: [tick, userInitiated])
    }

    func setPlaybackSpeed(_ speed: Double) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.setPlaybackSpeed", details: ["speed": String(describing: speed)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        guard speed.isFinite else { return }
        playbackSpeed = min(max(speed, practiceSpeedRange.lowerBound), practiceSpeedRange.upperBound)
        if speedLadderEnabled {
            speedLadderBaseSpeed = playbackSpeed
        }
        speedLadderTarget = max(speedLadderTarget, playbackSpeed)
        completedLoops = 0
        highestPracticeSpeed = max(highestPracticeSpeed, playbackSpeed)
        applyEffectivePlaybackSpeed()
        saveProfile()
    }

    func setScoreZoom(_ value: Double) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.setScoreZoom", details: ["value": String(describing: value)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        scoreZoom = value.isFinite ? min(max((value * 10).rounded() / 10, 0.8), 1.5) : 1
        call("setScoreZoom", arguments: [scoreZoom])
        saveProfile()
    }

    func setBaseBpm(_ bpm: Double) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.setBaseBpm", details: ["bpm": String(describing: bpm)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        guard bpm.isFinite else { return }
        baseBpm = min(max(bpm.rounded(), customBpmRange.lowerBound), customBpmRange.upperBound)
        playbackSpeed = min(max(playbackSpeed, practiceSpeedRange.lowerBound), practiceSpeedRange.upperBound)
        if let speedLadderBaseSpeed {
            self.speedLadderBaseSpeed = min(max(speedLadderBaseSpeed, practiceSpeedRange.lowerBound), practiceSpeedRange.upperBound)
        }
        speedLadderTarget = min(max(speedLadderTarget, playbackSpeed), practiceSpeedRange.upperBound)
        completedLoops = 0
        applyEffectivePlaybackSpeed()
        saveProfile()
    }

    func resetBaseBpm() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.resetBaseBpm", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        baseBpm = originalBaseBpm
        completedLoops = 0
        applyEffectivePlaybackSpeed()
        saveProfile()
    }

    func showTracks(_ indices: [Int]) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.showTracks", details: ["indices": String(describing: indices)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        if let first = indices.first { displayedTrack = first }
        call("showTracks", arguments: [indices])
        saveProfile()
    }

    func setTrackMute(index: Int, muted: Bool) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.setTrackMute", details: ["index": String(describing: index), "muted": String(describing: muted)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        if muted { mutedTracks.insert(index) } else { mutedTracks.remove(index) }
        call("setTrackMute", arguments: [index, muted])
        saveProfile()
    }

    func setTrackSolo(index: Int, solo: Bool) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.setTrackSolo", details: ["index": String(describing: index), "solo": String(describing: solo)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
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
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.setTrackVolume", details: ["index": String(describing: index), "volume": String(describing: volume)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        trackVolumes[index] = min(max(volume, 0), 4)
        call("setTrackVolume", arguments: [index, trackVolumes[index] ?? 1])
        saveProfile()
    }

    func setMasterVolume(_ volume: Double) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.setMasterVolume", details: ["volume": String(describing: volume)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        masterVolume = min(max(volume, 0), 16)
        call("setMasterVolume", arguments: [masterVolume])
        saveProfile()
    }

    func setBackingVolume(_ volume: Double) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.setBackingVolume", details: ["volume": String(describing: volume)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        backingVolume = min(max(volume, 0), 4)
        nativeBackingPlayer.setVolume(backingVolume)
        call("setBackingVolume", arguments: [backingVolume])
        saveProfile()
    }

    func setSynthEnabled(_ enabled: Bool) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.setSynthEnabled", details: ["enabled": String(describing: enabled)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        synthEnabled = enabled
        call("setSynthEnabled", arguments: [enabled])
        saveProfile()
    }

    func setBackingEnabled(_ enabled: Bool) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.setBackingEnabled", details: ["enabled": String(describing: enabled)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        backingEnabled = enabled
        if !enabled {
            nativeBackingPlayer.pause()
            nativeBackingPlaybackRequested = false
            nativeBackingStarted = false
        }
        call("setBackingEnabled", arguments: [enabled])
        saveProfile()
    }

    func setMetronomeVolume(_ volume: Double) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.setMetronomeVolume", details: ["volume": String(describing: volume)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        metronomeVolume = min(max(volume, 0), 6)
        call("setMetronomeVolume", arguments: [metronomeEnabled ? metronomeVolume : 0])
        call("setCountInVolume", arguments: [effectiveCountInVolume])
        saveProfile()
    }

    func setMetronomeEnabled(_ enabled: Bool) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.setMetronomeEnabled", details: ["enabled": String(describing: enabled)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        metronomeEnabled = enabled
        if enabled, metronomeVolume == 0 { metronomeVolume = 0.85 }
        call("setMetronomeVolume", arguments: [enabled ? metronomeVolume : 0])
        call("setCountInVolume", arguments: [effectiveCountInVolume])
        saveProfile()
    }

    func cycleCountInAccent(at index: Int) {
        guard countInAccents.indices.contains(index) else { return }
        countInAccents[index] = countInAccents[index].next
        call("setCountInAccents", arguments: [countInAccents.map(\.rawValue)])
        saveProfile()
        ReproductionStore.shared.record("action", "gp.count_in_accent", ["beat": String(index), "accent": countInAccents[index].rawValue])
    }

    func setCountInEnabled(_ enabled: Bool) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.setCountInEnabled", details: ["enabled": String(describing: enabled)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        countInEnabled = enabled
        if enabled, metronomeVolume == 0 { setMetronomeVolume(0.85) }
        call("setCountInAccents", arguments: [countInAccents.map(\.rawValue)])
        call("setCountInVolume", arguments: [effectiveCountInVolume])
        saveProfile()
    }

    func setMetronomeSubdivisionFactor(_ factor: Int) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.setMetronomeSubdivisionFactor", details: ["factor": String(describing: factor)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        guard [1, 2, 4, 8].contains(factor), factor != metronomeSubdivisionFactor else { return }
        metronomeSubdivisionFactor = factor
        playerReady = false
        call("setMetronomeSubdivision", arguments: [factor])
        saveProfile()
    }

    func cycleBeatAccent(at index: Int) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.cycleBeatAccent", details: ["index": String(describing: index)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        guard beatAccents.indices.contains(index) else { return }
        beatAccents[index] = beatAccents[index].next
        call("setBeatAccents", arguments: [beatAccents.map(\.rawValue), true])
        saveProfile()
    }

    func setRangeLoopingEnabled(_ enabled: Bool) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.setRangeLoopingEnabled", details: ["enabled": String(describing: enabled)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        guard loopRange != nil else { return }
        if !enabled { restoreSpeedBeforeLadder() }
        rangeLoopingEnabled = enabled
        if enabled { wholeSongLoopingEnabled = false }
        completedLoops = 0
        call("setRangeLoopingEnabled", arguments: [enabled])
        call("setCountInAccents", arguments: [countInAccents.map(\.rawValue)])
        call("setCountInVolume", arguments: [effectiveCountInVolume])
        saveProfile()
    }

    func setWholeSongLoopingEnabled(_ enabled: Bool) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.setWholeSongLoopingEnabled", details: ["enabled": String(describing: enabled)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        if enabled { restoreSpeedBeforeLadder() }
        wholeSongLoopingEnabled = enabled
        if enabled { rangeLoopingEnabled = false }
        completedLoops = 0
        call("setWholeSongLoopingEnabled", arguments: [enabled])
        call("setCountInAccents", arguments: [countInAccents.map(\.rawValue)])
        call("setCountInVolume", arguments: [effectiveCountInVolume])
        saveProfile()
    }

    func setLoopCountInEnabled(_ enabled: Bool) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.setLoopCountInEnabled", details: ["enabled": String(describing: enabled)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        loopCountInEnabled = enabled
        if enabled, metronomeVolume == 0 { setMetronomeVolume(0.85) }
        call("setLoopCountInEnabled", arguments: [enabled])
        call("setCountInAccents", arguments: [countInAccents.map(\.rawValue)])
        call("setCountInVolume", arguments: [effectiveCountInVolume])
        saveProfile()
    }

    func setSpeedLadderEnabled(_ enabled: Bool) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.setSpeedLadderEnabled", details: ["enabled": String(describing: enabled)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        guard speedLadderEnabled != enabled else { return }
        if enabled {
            speedLadderBaseSpeed = playbackSpeed
            speedLadderTarget = max(speedLadderTarget, playbackSpeed)
            speedLadderEnabled = true
        } else {
            restoreSpeedBeforeLadder()
        }
        completedLoops = 0
        saveProfile()
    }

    func setSpeedLadderTarget(_ target: Double) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.setSpeedLadderTarget", details: ["target": String(describing: target)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        speedLadderTarget = min(max(target, playbackSpeed), practiceSpeedRange.upperBound)
        completedLoops = 0
        saveProfile()
    }

    func setLoopsPerSpeedStep(_ loops: Int) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.setLoopsPerSpeedStep", details: ["loops": String(describing: loops)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        loopsPerSpeedStep = min(max(loops, 1), 10)
        completedLoops = 0
        saveProfile()
    }

    func setSpeedLadderStep(_ step: Double) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.setSpeedLadderStep", details: ["step": String(describing: step)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        speedLadderStep = min(max(step, 0.01), 0.25)
        completedLoops = 0
        saveProfile()
    }

    func clearLoop() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.clearLoop", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        restoreSpeedBeforeLadder()
        loopRange = nil
        loopPreview = nil
        loopSelectionMessage = nil
        rangeLoopingEnabled = false
        completedLoops = 0
        call("clearPlaybackRange")
        call("setCountInAccents", arguments: [countInAccents.map(\.rawValue)])
        call("setCountInVolume", arguments: [effectiveCountInVolume])
        saveProfile()
    }

    func setSceneActive(_ isActive: Bool) {
        if !isActive { interruptionRecovery.cancel(); stopStandaloneMetronome() }
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.setSceneActive", details: ["isActive": String(describing: isActive)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        if !isActive {
            nativeBackingPlayer.pause()
            nativeBackingPlaybackRequested = false
            nativeBackingStarted = false
            isPlaying = false
            updatePracticeClock(isPlaying: false)
            saveProfile()
        }
        sceneActive = isActive
        guard rendererReady else { return }
        call("lifecycle", arguments: [isActive])
    }

    func dismissError() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.dismissError", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        errorMessage = nil
    }

    func reportImportError(_ error: Error) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("gp.reportImportError", details: ["error": String(describing: error)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        errorMessage = "GP 导入失败：\(error.localizedDescription)"
    }

    func receive(_ event: GpBridgeEvent) {
        switch event {
        case .ready:
            webContentRequiresReloadOnNextScore = false
            rendererReady = true
            call("lifecycle", arguments: [sceneActive])
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
            if let operation = reproductionLoad { ReproductionRecorder.shared.end(operation, result: "player_ready_observed; correlate bridge generation") }
            reproductionLoad = nil
            playerReady = true
            // MIDI/player replacement can reset settings after scoreLoaded.
            applyPlayerSettings()
            if let pendingResumeTick {
                self.pendingResumeTick = nil
                seek(
                    to: gpResumeTick(
                        savedTick: pendingResumeTick,
                        loopRange: loopRange,
                        rangeLoopingEnabled: rangeLoopingEnabled
                    )
                )
            }
        case let .positionChanged(position):
            if position.isSeek != true && isPlaying { recoveryAttempts = 0 }
            self.position = position
            synchronizeNativeBacking(to: position)
            if
                pendingResumeTick == nil,
                playerReady,
                Date().timeIntervalSince(lastProfileSaveDate) >= 2
            {
                saveProfile()
            }
        case let .playerStateChanged(state):
            if isStandaloneMetronomePlaying {
                if state.state == 1 { call("pause") }
                return
            }
            isPlaying = state.state == 1 || state.transitioning == true
            if state.state == 1 {
                if !nativeBackingPlaybackRequested {
                    nativeBackingAnchorMilliseconds = position.currentTime
                    nativeBackingStarted = false
                }
                nativeBackingPlaybackRequested = true
            } else {
                nativeBackingPlaybackRequested = false
                nativeBackingStarted = false
                nativeBackingPlayer.pause()
            }
            updatePracticeClock(isPlaying: isPlaying)
        case .playerFinished:
            isPlaying = false
            nativeBackingPlaybackRequested = false
            nativeBackingStarted = false
            nativeBackingPlayer.pause()
            updatePracticeClock(isPlaying: false)
        case .rangeLoopCompleted:
            recordLoopCompletion()
        case let .backingAudioLoaded(audio):
            do {
                try nativeBackingPlayer.load(data: audio.data, mimeType: audio.mimeType)
                nativeBackingSyncPoints = audio.syncPoints
                nativeBackingPlayer.setRate(effectivePlaybackSpeed)
                nativeBackingPlayer.setVolume(backingVolume)
                appendNativeBackingDiagnostic(
                    String(
                        format: "native-loaded %@ bytes=%ld d=%.2f",
                        audio.mimeType,
                        audio.data.count,
                        nativeBackingPlayer.durationMilliseconds / 1_000
                    )
                )
            } catch {
                errorMessage = "内嵌伴奏原生加载失败：\(error.localizedDescription)"
                appendNativeBackingDiagnostic("native-load-failed \(error.localizedDescription)")
            }
        case let .barHit(bar):
            handle(loopSelection.tap(on: bar))
        case let .pointerDown(bar):
            handle(loopSelection.dragStart(on: bar))
        case let .pointerMove(bar):
            handle(loopSelection.dragUpdate(to: bar))
        case .pointerUp:
            handle(loopSelection.dragEnd())
        case .pointerCancel:
            handle(loopSelection.dragCancel())
        case let .diagnostic(message):
            let compactDiagnostic = compactBackingDiagnostic(message)
            if message.contains("\"stage\":\"typed-probe-") {
                backingProbeDiagnostic = compactDiagnostic
            }
            backingDiagnosticLines.append(compactDiagnostic)
            if backingDiagnosticLines.count > 12 {
                backingDiagnosticLines.removeFirst(backingDiagnosticLines.count - 12)
            }
            // The bridge already journals this event off the main thread. Synchronous
            // NSLog blocked scene updates in the 0.25.59 MetricKit watchdog report.
        case let .error(message):
            ReproductionStore.shared.record("incident", "gp.error", ["message": message])
            if let operation = reproductionLoad { ReproductionRecorder.shared.end(operation, result: "error: " + message) }
            reproductionLoad = nil
            errorMessage = message
        }
    }

    func receiveBridgeFailure(_ error: Error) {
        errorMessage = "GP 消息解析失败：\(error.localizedDescription)"
    }

    private func synchronizeNativeBacking(to position: GpPlaybackPosition) {
        guard nativeBackingPlayer.isLoaded else { return }
        guard let backingTime = gpBackingTime(
            forPlaybackTime: position.currentTime,
            playbackSpeed: effectivePlaybackSpeed,
            syncPoints: nativeBackingSyncPoints
        ) else { return }
        let isInsideBacking = backingTime >= 0
            && backingTime < nativeBackingPlayer.durationMilliseconds

        if !isInsideBacking {
            nativeBackingPlayer.pause()
            nativeBackingStarted = false
            return
        }
        guard nativeBackingPlaybackRequested, backingEnabled else { return }

        if !nativeBackingStarted {
            guard abs(position.currentTime - nativeBackingAnchorMilliseconds) >= 10 else { return }
            do {
                nativeBackingStarted = try nativeBackingPlayer.play(
                    at: backingTime,
                    rate: effectivePlaybackSpeed,
                    volume: backingVolume
                )
                appendNativeBackingDiagnostic(
                    String(
                        format: "native-play ok=%@ score=%.2f audio=%.2f rate=%.2f volume=%.2f",
                        nativeBackingStarted ? "true" : "false",
                        position.currentTime / 1_000,
                        backingTime / 1_000,
                        effectivePlaybackSpeed,
                        backingVolume
                    )
                )
            } catch {
                nativeBackingPlaybackRequested = false
                errorMessage = "内嵌伴奏原生播放失败：\(error.localizedDescription)"
                appendNativeBackingDiagnostic("native-play-failed \(error.localizedDescription)")
            }
            return
        }

        if position.isSeek == true {
            nativeBackingPlayer.seek(to: backingTime)
        }
    }

    private func appendNativeBackingDiagnostic(_ line: String) {
        backingDiagnosticLines.append(line)
        if backingDiagnosticLines.count > 12 {
            backingDiagnosticLines.removeFirst(backingDiagnosticLines.count - 12)
        }
        ReproductionStore.shared.record("event", "gp.native_audio", ["message": line])
    }

    private func compactBackingDiagnostic(_ message: String) -> String {
        guard
            let data = message.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data),
            let object = decoded as? [String: Any]
        else {
            return message
        }

        let stage = object["stage"] as? String ?? "unknown"
        let paused = object["paused"].map { String(describing: $0) } ?? "-"
        let ended = object["ended"].map { String(describing: $0) } ?? "-"
        let time = (object["currentTime"] as? NSNumber)?.doubleValue ?? 0
        let duration = (object["duration"] as? NSNumber)?.doubleValue ?? 0
        let readyState = object["readyState"].map { String(describing: $0) } ?? "-"
        let networkState = object["networkState"].map { String(describing: $0) } ?? "-"
        let mediaIndex = object["mediaIndex"].map { String(describing: $0) } ?? "-"
        let mediaCount = object["mediaCount"].map { String(describing: $0) } ?? "-"
        let volume = object["volume"].map { String(describing: $0) } ?? "-"
        let muted = object["muted"].map { String(describing: $0) } ?? "-"
        let masterVolume = object["masterVolume"].map { String(describing: $0) } ?? "-"
        let failure = object["rejection"] ?? object["thrown"] ?? object["error"]
        let failureText = failure.flatMap { value in
            value is NSNull ? nil : " err=\(String(describing: value))"
        } ?? ""
        return String(
            format: "%@ i=%@/%@ p=%@ e=%@ t=%.2f d=%.2f rs=%@ ns=%@ v=%@ m=%@ mv=%@%@",
            stage,
            mediaIndex,
            mediaCount,
            paused,
            ended,
            time,
            duration,
            readyState,
            networkState,
            volume,
            muted,
            masterVolume,
            failureText
        )
    }

    private func sendScore(_ data: Data) {
        call("prepareMetronomeSubdivision", arguments: [metronomeSubdivisionFactor])
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
            let tick = bar.seekTick ?? bar.startTick
            if rangeLoopingEnabled, let range = loopRange,
               !(range.startTick ..< range.endTick).contains(tick) {
                setRangeLoopingEnabled(false)
            }
            seek(to: tick, userInitiated: true)
        case let .selectStart(range):
            pause()
            restoreSpeedBeforeLadder()
            loopRange = nil
            loopPreview = range
            rangeLoopingEnabled = false
            wholeSongLoopingEnabled = false
            completedLoops = 0
            loopSelectionMessage = "已选起始音符 · 拖动选择终止音符，松手确认"
            call(
                "previewRange",
                arguments: [range.firstBar, range.lastBar, range.startTick, range.endTick]
            )
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case let .updatePreview(range):
            loopPreview = range
            call(
                "previewRange",
                arguments: [range.firstBar, range.lastBar, range.startTick, range.endTick]
            )
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
            call("setCountInAccents", arguments: [countInAccents.map(\.rawValue)])
            call("setCountInVolume", arguments: [effectiveCountInVolume])
            loopSelectionMessage = "已按音符循环第 \(range.firstBar + 1)–\(range.lastBar + 1) 小节内选定范围"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            saveProfile()
        case .cancelSelection:
            loopPreview = nil
            loopSelectionMessage = nil
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
        scoreZoom = pendingProfile.scoreZoom.isFinite ? min(max(pendingProfile.scoreZoom, 0.8), 1.5) : 1
        playbackSpeed = pendingProfile.playbackSpeed.isFinite ? pendingProfile.playbackSpeed : 1
        let bpmRange = gpCustomBaseBpmRange(originalBpm: metadata.initialBpm ?? 120)
        baseBpm = min(
            max(pendingProfile.baseBpm ?? metadata.initialBpm ?? 120, bpmRange.lowerBound),
            bpmRange.upperBound
        )
        playbackSpeed = min(max(playbackSpeed, practiceSpeedRange.lowerBound), practiceSpeedRange.upperBound)
        standaloneBpm = min(300, max(30, pendingProfile.standaloneBpm ?? 120))
        standaloneBeatsPerMeasure = min(16, max(1, pendingProfile.standaloneBeatsPerMeasure ?? 4))
        standaloneVolume = min(6, max(0, pendingProfile.standaloneVolume ?? 1))
        standaloneSubdivisionFactor = [1, 2, 4, 8].contains(pendingProfile.standaloneSubdivisionFactor ?? 1)
            ? (pendingProfile.standaloneSubdivisionFactor ?? 1) : 1
        let savedStandaloneAccents = pendingProfile.standaloneBeatAccents ?? []
        standaloneBeatAccents = (0..<standaloneBeatsPerMeasure).map { index in
            savedStandaloneAccents.indices.contains(index) ? savedStandaloneAccents[index] : (index == 0 ? .strong : .normal)
        }
        masterVolume = min(max(pendingProfile.masterVolume, 0), 16)
        backingVolume = min(max(pendingProfile.backingVolume, 0), 4)
        synthEnabled = pendingProfile.synthEnabled
        backingEnabled = pendingProfile.backingEnabled
        metronomeEnabled = pendingProfile.metronomeEnabled
        metronomeVolume = min(max(pendingProfile.metronomeVolume, 0), 6)
        countInAccents = (0..<max(1, metadata.beatsPerMeasure ?? 4)).map { index in
            pendingProfile.countInAccents.indices.contains(index) ? pendingProfile.countInAccents[index] : (index == 0 ? .strong : .normal)
        }
        countInEnabled = pendingProfile.countInEnabled
        metronomeSubdivisionFactor = [1, 2, 4, 8].contains(pendingProfile.metronomeSubdivisionFactor)
            ? pendingProfile.metronomeSubdivisionFactor
            : 1
        beatAccents = pendingProfile.beatAccents.isEmpty
            ? defaultGpBeatAccents(beatsPerMeasure: metadata.beatsPerMeasure ?? 4)
            : pendingProfile.beatAccents
        wholeSongLoopingEnabled = pendingProfile.wholeSongLoopingEnabled
        loopCountInEnabled = pendingProfile.loopCountInEnabled
        speedLadderEnabled = pendingProfile.speedLadderEnabled
        speedLadderTarget = min(max(pendingProfile.speedLadderTarget, playbackSpeed), practiceSpeedRange.upperBound)
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
        if speedLadderEnabled, rangeLoopingEnabled {
            speedLadderBaseSpeed = playbackSpeed
        } else {
            speedLadderEnabled = false
            speedLadderBaseSpeed = nil
        }

        applyCurrentSettings(to: metadata)
    }

    private func applyCurrentSettings(to metadata: GpScoreMetadata) {
        if beatAccents.isEmpty {
            beatAccents = defaultGpBeatAccents(beatsPerMeasure: metadata.beatsPerMeasure ?? 4)
        }
        call("setScoreZoom", arguments: [scoreZoom])
        call("showTracks", arguments: [[displayedTrack]])
        call("setBeatAccents", arguments: [beatAccents.map(\.rawValue)])
        applyPlayerSettings()
    }

    private func applyPlayerSettings() {
        call("setPlaybackSpeed", arguments: [effectivePlaybackSpeed])
        call("setMasterVolume", arguments: [masterVolume])
        call("setBackingVolume", arguments: [backingVolume])
        call("setSynthEnabled", arguments: [synthEnabled])
        call("setBackingEnabled", arguments: [backingEnabled])
        call("setMetronomeVolume", arguments: [metronomeEnabled ? metronomeVolume : 0])
        call("setLoopCountInEnabled", arguments: [loopCountInEnabled])
        call("setCountInAccents", arguments: [countInAccents.map(\.rawValue)])
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

    private func applyEffectivePlaybackSpeed() {
        let speed = effectivePlaybackSpeed
        nativeBackingPlayer.setRate(speed)
        call("setPlaybackSpeed", arguments: [speed])
    }

    private func restoreSpeedBeforeLadder() {
        let restoredSpeed = min(max(speedLadderBaseSpeed ?? playbackSpeed,
            practiceSpeedRange.lowerBound), practiceSpeedRange.upperBound)
        speedLadderEnabled = false
        speedLadderBaseSpeed = nil
        guard restoredSpeed != playbackSpeed else { return }
        playbackSpeed = restoredSpeed
        applyEffectivePlaybackSpeed()
    }

    private func recordLoopCompletion() {
        guard rangeLoopingEnabled, loopRange != nil else { return }
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
            applyEffectivePlaybackSpeed()
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
        // loadScore temporarily clears BPM and position before scoreLoaded applies
        // the saved profile. Scene/exit callbacks must never persist that placeholder.
        guard let currentFileName, didApplyPendingProfile else { return }
        try? settingsStore.save(
            GpPracticeProfile(
                standaloneBpm: standaloneBpm,
                standaloneBeatsPerMeasure: standaloneBeatsPerMeasure,
                standaloneVolume: standaloneVolume,
                standaloneSubdivisionFactor: standaloneSubdivisionFactor,
                standaloneBeatAccents: standaloneBeatAccents,
                scoreZoom: scoreZoom,
                playbackSpeed: playbackSpeed,
                baseBpm: baseBpm,
                lastPositionTick: pendingResumeTick ?? (position.currentTick.isFinite ? max(0, position.currentTick) : 0),
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
                countInAccents: countInAccents,
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
        lastProfileSaveDate = Date()
    }

    private func call(_ function: String, arguments: [Any] = []) {
        // Native cleanup still runs while WebContent is unavailable. Settings are
        // sent again by the ready/scoreLoaded flow once the replacement page exists.
        guard rendererReady else { return }
        // Binary load arguments are already preserved as material snapshots; never duplicate base64 in the journal.
        let safeArguments = function == "loadScore" || function == "loadSoundFont"
            ? "binary omitted; see materials" : String(describing: arguments)
        let operation = ReproductionRecorder.shared.begin("gp.command." + function, details: ["arguments": safeArguments, "loadID": reproductionLoad ?? "none"])
        guard let webView else {
            ReproductionRecorder.shared.end(operation, result: "not_dispatched: webview_missing")
            return
        }

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
                ReproductionRecorder.shared.end(operation, result: error?.localizedDescription ?? String(describing: result))
                Task { @MainActor [weak self] in
                    if let error {
                        ReproductionStore.shared.record("incident", "gp.command_failed", [
                            "command": function,
                            "message": error.localizedDescription,
                        ])
                        self?.errorMessage = "GP 命令 \(function) 执行失败：\(error.localizedDescription)"
                        return
                    }
                    guard
                        let result = result as? [String: Any],
                        result["ok"] as? Bool == false
                    else { return }
                    let message = result["message"] as? String ?? "未知 JavaScript 异常"
                    ReproductionStore.shared.record("incident", "gp.command_failed", [
                        "command": function,
                        "message": message,
                    ])
                    self?.errorMessage = "GP 命令 \(function) 执行失败：\(message)"
                }
            }
        } catch {
            ReproductionRecorder.shared.end(operation, result: "encoding_failed: " + error.localizedDescription)
            ReproductionStore.shared.record("incident", "gp.command_failed", [
                "command": function,
                "message": "编码失败：" + error.localizedDescription,
            ])
            errorMessage = "GP 命令 \(function) 编码失败：\(error.localizedDescription)"
        }
    }
    func reproductionSnapshot() {
        let store = ReproductionStore.shared
        var state: [String: String] = [:]
        state["gp.rendererReady"] = store.encoded(rendererReady)
        state["gp.playerReady"] = store.encoded(playerReady)
        state["gp.currentFileName"] = store.encoded(currentFileName)
        state["gp.position"] = store.encoded(position)
        state["gp.isPlaying"] = store.encoded(isPlaying)
        state["gp.scoreZoom"] = store.encoded(scoreZoom)
        state["gp.playbackSpeed"] = store.encoded(playbackSpeed)
        state["gp.baseBpm"] = store.encoded(baseBpm)
        state["gp.displayedTrack"] = store.encoded(displayedTrack)
        state["gp.mutedTracks"] = store.encoded(mutedTracks)
        state["gp.soloTrack"] = store.encoded(soloTrack)
        state["gp.trackVolumes"] = store.encoded(trackVolumes)
        state["gp.masterVolume"] = store.encoded(masterVolume)
        state["gp.backingVolume"] = store.encoded(backingVolume)
        state["gp.synthEnabled"] = store.encoded(synthEnabled)
        state["gp.backingEnabled"] = store.encoded(backingEnabled)
        state["gp.metronomeEnabled"] = store.encoded(metronomeEnabled)
        state["gp.metronomeVolume"] = store.encoded(metronomeVolume)
        state["gp.countInEnabled"] = store.encoded(countInEnabled)
        state["gp.countInVolume"] = store.encoded(countInVolume)
        state["gp.metronomeSubdivisionFactor"] = store.encoded(metronomeSubdivisionFactor)
        state["gp.beatAccents"] = store.encoded(beatAccents)
        state["gp.loopRange"] = store.encoded(loopRange)
        state["gp.loopPreview"] = store.encoded(loopPreview)
        state["gp.rangeLoopingEnabled"] = store.encoded(rangeLoopingEnabled)
        state["gp.wholeSongLoopingEnabled"] = store.encoded(wholeSongLoopingEnabled)
        state["gp.loopCountInEnabled"] = store.encoded(loopCountInEnabled)
        state["gp.speedLadderEnabled"] = store.encoded(speedLadderEnabled)
        state["gp.speedLadderTarget"] = store.encoded(speedLadderTarget)
        state["gp.loopsPerSpeedStep"] = store.encoded(loopsPerSpeedStep)
        state["gp.speedLadderStep"] = store.encoded(speedLadderStep)
        state["gp.completedLoops"] = store.encoded(completedLoops)
        state["gp.errorMessage"] = store.encoded(errorMessage)
        store.update(state)
    }

}
