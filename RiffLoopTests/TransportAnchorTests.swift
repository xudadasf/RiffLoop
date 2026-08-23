import XCTest
@testable import RiffLoop

final class TransportAnchorTests: XCTestCase {
    func testNormalRateMapping() {
        let anchor = TransportAnchor(mediaTime: 10, hostTime: 100, mediaRate: 1)
        XCTAssertEqual(anchor.hostTime(forMediaTime: 12.5), 102.5, accuracy: 1e-12)
    }

    func testHalfSpeedMapping() {
        let anchor = TransportAnchor(mediaTime: 10, hostTime: 100, mediaRate: 0.5)
        XCTAssertEqual(anchor.hostTime(forMediaTime: 12.5), 105, accuracy: 1e-12)
    }

    func testHostClockCanAdvanceAMetronomeOnlyMediaTimeline() {
        let anchor = TransportAnchor(mediaTime: 10, hostTime: 100, mediaRate: 0.5)

        XCTAssertEqual(anchor.mediaTime(forHostTime: 105), 12.5, accuracy: 1e-12)
    }

    func testLoopReanchorDoesNotCarryPreviousLoopError() {
        let firstLoop = TransportAnchor(mediaTime: 20, hostTime: 100, mediaRate: 1)
        let nextLoop = TransportAnchor(mediaTime: 20, hostTime: 110.125, mediaRate: 1)

        XCTAssertEqual(firstLoop.hostTime(forMediaTime: 21), 101, accuracy: 1e-12)
        XCTAssertEqual(nextLoop.hostTime(forMediaTime: 21), 111.125, accuracy: 1e-12)
    }

    func testFiftyLoopAnchorsKeepTheSamePhase() {
        let loopStart = 20.0
        let firstBeatInLoop = 20.5

        for loopIndex in 0..<50 {
            let hostStart = 100.0 + Double(loopIndex) * 4.125
            let anchor = TransportAnchor(
                mediaTime: loopStart,
                hostTime: hostStart,
                mediaRate: 1
            )

            XCTAssertEqual(
                anchor.hostTime(forMediaTime: firstBeatInLoop) - hostStart,
                0.5,
                accuracy: 1e-12
            )
        }
    }
}
