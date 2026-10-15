import XCTest
@testable import RiffLoop

final class GpTempoTests: XCTestCase {
    func testTypicalScoreKeepsTheProjectBpmRange() {
        XCTAssertEqual(gpCustomBaseBpmRange(originalBpm: 120), 30 ... 300)
    }

    func testDirectBpmRangeIsNotRestrictedByUnusedMultipliers() {
        XCTAssertEqual(gpCustomBaseBpmRange(originalBpm: 300), 38 ... 300)
        XCTAssertEqual(gpCustomBaseBpmRange(originalBpm: 40), 30 ... 300)
    }

    func testWiderMultipliersStayWithinTheEngineRange() {
        XCTAssertEqual(gpPracticeSpeedRange(originalBpm: 120, baseBpm: 120), 0.25 ... 2)
        let slow = gpPracticeSpeedRange(originalBpm: 300, baseBpm: 38)
        XCTAssertGreaterThan(slow.lowerBound, 0.9)
        XCTAssertEqual(gpEffectivePlaybackSpeed(originalBaseBpm: 300, baseBpm: 38,
            practiceMultiplier: slow.lowerBound), 0.125, accuracy: 1e-12)
        XCTAssertEqual(gpPracticeSpeedRange(originalBpm: 40, baseBpm: 300).upperBound, 8 / 7.5, accuracy: 1e-12)
    }

    @MainActor
    func testDirectTempoEntryResetsMultiplierAndKeepsIndependentTempoSeparate() {
        let model = GpWebViewModel()
        model.setPlaybackSpeed(0.25)
        model.setPracticeStartBpm(53)
        XCTAssertEqual(model.playbackSpeed, 1)
        XCTAssertEqual(model.practiceStartBpm, 53)
        XCTAssertEqual(model.currentBpm, 53)
        model.setStandaloneBpm(87)
        XCTAssertEqual(model.practiceStartBpm, 53)
        XCTAssertEqual(model.standaloneBpm, 87)
        model.setPlaybackSpeed(2)
        XCTAssertEqual(model.currentBpm, 106)
        XCTAssertEqual(model.standaloneBpm, 87)
    }

    func testOneTimesUsesTheUsersCurrentBaseBpm() {
        XCTAssertEqual(
            gpEffectivePlaybackSpeed(
                originalBaseBpm: 120,
                baseBpm: 90,
                practiceMultiplier: 1
            ),
            0.75,
            accuracy: 1e-12
        )
    }

    func testVariableTempoMapIsScaledWithoutFlatteningIt() {
        XCTAssertEqual(
            gpScaledCurrentBpm(
                originalTempo: 90,
                originalBaseBpm: 120,
                baseBpm: 150,
                practiceMultiplier: 0.8
            ),
            90,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            gpScaledCurrentBpm(
                originalTempo: 180,
                originalBaseBpm: 120,
                baseBpm: 150,
                practiceMultiplier: 0.8
            ),
            180,
            accuracy: 1e-12
        )
    }
}
