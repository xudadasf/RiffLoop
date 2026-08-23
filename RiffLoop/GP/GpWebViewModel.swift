import Combine
import Foundation
import AVFAudio
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
    @Published private(set) var loopSelectionMessage: String?
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
    @Published private(set) var backingDiagnosticLines: [String] = []
    @Published private(set) var backingProbeDiagnostic: String?

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
    private var pendingResumeTick: Double?
    private var lastProfileSaveDate = Date.distantPast
    private let nativeBackingPlayer = GpNativeBackingPlayer()
    private var nativeBackingPlaybackRequested = false
    private var nativeBackingStarted = false
    private var nativeBackingAnchorMilliseconds = 0.0
    private var nativeBackingSyncPoints: [GpBackingSyncPoint] = []

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    func loadScore(data: Data, fileName: String) {
        nativeBackingPlayer.reset()
        nativeBackingPlaybackRequested = false
        nativeBackingStarted = false
        nativeBackingSyncPoints = []
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
        previousPositionTick = nil
        completedLoops = 0
        sessionPracticeMilliseconds = 0
        selectedBar = nil
        loopRange = nil
        loopPreview = nil
        loopSelectionMessage = nil
        errorMessage = nil
        backingDiagnosticLines = []
        backingProbeDiagnostic = nil

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
        nativeBackingPlayer.pause()
        nativeBackingPlaybackRequested = false
        nativeBackingStarted = false
        call("pause")
    }

    func stop() {
        nativeBackingPlayer.pause()
        nativeBackingPlaybackRequested = false
        nativeBackingStarted = false
        call("stop")
    }

    func seek(to tick: Double) {
        call("seekTick", arguments: [tick])
    }

    func setPlaybackSpeed(_ speed: Double) {
        playbackSpeed = min(max(speed, 0.5), 1.5)
        speedLadderTarget = max(speedLadderTarget, playbackSpeed)
        completedLoops = 0
        nativeBackingPlayer.setRate(playbackSpeed)
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
        nativeBackingPlayer.setVolume(backingVolume)
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
        if !enabled {
            nativeBackingPlayer.pause()
            nativeBackingPlaybackRequested = false
            nativeBackingStarted = false
        }
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
        call("setBeatAccents", arguments: [beatAccents.map(\.rawValue), true])
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
        speedLadderTarget = min(max(target, playbackSpeed), 1.5)
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
        loopSelectionMessage = nil
        rangeLoopingEnabled = false
        completedLoops = 0
        call("clearPlaybackRange")
        saveProfile()
    }

    func setSceneActive(_ isActive: Bool) {
        if !isActive {
            nativeBackingPlayer.pause()
            nativeBackingPlaybackRequested = false
            nativeBackingStarted = false
            isPlaying = false
            updatePracticeClock(isPlaying: false)
            saveProfile()
        }
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
            recordLoopCompletionIfNeeded(position)
            self.position = position
            synchronizeNativeBacking(to: position)
            previousPositionTick = position.currentTick
            if
                pendingResumeTick == nil,
                playerReady,
                Date().timeIntervalSince(lastProfileSaveDate) >= 2
            {
                saveProfile()
            }
        case let .playerStateChanged(state):
            isPlaying = state.state == 1
            if isPlaying {
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
                try nativeBackingPlayer.load(data: audio.data)
                nativeBackingSyncPoints = audio.syncPoints
                nativeBackingPlayer.setRate(playbackSpeed)
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
            let session = AVAudioSession.sharedInstance()
            let routes = session.currentRoute.outputs
                .map { $0.portType.rawValue }
                .joined(separator: ",")
            let diagnosticLine = "\(ISO8601DateFormatter().string(from: Date())) js=\(message) "
                + "category=\(session.category.rawValue) mode=\(session.mode.rawValue) "
                + "outputVolume=\(session.outputVolume) "
                + "secondarySilenced=\(session.secondaryAudioShouldBeSilencedHint) routes=\(routes)"
            persistBackingDiagnostic(diagnosticLine, reset: message.contains("\"stage\":\"synth-score-loaded\""))
            NSLog(
                "%@",
                "[DEBUG-gp-audio-56] \(diagnosticLine)"
            )
        case let .error(message):
            errorMessage = message
        }
    }

    func receiveBridgeFailure(_ error: Error) {
        errorMessage = "GP 消息解析失败：\(error.localizedDescription)"
    }

    private func persistBackingDiagnostic(_ line: String, reset: Bool) {
        do {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fileURL = directory.appendingPathComponent("gp-audio-diagnostic.log")
            let data = Data((line + "\n").utf8)
            if reset || !FileManager.default.fileExists(atPath: fileURL.path) {
                try data.write(to: fileURL, options: .atomic)
                return
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            NSLog("%@", "[DEBUG-gp-audio-56] log-write-failed=\(error.localizedDescription)")
        }
    }

    private func synchronizeNativeBacking(to position: GpPlaybackPosition) {
        guard nativeBackingPlayer.isLoaded else { return }
        guard let backingTime = gpBackingTime(
            forPlaybackTime: position.currentTime,
            playbackSpeed: playbackSpeed,
            syncPoints: nativeBackingSyncPoints
        ) else { return }
        let isInsideBacking = backingTime >= 0
            && backingTime < nativeBackingPlayer.durationMilliseconds

        if position.isSeek == true {
            nativeBackingPlayer.seek(to: max(0, backingTime))
        }
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
                    rate: playbackSpeed,
                    volume: backingVolume
                )
                appendNativeBackingDiagnostic(
                    String(
                        format: "native-play ok=%@ score=%.2f audio=%.2f rate=%.2f volume=%.2f",
                        nativeBackingStarted ? "true" : "false",
                        position.currentTime / 1_000,
                        backingTime / 1_000,
                        playbackSpeed,
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

        if
            position.isSeek == true
            || abs(nativeBackingPlayer.currentTimeMilliseconds - backingTime) > 250
        {
            nativeBackingPlayer.seek(to: backingTime)
        }
    }

    private func appendNativeBackingDiagnostic(_ line: String) {
        backingDiagnosticLines.append(line)
        if backingDiagnosticLines.count > 12 {
            backingDiagnosticLines.removeFirst(backingDiagnosticLines.count - 12)
        }
        NSLog("%@", "[DEBUG-gp-native-backing] \(line)")
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
            seek(to: bar.seekTick ?? bar.startTick)
        case let .selectStart(range):
            pause()
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
        speedLadderTarget = min(max(pendingProfile.speedLadderTarget, playbackSpeed), 1.5)
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

        recordLoopCompletion()
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
            nativeBackingPlayer.setRate(playbackSpeed)
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
        PracticeHistoryStore.shared.record(seconds: Double(elapsed) / 1_000)
        saveProfile()
    }

    private func saveProfile() {
        guard let currentFileName else { return }
        try? settingsStore.save(
            GpPracticeProfile(
                playbackSpeed: playbackSpeed,
                lastPositionTick: position.currentTick.isFinite ? max(0, position.currentTick) : 0,
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
        lastProfileSaveDate = Date()
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
