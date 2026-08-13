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
    var pointA: TimeInterval?
    var pointB: TimeInterval?
    var loopEnabled = false
    var readingPoints: [PdfReadingPoint] = []
}
