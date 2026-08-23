import XCTest
@testable import RiffLoop

final class PracticeMathTests: XCTestCase {
    func testTapTempoAveragesRecentIntervalsAndResetsAfterPause() {
        var tracker = TapTempoTracker()
        XCTAssertNil(tracker.recordTap(timestampMilliseconds: 1_000))
        XCTAssertEqual(tracker.recordTap(timestampMilliseconds: 1_500)!, 120, accuracy: 0.001)
        XCTAssertEqual(tracker.recordTap(timestampMilliseconds: 2_000)!, 120, accuracy: 0.001)
        XCTAssertNil(tracker.recordTap(timestampMilliseconds: 4_500))
    }

    func testPositionSnapsToNearestQuarterBeat() {
        XCTAssertEqual(snapToNearestBeat(1.470, beatOffset: 0, bpm: 120), 1.5, accuracy: 1e-12)
        XCTAssertEqual(snapToNearestBeat(1.220, beatOffset: 0, bpm: 120), 1.0, accuracy: 1e-12)
    }

    func testSpeedLadderChangesOnlyAtConfiguredLoopCadence() {
        let first = speedAfterCompletedLoop(currentSpeed: 0.75, targetSpeed: 1, previousCompletedLoops: 0, enabled: true)
        let second = speedAfterCompletedLoop(currentSpeed: first.playbackSpeed, targetSpeed: 1, previousCompletedLoops: first.completedLoops, enabled: true)
        let third = speedAfterCompletedLoop(currentSpeed: second.playbackSpeed, targetSpeed: 1, previousCompletedLoops: second.completedLoops, enabled: true)

        XCTAssertEqual(third.completedLoops, 3)
        XCTAssertEqual(third.playbackSpeed, 0.8, accuracy: 1e-12)
        XCTAssertEqual(
            speedAfterCompletedLoop(currentSpeed: 0.98, targetSpeed: 1, previousCompletedLoops: 2, enabled: true).playbackSpeed,
            1,
            accuracy: 1e-12
        )
    }

    func testSpeedLadderRoundRepresentsTheLoopCurrentlyInProgress() {
        XCTAssertEqual(speedLadderRoundInProgress(completedLoops: 0, loopsPerStep: 3), 1)
        XCTAssertEqual(speedLadderRoundInProgress(completedLoops: 1, loopsPerStep: 3), 2)
        XCTAssertEqual(speedLadderRoundInProgress(completedLoops: 2, loopsPerStep: 3), 3)
        XCTAssertEqual(speedLadderRoundInProgress(completedLoops: 3, loopsPerStep: 3), 1)
    }
}
