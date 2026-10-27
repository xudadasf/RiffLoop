import XCTest
@testable import RiffLoop

@MainActor
final class PracticeSessionTimerTests: XCTestCase {
    func testForegroundVisitCountsPausedTimeButExcludesHomeAndBackground() {
        let start = Date(timeIntervalSince1970: 1000)
        var uptime = 0.0
        var recorded: TimeInterval = 0
        let clock = PracticeSessionClock(uptime: { uptime }) { seconds, _ in recorded += seconds }
        XCTAssertEqual(clock.elapsed(), 0)
        clock.setActive(true, at: start)
        uptime = 5; clock.checkpoint(at: start.addingTimeInterval(5))
        uptime = 6; clock.setActive(true, at: start.addingTimeInterval(6))
        uptime = 10; clock.setActive(false, at: start.addingTimeInterval(10))
        uptime = 200; clock.checkpoint(at: start.addingTimeInterval(200))
        XCTAssertEqual(clock.elapsed(), 10)
        XCTAssertEqual(recorded, 10)
        uptime = 300; clock.setActive(true, at: start.addingTimeInterval(300))
        uptime = 320; clock.setActive(false, at: start.addingTimeInterval(320))
        uptime = 340; clock.setActive(false, at: start.addingTimeInterval(340))
        XCTAssertEqual(clock.elapsed(), 30)
        XCTAssertEqual(recorded, 30, "Checkpoints and leaving the page must not double count")
        XCTAssertEqual(PracticeSessionClock(record: { _, _ in }).elapsed(), 0)
    }

    func testCrossMidnightCheckpointsAndBackgroundResumeKeepSessionStartDay() {
        let suite = "ForegroundHistory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27))!
        let history = PracticeHistoryStore(defaults: defaults, calendar: calendar)
        var uptime = 0.0
        let clock = PracticeSessionClock(uptime: { uptime }) { history.record(seconds: $0, forSessionStartedAt: $1) }
        clock.setActive(true, at: midnight.addingTimeInterval(-20))
        uptime = 15; clock.checkpoint(at: midnight.addingTimeInterval(-5))
        uptime = 25; clock.checkpoint(at: midnight.addingTimeInterval(5))
        uptime = 30; clock.setActive(false, at: midnight.addingTimeInterval(10))
        uptime = 3620; clock.setActive(true, at: midnight.addingTimeInterval(3600))
        uptime = 3635; clock.setActive(false, at: midnight.addingTimeInterval(3615))
        XCTAssertEqual(history.seconds(on: midnight.addingTimeInterval(-1)), 45)
        XCTAssertEqual(history.seconds(on: midnight), 0)
        XCTAssertEqual(history.totalSeconds, 45)
        XCTAssertEqual(clock.elapsed(), 45)
        let restored = PracticeHistoryStore(defaults: defaults, calendar: calendar)
        XCTAssertEqual(restored.seconds(on: midnight.addingTimeInterval(-1)), 45)
        let nextVisit = PracticeSessionClock(uptime: { uptime }) { history.record(seconds: $0, forSessionStartedAt: $1) }
        nextVisit.setActive(true, at: midnight.addingTimeInterval(4000))
        uptime += 12; nextVisit.setActive(false, at: midnight.addingTimeInterval(4012))
        XCTAssertEqual(history.seconds(on: midnight), 12, "A new visit belongs to its own start date")
        XCTAssertEqual(history.totalSeconds, 57)
    }

    func testWallClockCorrectionsDoNotChangeElapsedTimeOrDayAttribution() {
        let start = Date(timeIntervalSince1970: 1000)
        var uptime = 100.0
        var records: [(TimeInterval, Date)] = []
        let clock = PracticeSessionClock(uptime: { uptime }) { records.append(($0, $1)) }
        clock.setActive(true, at: start)
        uptime = 105; clock.checkpoint(at: start.addingTimeInterval(3600))
        uptime = 110; clock.checkpoint(at: start.addingTimeInterval(-3600))
        XCTAssertEqual(clock.elapsed(), 10)
        uptime = 115; clock.setActive(false, at: start.addingTimeInterval(-3595))
        XCTAssertEqual(clock.elapsed(), 15)
        XCTAssertEqual(records.reduce(0) { $0 + $1.0 }, 15)
        XCTAssertTrue(records.allSatisfy { $0.1 == start })
    }

    func testCompactSummaryAndPreciseSelectedDayDuration() {
        XCTAssertEqual(PracticeDurationText.compact(0), "0m")
        XCTAssertEqual(PracticeDurationText.compact(3599), "59m")
        XCTAssertEqual(PracticeDurationText.compact(3600), "1h 0m")
        XCTAssertEqual(PracticeDurationText.compact(7625), "2h 7m")
        XCTAssertEqual(PracticeDurationText.hoursMinutes(7625), "2h 7m")
        XCTAssertEqual(PracticeDurationText.hoursMinutes(59), "0h 0m")
        XCTAssertEqual(PracticeDurationText.hoursMinutes(900), "0h 15m")
        XCTAssertEqual(PracticeDurationText.hoursMinutes(-2), "0h 0m")
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
