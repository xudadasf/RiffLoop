import XCTest
import AVFAudio
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
    func testRangeReselectionPreservesDescendingDirectionOfBouncingPlan() {
        let model = makeStagedModel(playing: true)
        let plan = model.gpStages
        let originalRange = model.loopRange
        for _ in 0..<2 { model.receive(.rangeLoopCompleted) }
        assertStage(model, plan: plan, range: originalRange, index: 2, remaining: 4)
        for _ in 0..<4 { model.receive(.rangeLoopCompleted) }
        assertStage(model, plan: plan, range: originalRange, index: 1, remaining: 3)
        model.receive(.rangeLoopCompleted)
        assertStage(model, plan: plan, range: originalRange, index: 1, remaining: 2)

        model.receive(.pointerDown(.init(index: 4, startTick: 3840, endTick: 4800)))
        model.receive(.pointerMove(.init(index: 5, startTick: 4800, endTick: 5760)))
        model.receive(.pointerUp)

        let newRange = GpLoopBarRange(firstBar: 4, lastBar: 5, startTick: 3840, endTick: 5760)
        assertStage(model, plan: plan, range: newRange, index: 1, remaining: 3)
        startPlayback(model)
        for _ in 0..<3 { model.receive(.rangeLoopCompleted) }
        assertStage(model, plan: plan, range: newRange, index: 0, remaining: 2)
        model.pause()
    }

    @MainActor
    func testClearLoopDuringPreviewPreventsLatePointerUpFromRecreatingRange() {
        let model = makeStagedModel(playing: true)
        let plan = model.gpStages
        model.receive(.pointerDown(.init(index: 4, startTick: 3840, endTick: 4800)))
        model.receive(.pointerMove(.init(index: 5, startTick: 4800, endTick: 5760)))
        XCTAssertNotNil(model.loopPreview)

        model.clearLoop()
        model.receive(.pointerUp)
        model.receive(.pointerCancel)

        XCTAssertNil(model.loopRange, "A late gesture event cannot undo an explicit clear")
        XCTAssertNil(model.loopPreview)
        XCTAssertFalse(model.rangeLoopingEnabled)
        XCTAssertFalse(model.gpStagesEnabled)
        XCTAssertEqual(model.gpStages, plan)
        XCTAssertFalse(model.isPlaying)
    }

    @MainActor
    func testOutsideRangeTapStillExitsOrdinaryABLoop() {
        for playing in [false, true] {
            let model = makeRangeModel()
            let range = model.loopRange
            if playing { startPlayback(model) }

            model.receive(.barHit(.init(index: 6, startTick: 5760, endTick: 6720,
                                       seekTick: 6000, seekEndTick: 6240)))

            XCTAssertFalse(model.rangeLoopingEnabled)
            XCTAssertFalse(model.gpStagesEnabled)
            XCTAssertFalse(model.speedLadderEnabled)
            XCTAssertEqual(model.loopRange, range, "Ordinary A/B retains its stored range when disabled")
            model.pause()
        }
    }

    @MainActor
    func testCancelledRangePreviewPreservesLegacyLadderAndItsProgress() {
        let model = makeLegacyLadderModel()
        let range = model.loopRange
        let speed = model.playbackSpeed
        let loops = model.completedLoops
        let round = model.currentSpeedLadderRound

        model.receive(.pointerDown(.init(index: 4, startTick: 3840, endTick: 4800)))
        model.receive(.pointerMove(.init(index: 5, startTick: 4800, endTick: 5760)))
        model.receive(.pointerCancel)

        XCTAssertTrue(model.speedLadderEnabled)
        XCTAssertTrue(model.rangeLoopingEnabled)
        XCTAssertFalse(model.gpStagesEnabled)
        XCTAssertEqual(model.loopRange, range)
        XCTAssertEqual(model.playbackSpeed, speed, accuracy: 0.001)
        XCTAssertEqual(model.completedLoops, loops)
        XCTAssertEqual(model.currentSpeedLadderRound, round)
        XCTAssertEqual(model.speedLadderTarget, 1.2, accuracy: 0.001)
        XCTAssertEqual(model.speedLadderStep, 0.1, accuracy: 0.001)
        XCTAssertEqual(model.loopsPerSpeedStep, 2)
        XCTAssertNil(model.loopPreview)
        XCTAssertFalse(model.isPlaying)

        startPlayback(model)
        model.receive(.rangeLoopCompleted)
        XCTAssertEqual(model.playbackSpeed, 1.0, accuracy: 0.001,
                       "The resumed loop uses the preserved cadence")
        model.pause()
    }

    @MainActor
    func testCommittedRangePreviewStillExitsLegacyLadderAndRestoresManualSpeed() {
        let model = makeLegacyLadderModel()

        model.receive(.pointerDown(.init(index: 4, startTick: 3840, endTick: 4800)))
        model.receive(.pointerMove(.init(index: 5, startTick: 4800, endTick: 5760)))
        model.receive(.pointerUp)

        XCTAssertFalse(model.speedLadderEnabled)
        XCTAssertFalse(model.gpStagesEnabled)
        XCTAssertTrue(model.rangeLoopingEnabled)
        XCTAssertEqual(model.loopRange, GpLoopBarRange(firstBar: 4, lastBar: 5,
                                                     startTick: 3840, endTick: 5760))
        XCTAssertEqual(model.playbackSpeed, 0.8, accuracy: 0.001)
        XCTAssertEqual(model.completedLoops, 0)
        XCTAssertNil(model.loopPreview)
        XCTAssertFalse(model.isPlaying)
    }

    @MainActor
    func testCancelledRangePreviewPreservesWholeSongLooping() {
        for hasStoredRange in [false, true] {
            let model = hasStoredRange ? makeRangeModel() : GpWebViewModel()
            let range = model.loopRange
            model.setWholeSongLoopingEnabled(true)
            startPlayback(model)

            model.receive(.pointerDown(.init(index: 4, startTick: 3840, endTick: 4800)))
            model.receive(.pointerMove(.init(index: 5, startTick: 4800, endTick: 5760)))
            model.receive(.pointerCancel)

            XCTAssertTrue(model.wholeSongLoopingEnabled)
            XCTAssertFalse(model.rangeLoopingEnabled)
            XCTAssertEqual(model.loopRange, range)
            XCTAssertFalse(model.gpStagesEnabled)
            XCTAssertFalse(model.speedLadderEnabled)
            XCTAssertNil(model.loopPreview)
            XCTAssertFalse(model.isPlaying)
        }
    }

    @MainActor
    func testCancelledPreviewKeepsPausedTimedStageReadoutAndClockStopped() {
        let model = makeRangeModel()
        let plan = TempoStagePlan(stages: [
            .init(bpm: 70, unit: .seconds, length: 15),
            .init(bpm: 95, unit: .seconds, length: 30)
        ])
        model.setGpStages(plan)
        model.setGpStagesEnabled(true)
        model.selectStage(1, for: .gp)
        startPlayback(model)
        model.pause()
        // Capture only after pausing, so comparisons never depend on wall-clock timing.
        let readout = model.stageReadout(for: .gp)
        let range = model.loopRange

        model.receive(.pointerDown(.init(index: 4, startTick: 3840, endTick: 4800)))
        model.receive(.pointerMove(.init(index: 5, startTick: 4800, endTick: 5760)))
        model.receive(.pointerCancel)

        assertStage(model, plan: plan, range: range, index: 1, remaining: readout.remaining)
        XCTAssertEqual(model.stageReadout(for: .gp), readout)
        XCTAssertFalse(model.gpProgress.clockRunning)
        XCTAssertEqual(model.gpProgress.readout(in: plan, now: ProcessInfo.processInfo.systemUptime + 3600), readout,
                       "Time spent in the selection UI must not run a paused stage clock")
        XCTAssertFalse(model.isPlaying)
    }

    @MainActor
    func testPreviewRejectsLatePlaybackAndLoopCompletionEventsForBothLadderModes() {
        for legacy in [false, true] {
            let model = legacy ? makeLegacyLadderModel() : makeStagedModel(playing: true)
            let range = model.loopRange
            let plan = model.gpStages
            let readout = model.stageReadout(for: .gp)
            let loops = model.completedLoops
            let totalLoops = model.totalCompletedLoops
            let speed = model.playbackSpeed
            model.receive(.pointerDown(.init(index: 4, startTick: 3840, endTick: 4800)))
            model.receive(.pointerMove(.init(index: 5, startTick: 4800, endTick: 5760)))

            for state in [GpPlaybackState(state: 1, stopped: false, scorePlaying: true),
                          GpPlaybackState(state: 0, stopped: false, transitioning: true)] {
                model.receive(.playerStateChanged(state))
                XCTAssertFalse(model.isPlaying)
                XCTAssertFalse(model.gpProgress.clockRunning)
                model.receive(.rangeLoopCompleted)
                XCTAssertEqual(model.completedLoops, loops)
                XCTAssertEqual(model.totalCompletedLoops, totalLoops)
                XCTAssertEqual(model.stageReadout(for: .gp), readout)
                XCTAssertEqual(model.playbackSpeed, speed, accuracy: 0.001)
            }

            model.receive(.pointerCancel)
            XCTAssertEqual(model.loopRange, range)
            XCTAssertTrue(model.rangeLoopingEnabled)
            XCTAssertEqual(model.gpStagesEnabled, !legacy)
            XCTAssertEqual(model.speedLadderEnabled, legacy)
            XCTAssertEqual(model.gpStages, plan)
            XCTAssertFalse(model.isPlaying)
        }
    }

    @MainActor
    func testLateCompletionAfterPreviewEndsDoesNotCountUntilPlaybackResumes() {
        for mode in ["custom", "legacy", "ordinary"] {
            for commit in [false, true] {
                let model: GpWebViewModel
                switch mode {
                case "custom": model = makeStagedModel(playing: true)
                case "legacy": model = makeLegacyLadderModel()
                default:
                    model = makeRangeModel()
                    startPlayback(model)
                }
                defer { model.pause() }
                model.receive(.pointerDown(.init(index: 4, startTick: 3840, endTick: 4800)))
                model.receive(.pointerMove(.init(index: 5, startTick: 4800, endTick: 5760)))
                model.receive(commit ? .pointerUp : .pointerCancel)
                XCTAssertFalse(model.isPlaying)
                XCTAssertNil(model.loopPreview)
                XCTAssertTrue(model.rangeLoopingEnabled)
                let range = model.loopRange
                let readout = model.stageReadout(for: .gp)
                let loops = model.completedLoops
                let totalLoops = model.totalCompletedLoops
                let speed = model.playbackSpeed
                let customEnabled = model.gpStagesEnabled
                let legacyEnabled = model.speedLadderEnabled

                model.receive(.rangeLoopCompleted)

                XCTAssertEqual(model.completedLoops, loops, "\(mode), commit=\(commit)")
                XCTAssertEqual(model.totalCompletedLoops, totalLoops)
                XCTAssertEqual(model.stageReadout(for: .gp), readout)
                XCTAssertEqual(model.playbackSpeed, speed, accuracy: 0.001)
                XCTAssertEqual(model.loopRange, range)
                XCTAssertEqual(model.gpStagesEnabled, customEnabled)
                XCTAssertEqual(model.speedLadderEnabled, legacyEnabled)
                XCTAssertFalse(model.isPlaying)

                startPlayback(model)
                model.receive(.rangeLoopCompleted)
                XCTAssertEqual(model.totalCompletedLoops, totalLoops + 1,
                               "A real loop after explicit resume must still count")
                XCTAssertEqual(model.completedLoops, loops + 1)
            }
        }
    }

    @MainActor
    func testStageSelectionIsUnavailableWhileRangePreviewIsActive() {
        let model = makeStagedModel(playing: false)
        let plan = model.gpStages
        let range = model.loopRange
        XCTAssertTrue(model.canSelectStage(for: .gp))

        model.receive(.pointerDown(.init(index: 4, startTick: 3840, endTick: 4800)))
        model.receive(.pointerMove(.init(index: 5, startTick: 4800, endTick: 5760)))
        XCTAssertFalse(model.canSelectStage(for: .gp))
        model.selectStage(0, for: .gp)
        assertStage(model, plan: plan, range: range, index: 1, remaining: 2)
        XCTAssertNotNil(model.loopPreview)

        model.receive(.pointerCancel)
        XCTAssertTrue(model.canSelectStage(for: .gp))
        assertStage(model, plan: plan, range: range, index: 1, remaining: 2)
    }

    @MainActor
    func testExplicitLoopModeChangeDuringPreviewSurvivesLatePointerUp() {
        for useWholeSong in [false, true] {
            let model = makeStagedModel(playing: true)
            let range = model.loopRange
            let plan = model.gpStages
            model.receive(.pointerDown(.init(index: 4, startTick: 3840, endTick: 4800)))
            model.receive(.pointerMove(.init(index: 5, startTick: 4800, endTick: 5760)))

            if useWholeSong { model.setWholeSongLoopingEnabled(true) }
            else { model.setRangeLoopingEnabled(false) }
            model.receive(.pointerUp)
            model.receive(.pointerCancel)

            XCTAssertEqual(model.wholeSongLoopingEnabled, useWholeSong)
            XCTAssertFalse(model.rangeLoopingEnabled)
            XCTAssertFalse(model.gpStagesEnabled)
            XCTAssertEqual(model.loopRange, range)
            XCTAssertEqual(model.gpStages, plan)
            XCTAssertEqual(model.currentBpm, 85, accuracy: 0.001)
            XCTAssertNil(model.loopPreview)
            XCTAssertFalse(model.isPlaying)
        }
    }

    @MainActor
    func testAudioRouteDisconnectPausesWithoutLosingCustomStageProgress() {
        for duringCountIn in [false, true] {
            let model = makeStagedModel(playing: true)
            let plan = model.gpStages
            let range = model.loopRange
            if duringCountIn {
                model.receive(.playerStateChanged(.init(state: 0, stopped: false, transitioning: true)))
            }

            model.handleAudioRouteChange(reason: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue)
            assertStage(model, plan: plan, range: range, index: 1, remaining: 2)
            XCTAssertFalse(model.isPlaying)
            XCTAssertFalse(model.gpProgress.clockRunning)

            model.handleAudioRouteChange(reason: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue)
            assertStage(model, plan: plan, range: range, index: 1, remaining: 2)
            XCTAssertFalse(model.isPlaying, "Reconnecting an output waits for explicit Play")
            XCTAssertFalse(model.gpProgress.clockRunning)
        }
    }

    @MainActor
    func testBackgroundAndForegroundPreservePausedStageAndRange() {
        for playing in [false, true] {
            let model = makeStagedModel(playing: playing)
            let plan = model.gpStages
            let range = model.loopRange

            model.setSceneActive(false)
            assertStage(model, plan: plan, range: range, index: 1, remaining: 2)
            XCTAssertFalse(model.isPlaying)
            XCTAssertFalse(model.gpProgress.clockRunning)

            model.setSceneActive(true)
            assertStage(model, plan: plan, range: range, index: 1, remaining: 2)
            XCTAssertFalse(model.isPlaying, "Returning to the foreground does not start playback")
            XCTAssertFalse(model.gpProgress.clockRunning)
        }
    }

    @MainActor
    func testCountInSettingsPreserveCustomStageProgress() {
        for playing in [false, true] {
            let model = makeStagedModel(playing: playing)
            let plan = model.gpStages
            let range = model.loopRange

            for enabled in [true, false] {
                model.setLoopCountInEnabled(enabled)
                assertStage(model, plan: plan, range: range, index: 1, remaining: 2)
                model.setCountInEnabled(enabled)
                assertStage(model, plan: plan, range: range, index: 1, remaining: 2)
                XCTAssertEqual(model.isPlaying, playing)
            }
            model.pause()
        }
    }

    @MainActor
    func testStandaloneConfigurationDoesNotChangeGPStageOrPlayback() {
        for playing in [false, true] {
            let model = makeStagedModel(playing: playing)
            let plan = model.gpStages
            let range = model.loopRange
            let standalonePlan = TempoStagePlan(stages: [
                .init(bpm: 80, unit: .seconds, length: 10),
                .init(bpm: 100, unit: .seconds, length: 20)
            ], order: .bounce)

            model.setStandaloneStages(standalonePlan)
            model.setStandaloneStagesEnabled(true)
            assertStage(model, plan: plan, range: range, index: 1, remaining: 2)
            model.setStandaloneBpm(90)
            model.setStandaloneBeats(3)
            model.setStandaloneSubdivision(2)
            model.setStandaloneVolume(0.6)
            model.cycleStandaloneAccent(at: 1)
            model.setStandaloneGap(.init(enabled: true, soundBars: 3, silentBars: 2))
            assertStage(model, plan: plan, range: range, index: 1, remaining: 2)
            XCTAssertEqual(model.standaloneStages, standalonePlan)
            XCTAssertFalse(model.isStandaloneMetronomePlaying)
            XCTAssertEqual(model.isPlaying, playing)

            model.setStandaloneStagesEnabled(false)
            assertStage(model, plan: plan, range: range, index: 1, remaining: 2)
            XCTAssertEqual(model.isPlaying, playing)
            model.pause()
        }
    }

    @MainActor
    func testOutsideRangeTapPreservesLegacyLadderSpeedAndProgress() {
        let model = makeLegacyLadderModel()
        let range = model.loopRange
        let loops = model.completedLoops
        let speed = model.playbackSpeed

        model.receive(.barHit(.init(index: 6, startTick: 5760, endTick: 6720,
                                   seekTick: 6000, seekEndTick: 6240)))

        XCTAssertTrue(model.speedLadderEnabled)
        XCTAssertTrue(model.rangeLoopingEnabled)
        XCTAssertEqual(model.loopRange, range)
        XCTAssertEqual(model.completedLoops, loops)
        XCTAssertEqual(model.playbackSpeed, speed, accuracy: 0.001)
        model.pause()
    }

    @MainActor
    func testRangeTempoAnchorSurvivesCancelAndUpdatesForCommittedRange() {
        let model = makeStagedModel(playing: false)
        model.receive(.positionChanged(.init(currentTime: 500, totalTime: 9000,
            currentTick: 960, endTick: 9600, originalTempo: 90)))
        XCTAssertEqual(model.currentBpm, 95, accuracy: 0.001)

        model.receive(.pointerDown(.init(index: 4, startTick: 3840, endTick: 4800)))
        model.receive(.pointerCancel)
        XCTAssertEqual(model.currentBpm, 95, accuracy: 0.001)

        model.receive(.pointerDown(.init(index: 4, startTick: 3840, endTick: 4800)))
        model.receive(.pointerUp)
        model.receive(.positionChanged(.init(currentTime: 3000, totalTime: 9000,
            currentTick: 3840, endTick: 9600, originalTempo: 180)))
        XCTAssertEqual(model.gpProgress.index, 1)
        XCTAssertEqual(model.currentBpm, 95, accuracy: 0.001)
        XCTAssertTrue(model.gpStagesEnabled)
        XCTAssertFalse(model.isPlaying)
    }

    @MainActor
    private func makeRangeModel() -> GpWebViewModel {
        let model = GpWebViewModel()
        model.receive(.pointerDown(.init(index: 1, startTick: 960, endTick: 1920)))
        model.receive(.pointerMove(.init(index: 2, startTick: 1920, endTick: 2880)))
        model.receive(.pointerUp)
        model.setPracticeStartBpm(85)
        return model
    }

    @MainActor
    private func makeLegacyLadderModel(file: StaticString = #filePath,
                                      line: UInt = #line) -> GpWebViewModel {
        let model = makeRangeModel()
        model.setPlaybackSpeed(0.8)
        model.setSpeedLadderTarget(1.2)
        model.setSpeedLadderStep(0.1)
        model.setLoopsPerSpeedStep(2)
        model.setSpeedLadderEnabled(true)
        startPlayback(model)
        for _ in 0..<3 { model.receive(.rangeLoopCompleted) }
        XCTAssertTrue(model.speedLadderEnabled, file: file, line: line)
        XCTAssertTrue(model.rangeLoopingEnabled, file: file, line: line)
        XCTAssertEqual(model.playbackSpeed, 0.9, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(model.completedLoops, 3, file: file, line: line)
        return model
    }

    @MainActor
    private func makeStagedModel(playing: Bool,
                                 file: StaticString = #filePath, line: UInt = #line) -> GpWebViewModel {
        let model = makeRangeModel()
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
