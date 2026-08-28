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
    @Published private(set) var isRecordingReadingTrack = false
    @Published private(set) var isAutoFollowing = false
    @Published private(set) var autoFollowSuspended = false
    @Published private(set) var followLoopEnabled = false
    @Published private(set) var message: String?

    private let settingsStore = FilePracticeSettingsStore()
    private let metronome = MetronomeEngine()
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
    private var speedLadderBaseRate: Float?

    var isPlaying: Bool { isAudioPlaying || isMetronomePlaying }
    var hasUsableReadingTrack: Bool { isUsablePdfReadingTrack(readingPoints) }
    var isFollowingTransportActive: Bool { isAutoFollowing && isPlaying }

    init() {
        periodicObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.timeChanged(time.seconds)
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
        pause()
        removeItemObservers()
        audioFileName = url.lastPathComponent
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        observe(item)
        currentTime = max(0, restoringPosition)
        duration = 0
        player.seek(to: cmTime(currentTime), toleranceBefore: .zero, toleranceAfter: .zero)
        player.volume = audioVolume
        rebuildBoundaryObserver()
        save()
    }

    func removeAudio() {
        pause()
        resetAudioItem()
        pointA = nil
        pointB = nil
        loopEnabled = false
        save()
    }

    @discardableResult
    func pdfWasDeleted(at url: URL) -> Bool {
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
        document = nil
        pageCount = 0
        pageIndex = 0
        scaleFactor = 1
        verticalProgress = 0
        requestedProgress = nil
        readingPoints = []
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
        isPlaying ? pause() : play()
    }

    func toggleReadingFollowPlayback() {
        guard
            hasUsableReadingTrack,
            let firstTime = readingPoints.map(\.time).min(),
            let lastTime = readingPoints.map(\.time).max()
        else {
            message = "这份 PDF 还没有可用轨迹，请先随播放时间录制一次。"
            return
        }
        if isFollowingTransportActive {
            pause()
            return
        }
        let target = currentTime >= firstTime && currentTime < lastTime ? currentTime : firstTime
        startReadingFollow(at: target)
    }

    func stopReadingFollowPlayback() {
        guard let firstTime = readingPoints.map(\.time).min() else {
            pause()
            return
        }
        pause()
        prepareReadingFollow(at: firstTime, startPlayback: false)
    }

    func toggleAudioPlayback() {
        guard player.currentItem != nil else { return }
        isAudioPlaying ? pauseAudio() : startPlayback(
            audio: true,
            metronome: isMetronomePlaying
        )
    }

    func toggleMetronomePlayback() {
        if isMetronomePlaying {
            pauseMetronome()
        } else {
            if !metronomeEnabled { metronomeEnabled = true }
            startPlayback(audio: isAudioPlaying, metronome: true)
        }
    }

    func play(includeCountIn: Bool = false) {
        startPlayback(
            audio: player.currentItem != nil,
            metronome: metronomeEnabled,
            includeCountIn: includeCountIn
        )
    }

    func pause() {
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
        lastPracticeSampleDate = nil
        save()
    }

    func pauseAudio() {
        transportGeneration &+= 1
        recordPracticeTime()
        countInStopTask?.cancel()
        countInStopTask = nil
        player.pause()
        isLoopTransitioning = false
        isAudioPlaying = false
        if isMetronomePlaying, let activeTransportAnchor {
            startMetronomeOnlyClock(anchor: activeTransportAnchor)
        }
        lastPracticeSampleDate = isPlaying ? Date() : nil
        save()
    }

    func pauseMetronome() {
        transportGeneration &+= 1
        recordPracticeTime()
        countInStopTask?.cancel()
        countInStopTask = nil
        metronome.stop()
        stopMetronomeOnlyClock()
        activeTransportAnchor = nil
        isMetronomePlaying = false
        lastPracticeSampleDate = isPlaying ? Date() : nil
        save()
    }

    func stopAudio() {
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
                self.currentTime = 0
                self.save()
            }
        }
    }

    func stop() {
        pause()
        seek(to: 0)
    }

    func seek(to seconds: TimeInterval) {
        transportGeneration &+= 1
        isLoopTransitioning = false
        let generation = transportGeneration
        let target = duration > 0 ? min(max(seconds, 0), duration) : max(seconds, 0)
        let resumeAudio = isAudioPlaying
        let resumeMetronome = isMetronomePlaying
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
            if resumeMetronome { startPlayback(audio: false, metronome: true) }
            return
        }
        player.seek(to: cmTime(target), toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, finished else { return }
                guard self.transportGeneration == generation else { return }
                self.currentTime = target
                if resumeAudio || resumeMetronome {
                    self.startPlayback(audio: resumeAudio, metronome: resumeMetronome)
                } else {
                    self.lastPracticeSampleDate = nil
                    self.save()
                }
            }
        }
    }

    func setBeatOneAtAudioStart() {
        beatOffset = 0
        updateAudioSettings()
    }

    func setBeatOneAtCurrentPosition() {
        beatOffset = currentTime
        updateAudioSettings()
    }

    func setPointA() {
        pointA = currentTime
        if let pointB, pointB <= currentTime {
            self.pointB = nil
            loopEnabled = false
        }
        rebuildBoundaryObserver()
        save()
    }

    func setPointB() {
        guard pointA == nil || currentTime > (pointA ?? 0) else {
            message = "B 点必须晚于 A 点。"
            return
        }
        pointB = currentTime
        rebuildBoundaryObserver()
        save()
    }

    func updateAudioSettings() {
        let resumeAudio = isAudioPlaying
        let resumeMetronome = isMetronomePlaying
        bpm = min(max(bpm, 30), 300)
        playbackRate = min(max(playbackRate, 0.25), 1.5)
        audioVolume = min(max(audioVolume, 0), 1)
        metronomeVolume = min(max(metronomeVolume, 0), 1)
        synchronizationOffset = min(max(synchronizationOffset, -0.5), 0.5)
        player.volume = audioVolume
        rebuildBoundaryObserver()
        save()
        if resumeAudio || resumeMetronome {
            startPlayback(audio: resumeAudio, metronome: resumeMetronome)
        }
    }

    func setPlaybackRate(_ rate: Float) {
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
        beatsPerMeasure = min(max(beats, 1), 16)
        beatGrouping = [beatsPerMeasure]
        beatAccents = defaultBeatAccents(
            beatsPerMeasure: beatsPerMeasure,
            grouping: beatGrouping
        )
        updateAudioSettings()
    }

    func setBeatGrouping(_ input: String) -> Bool {
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
        guard beatAccents.indices.contains(index) else { return }
        beatAccents[index] = beatAccents[index].next
        updateAudioSettings()
    }

    func setLoopCountInEnabled(_ enabled: Bool) {
        loopCountInEnabled = enabled
        save()
    }

    func setSpeedLadderEnabled(_ enabled: Bool) {
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
        speedLadderTarget = min(max(target, playbackRate), 1.5)
        completedLoops = 0
        save()
    }

    func setLoopsPerSpeedStep(_ loops: Int) {
        loopsPerSpeedStep = min(max(loops, 1), 10)
        completedLoops = 0
        save()
    }

    func setSpeedLadderStep(_ step: Float) {
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
        isAutoFollowing = false
        autoFollowSuspended = false
        followLoopEnabled = false
        readingPoints = []
        isRecordingReadingTrack = true
        captureReadingPoint(force: true)
        message = nil
    }

    func finishReadingTrackRecording() {
        captureReadingPoint(force: true)
        isRecordingReadingTrack = false
        message = hasUsableReadingTrack
            ? nil
            : "没有记录到时间变化。请先点击播放，让伴奏或节拍器时间轴开始推进，再滚动或翻页。"
        save()
    }

    func toggleAutoFollow() {
        if isAutoFollowing {
            isAutoFollowing = false
            autoFollowSuspended = false
            requestedProgress = nil
            return
        }
        guard hasUsableReadingTrack else {
            message = "这份 PDF 还没有可用轨迹，请先随播放时间录制一次。"
            return
        }
        isRecordingReadingTrack = false
        isAutoFollowing = true
        autoFollowSuspended = false
        message = nil
        updateAutoFollow()
    }

    func startAutoFollowFromBeginning() {
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
        autoFollowSuspended = false
        message = nil
        updateAutoFollow()
    }

    func deleteReadingTrack() {
        readingPoints = []
        isRecordingReadingTrack = false
        isAutoFollowing = false
        autoFollowSuspended = false
        followLoopEnabled = false
        isReadingFollowLoopTransitioning = false
        save()
    }

    func setFollowLoopEnabled(_ enabled: Bool) {
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
        guard startAudio || startMetronome else { return }

        transportGeneration &+= 1
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
        activeTransportAnchor = metronomeStarted ? anchor : nil
        if metronomeStarted, !startAudio {
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
        applyReadingTarget(at: currentTime)
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
        guard player.currentItem != nil || metronomeEnabled else {
            message = "请先绑定伴奏或开启节拍器，再启动跟谱。"
            return
        }
        isRecordingReadingTrack = false
        isAutoFollowing = true
        autoFollowSuspended = false
        message = nil
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
            currentTime >= lastTime,
            lastTime > firstTime
        else { return false }
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
        pageIndex = min(max(profile.pageIndex, 0), max(0, pageCount - 1))
        scaleFactor = min(max(profile.scaleFactor, 0.75), 2.5)
        verticalProgress = min(max(profile.verticalProgress, 0), 1)
        requestedProgress = verticalProgress
        audioFileName = profile.audioFileName
        currentTime = max(0, profile.audioPosition)
        duration = 0
        playbackRate = min(max(profile.playbackRate, 0.25), 1.5)
        audioVolume = min(max(profile.audioVolume, 0), 1)
        bpm = min(max(profile.bpm, 30), 300)
        beatOffset = profile.beatOffset
        synchronizationOffset = min(max(profile.synchronizationOffset, -0.5), 0.5)
        metronomeEnabled = profile.metronomeEnabled
        metronomeVolume = min(max(profile.metronomeVolume, 0), 1)
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
            readingPoints: readingPoints,
            followLoopEnabled: followLoopEnabled
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
                    self.isMetronomePlaying, !self.isAudioPlaying else { return }
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
}
