import XCTest
@testable import RiffLoop

final class GpTempoTests: XCTestCase {
    func testTypicalScoreKeepsTheProjectBpmRange() {
        XCTAssertEqual(gpCustomBaseBpmRange(originalBpm: 120), 30 ... 300)
    }

    func testCustomRangeKeepsEveryPracticeMultiplierInsideAlphaTabLimits() {
        XCTAssertEqual(gpCustomBaseBpmRange(originalBpm: 300), 75 ... 300)
        XCTAssertEqual(gpCustomBaseBpmRange(originalBpm: 40), 30 ... 213)
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
