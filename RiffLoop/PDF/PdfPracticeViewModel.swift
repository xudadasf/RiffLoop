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
    @Published private(set) var message: String?

    private let settingsStore = FilePracticeSettingsStore()
    private let metronome = MetronomeEngine()
    private var periodicObserver: Any?
    private var boundaryObserver: Any?
    private var lastPracticeSampleDate: Date?
    private var isLoopTransitioning = false

    var isPlaying: Bool { isAudioPlaying || isMetronomePlaying }

    init() {
        periodicObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.timeChanged(time.seconds)
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let periodicObserver { player.removeTimeObserver(periodicObserver) }
            if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        }
    }

    func openPdf(at url: URL) {
        guard let document = PDFDocument(url: url) else {
            message = "PDF 无法打开，请重新选择文件。"
            return
        }
        pause()
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
            }
        }
        save()
    }

    func bindAudio(at url: URL, restoringPosition: TimeInterval = 0) {
        pause()
        audioFileName = url.lastPathComponent
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        currentTime = max(0, restoringPosition)
        player.seek(to: cmTime(currentTime), toleranceBefore: .zero, toleranceAfter: .zero)
        player.volume = audioVolume
        rebuildBoundaryObserver()
        save()
    }

    func removeAudio() {
        pause()
        player.replaceCurrentItem(with: nil)
        audioFileName = nil
        currentTime = 0
        duration = 0
        pointA = nil
        pointB = nil
        loopEnabled = false
        save()
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
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
        recordPracticeTime()
        player.pause()
        metronome.stop()
        isAudioPlaying = false
        isMetronomePlaying = false
        lastPracticeSampleDate = nil
        save()
    }

    func pauseAudio() {
        recordPracticeTime()
        player.pause()
        isAudioPlaying = false
        lastPracticeSampleDate = isPlaying ? Date() : nil
        save()
    }

    func pauseMetronome() {
        recordPracticeTime()
        metronome.stop()
        isMetronomePlaying = false
        lastPracticeSampleDate = isPlaying ? Date() : nil
        save()
    }

    func stopAudio() {
        pauseAudio()
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, finished else { return }
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
        let target = duration > 0 ? min(max(seconds, 0), duration) : max(seconds, 0)
        let resumeAudio = isAudioPlaying
        let resumeMetronome = isMetronomePlaying
        recordPracticeTime()
        player.pause()
        metronome.stop()
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
        speedLadderEnabled = enabled
        completedLoops = 0
        save()
    }

    func setSpeedLadderTarget(_ target: Float) {
        speedLadderTarget = min(max(target, 0.25), 1.5)
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
    }

    func manualViewportInteraction() {
        requestedProgress = nil
        if isAutoFollowing {
            autoFollowSuspended = true
            message = "已暂停自动跟谱，点击“继续跟谱”恢复。"
        }
    }

    func startReadingTrackRecording() {
        isAutoFollowing = false
        autoFollowSuspended = false
        readingPoints = []
        isRecordingReadingTrack = true
        captureReadingPoint(force: true)
        message = "正在记录：照常滚动和翻页即可。"
    }

    func finishReadingTrackRecording() {
        captureReadingPoint(force: true)
        isRecordingReadingTrack = false
        message = "轨迹已保存，共 \(readingPoints.count) 个位置点。"
        save()
    }

    func toggleAutoFollow() {
        guard !readingPoints.isEmpty else {
            message = "这份 PDF 还没有轨迹，请先录制一次。"
            return
        }
        isRecordingReadingTrack = false
        isAutoFollowing.toggle()
        autoFollowSuspended = false
        message = isAutoFollowing ? "自动跟谱已开启。" : "自动跟谱已关闭。"
    }

    func resumeAutoFollow() {
        autoFollowSuspended = false
        updateAutoFollow()
    }

    func deleteReadingTrack() {
        readingPoints = []
        isRecordingReadingTrack = false
        isAutoFollowing = false
        autoFollowSuspended = false
        save()
    }

    func dismissMessage() { message = nil }

    private func startPlayback(
        audio shouldPlayAudio: Bool,
        metronome shouldPlayMetronome: Bool,
        includeCountIn: Bool = false
    ) {
        let startAudio = shouldPlayAudio && player.currentItem != nil
        let startMetronome = shouldPlayMetronome && metronomeEnabled && beatOffset != nil
        guard startAudio || startMetronome else { return }

        recordPracticeTime()
        player.pause()
        metronome.stop()

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
        lastPracticeSampleDate = isPlaying ? Date() : nil
        save()
    }

    private func timeChanged(_ seconds: TimeInterval) {
        recordPracticeTime()
        if seconds.isFinite { currentTime = max(0, seconds) }
        if let item = player.currentItem, item.duration.seconds.isFinite {
            duration = max(0, item.duration.seconds)
        }
        updateAutoFollow()
    }

    private func updateAutoFollow() {
        guard
            isAutoFollowing,
            !autoFollowSuspended,
            let target = pdfReadingTarget(at: currentTime, points: readingPoints)
        else { return }
        pageIndex = min(max(target.pageIndex, 0), max(0, pageCount - 1))
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
        isAudioPlaying = false
        isMetronomePlaying = false
        player.seek(to: cmTime(pointA), toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLoopTransitioning = false
                guard finished, self.loopEnabled else {
                    self.pause()
                    return
                }
                self.currentTime = pointA
                self.startPlayback(
                    audio: true,
                    metronome: resumeMetronome,
                    includeCountIn: self.loopCountInEnabled
                )
            }
        }
        save()
    }

    private func recordPracticeTime() {
        defer { lastPracticeSampleDate = isPlaying ? Date() : nil }
        guard isPlaying, let lastPracticeSampleDate else { return }
        accumulatedPracticeTime += max(0, Date().timeIntervalSince(lastPracticeSampleDate))
    }

    private func apply(_ profile: PdfPracticeProfile) {
        pageIndex = min(max(profile.pageIndex, 0), max(0, pageCount - 1))
        scaleFactor = min(max(profile.scaleFactor, 0.75), 2.5)
        verticalProgress = min(max(profile.verticalProgress, 0), 1)
        requestedProgress = verticalProgress
        audioFileName = profile.audioFileName
        playbackRate = profile.playbackRate
        audioVolume = profile.audioVolume
        bpm = profile.bpm
        beatOffset = profile.beatOffset
        synchronizationOffset = profile.synchronizationOffset
        metronomeEnabled = profile.metronomeEnabled
        metronomeVolume = profile.metronomeVolume
        subdivision = profile.subdivision
        beatsPerMeasure = min(max(profile.beatsPerMeasure, 1), 16)
        beatGrouping = profile.beatGrouping.reduce(0, +) == beatsPerMeasure
            ? profile.beatGrouping
            : [beatsPerMeasure]
        beatAccents = profile.beatAccents.count == beatsPerMeasure
            ? profile.beatAccents
            : defaultBeatAccents(beatsPerMeasure: beatsPerMeasure, grouping: beatGrouping)
        rhythmMode = profile.rhythmMode
        pointA = profile.pointA
        pointB = profile.pointB
        loopEnabled = profile.loopEnabled
            && profile.pointA != nil
            && profile.pointB.map { $0 > (profile.pointA ?? 0) } == true
        loopCountInEnabled = profile.loopCountInEnabled
        speedLadderEnabled = profile.speedLadderEnabled
        speedLadderTarget = min(max(profile.speedLadderTarget, 0.25), 1.5)
        loopsPerSpeedStep = min(max(profile.loopsPerSpeedStep, 1), 10)
        speedLadderStep = min(max(profile.speedLadderStep, 0.01), 0.25)
        accumulatedPracticeTime = max(0, profile.accumulatedPracticeTime)
        totalCompletedLoops = max(0, profile.totalCompletedLoops)
        highestPlaybackRate = max(playbackRate, profile.highestPlaybackRate)
        completedLoops = 0
        readingPoints = profile.readingPoints
    }

    private func save() {
        guard let pdfFileName else { return }
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
            pointA: pointA,
            pointB: pointB,
            loopEnabled: loopEnabled,
            loopCountInEnabled: loopCountInEnabled,
            speedLadderEnabled: speedLadderEnabled,
            speedLadderTarget: speedLadderTarget,
            loopsPerSpeedStep: loopsPerSpeedStep,
            speedLadderStep: speedLadderStep,
            accumulatedPracticeTime: accumulatedPracticeTime,
            totalCompletedLoops: totalCompletedLoops,
            highestPlaybackRate: highestPlaybackRate,
            readingPoints: readingPoints
        )
        try? settingsStore.save(profile, kind: .pdf, fileName: pdfFileName)
    }

    private func cmTime(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
    }
}
