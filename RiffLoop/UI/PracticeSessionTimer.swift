import Combine
import SwiftUI

/// One foreground visit to a practice mode. Playback state never controls this clock.
@MainActor
final class PracticeSessionClock: ObservableObject {
    @Published private(set) var accumulated: TimeInterval = 0
    @Published private(set) var activeSince: Date?
    private let record: @MainActor (TimeInterval, Date) -> Void

    init(record: @escaping @MainActor (TimeInterval, Date) -> Void = {
        PracticeHistoryStore.shared.record(seconds: $0, endingAt: $1)
    }) {
        self.record = record
    }

    func setActive(_ active: Bool, at now: Date = Date()) {
        guard active != (activeSince != nil) else { return }
        if active { activeSince = now }
        else { checkpoint(at: now); activeSince = nil }
    }

    func checkpoint(at now: Date = Date()) {
        guard let start = activeSince else { return }
        let seconds = max(0, now.timeIntervalSince(start))
        accumulated += seconds
        activeSince = now
        if seconds > 0 { record(seconds, now) }
    }

    func elapsed(at now: Date) -> TimeInterval {
        accumulated + (activeSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }
}

struct PracticeSessionLifecycle: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var clock: PracticeSessionClock
    @State private var visible = false
    private let checkpoint = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true; clock.setActive(scenePhase == .active) }
            .onDisappear { visible = false; clock.setActive(false) }
            .onChange(of: scenePhase) { _, phase in clock.setActive(visible && phase == .active) }
            .onReceive(checkpoint) { clock.checkpoint(at: $0) }
    }
}

struct PracticeSessionTimer: View {
    @ObservedObject var clock: PracticeSessionClock

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Label(Self.elapsedText(seconds: clock.elapsed(at: context.date)), systemImage: "clock")
                .labelStyle(.titleAndIcon)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityLabel("本次练习时长")
                .accessibilityValue(Self.elapsedText(seconds: clock.elapsed(at: context.date)))
        }
    }

    static func elapsedText(from start: Date, to end: Date) -> String {
        elapsedText(seconds: end.timeIntervalSince(start))
    }

    static func elapsedText(seconds duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
