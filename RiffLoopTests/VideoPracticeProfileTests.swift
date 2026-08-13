import XCTest
@testable import RiffLoop

final class VideoPracticeProfileTests: XCTestCase {
    func testDefaultsStartAtBeginningWithFourFourAccents() {
        let profile = VideoPracticeProfile.default

        XCTAssertEqual(profile.lastPosition, 0)
        XCTAssertEqual(profile.beatOffset, 0)
        XCTAssertEqual(profile.beatGrouping, [4])
        XCTAssertEqual(profile.beatAccents, [.strong, .normal, .normal, .normal])
    }

    func testProfileRoundTripPreservesPerVideoPracticeSettings() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = FilePracticeSettingsStore(defaults: defaults)
        var profile = VideoPracticeProfile.default
        profile.bpm = 65
        profile.subdivision = .sixteenth
        profile.rhythmMode = .gapBars
        profile.pointA = 1
        profile.pointB = 9
        profile.loopEnabled = true
        profile.playbackRate = 0.8
        profile.lastPosition = 42

        try store.save(profile, kind: .video, fileName: "练习.mp4")

        XCTAssertEqual(
            try store.load(VideoPracticeProfile.self, kind: .video, fileName: "练习.mp4"),
            profile
        )
    }
}
