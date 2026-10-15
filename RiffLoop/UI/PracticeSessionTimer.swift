import SwiftUI

/// Wall-clock time in this practice page, independent of transport and saved play history.
struct PracticeSessionTimer: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            Label(Self.elapsedText(from: startedAt, to: context.date), systemImage: "clock")
                .labelStyle(.titleAndIcon)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityLabel("本次练习时长")
                .accessibilityValue(Self.elapsedText(from: startedAt, to: context.date))
        }
    }

    static func elapsedText(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
