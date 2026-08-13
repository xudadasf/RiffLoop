import Foundation

struct GpPracticeProfile: Codable, Equatable, Sendable {
    var playbackSpeed = 1.0
    var displayedTrack = 0
    var mutedTracks: Set<Int> = []
    var soloTrack: Int?
    var trackVolumes: [Int: Double] = [:]
    var loopRange: GpLoopBarRange?
    var masterVolume = 0.75
    var backingVolume = 0.75
    var synthEnabled = true
    var backingEnabled = true
    var metronomeVolume = 0.0
    var countInVolume = 0.0
}
