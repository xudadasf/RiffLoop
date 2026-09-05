import Foundation

struct PdfPracticeProfile: Codable, Equatable, Sendable {
    var pageIndex = 0
    var scaleFactor = 1.0
    var verticalProgress = 0.0
    var audioFileName: String?
    var audioPosition = 0.0
    var playbackRate: Float = 1
    var audioVolume: Float = 0.75
    var bpm = 120.0
    var beatOffset: TimeInterval? = 0
    var synchronizationOffset = 0.0
    var metronomeEnabled = true
    var metronomeVolume: Float = 1
    var subdivision: Subdivision = .quarter
    var beatsPerMeasure = 4
    var beatGrouping = [4]
    var beatAccents: [BeatAccent] = [.strong, .normal, .normal, .normal]
    var rhythmMode: RhythmMode = .click
    var pointA: TimeInterval?
    var pointB: TimeInterval?
    var loopEnabled = false
    var loopCountInEnabled = false
    var speedLadderEnabled = false
    var speedLadderTarget: Float = 1
    var loopsPerSpeedStep = 3
    var speedLadderStep: Float = 0.05
    var accumulatedPracticeTime: TimeInterval = 0
    var totalCompletedLoops = 0
    var highestPlaybackRate: Float = 1
    var readingPoints: [PdfReadingPoint] = []
    var readingStartCue: String?
    var followLoopEnabled = false

    init(
        pageIndex: Int = 0,
        scaleFactor: Double = 1,
        verticalProgress: Double = 0,
        audioFileName: String? = nil,
        audioPosition: Double = 0,
        playbackRate: Float = 1,
        audioVolume: Float = 0.75,
        bpm: Double = 120,
        beatOffset: TimeInterval? = 0,
        synchronizationOffset: Double = 0,
        metronomeEnabled: Bool = true,
        metronomeVolume: Float = 1,
        subdivision: Subdivision = .quarter,
        beatsPerMeasure: Int = 4,
        beatGrouping: [Int] = [4],
        beatAccents: [BeatAccent] = [.strong, .normal, .normal, .normal],
        rhythmMode: RhythmMode = .click,
        pointA: TimeInterval? = nil,
        pointB: TimeInterval? = nil,
        loopEnabled: Bool = false,
        loopCountInEnabled: Bool = false,
        speedLadderEnabled: Bool = false,
        speedLadderTarget: Float = 1,
        loopsPerSpeedStep: Int = 3,
        speedLadderStep: Float = 0.05,
        accumulatedPracticeTime: TimeInterval = 0,
        totalCompletedLoops: Int = 0,
        highestPlaybackRate: Float = 1,
        readingPoints: [PdfReadingPoint] = [],
        readingStartCue: String? = nil,
        followLoopEnabled: Bool = false
    ) {
        self.pageIndex = pageIndex
        self.scaleFactor = scaleFactor
        self.verticalProgress = verticalProgress
        self.audioFileName = audioFileName
        self.audioPosition = audioPosition
        self.playbackRate = playbackRate
        self.audioVolume = audioVolume
        self.bpm = bpm
        self.beatOffset = beatOffset
        self.synchronizationOffset = synchronizationOffset
        self.metronomeEnabled = metronomeEnabled
        self.metronomeVolume = metronomeVolume
        self.subdivision = subdivision
        self.beatsPerMeasure = beatsPerMeasure
        self.beatGrouping = beatGrouping
        self.beatAccents = beatAccents
        self.rhythmMode = rhythmMode
        self.pointA = pointA
        self.pointB = pointB
        self.loopEnabled = loopEnabled
        self.loopCountInEnabled = loopCountInEnabled
        self.speedLadderEnabled = speedLadderEnabled
        self.speedLadderTarget = speedLadderTarget
        self.loopsPerSpeedStep = loopsPerSpeedStep
        self.speedLadderStep = speedLadderStep
        self.accumulatedPracticeTime = accumulatedPracticeTime
        self.totalCompletedLoops = totalCompletedLoops
        self.highestPlaybackRate = highestPlaybackRate
        self.readingPoints = readingPoints
        self.readingStartCue = readingStartCue
        self.followLoopEnabled = followLoopEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pageIndex = try values.decodeIfPresent(Int.self, forKey: .pageIndex) ?? 0
        scaleFactor = try values.decodeIfPresent(Double.self, forKey: .scaleFactor) ?? 1
        verticalProgress = try values.decodeIfPresent(Double.self, forKey: .verticalProgress) ?? 0
        audioFileName = try values.decodeIfPresent(String.self, forKey: .audioFileName)
        audioPosition = try values.decodeIfPresent(Double.self, forKey: .audioPosition) ?? 0
        playbackRate = try values.decodeIfPresent(Float.self, forKey: .playbackRate) ?? 1
        audioVolume = try values.decodeIfPresent(Float.self, forKey: .audioVolume) ?? 0.75
        bpm = try values.decodeIfPresent(Double.self, forKey: .bpm) ?? 120
        beatOffset = try values.decodeIfPresent(TimeInterval.self, forKey: .beatOffset) ?? 0
        synchronizationOffset = try values.decodeIfPresent(Double.self, forKey: .synchronizationOffset) ?? 0
        metronomeEnabled = try values.decodeIfPresent(Bool.self, forKey: .metronomeEnabled) ?? true
        metronomeVolume = try values.decodeIfPresent(Float.self, forKey: .metronomeVolume) ?? 1
        subdivision = try values.decodeIfPresent(Subdivision.self, forKey: .subdivision) ?? .quarter
        beatsPerMeasure = try values.decodeIfPresent(Int.self, forKey: .beatsPerMeasure) ?? 4
        beatGrouping = try values.decodeIfPresent([Int].self, forKey: .beatGrouping) ?? [beatsPerMeasure]
        beatAccents = try values.decodeIfPresent([BeatAccent].self, forKey: .beatAccents)
            ?? defaultBeatAccents(beatsPerMeasure: beatsPerMeasure, grouping: beatGrouping)
        rhythmMode = try values.decodeIfPresent(RhythmMode.self, forKey: .rhythmMode) ?? .click
        pointA = try values.decodeIfPresent(TimeInterval.self, forKey: .pointA)
        pointB = try values.decodeIfPresent(TimeInterval.self, forKey: .pointB)
        loopEnabled = try values.decodeIfPresent(Bool.self, forKey: .loopEnabled) ?? false
        loopCountInEnabled = try values.decodeIfPresent(Bool.self, forKey: .loopCountInEnabled) ?? false
        speedLadderEnabled = try values.decodeIfPresent(Bool.self, forKey: .speedLadderEnabled) ?? false
        speedLadderTarget = try values.decodeIfPresent(Float.self, forKey: .speedLadderTarget) ?? 1
        loopsPerSpeedStep = try values.decodeIfPresent(Int.self, forKey: .loopsPerSpeedStep) ?? 3
        speedLadderStep = try values.decodeIfPresent(Float.self, forKey: .speedLadderStep) ?? 0.05
        accumulatedPracticeTime = try values.decodeIfPresent(TimeInterval.self, forKey: .accumulatedPracticeTime) ?? 0
        totalCompletedLoops = try values.decodeIfPresent(Int.self, forKey: .totalCompletedLoops) ?? 0
        highestPlaybackRate = try values.decodeIfPresent(Float.self, forKey: .highestPlaybackRate) ?? 1
        readingPoints = try values.decodeIfPresent([PdfReadingPoint].self, forKey: .readingPoints) ?? []
        readingStartCue = try values.decodeIfPresent(String.self, forKey: .readingStartCue)
        followLoopEnabled = try values.decodeIfPresent(Bool.self, forKey: .followLoopEnabled) ?? false
    }
}
