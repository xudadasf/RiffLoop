import Combine
import Foundation

struct PracticeDay: Identifiable, Equatable, Sendable {
    let id: String
    let date: Date
    let seconds: TimeInterval
    let isFuture: Bool
}

@MainActor
final class PracticeHistoryStore: ObservableObject {
    static let shared = PracticeHistoryStore()

    @Published private(set) var dailySeconds: [String: TimeInterval]

    private let defaults: UserDefaults
    private let calendar: Calendar
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current,
        storageKey: String = "practiceHistory.daily.v1"
    ) {
        self.defaults = defaults
        self.calendar = calendar
        self.storageKey = storageKey
        dailySeconds = (defaults.dictionary(forKey: storageKey) ?? [:]).compactMapValues {
            ($0 as? NSNumber)?.doubleValue
        }
    }

    func record(seconds: TimeInterval, endingAt: Date = Date()) {
        guard seconds.isFinite, seconds > 0 else { return }
        var segmentStart = endingAt.addingTimeInterval(-seconds)

        while segmentStart < endingAt {
            let dayStart = calendar.startOfDay(for: segmentStart)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            let segmentEnd = min(nextDay, endingAt)
            guard segmentEnd > segmentStart else { break }
            dailySeconds[dateKey(for: dayStart), default: 0] += segmentEnd.timeIntervalSince(segmentStart)
            segmentStart = segmentEnd
        }

        defaults.set(dailySeconds, forKey: storageKey)
    }

    func seconds(on date: Date) -> TimeInterval {
        dailySeconds[dateKey(for: date), default: 0]
    }

    func calendarDays(weeks: Int = 5, containing date: Date = Date()) -> [PracticeDay] {
        let weekCount = max(1, weeks)
        let today = calendar.startOfDay(for: date)
        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let start = calendar.date(
            byAdding: .weekOfYear,
            value: -(weekCount - 1),
            to: currentWeekStart
        ) ?? currentWeekStart

        return (0 ..< weekCount * 7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let key = dateKey(for: day)
            return PracticeDay(
                id: key,
                date: day,
                seconds: dailySeconds[key, default: 0],
                isFuture: day > today
            )
        }
    }

    func weekdaySymbols() -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = min(max(calendar.firstWeekday - 1, 0), symbols.count - 1)
        return Array(symbols[first...]) + Array(symbols[..<first])
    }

    func secondsThisWeek(containing date: Date = Date()) -> TimeInterval {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { return 0 }
        return dailySeconds.reduce(into: 0) { result, entry in
            guard let day = date(fromKey: entry.key), interval.contains(day) else { return }
            result += entry.value
        }
    }

    var totalSeconds: TimeInterval {
        dailySeconds.values.reduce(0, +)
    }

    private func dateKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func date(fromKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
