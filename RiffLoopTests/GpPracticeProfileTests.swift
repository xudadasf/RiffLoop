import XCTest
@testable import RiffLoop

final class GpPracticeProfileTests: XCTestCase {
    func testProfileRoundTripKeepsDisplaySeparateFromSoundMix() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = FilePracticeSettingsStore(defaults: defaults)
        let profile = GpPracticeProfile(
            playbackSpeed: 0.8,
            displayedTrack: 2,
            mutedTracks: [0, 1],
            soloTrack: 2,
            trackVolumes: [0: 0.4, 2: 0.9],
            loopRange: GpLoopBarRange(
                firstBar: 4,
                lastBar: 7,
                startTick: 3_840,
                endTick: 7_680
            )
        )

        try store.save(profile, kind: .guitarPro, fileName: "此生不换.gp")

        XCTAssertEqual(
            try store.load(GpPracticeProfile.self, kind: .guitarPro, fileName: "此生不换.gp"),
            profile
        )
    }

    func testLegacyProfileRestoresNewPracticeControlsWithSafeDefaults() throws {
        let data = Data(#"{"playbackSpeed":0.8,"displayedTrack":0,"mutedTracks":[],"trackVolumes":{},"masterVolume":0.75,"backingVolume":0.75,"synthEnabled":true,"backingEnabled":true,"metronomeVolume":0.6,"countInVolume":0.4}"#.utf8)

        let profile = try JSONDecoder().decode(GpPracticeProfile.self, from: data)

        XCTAssertTrue(profile.metronomeEnabled)
        XCTAssertTrue(profile.countInEnabled)
        XCTAssertFalse(profile.wholeSongLoopingEnabled)
        XCTAssertEqual(profile.loopsPerSpeedStep, 3)
        XCTAssertEqual(profile.speedLadderStep, 0.05)
    }
}
