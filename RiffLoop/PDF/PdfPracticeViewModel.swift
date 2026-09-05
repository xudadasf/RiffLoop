import AVFoundation
import Combine
import Foundation
import PDFKit

@MainActor
final class PdfPracticeViewModel: ObservableObject {
    @Published private(set) var document: PDFDocument?
    @Published private(set) var pdfFileName: String?
    @Published private(set) var pageCount = 0
    @Published var pageIndex = 0
    @Published var scaleFactor = 1.0
    @Published var verticalProgress = 0.0
    @Published private(set) var requestedProgress: Double?

    @Published private(set) var player = AVPlayer()
    @Published private(set) var audioFileName: String?
    @Published private(set) var isAudioPlaying = false
    @Published private(set) var isMetronomePlaying = false
    @Published private(set) var currentTime = 0.0
    @Published private(set) var duration = 0.0
    @Published var playbackRate: Float = 1
    @Published var audioVolume: Float = 0.75
    @Published var bpm = 120.0
    @Published var beatOffset: TimeInterval? = 0
    @Published var synchronizationOffset = 0.0
    @Published var metronomeEnabled = true
    @Published var metronomeVolume: Float = 1
    @Published var subdivision: Subdivision = .quarter
    @Published var beatsPerMeasure = 4
    @Published var beatGrouping = [4]
    @Published var beatAccents: [BeatAccent] = [.strong, .normal, .normal, .normal]
    @Published var rhythmMode: RhythmMode = .click
    @Published var pointA: TimeInterval?
    @Published var pointB: TimeInterval?
    @Published var loopEnabled = false
    @Published private(set) var loopCountInEnabled = false
    @Published private(set) var speedLadderEnabled = false
    @Published private(set) var speedLadderTarget: Float = 1
    @Published private(set) var loopsPerSpeedStep = 3
    @Published private(set) var speedLadderStep: Float = 0.05
    @Published private(set) var completedLoops = 0
    @Published private(set) var accumulatedPracticeTime: TimeInterval = 0
    @Published private(set) var totalCompletedLoops = 0
    @Published private(set) var highestPlaybackRate: Float = 1

    @Published private(set) var readingPoints: [PdfReadingPoint] = []
    @Published private(set) var readingStartCue: String?
    // While recording, autosaves must retain the last explicitly saved track.
    private struct SavedReadingTrack {
        var points: [PdfReadingPoint]
        var cue: String?
        var loopEnabled: Bool
    }
    private var recordingOriginal: SavedReadingTrack?
    @Published private(set) var isReadingClockRunning = false
    private var readingTimeOffset = 0.0
    private var readingUsesLiveClock = false
    @Published private(set) var isRecordingReadingTrack = false
    @Published private(set) var isAutoFollowing = false
    @Published private(set) var autoFollowSuspended = false
    @Published private(set) var followLoopEnabled = false
    @Published private(set) var message: String?

    private let settingsStore = FilePracticeSettingsStore()
    private let metronome = MetronomeEngine()
    private let audioGain = PlayerAudioGain()
    private var audioGainReady = false
    private var pendingAudioPlayback: (metronome: Bool, countIn: Bool, stopAfterCountIn: Bool)?
    private var periodicObserver: Any?
    private var boundaryObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var metronomeOnlyTimer: Timer?
    private var countInStopTask: Task<Void, Never>?
    private var viewportSaveTask: Task<Void, Never>?
    private var activeTransportAnchor: TransportAnchor?
    private var lastPracticeSampleDate: Date?
    private var lastProfileSaveDate = Date.distantPast
    private var isLoopTransitioning = false
    private var isReadingFollowLoopTransitioning = false
    private var transportGeneration: UInt64 = 0
    private var readinessObserver: NSKeyValueObservation?
    private var speedLadderBaseRate: Float?

    var isPlaying: Bool { isAudioPlaying || isMetronomePlaying || isReadingClockRunning }
    // The independent practice clock can continue after the accompaniment ends.
    var audioTimelinePosition: Double { min(max(currentTime, 0), max(duration, 0)) }
    var currentBeatCue: String {
        let beat = max(0, Int(floor((currentTime - (beatOffset ?? 0) - synchronizationOffset) * bpm / 60)))
        return "第 \(beat / max(1, beatsPerMeasure) + 1) 小节 · 第 \(beat % max(1, beatsPerMeasure) + 1) 拍"
    }
    var hasUsableReadingTrack: Bool { !isRecordingReadingTrack && isUsablePdfReadingTrack(readingPoints) }
    var isFollowingTransportActive: Bool { isAutoFollowing && isPlaying }

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        periodicObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.timeChanged(self.player.currentTime().seconds)
            }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                AVAudioSession.InterruptionType(rawValue: rawValue) == .began
            else { return }
            Task { @MainActor [weak self] in self?.pause() }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let periodicObserver { player.removeTimeObserver(periodicObserver) }
            if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
            removeItemObservers()
            if let interruptionObserver {
                NotificationCenter.default.removeObserver(interruptionObserver)
            }
            metronomeOnlyTimer?.invalidate()
            countInStopTask?.cancel()
            viewportSaveTask?.cancel()
        }
    }

    @discardableResult
    func openPdf(at url: URL) -> Bool {
        ReproductionStore.shared.capture(url, role: "pdf")
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.openPdf", details: ["url": String(describing: url.lastPathComponent)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            message = "PDF 无法打开，请重新选择文件。"
            return false
        }
        pause()
        resetAudioItem()
        self.document = document
        pdfFileName = url.lastPathComponent
        pageCount = document.pageCount
        let profile = (try? settingsStore.load(
            PdfPracticeProfile.self,
            kind: .pdf,
            fileName: url.lastPathComponent
        )) ?? PdfPracticeProfile()
        apply(profile)
        if let audioFileName = profile.audioFileName {
            let audioURL = RiffLoopDocumentStore()
                .folderURL(for: .pdf)
                .appendingPathComponent(audioFileName)
            if FileManager.default.fileExists(atPath: audioURL.path) {
                bindAudio(at: audioURL, restoringPosition: profile.audioPosition)
            } else {
                self.audioFileName = nil
                save()
            }
        }
        save()
        return true
    }

    func bindAudio(at url: URL, restoringPosition: TimeInterval = 0) {
        ReproductionStore.shared.capture(url, role: "pdf_audio")
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.bindAudio", details: ["url": String(describing: url.lastPathComponent), "restoringPosition": String(describing: restoringPosition)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        pause()
        removeItemObservers()
        audioFileName = url.lastPathComponent
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        audioGainReady = false
        Task { [weak self] in
            if let self { await self.audioGain.attach(to: item, player: self.player) }
            guard let self, self.player.currentItem === item else { return }
            self.audioGainReady = true
            if let pending = self.pendingAudioPlayback {
                self.pendingAudioPlayback = nil
                self.startPlayback(audio: true, metronome: pending.metronome,
                    includeCountIn: pending.countIn, stopMetronomeAfterCountIn: pending.stopAfterCountIn)
            }
        }
        observe(item)
        currentTime = max(0, restoringPosition)
        duration = 0
        player.seek(to: cmTime(currentTime), toleranceBefore: .zero, toleranceAfter: .zero)
        audioGain.setVolume(audioVolume, player: player)
        rebuildBoundaryObserver()
        save()
    }

    func removeAudio() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.removeAudio", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        pause()
        resetAudioItem()
        pointA = nil
        pointB = nil
        loopEnabled = false
        save()
    }

    @discardableResult
    func pdfWasDeleted(at url: URL) -> Bool {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.pdfWasDeleted", details: ["url": String(describing: url.lastPathComponent)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        guard pdfFileName == url.lastPathComponent else { return false }
        transportGeneration &+= 1
        recordPracticeTime()
        pdfFileName = nil
        player.pause()
        metronome.stop()
        stopMetronomeOnlyClock()
        countInStopTask?.cancel()
        countInStopTask = nil
        viewportSaveTask?.cancel()
        viewportSaveTask = nil
        activeTransportAnchor = nil
        isLoopTransitioning = false
        isReadingFollowLoopTransitioning = false
        isAudioPlaying = false
        isMetronomePlaying = false
        lastPracticeSampleDate = nil
        resetAudioItem()
        isReadingClockRunning = false
        document = nil
        pageCount = 0
        pageIndex = 0
        scaleFactor = 1
        verticalProgress = 0
        requestedProgress = nil
        readingPoints = []
        recordingOriginal = nil
        readingStartCue = nil
        isRecordingReadingTrack = false
        isAutoFollowing = false
        autoFollowSuspended = false
        followLoopEnabled = false
        pointA = nil
        pointB = nil
        loopEnabled = false
        return true
    }

    func togglePlayback() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.togglePlayback", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        isPlaying ? pause() : play()
    }

    func toggleReadingFollowPlayback() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.toggleReadingFollowPlayback", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        guard
            hasUsableReadingTrack,
            let firstTime = readingPoints.map(\.time).min()
        else {
            message = "这份 PDF 还没有可用轨迹，请先随播放时间录制一次。"
            return
        }
        if isFollowingTransportActive {
            stopFollowingOnly()
            return
        }
        startReadingFollow(at: firstTime)
    }

    func stopReadingFollowPlayback() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.stopReadingFollowPlayback", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        stopFollowingOnly()
        if let firstTime = readingPoints.map(\.time).min() {
            applyReadingTarget(at: firstTime)
            if !isPlaying { currentTime = firstTime }
        }
        save()
    }

    private func stopFollowingOnly() {
        isAutoFollowing = false
        autoFollowSuspended = false
        isReadingClockRunning = false
        readingTimeOffset = 0
        readingUsesLiveClock = false
        requestedProgress = nil
        if !isMetronomePlaying && !isAudioPlaying {
            stopMetronomeOnlyClock()
            activeTransportAnchor = nil
        }
    }

    func toggleAudioPlayback() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.toggleAudioPlayback", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        guard player.currentItem != nil else { return }
        isAudioPlaying ? pauseAudio() : startPlayback(
            audio: true,
            metronome: isMetronomePlaying
        )
    }

    func toggleMetronomePlayback() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.toggleMetronomePlayback", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        if isMetronomePlaying {
            metronomeEnabled = false
            pauseMetronome()
        } else {
            if !metronomeEnabled { metronomeEnabled = true }
            if let anchor = activeTransportAnchor, isPlaying {
                synchronizeIndependentMetronome(anchor: anchor)
            } else {
                startPlayback(audio: isAudioPlaying, metronome: true)
            }
        }
        save()
    }

    private func synchronizeIndependentMetronome(anchor: TransportAnchor) {
        do {
            try metronome.synchronize(
                timeline: BeatTimeline(bpm: bpm, beatOffset: (beatOffset ?? 0) + synchronizationOffset,
                    subdivision: effectiveSubdivision(subdivision, rhythmMode: rhythmMode),
                    quarterNotesPerMeasure: beatsPerMeasure, beatGrouping: beatGrouping, beatAccents: beatAccents),
                anchor: anchor, rhythmMode: rhythmMode, volume: metronomeVolume
            )
            isMetronomePlaying = true
        } catch { message = "节拍器启动失败：\(error.localizedDescription)" }
    }

    func play(includeCountIn: Bool = false) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.play", details: ["includeCountIn": String(describing: includeCountIn)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        startPlayback(
            audio: player.currentItem != nil,
            metronome: metronomeEnabled,
            includeCountIn: includeCountIn
        )
    }

    func pause() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.pause", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        pendingAudioPlayback = nil
        readinessObserver = nil
        transportGeneration &+= 1
        recordPracticeTime()
        player.pause()
        metronome.stop()
        stopMetronomeOnlyClock()
        countInStopTask?.cancel()
        countInStopTask = nil
        activeTransportAnchor = nil
        isLoopTransitioning = false
        isReadingFollowLoopTransitioning = false
        isAudioPlaying = false
        isMetronomePlaying = false
        isReadingClockRunning = false
        isAutoFollowing = false
        if isRecordingReadingTrack { cancelReadingTrackRecording() }
        lastPracticeSampleDate = nil
        save()
    }

    func pauseAudio() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.pauseAudio", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        pendingAudioPlayback = nil
        transportGeneration &+= 1
        recordPracticeTime()
        countInStopTask?.cancel()
        countInStopTask = nil
        player.pause()
        isLoopTransitioning = false
        isAudioPlaying = false
        if (isMetronomePlaying || isReadingClockRunning), let activeTransportAnchor {
            startMetronomeOnlyClock(anchor: activeTransportAnchor)
        }
        lastPracticeSampleDate = isPlaying ? Date() : nil
        save()
    }

    func pauseMetronome() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.pauseMetronome", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        recordPracticeTime()
        countInStopTask?.cancel()
        countInStopTask = nil
        metronome.stop()
        isMetronomePlaying = false
        if !isReadingClockRunning && !isAudioPlaying {
            stopMetronomeOnlyClock()
            activeTransportAnchor = nil
        }
        lastPracticeSampleDate = isPlaying ? Date() : nil
        save()
    }

    func stopAudio() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.stopAudio", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        pauseAudio()
        let generation = transportGeneration
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] finished in
            Task { @MainActor [weak self] in
                guard
                    let self,
                    finished,
                    self.transportGeneration == generation
                else { return }
                if !self.isPlaying { self.currentTime = 0 }
                self.save()
            }
        }
    }

    func stop() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.stop", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        pause()
        seek(to: 0)
    }

    func seek(to seconds: TimeInterval) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.seek", details: ["seconds": String(describing: seconds)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        transportGeneration &+= 1
        isLoopTransitioning = false
        let generation = transportGeneration
        let target = duration > 0 ? min(max(seconds, 0), duration) : max(seconds, 0)
        let resumeAudio = isAudioPlaying
        let resumeMetronome = isMetronomePlaying
        let resumeReading = isReadingClockRunning
        recordPracticeTime()
        player.pause()
        metronome.stop()
        stopMetronomeOnlyClock()
        countInStopTask?.cancel()
        countInStopTask = nil
        activeTransportAnchor = nil
        isAudioPlaying = false
        isMetronomePlaying = false
        guard player.currentItem != nil else {
            currentTime = target
            if resumeMetronome || resumeReading {
                startPlayback(audio: false, metronome: resumeMetronome)
            }
            return
        }
        player.seek(to: cmTime(target), toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, finished else { return }
                guard self.transportGeneration == generation else { return }
                self.currentTime = target
                if resumeAudio || resumeMetronome || resumeReading {
                    self.startPlayback(audio: resumeAudio, metronome: resumeMetronome)
                } else {
                    self.lastPracticeSampleDate = nil
                    self.save()
                }
            }
        }
    }

    func setBeatOneAtAudioStart() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.setBeatOneAtAudioStart", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        beatOffset = 0
        updateAudioSettings()
    }

    func setBeatOneAtCurrentPosition() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.setBeatOneAtCurrentPosition", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        beatOffset = currentTime
        updateAudioSettings()
    }

    func setPointA() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.setPointA", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        pointA = currentTime
        if let pointB, pointB <= currentTime {
            self.pointB = nil
            loopEnabled = false
        }
        rebuildBoundaryObserver()
        save()
    }

    func setPointB() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.setPointB", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        guard pointA == nil || currentTime > (pointA ?? 0) else {
            message = "B 点必须晚于 A 点。"
            return
        }
        pointB = currentTime
        rebuildBoundaryObserver()
        save()
    }

    func updateAudioSettings() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.updateAudioSettings", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        let resumeAudio = isAudioPlaying
        let resumeMetronome = isMetronomePlaying
        let resumeReading = isReadingClockRunning
        bpm = min(max(bpm, 30), 300)
        playbackRate = min(max(playbackRate, 0.25), 1.5)
        audioVolume = min(max(audioVolume, 0), 2)
        metronomeVolume = min(max(metronomeVolume, 0), 2)
        synchronizationOffset = min(max(synchronizationOffset, -0.5), 0.5)
        audioGain.setVolume(audioVolume, player: player)
        rebuildBoundaryObserver()
        save()
        if resumeAudio || resumeMetronome || resumeReading {
            startPlayback(audio: resumeAudio, metronome: resumeMetronome)
        }
    }

    func setPlaybackRate(_ rate: Float) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.setPlaybackRate", details: ["rate": String(describing: rate)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        playbackRate = min(max(rate, 0.25), 1.5)
        if speedLadderEnabled {
            speedLadderBaseRate = playbackRate
        }
        speedLadderTarget = max(speedLadderTarget, playbackRate)
        completedLoops = 0
        highestPlaybackRate = max(highestPlaybackRate, playbackRate)
        updateAudioSettings()
    }

    func setMeter(beats: Int) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.setMeter", details: ["beats": String(describing: beats)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        beatsPerMeasure = min(max(beats, 1), 16)
        beatGrouping = [beatsPerMeasure]
        beatAccents = defaultBeatAccents(
            beatsPerMeasure: beatsPerMeasure,
            grouping: beatGrouping
        )
        updateAudioSettings()
    }

    func setBeatGrouping(_ input: String) -> Bool {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.setBeatGrouping", details: ["input": String(describing: input)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        guard let grouping = parseBeatGrouping(input, beatsPerMeasure: beatsPerMeasure) else {
            message = "拍子分组必须为正整数，并且总和等于每小节拍数。"
            return false
        }
        beatGrouping = grouping
        beatAccents = defaultBeatAccents(
            beatsPerMeasure: beatsPerMeasure,
            grouping: grouping
        )
        updateAudioSettings()
        return true
    }

    func cycleAccent(at index: Int) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.cycleAccent", details: ["index": String(describing: index)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        guard beatAccents.indices.contains(index) else { return }
        beatAccents[index] = beatAccents[index].next
        updateAudioSettings()
    }

    func setLoopCountInEnabled(_ enabled: Bool) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.setLoopCountInEnabled", details: ["enabled": String(describing: enabled)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        loopCountInEnabled = enabled
        save()
    }

    func setSpeedLadderEnabled(_ enabled: Bool) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.setSpeedLadderEnabled", details: ["enabled": String(describing: enabled)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        guard speedLadderEnabled != enabled else { return }
        if enabled {
            speedLadderBaseRate = playbackRate
            speedLadderTarget = max(speedLadderTarget, playbackRate)
        } else {
            playbackRate = speedLadderBaseRate ?? playbackRate
            speedLadderBaseRate = nil
        }
        speedLadderEnabled = enabled
        completedLoops = 0
        updateAudioSettings()
    }

    func setSpeedLadderTarget(_ target: Float) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.setSpeedLadderTarget", details: ["target": String(describing: target)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        speedLadderTarget = min(max(target, playbackRate), 1.5)
        completedLoops = 0
        save()
    }

    func setLoopsPerSpeedStep(_ loops: Int) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.setLoopsPerSpeedStep", details: ["loops": String(describing: loops)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        loopsPerSpeedStep = min(max(loops, 1), 10)
        completedLoops = 0
        save()
    }

    func setSpeedLadderStep(_ step: Float) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.setSpeedLadderStep", details: ["step": String(describing: step)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        speedLadderStep = min(max(step, 0.01), 0.25)
        completedLoops = 0
        save()
    }

    func setPage(_ index: Int) {
        pageIndex = min(max(index, 0), max(0, pageCount - 1))
        if isRecordingReadingTrack { captureReadingPoint(force: true) }
        save()
    }

    func setScale(_ scale: Double) {
        scaleFactor = min(max(scale, 0.75), 2.5)
        requestedProgress = verticalProgress
        save()
    }

    func setVerticalProgress(_ progress: Double) {
        verticalProgress = min(max(progress, 0), 1)
        if isRecordingReadingTrack { captureReadingPoint() }
        scheduleViewportSave()
    }

    func manualViewportInteraction() {
        requestedProgress = nil
        if isAutoFollowing {
            autoFollowSuspended = true
        }
    }

    func startReadingTrackRecording() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.startReadingTrackRecording", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        guard !isRecordingReadingTrack else { return }
        recordingOriginal = SavedReadingTrack(points: readingPoints, cue: readingStartCue, loopEnabled: followLoopEnabled)
        isAutoFollowing = false
        autoFollowSuspended = false
        followLoopEnabled = false
        readingPoints = []
        readingTimeOffset = 0
        isRecordingReadingTrack = true
        metronomeEnabled = true
        if beatOffset == nil { beatOffset = 0 }
        if !isMetronomePlaying { toggleMetronomePlayback() }
        guard isMetronomePlaying else {
            cancelReadingTrackRecording()
            isReadingClockRunning = false
            stopMetronomeOnlyClock()
            return
        }
        readingStartCue = "\(currentBeatCue) · \(Int(bpm)) BPM · \(beatsPerMeasure)/4"
        captureReadingPoint(force: true)
        message = nil
    }

    func finishReadingTrackRecording() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.finishReadingTrackRecording", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        guard isRecordingReadingTrack else { return }
        captureReadingPoint(force: true)
        guard isUsablePdfReadingTrack(readingPoints) else {
            message = "记录时间太短。请随节拍滚动或翻页后再保存；原轨迹仍保留。"
            return
        }
        isRecordingReadingTrack = false
        recordingOriginal = nil
        isReadingClockRunning = isAutoFollowing
        if !isMetronomePlaying && !isReadingClockRunning { stopMetronomeOnlyClock() }
        message = hasUsableReadingTrack
            ? nil
            : "没有记录到时间变化。请先点击播放，让伴奏或节拍器时间轴开始推进，再滚动或翻页。"
        save()
    }

    func cancelReadingTrackRecording() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.cancelReadingTrackRecording", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        guard let original = recordingOriginal else { return }
        recordPracticeTime()
        readingPoints = original.points
        readingStartCue = original.cue
        followLoopEnabled = original.loopEnabled
        recordingOriginal = nil
        isRecordingReadingTrack = false
        isReadingClockRunning = false
        readingTimeOffset = 0
        if !isMetronomePlaying { stopMetronomeOnlyClock() }
        message = nil
        save()
    }

    func toggleAutoFollow() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.toggleAutoFollow", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        if isAutoFollowing {
            stopFollowingOnly()
            return
        }
        guard hasUsableReadingTrack else {
            message = "这份 PDF 还没有可用轨迹，请先随播放时间录制一次。"
            return
        }
        startAutoFollowFromBeginning()
    }

    func startAutoFollowFromBeginning() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.startAutoFollowFromBeginning", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        guard
            hasUsableReadingTrack,
            let startTime = readingPoints.map(\.time).min()
        else {
            message = "这份 PDF 还没有可用轨迹，请先随播放时间录制一次。"
            return
        }
        startReadingFollow(at: startTime)
    }

    func resumeAutoFollow() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.resumeAutoFollow", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        autoFollowSuspended = false
        message = nil
        updateAutoFollow()
    }

    func deleteReadingTrack() {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.deleteReadingTrack", details: [:])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        guard !isRecordingReadingTrack else { return }
        stopFollowingOnly()
        readingPoints = []
        readingStartCue = nil
        isRecordingReadingTrack = false
        isAutoFollowing = false
        autoFollowSuspended = false
        followLoopEnabled = false
        isReadingFollowLoopTransitioning = false
        save()
    }

    func setFollowLoopEnabled(_ enabled: Bool) {
        reproductionSnapshot()
        let reproductionOperation = ReproductionRecorder.shared.begin("pdf.setFollowLoopEnabled", details: ["enabled": String(describing: enabled)])
        defer {
            reproductionSnapshot()
            ReproductionRecorder.shared.end(reproductionOperation, result: "method_returned; check subsequent state/async events")
        }
        guard !enabled || hasUsableReadingTrack else {
            message = "请先完成一条有效的跟谱轨迹。"
            return
        }
        followLoopEnabled = enabled
        save()
    }

    func dismissMessage() { message = nil }

    private func startPlayback(
        audio shouldPlayAudio: Bool,
        metronome shouldPlayMetronome: Bool,
        includeCountIn: Bool = false,
        stopMetronomeAfterCountIn: Bool = false
    ) {
        let startAudio = shouldPlayAudio && player.currentItem != nil
        let startMetronome = shouldPlayMetronome && metronomeEnabled && beatOffset != nil
        let startReadingClock = isAutoFollowing || isRecordingReadingTrack
        guard startAudio || startMetronome || startReadingClock else { return }

        if startAudio, !audioGainReady {
            pendingAudioPlayback = (shouldPlayMetronome, includeCountIn, stopMetronomeAfterCountIn)
            return
        }
        if startAudio, player.status != .readyToPlay {
            transportGeneration &+= 1
            let generation = transportGeneration
            readinessObserver = player.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.transportGeneration == generation,
                        self.readinessObserver != nil else { return }
                    guard self.player.status != .unknown else { return }
                    self.readinessObserver = nil
                    guard self.player.status == .readyToPlay else {
                        self.pause()
                        self.message = "伴奏无法播放，请重新选择文件。"
                        return
                    }
                    self.startPlayback(
                        audio: shouldPlayAudio,
                        metronome: shouldPlayMetronome,
                        includeCountIn: includeCountIn,
                        stopMetronomeAfterCountIn: stopMetronomeAfterCountIn
                    )
                }
            }
            return
        }

        transportGeneration &+= 1
        readinessObserver = nil
        let generation = transportGeneration
        isLoopTransitioning = false
        recordPracticeTime()
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        metronome.stop()
        stopMetronomeOnlyClock()
        countInStopTask?.cancel()

        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        let countInMediaDuration = includeCountIn && startMetronome
            ? Double(beatsPerMeasure) * 60 / bpm
            : 0
        let anchorHostTime = CMTimeAdd(
            hostNow,
            CMTime(seconds: 0.1, preferredTimescale: 1_000_000_000)
        )
        let anchor = TransportAnchor(
            mediaTime: currentTime - countInMediaDuration,
            hostTime: anchorHostTime.seconds,
            mediaRate: Double(playbackRate)
        )

        if startAudio {
            player.setRate(
                playbackRate,
                time: cmTime(currentTime),
                atHostTime: cmTime(anchor.hostTime(forMediaTime: currentTime))
            )
        }

        var metronomeStarted = false
        if startMetronome, let beatOffset {
            do {
                try metronome.synchronize(
                    timeline: BeatTimeline(
                        bpm: bpm,
                        beatOffset: beatOffset + synchronizationOffset,
                        subdivision: effectiveSubdivision(subdivision, rhythmMode: rhythmMode),
                        quarterNotesPerMeasure: beatsPerMeasure,
                        beatGrouping: beatGrouping,
                        beatAccents: beatAccents
                    ),
                    anchor: anchor,
                    rhythmMode: rhythmMode,
                    volume: metronomeVolume
                )
                metronomeStarted = true
                message = nil
            } catch {
                message = "节拍器启动失败：\(error.localizedDescription)"
            }
        }

        isAudioPlaying = startAudio
        isMetronomePlaying = metronomeStarted
        isReadingClockRunning = startReadingClock
        activeTransportAnchor = anchor
        if (metronomeStarted || startReadingClock), !startAudio {
            startMetronomeOnlyClock(anchor: anchor)
        }
        if metronomeStarted, startAudio, includeCountIn, stopMetronomeAfterCountIn {
            let delay = max(0, anchor.hostTime(forMediaTime: currentTime) - hostNow.seconds)
            countInStopTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard
                    !Task.isCancelled,
                    let self,
                    self.transportGeneration == generation,
                    self.isAudioPlaying
                else { return }
                self.metronome.stop()
                self.isMetronomePlaying = false
                self.activeTransportAnchor = nil
                self.lastPracticeSampleDate = self.isPlaying ? Date() : nil
                self.save()
            }
        }
        lastPracticeSampleDate = isPlaying ? Date() : nil
        save()
    }

    private func timeChanged(_ seconds: TimeInterval) {
        recordPracticeTime()
        if isAudioPlaying, seconds.isFinite { currentTime = max(0, seconds) }
        if let item = player.currentItem, item.duration.seconds.isFinite {
            duration = max(0, item.duration.seconds)
        }
        updateAutoFollow()
        restartReadingFollowLoopIfNeeded()
        if isPlaying, Date().timeIntervalSince(lastProfileSaveDate) >= 2 {
            save()
        }
    }

    private func updateAutoFollow() {
        guard isAutoFollowing, !autoFollowSuspended else { return }
        applyReadingTarget(at: currentTime + readingTimeOffset)
    }

    private func applyReadingTarget(at time: TimeInterval) {
        guard let target = pdfReadingTarget(at: time, points: readingPoints) else { return }
        pageIndex = min(max(target.pageIndex, 0), max(0, pageCount - 1))
        verticalProgress = target.verticalProgress
        requestedProgress = target.verticalProgress
    }

    private func captureReadingPoint(force: Bool = false) {
        readingPoints = recordPdfReadingPoint(
            PdfReadingPoint(
                time: currentTime,
                pageIndex: pageIndex,
                verticalProgress: verticalProgress
            ),
            in: readingPoints,
            force: force
        )
        save()
    }

    private func startReadingFollow(at time: TimeInterval) {
        guard hasUsableReadingTrack else {
            message = "这份 PDF 还没有可用轨迹，请先随播放时间录制一次。"
            return
        }
        isRecordingReadingTrack = false
        isAutoFollowing = true
        autoFollowSuspended = false
        message = nil
        if isPlaying {
            // Starting follow at a beat chosen by the user must not restart that beat.
            readingTimeOffset = time - currentTime
            readingUsesLiveClock = true
            isReadingClockRunning = true
            updateAutoFollow()
            return
        }
        readingTimeOffset = 0
        readingUsesLiveClock = false
        prepareReadingFollow(at: time, startPlayback: true)
    }

    private func prepareReadingFollow(at time: TimeInterval, startPlayback shouldStartPlayback: Bool) {
        transportGeneration &+= 1
        let generation = transportGeneration
        let target = max(0, time)
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        metronome.stop()
        stopMetronomeOnlyClock()
        countInStopTask?.cancel()
        countInStopTask = nil
        activeTransportAnchor = nil
        isAudioPlaying = false
        isMetronomePlaying = false

        let complete: () -> Void = { [weak self] in
            guard let self, self.transportGeneration == generation else { return }
            self.currentTime = target
            self.applyReadingTarget(at: target)
            self.isReadingFollowLoopTransitioning = false
            if shouldStartPlayback {
                self.startPlayback(
                    audio: self.player.currentItem != nil,
                    metronome: self.metronomeEnabled
                )
            } else {
                self.lastPracticeSampleDate = nil
                self.save()
            }
        }

        guard player.currentItem != nil else {
            complete()
            return
        }
        player.seek(to: cmTime(target), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in
                guard self.transportGeneration == generation else { return }
                guard finished else {
                    self.isReadingFollowLoopTransitioning = false
                    self.pause()
                    return
                }
                complete()
            }
        }
    }

    @discardableResult
    private func restartReadingFollowLoopIfNeeded() -> Bool {
        guard
            followLoopEnabled,
            isAutoFollowing,
            isPlaying,
            !isReadingFollowLoopTransitioning,
            let firstTime = readingPoints.map(\.time).min(),
            let lastTime = readingPoints.map(\.time).max(),
            currentTime + readingTimeOffset >= lastTime,
            lastTime > firstTime
        else { return false }
        if readingUsesLiveClock {
            readingTimeOffset = firstTime - currentTime
            updateAutoFollow()
            return true
        }
        isReadingFollowLoopTransitioning = true
        prepareReadingFollow(at: firstTime, startPlayback: true)
        return true
    }

    private func rebuildBoundaryObserver() {
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
            self.boundaryObserver = nil
        }
        guard loopEnabled, let pointA, let pointB, pointB > pointA else { return }
        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: cmTime(pointB))],
            queue: .main
        ) { [weak self] in
            Task { @MainActor [weak self] in self?.handleLoopBoundary() }
        }
    }

    private func handleLoopBoundary() {
        guard
            loopEnabled,
            let pointA,
            let pointB,
            pointB > pointA,
            isAudioPlaying,
            !isLoopTransitioning
        else { return }

        isLoopTransitioning = true
        transportGeneration &+= 1
        let generation = transportGeneration
        let update = speedAfterCompletedLoop(
            currentSpeed: Double(playbackRate),
            targetSpeed: Double(speedLadderTarget),
            previousCompletedLoops: completedLoops,
            enabled: speedLadderEnabled,
            loopsPerStep: loopsPerSpeedStep,
            speedStep: Double(speedLadderStep)
        )
        completedLoops = update.completedLoops
        totalCompletedLoops += 1
        playbackRate = Float(update.playbackSpeed)
        highestPlaybackRate = max(highestPlaybackRate, playbackRate)
        recordPracticeTime()
        let resumeMetronome = isMetronomePlaying
        player.pause()
        metronome.stop()
        stopMetronomeOnlyClock()
        countInStopTask?.cancel()
        isAudioPlaying = false
        isMetronomePlaying = false
        player.seek(to: cmTime(pointA), toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] finished in
            Task { @MainActor [weak self] in
                guard
                    let self,
                    self.transportGeneration == generation
                else { return }
                self.isLoopTransitioning = false
                guard finished, self.loopEnabled else {
                    self.pause()
                    return
                }
                self.currentTime = pointA
                self.startPlayback(
                    audio: true,
                    metronome: resumeMetronome || self.loopCountInEnabled,
                    includeCountIn: self.loopCountInEnabled,
                    stopMetronomeAfterCountIn: self.loopCountInEnabled && !resumeMetronome
                )
            }
        }
        save()
    }

    private func recordPracticeTime() {
        defer { lastPracticeSampleDate = isPlaying ? Date() : nil }
        guard isPlaying, let lastPracticeSampleDate else { return }
        let elapsed = max(0, Date().timeIntervalSince(lastPracticeSampleDate))
        accumulatedPracticeTime += elapsed
        PracticeHistoryStore.shared.record(seconds: elapsed)
    }

    private func apply(_ profile: PdfPracticeProfile) {
        recordingOriginal = nil
        pageIndex = min(max(profile.pageIndex, 0), max(0, pageCount - 1))
        scaleFactor = min(max(profile.scaleFactor, 0.75), 2.5)
        verticalProgress = min(max(profile.verticalProgress, 0), 1)
        requestedProgress = verticalProgress
        audioFileName = profile.audioFileName
        currentTime = max(0, profile.audioPosition)
        duration = 0
        playbackRate = min(max(profile.playbackRate, 0.25), 1.5)
        audioVolume = min(max(profile.audioVolume, 0), 2)
        bpm = min(max(profile.bpm, 30), 300)
        beatOffset = profile.beatOffset
        synchronizationOffset = min(max(profile.synchronizationOffset, -0.5), 0.5)
        metronomeEnabled = profile.metronomeEnabled
        metronomeVolume = min(max(profile.metronomeVolume, 0), 2)
        subdivision = profile.subdivision
        beatsPerMeasure = min(max(profile.beatsPerMeasure, 1), 16)
        beatGrouping = profile.beatGrouping.reduce(0, +) == beatsPerMeasure
            ? profile.beatGrouping
            : [beatsPerMeasure]
        beatAccents = profile.beatAccents.count == beatsPerMeasure
            ? profile.beatAccents
            : defaultBeatAccents(beatsPerMeasure: beatsPerMeasure, grouping: beatGrouping)
        rhythmMode = profile.rhythmMode
        pointA = nil
        pointB = nil
        loopEnabled = false
        loopCountInEnabled = false
        speedLadderEnabled = false
        speedLadderBaseRate = nil
        speedLadderTarget = min(max(profile.speedLadderTarget, playbackRate), 1.5)
        loopsPerSpeedStep = min(max(profile.loopsPerSpeedStep, 1), 10)
        speedLadderStep = min(max(profile.speedLadderStep, 0.01), 0.25)
        accumulatedPracticeTime = max(0, profile.accumulatedPracticeTime)
        totalCompletedLoops = max(0, profile.totalCompletedLoops)
        highestPlaybackRate = max(playbackRate, profile.highestPlaybackRate)
        completedLoops = 0
        readingPoints = profile.readingPoints
        readingStartCue = profile.readingStartCue
        readingTimeOffset = 0
        followLoopEnabled = profile.followLoopEnabled && hasUsableReadingTrack
    }

    private func save() {
        guard let pdfFileName else { return }
        lastProfileSaveDate = Date()
        let profile = PdfPracticeProfile(
            pageIndex: pageIndex,
            scaleFactor: scaleFactor,
            verticalProgress: verticalProgress,
            audioFileName: audioFileName,
            audioPosition: currentTime,
            playbackRate: playbackRate,
            audioVolume: audioVolume,
            bpm: bpm,
            beatOffset: beatOffset,
            synchronizationOffset: synchronizationOffset,
            metronomeEnabled: metronomeEnabled,
            metronomeVolume: metronomeVolume,
            subdivision: subdivision,
            beatsPerMeasure: beatsPerMeasure,
            beatGrouping: beatGrouping,
            beatAccents: beatAccents,
            rhythmMode: rhythmMode,
            pointA: nil,
            pointB: nil,
            loopEnabled: false,
            loopCountInEnabled: false,
            speedLadderEnabled: false,
            speedLadderTarget: speedLadderTarget,
            loopsPerSpeedStep: loopsPerSpeedStep,
            speedLadderStep: speedLadderStep,
            accumulatedPracticeTime: accumulatedPracticeTime,
            totalCompletedLoops: totalCompletedLoops,
            highestPlaybackRate: highestPlaybackRate,
            readingPoints: recordingOriginal?.points ?? readingPoints,
            readingStartCue: recordingOriginal == nil ? readingStartCue : recordingOriginal?.cue,
            followLoopEnabled: recordingOriginal?.loopEnabled ?? followLoopEnabled
        )
        try? settingsStore.save(profile, kind: .pdf, fileName: pdfFileName)
    }

    private func observe(_ item: AVPlayerItem) {
        removeItemObservers()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleAudioPlaybackEnded(item) }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor [weak self] in self?.handleAudioPlaybackFailed(error, item: item) }
        }
    }

    private func removeItemObservers() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        failureObserver = nil
    }

    private func resetAudioItem() {
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
            self.boundaryObserver = nil
        }
        removeItemObservers()
        player.replaceCurrentItem(with: nil)
        audioFileName = nil
        currentTime = 0
        duration = 0
        isAudioPlaying = false
    }

    private func handleAudioPlaybackEnded(_ item: AVPlayerItem) {
        guard player.currentItem === item, isAudioPlaying else { return }
        let endPosition = item.duration.seconds.isFinite ? item.duration.seconds : duration
        // A queued end notification from the preceding round must not stop a new seek/start.
        guard player.currentTime().seconds >= endPosition - 0.05 else { return }
        currentTime = endPosition
        updateAutoFollow()
        if restartReadingFollowLoopIfNeeded() { return }
        pause()
        currentTime = endPosition
        save()
    }

    private func handleAudioPlaybackFailed(_ error: Error?, item: AVPlayerItem) {
        guard player.currentItem === item else { return }
        pause()
        message = error.map { "伴奏播放失败：\($0.localizedDescription)" }
            ?? "伴奏播放失败，请重新选择文件。"
    }

    private func startMetronomeOnlyClock(anchor: TransportAnchor) {
        metronomeOnlyTimer?.invalidate()
        let generation = transportGeneration
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.transportGeneration == generation,
                    (self.isMetronomePlaying || self.isReadingClockRunning), !self.isAudioPlaying else { return }
                let hostTime = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                self.currentTime = max(0, anchor.mediaTime(forHostTime: hostTime))
                self.recordPracticeTime()
                self.updateAutoFollow()
                self.restartReadingFollowLoopIfNeeded()
                if Date().timeIntervalSince(self.lastProfileSaveDate) >= 2 {
                    self.save()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        metronomeOnlyTimer = timer
    }

    private func stopMetronomeOnlyClock() {
        metronomeOnlyTimer?.invalidate()
        metronomeOnlyTimer = nil
    }

    private func scheduleViewportSave() {
        viewportSaveTask?.cancel()
        viewportSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func cmTime(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
    }
    func reproductionSnapshot() {
        let store = ReproductionStore.shared
        var state: [String: String] = [:]
        state["pdf.pdfFileName"] = store.encoded(pdfFileName)
        state["pdf.audioFileName"] = store.encoded(audioFileName)
        state["pdf.pageIndex"] = store.encoded(pageIndex)
        state["pdf.pageCount"] = store.encoded(pageCount)
        state["pdf.scaleFactor"] = store.encoded(scaleFactor)
        state["pdf.verticalProgress"] = store.encoded(verticalProgress)
        state["pdf.isAudioPlaying"] = store.encoded(isAudioPlaying)
        state["pdf.isMetronomePlaying"] = store.encoded(isMetronomePlaying)
        state["pdf.currentTime"] = store.encoded(currentTime)
        state["pdf.duration"] = store.encoded(duration)
        state["pdf.playbackRate"] = store.encoded(playbackRate)
        state["pdf.audioVolume"] = store.encoded(audioVolume)
        state["pdf.bpm"] = store.encoded(bpm)
        state["pdf.beatOffset"] = store.encoded(beatOffset)
        state["pdf.synchronizationOffset"] = store.encoded(synchronizationOffset)
        state["pdf.metronomeEnabled"] = store.encoded(metronomeEnabled)
        state["pdf.metronomeVolume"] = store.encoded(metronomeVolume)
        state["pdf.subdivision"] = store.encoded(subdivision)
        state["pdf.beatsPerMeasure"] = store.encoded(beatsPerMeasure)
        state["pdf.beatGrouping"] = store.encoded(beatGrouping)
        state["pdf.beatAccents"] = store.encoded(beatAccents)
        state["pdf.rhythmMode"] = store.encoded(rhythmMode)
        state["pdf.pointA"] = store.encoded(pointA)
        state["pdf.pointB"] = store.encoded(pointB)
        state["pdf.loopEnabled"] = store.encoded(loopEnabled)
        state["pdf.loopCountInEnabled"] = store.encoded(loopCountInEnabled)
        state["pdf.speedLadderEnabled"] = store.encoded(speedLadderEnabled)
        state["pdf.speedLadderTarget"] = store.encoded(speedLadderTarget)
        state["pdf.loopsPerSpeedStep"] = store.encoded(loopsPerSpeedStep)
        state["pdf.speedLadderStep"] = store.encoded(speedLadderStep)
        state["pdf.isRecordingReadingTrack"] = store.encoded(isRecordingReadingTrack)
        state["pdf.isAutoFollowing"] = store.encoded(isAutoFollowing)
        state["pdf.autoFollowSuspended"] = store.encoded(autoFollowSuspended)
        state["pdf.followLoopEnabled"] = store.encoded(followLoopEnabled)
        state["pdf.message"] = store.encoded(message)
        store.update(state)
    }

}
