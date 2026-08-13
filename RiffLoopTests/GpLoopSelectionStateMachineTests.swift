import XCTest
@testable import RiffLoop

final class GpLoopSelectionStateMachineTests: XCTestCase {
    func testTapBeforeLongPressStillSeeks() {
        var machine = GpLoopSelectionStateMachine()
        let bar = makeBar(3)

        XCTAssertEqual(machine.pointerDown(on: bar), .none)
        XCTAssertEqual(machine.pointerUp(), .seek(bar))
    }

    func testLongPressThenForwardDragCommitsWholeBars() {
        var machine = GpLoopSelectionStateMachine()
        machine.pointerDown(on: makeBar(2))

        XCTAssertEqual(machine.longPressActivated(), .pauseForSelection)
        XCTAssertEqual(
            machine.pointerMoved(to: makeBar(5)),
            .preview(GpLoopBarRange(firstBar: 2, lastBar: 5, startTick: 1_920, endTick: 5_760))
        )
        XCTAssertEqual(
            machine.pointerUp(),
            .commit(GpLoopBarRange(firstBar: 2, lastBar: 5, startTick: 1_920, endTick: 5_760))
        )
    }

    func testReverseDragAndDragBackNormalizeAndShrink() {
        var machine = GpLoopSelectionStateMachine()
        machine.pointerDown(on: makeBar(5))
        machine.longPressActivated()

        XCTAssertEqual(
            machine.pointerMoved(to: makeBar(2)),
            .preview(GpLoopBarRange(firstBar: 2, lastBar: 5, startTick: 1_920, endTick: 5_760))
        )
        XCTAssertEqual(
            machine.pointerMoved(to: makeBar(4)),
            .preview(GpLoopBarRange(firstBar: 4, lastBar: 5, startTick: 3_840, endTick: 5_760))
        )
    }

    func testSingleBarCommitHasStrictlyPositiveTickRange() {
        var machine = GpLoopSelectionStateMachine()
        machine.pointerDown(on: makeBar(7))
        machine.longPressActivated()

        guard case let .commit(range) = machine.pointerUp() else {
            return XCTFail("Expected a committed single-bar range")
        }
        XCTAssertEqual(range.firstBar, 7)
        XCTAssertEqual(range.lastBar, 7)
        XCTAssertGreaterThan(range.endTick, range.startTick)
    }

    func testCancellationDoesNotCommitPreview() {
        var machine = GpLoopSelectionStateMachine()
        machine.pointerDown(on: makeBar(2))
        machine.longPressActivated()
        machine.pointerMoved(to: makeBar(6))

        XCTAssertEqual(machine.cancel(), .cancelSelection)
        XCTAssertEqual(machine.pointerUp(), .none)
    }

    private func makeBar(_ index: Int) -> GpBarHit {
        GpBarHit(
            index: index,
            startTick: Double(index * 960),
            endTick: Double((index + 1) * 960)
        )
    }
}
