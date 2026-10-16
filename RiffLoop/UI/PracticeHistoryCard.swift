import SwiftUI

struct PracticeHistoryCard: View {
    @ObservedObject var history: PracticeHistoryStore
    @Binding var selectedDay: PracticeDay?

    var body: some View {
        let days = history.calendarDays(weeks: 4)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("练习概览").font(.headline)
                Spacer(minLength: 8)
                // Reuse the header's existing space: selecting a day never moves the grid.
                ZStack(alignment: .trailing) {
                    if let day = selectedDay {
                        Text(PracticeDurationText.hoursMinutes(history.seconds(on: day.date)))
                            .font(.caption.monospacedDigit().weight(.medium))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().stroke(.primary.opacity(0.12), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                            .accessibilityIdentifier("practice.day.duration")
                            .accessibilityLabel("所选日练习时长")
                            .accessibilityValue(PracticeDurationText.hoursMinutes(history.seconds(on: day.date)))
                    } else {
                        Text("最近一个月").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 24)
            }
            HStack(spacing: 24) {
                metric("今天", seconds: history.seconds(on: Date()))
                metric("本周", seconds: history.secondsThisWeek())
                metric("累计", seconds: history.totalSeconds)
            }
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(days) { day in
                    let selected = selectedDay?.id == day.id
                    Button { selectedDay = selected ? nil : day } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(color(for: day)).frame(height: 22)
                            .overlay {
                                if selected {
                                    RoundedRectangle(cornerRadius: 4).stroke(.primary, lineWidth: 2)
                                } else if Calendar.current.isDateInToday(day.date) {
                                    RoundedRectangle(cornerRadius: 4).stroke(.orange, lineWidth: 1.5)
                                }
                            }
                    }
                    .buttonStyle(.plain).disabled(day.isFuture)
                    .accessibilityIdentifier("practice.day.\(day.id)")
                    .accessibilityLabel(day.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: "zh_CN"))))
                    .accessibilityValue(PracticeDurationText.hoursMinutes(day.seconds))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .padding(18)
        .cardSurface()
    }

    private func metric(_ title: String, seconds: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(PracticeDurationText.compact(seconds)).font(.headline.monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func color(for day: PracticeDay) -> Color {
        guard !day.isFuture else { return Color(.quaternarySystemFill) }
        let minutes = day.seconds / 60
        if minutes == 0 { return Color(.quaternarySystemFill) }
        if minutes < 5 { return Color.orange.opacity(0.3) }
        if minutes < 15 { return Color.orange.opacity(0.5) }
        if minutes < 30 { return Color.orange.opacity(0.7) }
        return .orange
    }
}
