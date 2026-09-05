import SwiftUI
import UIKit

@MainActor
enum PracticeScreenAwakeCoordinator {
    private static var owners = Set<UUID>()

    static func setActive(_ active: Bool, owner: UUID) {
        if active { owners.insert(owner) } else { owners.remove(owner) }
        UIApplication.shared.isIdleTimerDisabled = !owners.isEmpty
    }
}

private struct PracticeScreenAwake: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var owner = UUID()
    let hasFile: Bool

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true; update() }
            .onDisappear { visible = false; update() }
            .onChange(of: hasFile) { _, _ in update() }
            .onChange(of: scenePhase) { _, _ in update() }
    }

    private func update() {
        PracticeScreenAwakeCoordinator.setActive(visible && hasFile && scenePhase == .active, owner: owner)
    }
}

extension View {
    func keepPracticeScreenAwake(hasFile: Bool) -> some View {
        modifier(PracticeScreenAwake(hasFile: hasFile))
    }
}
