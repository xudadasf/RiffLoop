import XCTest
@testable import RiffLoop

@MainActor
final class PracticeSessionTimerTests: XCTestCase {
    func testForegroundVisitCountsPausedTimeButExcludesHomeAndBackground() {
        let start = Date(timeIntervalSince1970: 1000)
        var recorded: TimeInterval = 0
        let clock = PracticeSessionClock { seconds, _ in recorded += seconds }
        XCTAssertEqual(clock.elapsed(at: start), 0)
        clock.setActive(true, at: start)
        clock.checkpoint(at: start.addingTimeInterval(5))
        clock.setActive(true, at: start.addingTimeInterval(6)) // repeated activation must not reset
        clock.setActive(false, at: start.addingTimeInterval(10))
        clock.checkpoint(at: start.addingTimeInterval(200)) // timer delivery while backgrounded
        XCTAssertEqual(clock.elapsed(at: start.addingTimeInterval(200)), 10)
        XCTAssertEqual(recorded, 10)
        clock.setActive(true, at: start.addingTimeInterval(300))
        clock.setActive(false, at: start.addingTimeInterval(320))
        clock.setActive(false, at: start.addingTimeInterval(340))
        XCTAssertEqual(clock.elapsed(at: start.addingTimeInterval(500)), 30)
        XCTAssertEqual(recorded, 30, "Checkpoints and leaving the page must not double count")
        XCTAssertEqual(PracticeSessionClock(record: { _, _ in }).elapsed(at: start), 0)
    }

    func testForegroundSegmentsAreAssignedToTheirActualDayAcrossBackgroundMidnight() {
        let suite = "ForegroundHistory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16))!
        let history = PracticeHistoryStore(defaults: defaults, calendar: calendar)
        let clock = PracticeSessionClock { history.record(seconds: $0, endingAt: $1) }
        clock.setActive(true, at: midnight.addingTimeInterval(-20))
        clock.setActive(false, at: midnight.addingTimeInterval(10))
        clock.setActive(true, at: midnight.addingTimeInterval(3600))
        clock.setActive(false, at: midnight.addingTimeInterval(3615))
        XCTAssertEqual(history.seconds(on: midnight.addingTimeInterval(-1)), 20)
        XCTAssertEqual(history.seconds(on: midnight), 25)
        XCTAssertEqual(history.totalSeconds, 45)
        XCTAssertEqual(clock.elapsed(at: midnight.addingTimeInterval(5000)), 45)
    }

    func testCompactSummaryAndPreciseSelectedDayDuration() {
        XCTAssertEqual(PracticeDurationText.compact(0), "0m")
        XCTAssertEqual(PracticeDurationText.compact(3599), "59m")
        XCTAssertEqual(PracticeDurationText.compact(3600), "1h 0m")
        XCTAssertEqual(PracticeDurationText.compact(7625), "2h 7m")
        XCTAssertEqual(PracticeDurationText.detailed(7625), "2h 7m 5s")
        XCTAssertEqual(PracticeDurationText.detailed(45), "0h 0m 45s")
    }

    func testElapsedTimeCrossesAnHourAndDoesNotDependOnPlayback() {
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(PracticeSessionTimer.elapsedText(from: start, to: start), "00:00")
        XCTAssertEqual(PracticeSessionTimer.elapsedText(from: start, to: start.addingTimeInterval(3599)), "59:59")
        XCTAssertEqual(PracticeSessionTimer.elapsedText(from: start, to: start.addingTimeInterval(3661)), "1:01:01")
        XCTAssertEqual(PracticeSessionTimer.elapsedText(from: start, to: start.addingTimeInterval(-1)), "00:00")
    }
}
