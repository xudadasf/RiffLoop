import XCTest
@testable import RiffLoop

final class PdfPracticeProfileTests: XCTestCase {
    func testLegacyProfileGetsAndroidParityDefaults() throws {
        let data = Data(#"{"pageIndex":1,"scaleFactor":1.25,"verticalProgress":0.5,"audioPosition":3,"playbackRate":0.8,"audioVolume":0.75,"bpm":120,"beatOffset":0,"synchronizationOffset":0,"metronomeEnabled":true,"metronomeVolume":1,"loopEnabled":false,"readingPoints":[]}"#.utf8)

        let profile = try JSONDecoder().decode(PdfPracticeProfile.self, from: data)

        XCTAssertEqual(profile.subdivision, .quarter)
        XCTAssertEqual(profile.beatAccents, [.strong, .normal, .normal, .normal])
        XCTAssertFalse(profile.loopCountInEnabled)
        XCTAssertEqual(profile.loopsPerSpeedStep, 3)
        XCTAssertEqual(profile.speedLadderStep, 0.05)
    }

    func testExtendedProfileRoundTrips() throws {
        let profile = PdfPracticeProfile(
            loopEnabled: true,
            loopCountInEnabled: true,
            speedLadderEnabled: true,
            speedLadderTarget: 1.25,
            loopsPerSpeedStep: 2,
            speedLadderStep: 0.1,
            accumulatedPracticeTime: 120,
            totalCompletedLoops: 8,
            highestPlaybackRate: 1.1
        )

        XCTAssertEqual(try JSONDecoder().decode(PdfPracticeProfile.self, from: JSONEncoder().encode(profile)), profile)
    }
}
