import XCTest
@testable import RiffLoop

final class GpStageInteractionTests: XCTestCase {
    @MainActor
    func testOutsideRangeTapPreservesCustomStagesAndProgress() {
        for playing in [false, true] {
            let model = makeStagedModel(playing: playing)
            let plan = model.gpStages
            let range = model.loopRange
            let readout = model.stageReadout(for: .gp)

            model.receive(.barHit(.init(index: 6, startTick: 5760, endTick: 6720,
                                       seekTick: 6000, seekEndTick: 6240)))

            assertStage(model, plan: plan, range: range, index: 1, remaining: 2)
            XCTAssertEqual(model.stageReadout(for: .gp), readout)
            XCTAssertEqual(model.gpProgress.rounds, 1)
            model.pause()
        }
    }

    @MainActor
    func testInsideRangeTapPreservesCustomStagesAndProgress() {
        for playing in [false, true] {
            let model = makeStagedModel(playing: playing)
            let plan = model.gpStages
            let range = model.loopRange
            let readout = model.stageReadout(for: .gp)

            model.receive(.barHit(.init(index: 1, startTick: 960, endTick: 1920,
                                       seekTick: 1200, seekEndTick: 1440)))

            assertStage(model, plan: plan, range: range, index: 1, remaining: 2)
            XCTAssertEqual(model.stageReadout(for: .gp), readout)
            XCTAssertEqual(model.gpProgress.rounds, 1)
            model.pause()
        }
    }

    @MainActor
    func testCancelledRangeReselectionRestoresOriginalRangeAndStageProgress() {
        for playing in [false, true] {
            let model = makeStagedModel(playing: playing)
            let plan = model.gpStages
            let range = model.loopRange
            let readout = model.stageReadout(for: .gp)

            model.receive(.pointerDown(.init(index: 4, startTick: 3840, endTick: 4800)))
            model.receive(.pointerMove(.init(index: 5, startTick: 4800, endTick: 5760)))
            model.receive(.pointerCancel)

            assertStage(model, plan: plan, range: range, index: 1, remaining: 2)
            XCTAssertEqual(model.stageReadout(for: .gp), readout)
            XCTAssertEqual(model.gpProgress.rounds, 1)
            XCTAssertNil(model.loopPreview)
            XCTAssertFalse(model.isPlaying, "Cancelling a selection must not restart playback")
            XCTAssertFalse(model.gpProgress.clockRunning)
        }
    }

    @MainActor
    func testCommittedRangeReselectionKeepsPlanAndRestartsCurrentStage() {
        for playing in [false, true] {
            let model = makeStagedModel(playing: playing)
            let plan = model.gpStages

            model.receive(.pointerDown(.init(index: 4, startTick: 3840, endTick: 4800)))
            model.receive(.pointerMove(.init(index: 5, startTick: 4800, endTick: 5760)))
            model.receive(.pointerUp)

            let newRange = GpLoopBarRange(firstBar: 4, lastBar: 5,
                                        startTick: 3840, endTick: 5760)
            assertStage(model, plan: plan, range: newRange, index: 1, remaining: 3)
            XCTAssertEqual(model.gpProgress.rounds, 0)
            XCTAssertNil(model.loopPreview)
            XCTAssertFalse(model.isPlaying, "Committing a selection waits for explicit Play")
            XCTAssertFalse(model.gpProgress.clockRunning)

            startPlayback(model)
            model.receive(.rangeLoopCompleted)
            assertStage(model, plan: plan, range: newRange, index: 1, remaining: 2)
            model.pause()
        }
    }

    @MainActor
    func testPauseResumeAndStopDoNotDisableCustomStages() {
        let model = makeStagedModel(playing: true)
        let plan = model.gpStages
        let range = model.loopRange

        model.pause()
        assertStage(model, plan: plan, range: range, index: 1, remaining: 2)
        XCTAssertFalse(model.isPlaying)

        startPlayback(model)
        assertStage(model, plan: plan, range: range, index: 1, remaining: 2)
        model.receive(.rangeLoopCompleted)
        assertStage(model, plan: plan, range: range, index: 1, remaining: 1)

        model.stop()
        // Stop intentionally returns to the first stage; it does not turn the plan off.
        assertStage(model, plan: plan, range: range, index: 0, remaining: 2)
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.gpProgress.clockRunning)
    }

    @MainActor
    func testVolumeZoomAndDisplayedTrackChangesPreserveCustomStages() {
        for playing in [false, true] {
            let model = makeStagedModel(playing: playing)
            let plan = model.gpStages
            let range = model.loopRange

            model.setMasterVolume(0.7)
            assertStage(model, plan: plan, range: range, index: 1, remaining: 2)
            model.setBackingVolume(0.5)
            assertStage(model, plan: plan, range: range, index: 1, remaining: 2)
            model.setMetronomeVolume(0.4)
            assertStage(model, plan: plan, range: range, index: 1, remaining: 2)
            model.setTrackVolume(index: 0, volume: 0.6)
            assertStage(model, plan: plan, range: range, index: 1, remaining: 2)
            model.setScoreZoom(1.3)
            assertStage(model, plan: plan, range: range, index: 1, remaining: 2)
            model.showTracks([1])
            assertStage(model, plan: plan, range: range, index: 1, remaining: 2)
            model.pause()
        }
    }

    @MainActor
    func testExplicitStageDisableStillExitsCustomStagesAndPreservesPlan() {
        let model = makeStagedModel(playing: false)
        let plan = model.gpStages
        let range = model.loopRange

        model.setGpStagesEnabled(false)

        XCTAssertFalse(model.gpStagesEnabled)
        XCTAssertTrue(model.rangeLoopingEnabled)
        XCTAssertEqual(model.loopRange, range)
        XCTAssertEqual(model.gpStages, plan)
        XCTAssertEqual(model.currentBpm, 85, accuracy: 0.001)
    }

    @MainActor
    func testExplicitRangeDisableStillExitsCustomStages() {
        let model = makeStagedModel(playing: false)
        let plan = model.gpStages
        let range = model.loopRange

        model.setRangeLoopingEnabled(false)

        XCTAssertFalse(model.gpStagesEnabled)
        XCTAssertFalse(model.rangeLoopingEnabled)
        XCTAssertEqual(model.loopRange, range)
        XCTAssertEqual(model.gpStages, plan)
        XCTAssertEqual(model.currentBpm, 85, accuracy: 0.001)
    }

    @MainActor
    func testExplicitClearLoopStillExitsCustomStages() {
        let model = makeStagedModel(playing: false)
        let plan = model.gpStages

        model.clearLoop()

        XCTAssertFalse(model.gpStagesEnabled)
        XCTAssertFalse(model.rangeLoopingEnabled)
        XCTAssertNil(model.loopRange)
        XCTAssertNil(model.loopPreview)
        XCTAssertEqual(model.gpStages, plan)
        XCTAssertEqual(model.currentBpm, 85, accuracy: 0.001)
    }

    @MainActor
    private func makeStagedModel(playing: Bool,
                                 file: StaticString = #filePath, line: UInt = #line) -> GpWebViewModel {
        let model = GpWebViewModel()
        model.receive(.pointerDown(.init(index: 1, startTick: 960, endTick: 1920)))
        model.receive(.pointerMove(.init(index: 2, startTick: 1920, endTick: 2880)))
        model.receive(.pointerUp)
        model.setPracticeStartBpm(85)
        let plan = TempoStagePlan(stages: [
            .init(bpm: 70, unit: .loops, length: 2),
            .init(bpm: 95, unit: .loops, length: 3),
            .init(bpm: 115, unit: .loops, length: 4)
        ], order: .bounce)
        model.setGpStages(plan)
        model.setGpStagesEnabled(true)
        model.selectStage(1, for: .gp)
        startPlayback(model)
        model.receive(.rangeLoopCompleted)
        if !playing { model.pause() }

        let range = GpLoopBarRange(firstBar: 1, lastBar: 2, startTick: 960, endTick: 2880)
        assertStage(model, plan: plan, range: range, index: 1, remaining: 2,
                    file: file, line: line)
        XCTAssertEqual(model.gpProgress.rounds, 1, file: file, line: line)
        XCTAssertEqual(model.isPlaying, playing, file: file, line: line)
        return model
    }

    @MainActor
    private func startPlayback(_ model: GpWebViewModel) {
        model.receive(.playerStateChanged(.init(state: 1, stopped: false, scorePlaying: true)))
    }

    @MainActor
    private func assertStage(_ model: GpWebViewModel, plan: TempoStagePlan,
                             range: GpLoopBarRange?, index: Int, remaining: Int,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(model.gpStagesEnabled, "The custom stage plan stays enabled", file: file, line: line)
        XCTAssertTrue(model.rangeLoopingEnabled, "The A/B loop stays enabled", file: file, line: line)
        XCTAssertEqual(model.gpStages, plan, file: file, line: line)
        XCTAssertEqual(model.loopRange, range, file: file, line: line)
        XCTAssertEqual(model.gpProgress.index, index, file: file, line: line)
        XCTAssertEqual(model.stageReadout(for: .gp).remaining, remaining, file: file, line: line)
        XCTAssertEqual(model.currentBpm, Double(plan.stages[index].bpm), accuracy: 0.001,
                       file: file, line: line)
    }
}
