import XCTest
@testable import RiffLoop

final class TempoStageDraftTests: XCTestCase {
    func testContinuousEntryAndSavingWithoutChangingOriginalOrLosingUnfinishedCells() throws {
        let original = TempoStagePlan.initial(bpm: 90, unit: .loops)
        var d = TempoStageDraft(plan: original, bpmRange: 30...300, timedOnly: false)
        d.enter(1); d.enter(2); d.enter(5)
        XCTAssertEqual(d.selected.bpm, "125")
        d.move(1); d.enter(6)
        d.move(1); d.enter(2)
        XCTAssertNil(d.plan, "A partial BPM must not be saved or silently clamped")
        let second = d.selectedID
        d.select(original.stages[0].id, .length)
        XCTAssertEqual(d.selected.length, "6")
        d.select(second, .bpm); d.enter(9); d.enter(5)
        d.setUnit(.seconds, for: second); d.enter(3); d.enter(0)
        d.add()
        XCTAssertEqual(d.selected.bpm, "100")
        XCTAssertEqual(d.selected.unit, .loops)
        d.nudge(1)
        let saved = try XCTUnwrap(d.plan)
        XCTAssertEqual(saved.stages.map(\.bpm), [125, 95, 100, 101])
        XCTAssertEqual(saved.stages.map(\.length), [6,30,3,3])
        XCTAssertEqual(saved.stages.map(\.unit), [.loops,.seconds,.loops,.loops])
        XCTAssertEqual(Array(saved.stages.prefix(3)).map(\.id), original.stages.map(\.id))
        XCTAssertEqual(Set(saved.stages.map(\.id)).count, 4)
        XCTAssertEqual(original.stages.map(\.bpm), [90,95,100])
    }

    func testUnifiedLengthPreservesOtherUnitsAndSelectionSurvivesDeletion() {
        let plan = TempoStagePlan(stages: [.init(bpm: 80, unit: .seconds, length: 30),
                                          .init(bpm: 85, unit: .loops, length: 4),
                                          .init(bpm: 90, unit: .seconds, length: 10)])
        var d = TempoStageDraft(plan: plan, bpmRange: 30...300, timedOnly: false)
        d.move(1); d.enter(4); d.enter(5); d.repeatLength()
        XCTAssertEqual(d.plan?.stages.map(\.length), [45,4,45])
        d.remove(d.selectedID)
        XCTAssertEqual(d.selected.id, plan.stages[1].id)
        d.backspace(); XCTAssertNil(d.plan)
        d.nudge(1); XCTAssertEqual(d.selected.length, "1")
        d.remove(plan.stages[2].id); d.remove(d.selectedID)
        XCTAssertEqual(d.rows.count, 1); XCTAssertFalse(d.canMove(1))
        d.move(-1); XCTAssertFalse(d.canMove(-1))
    }

    func testTimedOnlyAndFiniteInputBounds() {
        let plan = TempoStagePlan.initial(bpm: 298, unit: .seconds)
        var d = TempoStageDraft(plan: plan, bpmRange: 30...300, timedOnly: true)
        d.setUnit(.loops, for: d.selectedID); XCTAssertEqual(d.selected.unit, .seconds)
        d.select(d.selectedID, .bpm); d.enter(9); d.enter(9); d.enter(9); d.enter(9)
        XCTAssertEqual(d.selected.bpm, "999"); XCTAssertNil(d.plan)
        d.nudge(1); XCTAssertEqual(d.selected.bpm, "300")
        d.move(1); for _ in 0..<6 { d.enter(9) }
        d.add()
        XCTAssertEqual(d.selected.unit, .seconds)
        d.move(-1); d.move(-1); d.move(-1)
        XCTAssertEqual(d.selected.length, "9999")
        XCTAssertNotNil(d.plan)
    }
}
