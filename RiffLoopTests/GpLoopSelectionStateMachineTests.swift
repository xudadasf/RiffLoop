import XCTest
@testable import RiffLoop

final class GpLoopSelectionStateMachineTests: XCTestCase {
    func testTapOutsidePickingModeSeeks() {
        var machine = GpLoopSelectionStateMachine()
        let bar = makeBar(3)

        XCTAssertEqual(machine.tap(on: bar), .seek(bar))
    }

    func testPickingModeSelectsStartThenCommitsEnd() {
        var machine = GpLoopSelectionStateMachine()
        XCTAssertEqual(machine.setPickingEnabled(true), .none)
        XCTAssertEqual(machine.step, .start)

        XCTAssertEqual(
            machine.tap(on: makeBar(2)),
            .selectStart(GpLoopBarRange(firstBar: 2, lastBar: 2, startTick: 1_920, endTick: 2_880))
        )
        XCTAssertEqual(machine.step, .end(startBar: 2))
        XCTAssertEqual(
            machine.tap(on: makeBar(5)),
            .commit(GpLoopBarRange(firstBar: 2, lastBar: 5, startTick: 1_920, endTick: 5_760))
        )
        XCTAssertEqual(machine.step, .inactive)
    }

    func testEndBeforeStartIsRejectedAndWaitsForAnotherEnd() {
        var machine = GpLoopSelectionStateMachine()
        machine.setPickingEnabled(true)
        machine.tap(on: makeBar(5))

        XCTAssertEqual(machine.tap(on: makeBar(2)), .rejectEndBeforeStart)
        XCTAssertEqual(machine.step, .end(startBar: 5))
    }

    func testSameBarCanBeStartAndEnd() {
        var machine = GpLoopSelectionStateMachine()
        machine.setPickingEnabled(true)
        machine.tap(on: makeBar(7))

        guard case let .commit(range) = machine.tap(on: makeBar(7)) else {
            return XCTFail("Expected a committed single-bar range")
        }
        XCTAssertEqual(range.firstBar, 7)
        XCTAssertEqual(range.lastBar, 7)
        XCTAssertGreaterThan(range.endTick, range.startTick)
    }

    func testDisablingPickingCancelsStartPreview() {
        var machine = GpLoopSelectionStateMachine()
        machine.setPickingEnabled(true)
        machine.tap(on: makeBar(2))

        XCTAssertEqual(machine.setPickingEnabled(false), .cancelSelection)
        XCTAssertEqual(machine.step, .inactive)
    }

    private func makeBar(_ index: Int) -> GpBarHit {
        GpBarHit(
            index: index,
            startTick: Double(index * 960),
            endTick: Double((index + 1) * 960)
        )
    }
}
