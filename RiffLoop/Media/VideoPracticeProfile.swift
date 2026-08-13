import Foundation

struct VideoPracticeProfile: Codable, Equatable, Sendable {
    var bpm: Double
    var beatsPerMeasure: Int
    var beatUnit: Int
    var beatGrouping: [Int]
    var beatAccents: [BeatAccent]
    var subdivision: Subdivision
    var rhythmMode: RhythmMode
    var metronomeEnabled: Bool
    var mediaVolume: Float
    var metronomeVolume: Float
    var synchronizationOffset: TimeInterval
    var beatOffset: TimeInterval?
    var pointA: TimeInterval?
    var pointB: TimeInterval?
    var loopEnabled: Bool
    var snapLoopPointsToBeat: Bool
    var playbackRate: Float
    var loopCountInEnabled: Bool
    var speedLadderEnabled: Bool
    var speedLadderTarget: Float
    var loopsPerSpeedStep: Int
    var speedLadderStep: Float
    var lastPosition: TimeInterval
    var accumulatedPracticeTime: TimeInterval
    var completedLoops: Int
    var highestPlaybackRate: Float

    static let `default` = VideoPracticeProfile(
        bpm: 120,
        beatsPerMeasure: 4,
        beatUnit: 4,
        beatGrouping: [4],
        beatAccents: [.strong, .normal, .normal, .normal],
        subdivision: .quarter,
        rhythmMode: .click,
        metronomeEnabled: true,
        mediaVolume: 0.75,
        metronomeVolume: 1,
        synchronizationOffset: 0,
        beatOffset: 0,
        pointA: nil,
        pointB: nil,
        loopEnabled: false,
        snapLoopPointsToBeat: true,
        playbackRate: 1,
        loopCountInEnabled: false,
        speedLadderEnabled: false,
        speedLadderTarget: 1,
        loopsPerSpeedStep: 3,
        speedLadderStep: 0.05,
        lastPosition: 0,
        accumulatedPracticeTime: 0,
        completedLoops: 0,
        highestPlaybackRate: 1
    )
}
