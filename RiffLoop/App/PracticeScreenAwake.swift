import SwiftUI
import UIKit

private struct PracticeScreenAwake: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    let hasFile: Bool

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true; update() }
            .onDisappear { visible = false; update() }
            .onChange(of: hasFile) { _, _ in update() }
            .onChange(of: scenePhase) { _, _ in update() }
    }

    private func update() {
        UIApplication.shared.isIdleTimerDisabled = visible && hasFile && scenePhase == .active
    }
}

extension View {
    func keepPracticeScreenAwake(hasFile: Bool) -> some View {
        modifier(PracticeScreenAwake(hasFile: hasFile))
    }
}
