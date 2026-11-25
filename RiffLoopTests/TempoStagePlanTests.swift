import XCTest
@testable import RiffLoop

final class TempoStagePlanTests: XCTestCase {
    func testSelectingGpStageResetsItsClockAndRejectsInvalidIndices() {
        let plan = TempoStagePlan(stages: [.init(bpm: 75, unit: .seconds, length: 8),
                                          .init(bpm: 90, unit: .loops, length: 3)])
        var progress = LoopStageProgress()
        progress.setPlaying(true, now: 10)
        progress.setPlaying(false, now: 13)
        XCTAssertEqual(progress.readout(in: plan, now: 100).remaining, 5)
        let paused = progress.readout(in: plan, now: 100)
        XCTAssertFalse(progress.start(at: -1, in: plan))
        XCTAssertFalse(progress.start(at: plan.stages.count, in: plan))
        XCTAssertEqual(progress.readout(in: plan, now: 200), paused)

        XCTAssertTrue(progress.start(at: 1, in: plan))
        XCTAssertEqual(progress.readout(in: plan, now: 200).remaining, 3)
        XCTAssertFalse(progress.clockRunning, "Selecting a stage must not start its clock")
        progress.setPlaying(true, now: 200)
        progress.finishLoop(in: plan, now: 201)
        progress.setPlaying(false, now: 201)
        XCTAssertEqual(progress.readout(in: plan, now: 900).remaining, 2)
        progress.setPlaying(true, now: 900)
        XCTAssertEqual(progress.readout(in: plan, now: 901).remaining, 2,
                       "Ordinary resume must preserve the unfinished stage")
        progress.setPlaying(false, now: 901)
        XCTAssertTrue(progress.start(at: 1, in: plan))
        XCTAssertEqual(progress.rounds, 0, "Explicitly selecting the current stage restarts it")
        XCTAssertEqual(progress.readout(in: plan, now: 999).remaining, 3)
        XCTAssertTrue(progress.start(at: 0, in: plan))
        XCTAssertEqual(progress.readout(in: plan, now: 999).remaining, 8)
        XCTAssertFalse(progress.clockRunning)
    }

    func testSelectingGpStageStartsForwardAndRetainsWrapOrBounceOrder() {
        for order in [TempoStageOrder.wrap, .bounce] {
            let plan = TempoStagePlan(stages: [70, 85, 100, 115].map {
                TempoStage(bpm: $0, unit: .loops, length: 1)
            }, order: order)
            var progress = LoopStageProgress()
            XCTAssertTrue(progress.start(at: 3, in: plan))
            progress.finishLoop(in: plan, now: 1)
            XCTAssertEqual(progress.index, order == .bounce ? 2 : 0)
            // In bounce mode the previous traversal is now descending.
            XCTAssertTrue(progress.start(at: 2, in: plan))
            progress.finishLoop(in: plan, now: 2)
            XCTAssertEqual(progress.index, 3, "A newly chosen middle stage starts towards the end")
            progress.finishLoop(in: plan, now: 3)
            XCTAssertEqual(progress.index, order == .bounce ? 2 : 0)
        }
        let single = TempoStagePlan(stages: [.init(bpm: 80, unit: .loops, length: 1)], order: .bounce)
        var progress = LoopStageProgress()
        XCTAssertTrue(progress.start(at: 0, in: single))
        progress.finishLoop(in: single, now: 1)
        XCTAssertEqual(progress.index, 0)
        XCTAssertFalse(progress.start(at: 0, in: TempoStagePlan(stages: [])))
    }

    func testStandaloneStageStartUsesForwardOccurrenceAndAnAudibleDownbeat() throws {
        for order in [TempoStageOrder.wrap, .bounce] {
            let plan = TempoStagePlan(stages: [
                .init(bpm: 60, unit: .seconds, length: 4),
                .init(bpm: 120, unit: .seconds, length: 2),
                .init(bpm: 90, unit: .seconds, length: 1)
            ], order: order)
            let schedule = MetronomeStageSchedule(plan: plan, beats: 4, subdivisions: 4)
            let chosen = try XCTUnwrap(schedule.start(of: 1))
            XCTAssertEqual(chosen.start, 4, accuracy: 1e-8)
            XCTAssertEqual(chosen.firstEvent, 16)
            let position = schedule.position(at: chosen.start)
            XCTAssertEqual(position.stage, 1)
            XCTAssertEqual(position.elapsedInStage, 0, accuracy: 1e-8)
            XCTAssertEqual(position.nextEvent, chosen.firstEvent)
            XCTAssertEqual(schedule.time(of: position.nextEvent), chosen.start, accuracy: 1e-8)
            XCTAssertEqual(schedule.position(at: chosen.start + 2).stage, 2,
                           "Selecting a repeated bounce stage uses the forward occurrence")
            let gap = MetronomeGapPattern(enabled: true, soundBars: 1, silentBars: 2)
            let firstMeasure = chosen.firstEvent / 16
            XCTAssertFalse(gap.sounds(in: firstMeasure), "The original absolute phase would be silent")
            XCTAssertTrue(gap.sounds(in: firstMeasure, startingAt: firstMeasure))
            XCTAssertFalse(gap.sounds(in: firstMeasure + 1, startingAt: firstMeasure))
            XCTAssertNil(schedule.start(of: -1))
            XCTAssertNil(schedule.start(of: plan.stages.count))
        }
    }

    @MainActor
    func testGpStageSelectionRequiresPausedRangeAndPreservesOrdinaryResume() {
        let model = GpWebViewModel()
        let plan = TempoStagePlan(stages: [.init(bpm: 70, unit: .loops, length: 1),
                                          .init(bpm: 95, unit: .loops, length: 3),
                                          .init(bpm: 115, unit: .seconds, length: 7)])
        model.setGpStages(plan)
        XCTAssertFalse(model.canSelectStage(for: .gp))
        model.selectStage(1, for: .gp)
        XCTAssertEqual(model.gpProgress.index, 0)
        model.receive(.pointerDown(.init(index: 0, startTick: 0, endTick: 960)))
        model.receive(.pointerUp)
        model.setGpStagesEnabled(true)
        XCTAssertTrue(model.canSelectStage(for: .gp))
        model.selectStage(1, for: .gp)
        XCTAssertEqual(model.currentBpm, 95, accuracy: 0.001)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.stageReadout(for: .gp).remaining, 3)
        model.receive(.playerStateChanged(.init(state: 1, stopped: false, scorePlaying: true)))
        model.receive(.rangeLoopCompleted)
        XCTAssertFalse(model.canSelectStage(for: .gp))
        model.selectStage(0, for: .gp)
        XCTAssertEqual(model.gpProgress.index, 1)
        model.pause()
        XCTAssertEqual(model.stageReadout(for: .gp).remaining, 2)
        model.receive(.playerStateChanged(.init(state: 1, stopped: false, scorePlaying: true)))
        XCTAssertEqual(model.stageReadout(for: .gp).remaining, 2)
        model.receive(.rangeLoopCompleted)
        model.pause()
        XCTAssertEqual(model.stageReadout(for: .gp).remaining, 1)
        let completedLoops = model.totalCompletedLoops
        model.selectStage(1, for: .gp)
        XCTAssertEqual(model.stageReadout(for: .gp).remaining, 3)
        XCTAssertEqual(model.totalCompletedLoops, completedLoops, "Selection does not erase practice totals")

        model.selectStage(2, for: .gp)
        XCTAssertEqual(model.currentBpm, 115, accuracy: 0.001)
        XCTAssertEqual(model.stageReadout(for: .gp).remaining, 7)
        model.receive(.playerStateChanged(.init(state: 0, stopped: false, transitioning: true)))
        XCTAssertFalse(model.canSelectStage(for: .gp), "Count-in is part of active playback")
        XCTAssertFalse(model.gpProgress.clockRunning)
        model.selectStage(0, for: .gp)
        XCTAssertEqual(model.gpProgress.index, 2)
        model.receive(.playerStateChanged(.init(state: 1, stopped: false, scorePlaying: false)))
        XCTAssertFalse(model.gpProgress.clockRunning)
        XCTAssertEqual(model.stageReadout(for: .gp).remaining, 7)
        model.pause()
        model.stop()
        XCTAssertEqual(model.gpProgress.index, 0)
        XCTAssertEqual(model.currentBpm, 70, accuracy: 0.001)
        model.clearLoop()
        XCTAssertFalse(model.canSelectStage(for: .gp))
    }

    @MainActor
    func testStageSelectionKeepsTransportsIndependentAndRejectsStaleIndices() {
        let model = GpWebViewModel()
        model.setGpStages(.init(stages: [.init(bpm: 75, unit: .loops, length: 2),
                                        .init(bpm: 95, unit: .loops, length: 3)]))
        model.receive(.pointerDown(.init(index: 0, startTick: 0, endTick: 960)))
        model.receive(.pointerUp)
        model.setGpStagesEnabled(true)
        model.setStandaloneStages(.init(stages: [.init(bpm: 60, unit: .seconds, length: 4),
                                                .init(bpm: 87, unit: .seconds, length: 8),
                                                .init(bpm: 113, unit: .seconds, length: 13)], order: .bounce))
        model.setStandaloneStagesEnabled(true)
        XCTAssertEqual(model.stageReadout(for: .standalone).index, 0)
        model.selectStage(2, for: .standalone)
        XCTAssertEqual(model.playingStandaloneBpm, 113)
        XCTAssertEqual(model.stageReadout(for: .standalone).remaining, 13)
        XCTAssertEqual(model.gpProgress.index, 0)
        model.selectStage(1, for: .gp)
        XCTAssertEqual(model.currentBpm, 95, accuracy: 0.001)
        XCTAssertEqual(model.stageReadout(for: .standalone).index, 2)
        for index in [-1, 99] {
            model.selectStage(index, for: .gp)
            model.selectStage(index, for: .standalone)
        }
        XCTAssertEqual(model.gpProgress.index, 1)
        XCTAssertEqual(model.stageReadout(for: .standalone).index, 2)

        model.receive(.playerStateChanged(.init(state: 1, stopped: false, scorePlaying: true)))
        XCTAssertFalse(model.canSelectStage(for: .standalone))
        model.selectStage(0, for: .standalone)
        XCTAssertEqual(model.stageReadout(for: .standalone).index, 2)
        model.pause()
        model.setStandaloneBeats(7)
        model.setStandaloneSubdivision(8)
        XCTAssertEqual(model.stageReadout(for: .standalone).index, 2)
        XCTAssertEqual(model.stageReadout(for: .standalone).remaining, 13,
                       "Changing the meter before Play keeps the selected stage at its first beat")
        XCTAssertFalse(model.isStandaloneMetronomePlaying)

        model.setGpStages(.init(stages: [.init(bpm: 80, unit: .loops, length: 2)]))
        model.setStandaloneStages(.init(stages: [.init(bpm: 90, unit: .seconds, length: 9)]))
        XCTAssertEqual(model.gpProgress.index, 0)
        XCTAssertEqual(model.stageReadout(for: .gp).remaining, 2)
        XCTAssertEqual(model.stageReadout(for: .standalone).index, 0)
        XCTAssertEqual(model.stageReadout(for: .standalone).remaining, 9)
        model.selectStage(2, for: .standalone)
        model.selectStage(1, for: .gp)
        XCTAssertEqual(model.gpProgress.index, 0)
        XCTAssertEqual(model.stageReadout(for: .standalone).index, 0)
        model.setStandaloneStagesEnabled(false)
        XCTAssertFalse(model.canSelectStage(for: .standalone))
        model.setStandaloneStagesEnabled(true)
        XCTAssertEqual(model.stageReadout(for: .standalone).index, 0)
    }

    func testTimedGpStageWaitsForLoopEndAndExcludesPausesAndCountIn() {
        let plan = TempoStagePlan(stages: [
            TempoStage(bpm: 80, unit: .seconds, length: 5),
            TempoStage(bpm: 103, unit: .loops, length: 2)
        ])
        var progress = LoopStageProgress()
        progress.setPlaying(true, now: 0)
        progress.finishLoop(in: plan, now: 2)
        progress.setPlaying(false, now: 2.5)
        progress.setPlaying(true, now: 20)
        progress.finishLoop(in: plan, now: 22)
        XCTAssertEqual(progress.index, 0)
        progress.finishLoop(in: plan, now: 24)
        XCTAssertEqual(progress.index, 1)
        progress.finishLoop(in: plan, now: 34)
        XCTAssertEqual(progress.index, 1)
        progress.finishLoop(in: plan, now: 44)
        XCTAssertEqual(progress.index, 0)
        XCTAssertEqual(progress.rounds, 0)
    }

    func testCountdownHoldsZeroUntilLoopAndStartsNextStageOnlyWhenPlaying() {
        let plan = TempoStagePlan(stages: [.init(bpm: 80, unit: .seconds, length: 3),
                                          .init(bpm: 95, unit: .loops, length: 2)])
        var progress = LoopStageProgress()
        func remaining(_ at: Double) -> Int { progress.readout(in: plan, now: at).remaining }
        XCTAssertEqual(remaining(250), 3)
        progress.setPlaying(true, now: 250)
        XCTAssertEqual(remaining(250.9), 3)
        progress.setPlaying(true, now: 251)
        progress.setPlaying(false, now: 251.25)
        XCTAssertEqual(remaining(600), 2)
        progress.setPlaying(true, now: 600)
        XCTAssertEqual(remaining(601.749), 1)
        XCTAssertEqual(remaining(601.75), 0)
        XCTAssertEqual(remaining(650), 0)
        XCTAssertEqual(progress.index, 0, "Reading zero never triggers a speed change")
        progress.finishLoop(in: plan, now: 650)
        progress.setPlaying(false, now: 650)
        XCTAssertEqual(progress.readout(in: plan, now: 999).unit, .loops)
        XCTAssertEqual(remaining(999), 2)
        progress.setPlaying(true, now: 999)
        progress.finishLoop(in: plan, now: 1001)
        XCTAssertEqual(remaining(1005), 1)
        progress.finishLoop(in: plan, now: 1006)
        progress.setPlaying(false, now: 1006)
        XCTAssertEqual(remaining(1020), 3, "Count-in before a timed stage does not consume its time")
        progress.setPlaying(true, now: 1020)
        XCTAssertEqual(remaining(1021), 2)
    }

    func testStandaloneCountdownUsesEachOccurrenceAndWaitsForTheDownbeat() {
        let plan = TempoStagePlan(stages: [1,2,3].map { TempoStage(bpm: 60, unit: .seconds, length: $0) }, order: .bounce)
        let schedule = MetronomeStageSchedule(plan: plan, beats: 4, subdivisions: 2)
        for (time, stage, remaining) in [(0.0,0,1), (0.99,0,1), (1,0,0), (3.99,0,0),
                                        (4,1,2), (6,1,0), (8,2,3), (10,2,1), (11,2,0),
                                        (12,1,2), (13,1,1), (15.99,1,0), (16,0,1), (20,1,2)] {
            let p = schedule.position(at: time)
            let snapshot = TempoStageReadout(plan: plan, index: p.stage, secondsPlayed: p.elapsedInStage)
            XCTAssertEqual(snapshot.index, stage, "at \(time)"); XCTAssertEqual(snapshot.remaining, remaining, "at \(time)")
        }
        let single = TempoStagePlan(stages: [.init(bpm: 60, unit: .seconds, length: 1)])
        let p = MetronomeStageSchedule(plan: single, beats: 4, subdivisions: 1).position(at: 4)
        XCTAssertEqual(TempoStageReadout(plan: single, index: p.stage, secondsPlayed: p.elapsedInStage).remaining, 1)
    }

    func testWrapAndBounceDoNotDuplicateEndpoints() {
        for (order, expected) in [(TempoStageOrder.wrap, [0,1,2,0,1,2,0]), (.bounce, [0,1,2,1,0,1,2])] {
            let plan = TempoStagePlan(stages: [80,110,95].map { TempoStage(bpm: $0, unit: .loops, length: 1) }, order: order)
            var progress = LoopStageProgress()
            for index in expected {
                XCTAssertEqual(progress.index, index)
                progress.finishLoop(in: plan, now: 0)
            }
        }
        let single = TempoStagePlan(stages: [.init(bpm: 60, unit: .loops, length: 1)], order: .bounce)
        var progress = LoopStageProgress()
        progress.finishLoop(in: single, now: 1)
        XCTAssertEqual(progress.index, 0)
    }

    func testMetronomeChangesOnDownbeatWithUnbrokenSubdivisions() {
        // At 75 BPM a 4/4 bar is 3.2s. A five-second stage must last two bars.
        let plan = TempoStagePlan(stages: [TempoStage(bpm: 75, unit: .seconds, length: 5),
                                          TempoStage(bpm: 120, unit: .seconds, length: 2),
                                          TempoStage(bpm: 60, unit: .seconds, length: 1)], order: .bounce)
        let schedule = MetronomeStageSchedule(plan: plan, beats: 4, subdivisions: 2)
        XCTAssertEqual(schedule.segments.map(\.index), [0,1,2,1])
        XCTAssertEqual(schedule.position(at: 6.39).stage, 0)
        XCTAssertEqual(schedule.position(at: 6.4).stage, 1)
        XCTAssertEqual(schedule.time(of: 15), 6, accuracy: 1e-8)
        XCTAssertEqual(schedule.time(of: 16), 6.4, accuracy: 1e-8)
        XCTAssertEqual(schedule.time(of: 17), 6.65, accuracy: 1e-8)
        XCTAssertEqual(schedule.position(at: 6.5).nextEvent, 17)
        for event in Int64(0)..<120 {
            let time = schedule.time(of: event)
            XCTAssertEqual(schedule.position(at: time).nextEvent, event)
            XCTAssertGreaterThan(schedule.time(of: event + 1), time)
        }
    }

    func testGapBarsSilenceAllSubdivisionsAndKeepTheirPlaceAcrossTempoChanges() {
        // One bar takes 2s, then 1s. The second stage starts inside a silent bar.
        let plan = TempoStagePlan(stages: [TempoStage(bpm: 120, unit: .seconds, length: 4),
                                          TempoStage(bpm: 240, unit: .seconds, length: 3)])
        let schedule = MetronomeStageSchedule(plan: plan, beats: 4, subdivisions: 4)
        let gap = MetronomeGapPattern(enabled: true, soundBars: 2, silentBars: 1)
        let beats = BeatTimeline(bpm: 120, beatOffset: 0, subdivision: .sixteenth, quarterNotesPerMeasure: 4)
        let heard = (Int64(0)..<96).filter { gap.sounds(in: beats.measureIndex($0)) && beats.shouldPlay($0, mode: .click) }
        XCTAssertEqual((8..<14).map { gap.sounds(in: Int64($0), startingAt: 8) }, [true,true,false,true,true,false])
        XCTAssertTrue(heard.contains(31))
        XCTAssertTrue(heard.filter { (32..<48).contains($0) }.isEmpty)
        XCTAssertEqual(schedule.position(at: 4).stage, 1)
        XCTAssertEqual(schedule.time(of: 48), 5, accuracy: 1e-8)
        XCTAssertTrue(heard.contains(48))
        XCTAssertTrue(heard.filter { (80..<96).contains($0) }.isEmpty)
        XCTAssertTrue((0..<5).allSatisfy { MetronomeGapPattern().sounds(in: Int64($0)) })
        XCTAssertFalse(MetronomeGapPattern(enabled: true, soundBars: 0, silentBars: 0).valid)
        XCTAssertEqual(TempoStagePlan.initial(bpm: 87, unit: .loops).stages.map(\.bpm), [87,92,97])
        XCTAssertEqual(TempoStagePlan.initial(bpm: 298, unit: .seconds).stages.map(\.bpm), [298,300])
    }

    @MainActor
    func testGpRequiresAnABRangeAndRestoresManualTempo() {
        let model = GpWebViewModel()
        let plan = TempoStagePlan(stages: [TempoStage(bpm: 70, unit: .loops, length: 1),
                                          TempoStage(bpm: 95, unit: .loops, length: 2)])
        model.setGpStages(plan)
        model.setWholeSongLoopingEnabled(true)
        model.setGpStagesEnabled(true)
        XCTAssertFalse(model.gpStagesEnabled)
        let hit = GpBarHit(index: 0, startTick: 0, endTick: 960)
        model.receive(.pointerDown(hit))
        model.receive(.pointerUp)
        model.setPracticeStartBpm(85)
        model.setGpStagesEnabled(true)
        model.receive(.positionChanged(.init(currentTime: 0, totalTime: 500, currentTick: 0, endTick: 960, isSeek: true, originalTempo: 100)))
        XCTAssertEqual(model.currentBpm, 70, accuracy: 0.001)
        model.receive(.playerStateChanged(.init(state: 0, stopped: false, transitioning: true)))
        XCTAssertFalse(model.gpProgress.clockRunning, "Count-in must not consume stage time")
        model.receive(.playerStateChanged(.init(state: 1, stopped: false, scorePlaying: false)))
        XCTAssertFalse(model.gpProgress.clockRunning, "The Play request can precede the synth")
        model.receive(.playerStateChanged(.init(state: 1, stopped: false, scorePlaying: true)))
        XCTAssertTrue(model.gpProgress.clockRunning)
        XCTAssertEqual(model.stageReadout(for: .gp).remaining, 1)
        model.receive(.rangeLoopCompleted)
        XCTAssertEqual(model.gpProgress.index, 1)
        XCTAssertEqual(model.currentBpm, 95, accuracy: 0.001)
        XCTAssertEqual(model.standaloneBpm, 120)
        model.pause()
        model.receive(.rangeLoopCompleted)
        XCTAssertEqual(model.gpProgress.rounds, 0)
        model.clearLoop()
        XCTAssertFalse(model.gpStagesEnabled)
        XCTAssertEqual(model.practiceStartBpm, 85)
    }

    func testProfilesKeepGpPlanWithSongAndStandalonePlanWithMode() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FilePracticeSettingsStore(defaults: defaults)
        let gp = TempoStagePlan.initial(bpm: 75, unit: .loops)
        let solo = TempoStagePlan.initial(bpm: 110, unit: .seconds)
        let gap = MetronomeGapPattern(enabled: true, soundBars: 3, silentBars: 2)
        let profile = GpPracticeProfile(gpStages: gp, standaloneStages: solo, standaloneGap: gap, standaloneStagesEnabled: true)
        try store.save(profile, kind: .guitarPro, fileName: "a.gp")
        let a = try XCTUnwrap(store.load(GpPracticeProfile.self, kind: .guitarPro, fileName: "a.gp"))
        let b = try XCTUnwrap(store.load(GpPracticeProfile.self, kind: .guitarPro, fileName: "b.gp"))
        XCTAssertEqual(a.gpStages, gp)
        XCTAssertNil(b.gpStages)
        XCTAssertEqual(b.standaloneGap, gap)
        XCTAssertEqual(b.standaloneStages, solo)
        XCTAssertEqual(b.standaloneStagesEnabled, true)
        XCTAssertFalse(gp.valid(in: 30...300, timedOnly: true))
    }
}
