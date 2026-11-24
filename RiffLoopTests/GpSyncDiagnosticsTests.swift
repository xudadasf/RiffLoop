import XCTest
@testable import RiffLoop

final class GpSyncDiagnosticsTests: XCTestCase {
    func testSyncSamplesHaveAnIndependentOneSecondLimit() {
        var policy = GpDiagnosticBridgePolicy()
        XCTAssertEqual(policy.kind(for: "positionChanged", now: 10), "sample")
        XCTAssertEqual(policy.kind(for: "reproductionSync", now: 10), "sample")
        XCTAssertNil(policy.kind(for: "positionChanged", now: 10.5))
        XCTAssertNil(policy.kind(for: "reproductionSync", now: 10.5))
        XCTAssertEqual(policy.kind(for: "reproductionSync", now: 11), "sample")
        XCTAssertEqual(policy.kind(for: "positionChanged", now: 11), "sample")
    }

    func testSyncAnomaliesArePreservedInsideTheSampleLimit() {
        var policy = GpDiagnosticBridgePolicy()
        XCTAssertEqual(policy.kind(for: "reproductionSync", now: 100), "sample")
        XCTAssertEqual(policy.kind(for: "reproductionSyncAnomaly", now: 100.1), "incident")
        XCTAssertEqual(policy.kind(for: "reproductionError", now: 100.2), "incident")
        XCTAssertEqual(policy.kind(for: "error", now: 100.3), "incident")
        XCTAssertEqual(policy.kind(for: "reproductionAudio", now: 100.4), "event")
        XCTAssertEqual(policy.kind(for: "reproductionSyncMark", now: 100.4), "event",
                       "A user's immediate snapshot must bypass the periodic sample limit")
        XCTAssertNil(policy.kind(for: "reproductionSync", now: 100.5))
    }

    @MainActor
    func testManualSyncMarkDebouncesWithoutChangingPlaybackOrSettings() {
        let model = GpWebViewModel()
        XCTAssertFalse(model.markSyncProblem(now: 10), "An empty practice screen has no score to mark")
        model.receive(.scoreLoaded(GpScoreMetadata(
            title: "Capture test", artist: "", bars: 4, hasBackingTrack: false, tracks: []
        )))
        model.receive(.playerReady)
        model.receive(.playerStateChanged(GpPlaybackState(state: 1, stopped: false)))
        model.receive(.positionChanged(GpPlaybackPosition(
            currentTime: 1_000, totalTime: 8_000, currentTick: 960, endTick: 7_680,
            isSeek: false
        )))
        let position = model.position
        let bpm = model.baseBpm
        let speed = model.playbackSpeed
        let loops = model.completedLoops

        XCTAssertTrue(model.markSyncProblem(now: 10))
        XCTAssertFalse(model.markSyncProblem(now: 10.1))
        XCTAssertFalse(model.markSyncProblem(now: 12.999))
        XCTAssertTrue(model.markSyncProblem(now: 13))
        XCTAssertFalse(model.markSyncProblem(now: .nan))
        XCTAssertTrue(model.isPlaying)
        XCTAssertTrue(model.playerReady)
        XCTAssertEqual(model.position, position)
        XCTAssertEqual(model.baseBpm, bpm)
        XCTAssertEqual(model.playbackSpeed, speed)
        XCTAssertEqual(model.completedLoops, loops)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testMarkingPausedScoreDoesNotResumePlayback() {
        let model = GpWebViewModel()
        model.receive(.scoreLoaded(GpScoreMetadata(
            title: "Paused capture", artist: "", bars: 1, hasBackingTrack: false, tracks: []
        )))
        model.receive(.playerReady)
        XCTAssertTrue(model.markSyncProblem(now: 20))
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.isStandaloneMetronomePlaying)
        XCTAssertNil(model.errorMessage)
    }
}
