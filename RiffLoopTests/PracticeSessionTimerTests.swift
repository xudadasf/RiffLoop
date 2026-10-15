import XCTest
@testable import RiffLoop

@MainActor
final class PracticeSessionTimerTests: XCTestCase {
    func testElapsedTimeCrossesAnHourAndDoesNotDependOnPlayback() {
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(PracticeSessionTimer.elapsedText(from: start, to: start), "00:00")
        XCTAssertEqual(PracticeSessionTimer.elapsedText(from: start, to: start.addingTimeInterval(3599)), "59:59")
        XCTAssertEqual(PracticeSessionTimer.elapsedText(from: start, to: start.addingTimeInterval(3661)), "1:01:01")
        XCTAssertEqual(PracticeSessionTimer.elapsedText(from: start, to: start.addingTimeInterval(-1)), "00:00")
    }
}
