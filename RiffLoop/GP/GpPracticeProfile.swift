import Foundation

struct GpPracticeProfile: Codable, Equatable, Sendable {
    var scoreZoom = 1.0
    var playbackSpeed = 1.0
    var baseBpm: Double?
    var lastPositionTick = 0.0
    var displayedTrack = 0
    var mutedTracks: Set<Int> = []
    var soloTrack: Int?
    var trackVolumes: [Int: Double] = [:]
    var loopRange: GpLoopBarRange?
    var masterVolume = 0.75
    var backingVolume = 0.75
    var synthEnabled = true
    var backingEnabled = true
    var metronomeEnabled = false
    var metronomeVolume = 0.0
    var countInEnabled = false
    var countInVolume = 0.0
    var metronomeSubdivisionFactor = 1
    var beatAccents: [GpBeatAccent] = []
    var rangeLoopingEnabled = true
    var wholeSongLoopingEnabled = false
    var loopCountInEnabled = false
    var speedLadderEnabled = false
    var speedLadderTarget = 1.0
    var loopsPerSpeedStep = 3
    var speedLadderStep = 0.05
    var totalPracticeMilliseconds: Int64 = 0
    var totalCompletedLoops = 0
    var highestPracticeSpeed = 1.0

    init(
        scoreZoom: Double = 1.0,
        playbackSpeed: Double = 1.0,
        baseBpm: Double? = nil,
        lastPositionTick: Double = 0,
        displayedTrack: Int = 0,
        mutedTracks: Set<Int> = [],
        soloTrack: Int? = nil,
        trackVolumes: [Int: Double] = [:],
        loopRange: GpLoopBarRange? = nil,
        masterVolume: Double = 0.75,
        backingVolume: Double = 0.75,
        synthEnabled: Bool = true,
        backingEnabled: Bool = true,
        metronomeEnabled: Bool = false,
        metronomeVolume: Double = 0.0,
        countInEnabled: Bool = false,
        countInVolume: Double = 0.0,
        metronomeSubdivisionFactor: Int = 1,
        beatAccents: [GpBeatAccent] = [],
        rangeLoopingEnabled: Bool = true,
        wholeSongLoopingEnabled: Bool = false,
        loopCountInEnabled: Bool = false,
        speedLadderEnabled: Bool = false,
        speedLadderTarget: Double = 1.0,
        loopsPerSpeedStep: Int = 3,
        speedLadderStep: Double = 0.05,
        totalPracticeMilliseconds: Int64 = 0,
        totalCompletedLoops: Int = 0,
        highestPracticeSpeed: Double = 1.0
    ) {
        self.scoreZoom = scoreZoom
        self.playbackSpeed = playbackSpeed
        self.baseBpm = baseBpm
        self.lastPositionTick = lastPositionTick
        self.displayedTrack = displayedTrack
        self.mutedTracks = mutedTracks
        self.soloTrack = soloTrack
        self.trackVolumes = trackVolumes
        self.loopRange = loopRange
        self.masterVolume = masterVolume
        self.backingVolume = backingVolume
        self.synthEnabled = synthEnabled
        self.backingEnabled = backingEnabled
        self.metronomeEnabled = metronomeEnabled
        self.metronomeVolume = metronomeVolume
        self.countInEnabled = countInEnabled
        self.countInVolume = countInVolume
        self.metronomeSubdivisionFactor = metronomeSubdivisionFactor
        self.beatAccents = beatAccents
        self.rangeLoopingEnabled = rangeLoopingEnabled
        self.wholeSongLoopingEnabled = wholeSongLoopingEnabled
        self.loopCountInEnabled = loopCountInEnabled
        self.speedLadderEnabled = speedLadderEnabled
        self.speedLadderTarget = speedLadderTarget
        self.loopsPerSpeedStep = loopsPerSpeedStep
        self.speedLadderStep = speedLadderStep
        self.totalPracticeMilliseconds = totalPracticeMilliseconds
        self.totalCompletedLoops = totalCompletedLoops
        self.highestPracticeSpeed = highestPracticeSpeed
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        scoreZoom = try values.decodeIfPresent(Double.self, forKey: .scoreZoom) ?? 1
        playbackSpeed = try values.decodeIfPresent(Double.self, forKey: .playbackSpeed) ?? 1
        baseBpm = try values.decodeIfPresent(Double.self, forKey: .baseBpm)
        lastPositionTick = try values.decodeIfPresent(Double.self, forKey: .lastPositionTick) ?? 0
        displayedTrack = try values.decodeIfPresent(Int.self, forKey: .displayedTrack) ?? 0
        mutedTracks = try values.decodeIfPresent(Set<Int>.self, forKey: .mutedTracks) ?? []
        soloTrack = try values.decodeIfPresent(Int.self, forKey: .soloTrack)
        trackVolumes = try values.decodeIfPresent([Int: Double].self, forKey: .trackVolumes) ?? [:]
        loopRange = try values.decodeIfPresent(GpLoopBarRange.self, forKey: .loopRange)
        masterVolume = try values.decodeIfPresent(Double.self, forKey: .masterVolume) ?? 0.75
        backingVolume = try values.decodeIfPresent(Double.self, forKey: .backingVolume) ?? 0.75
        synthEnabled = try values.decodeIfPresent(Bool.self, forKey: .synthEnabled) ?? true
        backingEnabled = try values.decodeIfPresent(Bool.self, forKey: .backingEnabled) ?? true
        metronomeVolume = try values.decodeIfPresent(Double.self, forKey: .metronomeVolume) ?? 0
        metronomeEnabled = try values.decodeIfPresent(Bool.self, forKey: .metronomeEnabled)
            ?? (metronomeVolume > 0)
        countInVolume = try values.decodeIfPresent(Double.self, forKey: .countInVolume) ?? 0
        metronomeSubdivisionFactor = try values.decodeIfPresent(Int.self, forKey: .metronomeSubdivisionFactor) ?? 1
        beatAccents = try values.decodeIfPresent([GpBeatAccent].self, forKey: .beatAccents) ?? []
        countInEnabled = try values.decodeIfPresent(Bool.self, forKey: .countInEnabled)
            ?? (countInVolume > 0)
        rangeLoopingEnabled = try values.decodeIfPresent(Bool.self, forKey: .rangeLoopingEnabled)
            ?? (loopRange != nil)
        wholeSongLoopingEnabled = try values.decodeIfPresent(Bool.self, forKey: .wholeSongLoopingEnabled) ?? false
        loopCountInEnabled = try values.decodeIfPresent(Bool.self, forKey: .loopCountInEnabled) ?? false
        speedLadderEnabled = try values.decodeIfPresent(Bool.self, forKey: .speedLadderEnabled) ?? false
        speedLadderTarget = try values.decodeIfPresent(Double.self, forKey: .speedLadderTarget) ?? 1
        loopsPerSpeedStep = try values.decodeIfPresent(Int.self, forKey: .loopsPerSpeedStep) ?? 3
        speedLadderStep = try values.decodeIfPresent(Double.self, forKey: .speedLadderStep) ?? 0.05
        totalPracticeMilliseconds = try values.decodeIfPresent(Int64.self, forKey: .totalPracticeMilliseconds) ?? 0
        totalCompletedLoops = try values.decodeIfPresent(Int.self, forKey: .totalCompletedLoops) ?? 0
        highestPracticeSpeed = try values.decodeIfPresent(Double.self, forKey: .highestPracticeSpeed) ?? 1
    }
}
