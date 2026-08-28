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
    @Published var beatsPerMeasure = 4
    @Published var beatUnit = 4
    @Published var beatGrouping = [4]
    @Published var beatAccents: [BeatAccent] = [.strong, .normal, .normal, .normal]
    @Published var rhythmMode: RhythmMode = .click
    @Published var metronomeEnabled = true
    @Published var beatOffset: TimeInterval?
    @Published var pointA: TimeInterval?
    @Published var pointB: TimeInterval?
    @Published var loopEnabled = false
    @Published var playbackRate: Float = 1
    @Published var mediaVolume: Float = 0.75
    @Published var metronomeVolume: Float = 1
    @Published var synchronizationOffset: TimeInterval = 0
    @Published var snapLoopPointsToBeat = true
    @Published var loopCountInEnabled = false
    @Published var speedLadderEnabled = false
    @Published var speedLadderTarget: Float = 1
    @Published var loopsPerSpeedStep = 3
    @Published var speedLadderStep: Float = 0.05
    @Published private(set) var completedLoops = 0
    @Published private(set) var accumulatedPracticeTime: TimeInterval = 0
    @Published private(set) var highestPlaybackRate: Float = 1
    @Published private(set) var currentBeatIndex = 0

    private let metronome = MetronomeEngine()
    private let settingsStore = FilePracticeSettingsStore()
    private var periodicTimeObserver: Any?
    private var loopBoundaryObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var isLoopTransitioning = false
    private var transportGeneration: UInt64 = 0
    private var currentFileName: String?
    private var speedLadderBaseRate: Float?
    private var tapTempoTracker = TapTempoTracker()
    private var lastPracticeSampleDate: Date?
    private var lastProfileSaveDate = Date.distantPast

    var minimumSpeedLadderTarget: Float { speedLadderBaseRate ?? playbackRate }

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        player.volume = mediaVolume
        installPeriodicTimeObserver()
    }

    deinit {
        MainActor.assumeIsolated {
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
    }

    func openMedia(at url: URL) {
        pause()
        currentFileName = url.lastPathComponent
        let profile = (try? settingsStore.load(
            VideoPracticeProfile.self,
            kind: .video,
            fileName: url.lastPathComponent
        )) ?? .default
        apply(profile)

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        observeEnd(of: item)

        currentTime = max(0, profile.lastPosition)
        duration = 0
        rebuildLoopBoundaryObserver()
        hasMedia = true
        errorMessage = nil
        player.seek(to: cmTime(currentTime), toleranceBefore: .zero, toleranceAfter: .zero)
        saveProfile()
    }

    func dismissError() {
        errorMessage = nil
    }

    func togglePlayback() {
        guard hasMedia else { return }
        isPlaying ? pause() : preparePlaybackAndStart(at: currentTime)
    }

    func pause() {
        recordPracticeTime()
        transportGeneration &+= 1
        player.cancelPendingPrerolls()
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        metronome.stop()
        isPlaying = false
        isLoopTransitioning = false
        lastPracticeSampleDate = nil
        saveProfile()
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
                    self.player.preroll(atRate: self.playbackRate) { [weak self] ready in
                        Task { @MainActor [weak self] in
                            guard let self, self.transportGeneration == generation else { return }
                            guard ready else {
                                self.isPlaying = false
                                self.errorMessage = "视频尚未准备好，请重试。"
                                return
                            }
                            self.coordinatedStart(at: target)
                        }
                    }
                }
            }
        }
    }

    func setBeatOne() {
        beatOffset = currentTime
        saveProfile()
        restartAfterTimingChange()
    }

    func setPointA() {
        pointA = loopPoint(from: currentTime)
        normalizeLoopPointsAfterSettingA()
        rebuildLoopBoundaryObserver()
        saveProfile()
    }

    func setPointB() {
        let point = loopPoint(from: currentTime)
        guard pointA == nil || point > (pointA ?? 0) else {
            errorMessage = "B 点必须晚于 A 点。"
            return
        }
        pointB = point
        rebuildLoopBoundaryObserver()
        saveProfile()
    }

    func setLoopEnabled(_ enabled: Bool) {
        guard !enabled || validLoopRange != nil else {
            errorMessage = "请先设置 A 点和 B 点。"
            loopEnabled = false
            return
        }
        let loopEntryTarget = enabled ? pointA : nil
        loopEnabled = enabled
        completedLoops = 0
        rebuildLoopBoundaryObserver()
        saveProfile()
        if let loopEntryTarget {
            seek(to: loopEntryTarget)
        }
    }

    func applyTimingSettings() {
        bpm = min(max(bpm, 30), 300)
        beatsPerMeasure = min(max(beatsPerMeasure, 1), 16)
        if ![2, 4, 8, 16].contains(beatUnit) { beatUnit = 4 }
        if beatGrouping.reduce(0, +) != beatsPerMeasure {
            beatGrouping = defaultBeatGrouping(
                beatsPerMeasure: beatsPerMeasure,
                beatUnit: beatUnit
            )
        }
        if beatAccents.count != beatsPerMeasure {
            beatAccents = defaultBeatAccents(
                beatsPerMeasure: beatsPerMeasure,
                grouping: beatGrouping
            )
        }
        subdivision = effectiveSubdivision(subdivision, rhythmMode: rhythmMode)
        synchronizationOffset = min(max(synchronizationOffset, -0.5), 0.5)
        saveProfile()
        restartAfterTimingChange()
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = min(max(rate, 0.25), 1.5)
        if speedLadderEnabled {
            speedLadderBaseRate = playbackRate
        }
        speedLadderTarget = max(speedLadderTarget, playbackRate)
        completedLoops = 0
        highestPlaybackRate = max(highestPlaybackRate, playbackRate)
        saveProfile()
        restartAfterTimingChange()
    }

    func setMediaVolume(_ volume: Float) {
        mediaVolume = min(max(volume, 0), 1)
        player.volume = mediaVolume
        saveProfile()
    }

    func setMetronomeVolume(_ volume: Float) {
        metronomeVolume = min(max(volume, 0), 1)
        saveProfile()
        restartAfterTimingChange()
    }

    func setLoopCountInEnabled(_ enabled: Bool) {
        loopCountInEnabled = enabled
        saveProfile()
    }

    func setSnapLoopPointsToBeat(_ enabled: Bool) {
        snapLoopPointsToBeat = enabled
        if enabled {
            pointA = pointA.map { snapToNearestBeat($0, beatOffset: beatOffset, bpm: bpm) }
            pointB = pointB.map { snapToNearestBeat($0, beatOffset: beatOffset, bpm: bpm) }
            normalizeLoopPointsAfterSettingA()
            rebuildLoopBoundaryObserver()
        }
        saveProfile()
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
        saveProfile()
        if !enabled {
            restartAfterTimingChange()
        }
    }

    func setSpeedLadderTarget(_ target: Float) {
        speedLadderTarget = min(max(target, minimumSpeedLadderTarget), 1.5)
        completedLoops = 0
        saveProfile()
    }

    func setLoopsPerSpeedStep(_ loops: Int) {
        loopsPerSpeedStep = min(max(loops, 1), 10)
        completedLoops = 0
        saveProfile()
    }

    func setSpeedLadderStep(_ step: Float) {
        speedLadderStep = min(max(step, 0.01), 0.25)
        completedLoops = 0
        saveProfile()
    }

    func adjustSynchronization(by seconds: TimeInterval) {
        synchronizationOffset = min(max(synchronizationOffset + seconds, -0.5), 0.5)
        saveProfile()
        resynchronizeMetronome()
    }

    func setMeter(beats: Int, unit: Int) {
        beatsPerMeasure = min(max(beats, 1), 16)
        beatUnit = [2, 4, 8, 16].contains(unit) ? unit : 4
        beatGrouping = defaultBeatGrouping(
            beatsPerMeasure: beatsPerMeasure,
            beatUnit: beatUnit
        )
        beatAccents = defaultBeatAccents(
            beatsPerMeasure: beatsPerMeasure,
            grouping: beatGrouping
        )
        applyTimingSettings()
    }

    func setBeatGrouping(_ input: String) -> Bool {
        guard let grouping = parseBeatGrouping(input, beatsPerMeasure: beatsPerMeasure) else {
            return false
        }
        beatGrouping = grouping
        beatAccents = defaultBeatAccents(
            beatsPerMeasure: beatsPerMeasure,
            grouping: grouping
        )
        applyTimingSettings()
        return true
    }

    func cycleAccent(at index: Int) {
        guard beatAccents.indices.contains(index) else { return }
        beatAccents[index] = beatAccents[index].next
        applyTimingSettings()
    }

    func recordTap() {
        let milliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        if let estimate = tapTempoTracker.recordTap(timestampMilliseconds: milliseconds) {
            bpm = estimate
            applyTimingSettings()
        }
    }

    func clearLoop() {
        pointA = nil
        pointB = nil
        loopEnabled = false
        completedLoops = 0
        rebuildLoopBoundaryObserver()
        saveProfile()
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    private var validLoopRange: (a: TimeInterval, b: TimeInterval)? {
        guard let pointA, let pointB, pointB > pointA else { return nil }
        return (pointA, pointB)
    }

    private func preparePlaybackAndStart(at mediaTime: TimeInterval) {
        transportGeneration &+= 1
        let generation = transportGeneration
        let startTime = validLoopRange.map { range in
            mediaTime >= range.b ? range.a : mediaTime
        } ?? mediaTime

        player.cancelPendingPrerolls()
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        metronome.stop()
        isPlaying = false

        player.seek(
            to: cmTime(startTime),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.transportGeneration == generation else { return }
                guard finished else {
                    self.errorMessage = "无法准备视频播放。"
                    return
                }
                self.currentTime = startTime
                self.player.preroll(atRate: self.playbackRate) { [weak self] ready in
                    Task { @MainActor [weak self] in
                        guard
                            let self,
                            self.transportGeneration == generation
                        else { return }
                        guard ready else {
                            self.errorMessage = "视频尚未准备好，请重试。"
                            return
                        }
                        self.coordinatedStart(at: startTime)
                    }
                }
            }
        }
    }

    private func coordinatedStart(at mediaTime: TimeInterval, includeCountIn: Bool = false) {
        transportGeneration &+= 1
        player.cancelPendingPrerolls()
        player.currentItem?.cancelPendingSeeks()

        let startTime = validLoopRange.map { range in
            mediaTime >= range.b ? range.a : mediaTime
        } ?? mediaTime

        do {
            if metronomeEnabled, beatOffset != nil {
                try metronome.prepare()
            }

            let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
            let countInMediaDuration = includeCountIn && metronomeEnabled
                ? Double(beatsPerMeasure) * 60 / bpm
                : 0
            let anchorHostTime = CMTimeAdd(
                hostNow,
                CMTime(seconds: 0.100, preferredTimescale: 1_000_000_000)
            )
            let anchor = TransportAnchor(
                mediaTime: startTime - countInMediaDuration,
                hostTime: anchorHostTime.seconds,
                mediaRate: Double(playbackRate)
            )
            let mediaHostTime = CMTime(
                seconds: anchor.hostTime(forMediaTime: startTime),
                preferredTimescale: 1_000_000_000
            )

            player.setRate(
                playbackRate,
                time: cmTime(startTime),
                atHostTime: mediaHostTime
            )

            if metronomeEnabled, let beatOffset {
                try metronome.synchronize(
                    timeline: makeTimeline(beatOffset: beatOffset + synchronizationOffset),
                    anchor: anchor,
                    rhythmMode: rhythmMode,
                    volume: metronomeVolume
                )
            } else {
                metronome.stop()
            }

            isPlaying = true
            currentTime = startTime
            lastPracticeSampleDate = Date()
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

    private func resynchronizeMetronome() {
        guard isPlaying, metronomeEnabled, let beatOffset else { return }

        let playerTime = player.currentTime().seconds
        let mediaTime = playerTime.isFinite ? max(0, playerTime) : currentTime
        let lead: TimeInterval = 0.100
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock()).seconds + lead
        let anchor = TransportAnchor(
            mediaTime: mediaTime + lead * Double(playbackRate),
            hostTime: hostTime,
            mediaRate: Double(playbackRate)
        )

        do {
            try metronome.synchronize(
                timeline: makeTimeline(beatOffset: beatOffset + synchronizationOffset),
                anchor: anchor,
                rhythmMode: rhythmMode,
                volume: metronomeVolume
            )
        } catch {
            errorMessage = "节拍器同步失败：\(error.localizedDescription)"
        }
    }

    private func handleLoopBoundary() {
        guard
            loopEnabled,
            let range = validLoopRange,
            isPlaying,
            !isLoopTransitioning
        else { return }

        isLoopTransitioning = true
        let ladder = speedAfterCompletedLoop(
            currentSpeed: Double(playbackRate),
            targetSpeed: Double(speedLadderTarget),
            previousCompletedLoops: completedLoops,
            enabled: speedLadderEnabled,
            loopsPerStep: loopsPerSpeedStep,
            speedStep: Double(speedLadderStep)
        )
        completedLoops = ladder.completedLoops
        playbackRate = Float(ladder.playbackSpeed)
        highestPlaybackRate = max(highestPlaybackRate, playbackRate)
        saveProfile()
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
                            self.coordinatedStart(
                                at: range.a,
                                includeCountIn: self.loopCountInEnabled
                            )
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
                    self.updateCurrentBeat()
                    self.recordPracticeTime()
                    if Date().timeIntervalSince(self.lastProfileSaveDate) >= 2 {
                        self.saveProfile()
                    }
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

    private func loopPoint(from position: TimeInterval) -> TimeInterval {
        snapLoopPointsToBeat
            ? snapToNearestBeat(position, beatOffset: beatOffset, bpm: bpm)
            : position
    }

    private func makeTimeline(beatOffset: TimeInterval) -> BeatTimeline {
        BeatTimeline(
            bpm: bpm,
            beatOffset: beatOffset,
            subdivision: effectiveSubdivision(subdivision, rhythmMode: rhythmMode),
            quarterNotesPerMeasure: beatsPerMeasure,
            beatGrouping: beatGrouping,
            beatAccents: beatAccents
        )
    }

    private func updateCurrentBeat() {
        guard let beatOffset else {
            currentBeatIndex = 0
            return
        }
        let timeline = makeTimeline(beatOffset: beatOffset + synchronizationOffset)
        let event = timeline.eventIndex(atOrAfter: currentTime) - 1
        currentBeatIndex = timeline.beatIndex(event)
    }

    private func recordPracticeTime() {
        guard isPlaying else {
            lastPracticeSampleDate = nil
            return
        }
        let now = Date()
        if let lastPracticeSampleDate {
            let elapsed = min(max(now.timeIntervalSince(lastPracticeSampleDate), 0), 0.5)
            accumulatedPracticeTime += elapsed
            PracticeHistoryStore.shared.record(seconds: elapsed, endingAt: now)
        }
        self.lastPracticeSampleDate = now
    }

    private func apply(_ profile: VideoPracticeProfile) {
        bpm = min(max(profile.bpm, 30), 300)
        beatsPerMeasure = min(max(profile.beatsPerMeasure, 1), 16)
        beatUnit = [2, 4, 8, 16].contains(profile.beatUnit) ? profile.beatUnit : 4
        beatGrouping = profile.beatGrouping.reduce(0, +) == beatsPerMeasure
            ? profile.beatGrouping
            : defaultBeatGrouping(beatsPerMeasure: beatsPerMeasure, beatUnit: beatUnit)
        beatAccents = profile.beatAccents.count == beatsPerMeasure
            ? profile.beatAccents
            : defaultBeatAccents(beatsPerMeasure: beatsPerMeasure, grouping: beatGrouping)
        subdivision = profile.subdivision
        rhythmMode = profile.rhythmMode
        metronomeEnabled = profile.metronomeEnabled
        mediaVolume = min(max(profile.mediaVolume, 0), 1)
        metronomeVolume = min(max(profile.metronomeVolume, 0), 1)
        synchronizationOffset = min(max(profile.synchronizationOffset, -0.5), 0.5)
        beatOffset = profile.beatOffset
        pointA = profile.pointA
        pointB = profile.pointB
        loopEnabled = profile.loopEnabled
            && profile.pointA != nil
            && profile.pointB.map { $0 > (profile.pointA ?? 0) } == true
        snapLoopPointsToBeat = profile.snapLoopPointsToBeat
        playbackRate = min(max(profile.playbackRate, 0.25), 1.5)
        loopCountInEnabled = profile.loopCountInEnabled
        speedLadderEnabled = profile.speedLadderEnabled
        speedLadderBaseRate = speedLadderEnabled ? playbackRate : nil
        speedLadderTarget = min(
            max(profile.speedLadderTarget, minimumSpeedLadderTarget),
            1.5
        )
        loopsPerSpeedStep = min(max(profile.loopsPerSpeedStep, 1), 10)
        speedLadderStep = min(max(profile.speedLadderStep, 0.01), 0.25)
        accumulatedPracticeTime = max(0, profile.accumulatedPracticeTime)
        completedLoops = max(0, profile.completedLoops)
        highestPlaybackRate = max(profile.highestPlaybackRate, playbackRate)
        player.volume = mediaVolume
    }

    private func saveProfile() {
        guard let currentFileName else { return }
        let profile = VideoPracticeProfile(
            bpm: bpm,
            beatsPerMeasure: beatsPerMeasure,
            beatUnit: beatUnit,
            beatGrouping: beatGrouping,
            beatAccents: beatAccents,
            subdivision: subdivision,
            rhythmMode: rhythmMode,
            metronomeEnabled: metronomeEnabled,
            mediaVolume: mediaVolume,
            metronomeVolume: metronomeVolume,
            synchronizationOffset: synchronizationOffset,
            beatOffset: beatOffset,
            pointA: pointA,
            pointB: pointB,
            loopEnabled: loopEnabled,
            snapLoopPointsToBeat: snapLoopPointsToBeat,
            playbackRate: playbackRate,
            loopCountInEnabled: loopCountInEnabled,
            speedLadderEnabled: speedLadderEnabled,
            speedLadderTarget: speedLadderTarget,
            loopsPerSpeedStep: loopsPerSpeedStep,
            speedLadderStep: speedLadderStep,
            lastPosition: currentTime,
            accumulatedPracticeTime: accumulatedPracticeTime,
            completedLoops: completedLoops,
            highestPlaybackRate: highestPlaybackRate
        )
        do {
            try settingsStore.save(
                profile,
                kind: .video,
                fileName: currentFileName
            )
            lastProfileSaveDate = Date()
        } catch {
            errorMessage = "练习设置保存失败：\(error.localizedDescription)"
        }
    }
}
