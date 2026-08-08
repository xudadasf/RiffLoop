import AVFoundation
import Combine
import Foundation

@MainActor
final class PracticeViewModel: ObservableObject {
    @Published private(set) var player = AVPlayer()
    @Published private(set) var hasMedia = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorMessage: String?

    @Published var bpm: Double = 120
    @Published var subdivision: Subdivision = .quarter
    @Published var metronomeEnabled = true
    @Published var beatOffset: TimeInterval?
    @Published var pointA: TimeInterval?
    @Published var pointB: TimeInterval?
    @Published var loopEnabled = false
    @Published var playbackRate: Float = 1

    private let metronome = MetronomeEngine()
    private let mediaStore = ImportedMediaStore()
    private var periodicTimeObserver: Any?
    private var loopBoundaryObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var isLoopTransitioning = false
    private var transportGeneration: UInt64 = 0

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        installPeriodicTimeObserver()
    }

    deinit {
        if let periodicTimeObserver {
            player.removeTimeObserver(periodicTimeObserver)
        }
        if let loopBoundaryObserver {
            player.removeTimeObserver(loopBoundaryObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    func importMedia(from sourceURL: URL) {
        do {
            pause()
            let localURL = try mediaStore.copyIntoSandbox(sourceURL)
            let item = AVPlayerItem(url: localURL)
            player.replaceCurrentItem(with: item)
            observeEnd(of: item)

            currentTime = 0
            duration = 0
            beatOffset = nil
            pointA = nil
            pointB = nil
            loopEnabled = false
            rebuildLoopBoundaryObserver()
            hasMedia = true
            errorMessage = nil
        } catch {
            errorMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func togglePlayback() {
        guard hasMedia else { return }
        isPlaying ? pause() : coordinatedStart(at: currentTime)
    }

    func pause() {
        transportGeneration &+= 1
        player.cancelPendingPrerolls()
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        metronome.stop()
        isPlaying = false
        isLoopTransitioning = false
    }

    func seek(to seconds: TimeInterval) {
        guard hasMedia else { return }
        let target = min(max(seconds, 0), duration)
        let wasPlaying = isPlaying
        transportGeneration &+= 1
        let generation = transportGeneration

        player.cancelPendingPrerolls()
        player.pause()
        metronome.stop()
        isPlaying = false
        player.seek(
            to: cmTime(target),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.transportGeneration == generation else { return }
                guard finished else {
                    self.errorMessage = "无法跳转到所选时间。"
                    return
                }
                self.currentTime = target
                if wasPlaying {
                    self.coordinatedStart(at: target)
                }
            }
        }
    }

    func setBeatOne() {
        beatOffset = currentTime
        restartAfterTimingChange()
    }

    func setPointA() {
        pointA = currentTime
        normalizeLoopPointsAfterSettingA()
        rebuildLoopBoundaryObserver()
    }

    func setPointB() {
        guard pointA == nil || currentTime > (pointA ?? 0) else {
            errorMessage = "B 点必须晚于 A 点。"
            return
        }
        pointB = currentTime
        rebuildLoopBoundaryObserver()
    }

    func setLoopEnabled(_ enabled: Bool) {
        guard !enabled || validLoopRange != nil else {
            errorMessage = "请先设置 A 点和 B 点。"
            loopEnabled = false
            return
        }
        loopEnabled = enabled
        rebuildLoopBoundaryObserver()
    }

    func applyTimingSettings() {
        bpm = min(max(bpm, 30), 300)
        restartAfterTimingChange()
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        restartAfterTimingChange()
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    private var validLoopRange: (a: TimeInterval, b: TimeInterval)? {
        guard let pointA, let pointB, pointB > pointA else { return nil }
        return (pointA, pointB)
    }

    private func coordinatedStart(at mediaTime: TimeInterval) {
        transportGeneration &+= 1
        player.cancelPendingPrerolls()
        player.currentItem?.cancelPendingSeeks()

        let startTime = validLoopRange.map { range in
            mediaTime >= range.b ? range.a : mediaTime
        } ?? mediaTime

        do {
            if metronomeEnabled, let beatOffset {
                try metronome.prepare()
            }

            let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
            let hostStartTime = CMTimeAdd(
                hostNow,
                CMTime(seconds: 0.100, preferredTimescale: 1_000_000_000)
            )
            let hostStart = hostStartTime.seconds
            let anchor = TransportAnchor(
                mediaTime: startTime,
                hostTime: hostStart,
                mediaRate: Double(playbackRate)
            )

            player.setRate(
                playbackRate,
                time: cmTime(startTime),
                atHostTime: hostStartTime
            )

            if metronomeEnabled, let beatOffset {
                try metronome.synchronize(
                    timeline: BeatTimeline(
                        bpm: bpm,
                        beatOffset: beatOffset,
                        subdivision: subdivision
                    ),
                    anchor: anchor
                )
            } else {
                metronome.stop()
            }

            isPlaying = true
            currentTime = startTime
            errorMessage = nil
        } catch {
            player.pause()
            metronome.stop()
            isPlaying = false
            errorMessage = "音频引擎启动失败：\(error.localizedDescription)"
        }
    }

    private func restartAfterTimingChange() {
        guard isPlaying else { return }
        coordinatedStart(at: currentTime)
    }

    private func handleLoopBoundary() {
        guard
            loopEnabled,
            let range = validLoopRange,
            isPlaying,
            !isLoopTransitioning
        else { return }

        isLoopTransitioning = true
        transportGeneration &+= 1
        let generation = transportGeneration
        player.pause()
        metronome.stop()

        player.seek(
            to: cmTime(range.a),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.transportGeneration == generation else { return }
                guard finished else {
                    self.isLoopTransitioning = false
                    self.pause()
                    self.errorMessage = "Loop 回跳失败。"
                    return
                }
                self.player.preroll(atRate: self.playbackRate) { [weak self] ready in
                    Task { @MainActor [weak self] in
                        guard
                            let self,
                            self.transportGeneration == generation
                        else { return }
                        self.isLoopTransitioning = false
                        if ready, self.loopEnabled, self.isPlaying {
                            self.coordinatedStart(at: range.a)
                        } else {
                            self.pause()
                        }
                    }
                }
            }
        }
    }

    private func normalizeLoopPointsAfterSettingA() {
        if let pointB, let pointA, pointB <= pointA {
            self.pointB = nil
            loopEnabled = false
        }
    }

    private func installPeriodicTimeObserver() {
        periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                let seconds = time.seconds
                if seconds.isFinite {
                    self.currentTime = max(0, seconds)
                }

                if let item = self.player.currentItem {
                    let itemDuration = item.duration.seconds
                    if itemDuration.isFinite {
                        self.duration = max(0, itemDuration)
                    }
                }
            }
        }
    }

    private func rebuildLoopBoundaryObserver() {
        if let loopBoundaryObserver {
            player.removeTimeObserver(loopBoundaryObserver)
            self.loopBoundaryObserver = nil
        }

        guard loopEnabled, let range = validLoopRange else { return }
        loopBoundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: cmTime(range.b))],
            queue: .main
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleLoopBoundary()
            }
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pause()
            }
        }
    }

    private func cmTime(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
    }
}
