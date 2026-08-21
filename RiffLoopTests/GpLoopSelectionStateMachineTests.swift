import XCTest
@testable import RiffLoop

final class GpLoopSelectionStateMachineTests: XCTestCase {
    func testResumeOutsideEnabledLoopUsesLoopStart() {
        let range = GpLoopBarRange(firstBar: 8, lastBar: 8, startTick: 30_720, endTick: 34_560)

        XCTAssertEqual(
            gpResumeTick(savedTick: 64_000, loopRange: range, rangeLoopingEnabled: true),
            range.startTick
        )
    }

    func testResumeInsideEnabledLoopPreservesSavedTick() {
        let range = GpLoopBarRange(firstBar: 8, lastBar: 8, startTick: 30_720, endTick: 34_560)

        XCTAssertEqual(
            gpResumeTick(savedTick: 32_000, loopRange: range, rangeLoopingEnabled: true),
            32_000
        )
    }

    func testResumeOutsideDisabledLoopPreservesSavedTick() {
        let range = GpLoopBarRange(firstBar: 8, lastBar: 8, startTick: 30_720, endTick: 34_560)

        XCTAssertEqual(
            gpResumeTick(savedTick: 64_000, loopRange: range, rangeLoopingEnabled: false),
            64_000
        )
    }

    func testTapSeeks() {
        var machine = GpLoopSelectionStateMachine()
        let bar = makeBar(3)

        XCTAssertEqual(machine.tap(on: bar), .seek(bar))
    }

    func testTapIsIgnoredWhileDragging() {
        var machine = GpLoopSelectionStateMachine()
        XCTAssertEqual(
            machine.dragStart(on: makeBar(2)),
            .selectStart(GpLoopBarRange(firstBar: 2, lastBar: 2, startTick: 1_920, endTick: 2_880))
        )

        XCTAssertEqual(machine.tap(on: makeBar(5)), .none)
    }

    func testDragStartPreviewsASingleBar() {
        var machine = GpLoopSelectionStateMachine()

        XCTAssertEqual(
            machine.dragStart(on: makeBar(2)),
            .selectStart(GpLoopBarRange(firstBar: 2, lastBar: 2, startTick: 1_920, endTick: 2_880))
        )
        XCTAssertTrue(machine.isDragging)
    }

    func testDragForwardUpdatesPreview() {
        var machine = GpLoopSelectionStateMachine()
        machine.dragStart(on: makeBar(2))

        XCTAssertEqual(
            machine.dragUpdate(to: makeBar(5)),
            .updatePreview(
                GpLoopBarRange(firstBar: 2, lastBar: 5, startTick: 1_920, endTick: 5_760)
            )
        )
    }

    func testDragBackwardNormalizesThePreview() {
        var machine = GpLoopSelectionStateMachine()
        machine.dragStart(on: makeBar(5))

        XCTAssertEqual(
            machine.dragUpdate(to: makeBar(2)),
            .updatePreview(
                GpLoopBarRange(firstBar: 2, lastBar: 5, startTick: 1_920, endTick: 5_760)
            )
        )
    }

    func testDragCanShrinkBackTowardTheStart() {
        var machine = GpLoopSelectionStateMachine()
        machine.dragStart(on: makeBar(2))
        machine.dragUpdate(to: makeBar(7))

        XCTAssertEqual(
            machine.dragUpdate(to: makeBar(3)),
            .updatePreview(
                GpLoopBarRange(firstBar: 2, lastBar: 3, startTick: 1_920, endTick: 3_840)
            )
        )
    }

    func testDragEndCommitsTheLastPreviewedRange() {
        var machine = GpLoopSelectionStateMachine()
        machine.dragStart(on: makeBar(2))
        machine.dragUpdate(to: makeBar(5))

        XCTAssertEqual(
            machine.dragEnd(),
            .commit(GpLoopBarRange(firstBar: 2, lastBar: 5, startTick: 1_920, endTick: 5_760))
        )
        XCTAssertFalse(machine.isDragging)
    }

    func testDragEndAfterBackwardDragCommitsTheNormalizedRange() {
        var machine = GpLoopSelectionStateMachine()
        machine.dragStart(on: makeBar(5))
        machine.dragUpdate(to: makeBar(2))

        XCTAssertEqual(
            machine.dragEnd(),
            .commit(GpLoopBarRange(firstBar: 2, lastBar: 5, startTick: 1_920, endTick: 5_760))
        )
    }

    func testSameBarDragCommitsASingleBarRange() {
        var machine = GpLoopSelectionStateMachine()
        machine.dragStart(on: makeBar(7))

        guard case let .commit(range) = machine.dragEnd() else {
            return XCTFail("Expected a committed single-bar range")
        }
        XCTAssertEqual(range.firstBar, 7)
        XCTAssertEqual(range.lastBar, 7)
        XCTAssertGreaterThan(range.endTick, range.startTick)
    }

    func testSameBarDragUsesSelectedBeatBoundaries() {
        var machine = GpLoopSelectionStateMachine()
        machine.dragStart(on: makeBeat(bar: 7, startTick: 7_200, endTick: 7_440))
        machine.dragUpdate(to: makeBeat(bar: 7, startTick: 7_680, endTick: 7_920))

        XCTAssertEqual(
            machine.dragEnd(),
            .commit(GpLoopBarRange(firstBar: 7, lastBar: 7, startTick: 7_200, endTick: 7_920))
        )
    }

    func testBackwardSameBarDragNormalizesSelectedBeatBoundaries() {
        var machine = GpLoopSelectionStateMachine()
        machine.dragStart(on: makeBeat(bar: 7, startTick: 7_680, endTick: 7_920))
        machine.dragUpdate(to: makeBeat(bar: 7, startTick: 7_200, endTick: 7_440))

        XCTAssertEqual(
            machine.dragEnd(),
            .commit(GpLoopBarRange(firstBar: 7, lastBar: 7, startTick: 7_200, endTick: 7_920))
        )
    }

    func testDragCancelKeepsTheOldRangeAndClearsState() {
        var machine = GpLoopSelectionStateMachine()
        machine.dragStart(on: makeBar(2))
        machine.dragUpdate(to: makeBar(5))

        XCTAssertEqual(machine.dragCancel(), .cancelSelection)
        XCTAssertFalse(machine.isDragging)
        XCTAssertEqual(machine.tap(on: makeBar(3)), .seek(makeBar(3)))
    }

    func testDragCancelBeforeStartIsANoOp() {
        var machine = GpLoopSelectionStateMachine()

        XCTAssertEqual(machine.dragCancel(), .none)
    }

    func testSecondDragStartIsIgnoredWhileDragging() {
        var machine = GpLoopSelectionStateMachine()
        machine.dragStart(on: makeBar(2))

        XCTAssertEqual(machine.dragStart(on: makeBar(9)), .none)
    }

    private func makeBar(_ index: Int) -> GpBarHit {
        GpBarHit(
            index: index,
            startTick: Double(index * 960),
            endTick: Double((index + 1) * 960)
        )
    }

    private func makeBeat(bar: Int, startTick: Double, endTick: Double) -> GpBarHit {
        GpBarHit(
            index: bar,
            startTick: Double(bar * 960),
            endTick: Double((bar + 1) * 960),
            seekTick: startTick,
            seekEndTick: endTick
        )
    }
}
