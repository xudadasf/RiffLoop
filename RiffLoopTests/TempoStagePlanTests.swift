import XCTest
@testable import RiffLoop

final class TempoStagePlanTests: XCTestCase {
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
        model.receive(.playerStateChanged(.init(state: 1, stopped: false)))
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
        let profile = GpPracticeProfile(gpStages: gp, standaloneStages: solo, standaloneStagesEnabled: true)
        try store.save(profile, kind: .guitarPro, fileName: "a.gp")
        let a = try XCTUnwrap(store.load(GpPracticeProfile.self, kind: .guitarPro, fileName: "a.gp"))
        let b = try XCTUnwrap(store.load(GpPracticeProfile.self, kind: .guitarPro, fileName: "b.gp"))
        XCTAssertEqual(a.gpStages, gp)
        XCTAssertNil(b.gpStages)
        XCTAssertEqual(b.standaloneStages, solo)
        XCTAssertEqual(b.standaloneStagesEnabled, true)
        XCTAssertFalse(gp.valid(in: 30...300, timedOnly: true))
    }
}
