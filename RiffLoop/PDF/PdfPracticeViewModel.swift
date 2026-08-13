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
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime = 0.0
    @Published private(set) var duration = 0.0
    @Published var playbackRate: Float = 1
    @Published var audioVolume: Float = 0.75
    @Published var bpm = 120.0
    @Published var beatOffset: TimeInterval? = 0
    @Published var synchronizationOffset = 0.0
    @Published var metronomeEnabled = true
    @Published var metronomeVolume: Float = 1
    @Published var pointA: TimeInterval?
    @Published var pointB: TimeInterval?
    @Published var loopEnabled = false

    @Published private(set) var readingPoints: [PdfReadingPoint] = []
    @Published private(set) var isRecordingReadingTrack = false
    @Published private(set) var isAutoFollowing = false
    @Published private(set) var autoFollowSuspended = false
    @Published private(set) var message: String?

    private let settingsStore = FilePracticeSettingsStore()
    private let metronome = MetronomeEngine()
    private var periodicObserver: Any?
    private var boundaryObserver: Any?

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

    func play() {
        guard player.currentItem != nil || metronomeEnabled else { return }
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        let hostStart = CMTimeAdd(
            hostNow,
            CMTime(seconds: 0.1, preferredTimescale: 1_000_000_000)
        )
        let anchor = TransportAnchor(
            mediaTime: currentTime,
            hostTime: hostStart.seconds,
            mediaRate: Double(playbackRate)
        )
        if player.currentItem != nil {
            player.setRate(playbackRate, time: cmTime(currentTime), atHostTime: hostStart)
        }
        if metronomeEnabled, let beatOffset {
            do {
                try metronome.synchronize(
                    timeline: BeatTimeline(
                        bpm: bpm,
                        beatOffset: beatOffset + synchronizationOffset,
                        subdivision: .quarter
                    ),
                    anchor: anchor,
                    volume: metronomeVolume
                )
            } catch {
                message = "节拍器启动失败：\(error.localizedDescription)"
            }
        }
        isPlaying = true
    }

    func pause() {
        player.pause()
        metronome.stop()
        isPlaying = false
        save()
    }

    func stop() {
        pause()
        seek(to: 0)
    }

    func seek(to seconds: TimeInterval) {
        let target = duration > 0 ? min(max(seconds, 0), duration) : max(seconds, 0)
        let wasPlaying = isPlaying
        player.pause()
        metronome.stop()
        player.seek(to: cmTime(target), toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, finished else { return }
                self.currentTime = target
                if wasPlaying { self.play() }
            }
        }
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
        bpm = min(max(bpm, 30), 300)
        playbackRate = min(max(playbackRate, 0.25), 1.5)
        audioVolume = min(max(audioVolume, 0), 1)
        metronomeVolume = min(max(metronomeVolume, 0), 1)
        synchronizationOffset = min(max(synchronizationOffset, -0.5), 0.5)
        player.volume = audioVolume
        rebuildBoundaryObserver()
        save()
        if isPlaying { play() }
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

    private func timeChanged(_ seconds: TimeInterval) {
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
            Task { @MainActor [weak self] in self?.seek(to: pointA) }
        }
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
        pointA = profile.pointA
        pointB = profile.pointB
        loopEnabled = profile.loopEnabled
            && profile.pointA != nil
            && profile.pointB.map { $0 > (profile.pointA ?? 0) } == true
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
            pointA: pointA,
            pointB: pointB,
            loopEnabled: loopEnabled,
            readingPoints: readingPoints
        )
        try? settingsStore.save(profile, kind: .pdf, fileName: pdfFileName)
    }

    private func cmTime(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
    }
}
