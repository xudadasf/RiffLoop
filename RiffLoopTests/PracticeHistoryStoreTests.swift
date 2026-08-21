import XCTest
@testable import RiffLoop

final class PracticeHistoryStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        suiteName = "PracticeHistoryStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        suiteName = nil
        defaults = nil
        calendar = nil
        super.tearDown()
    }

    @MainActor
    func testRecordsPracticeAcrossMidnightOnTheCorrectDays() {
        let store = PracticeHistoryStore(defaults: defaults, calendar: calendar)
        let endingAt = date(year: 2026, month: 8, day: 22, hour: 0, minute: 5)

        store.record(seconds: 15 * 60, endingAt: endingAt)

        XCTAssertEqual(store.seconds(on: date(year: 2026, month: 8, day: 21)), 10 * 60, accuracy: 0.001)
        XCTAssertEqual(store.seconds(on: endingAt), 5 * 60, accuracy: 0.001)
    }

    @MainActor
    func testCalendarUsesFiveAlignedWeeksAndPersistsDurations() {
        let today = date(year: 2026, month: 8, day: 21, hour: 12)
        let store = PracticeHistoryStore(defaults: defaults, calendar: calendar)
        store.record(seconds: 1_800, endingAt: today)

        let days = store.calendarDays(weeks: 5, containing: today)

        XCTAssertEqual(days.count, 35)
        XCTAssertEqual(days.first?.date, date(year: 2026, month: 7, day: 20))
        XCTAssertEqual(days.first(where: { calendar.isDate($0.date, inSameDayAs: today) })?.seconds, 1_800)
        XCTAssertEqual(PracticeHistoryStore(defaults: defaults, calendar: calendar).seconds(on: today), 1_800)
    }

    private func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}
