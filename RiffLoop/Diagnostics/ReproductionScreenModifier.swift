import SwiftUI

/// Keep recording outside the already large practice screen view expressions.
@MainActor
struct ReproductionScreenModifier: ViewModifier {
    let mode: String
    let panel: String
    let libraries: [String: Bool]
    let snapshot: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {
                snapshot()
                ReproductionStore.shared.update(["screen": mode, "panel": panel,
                    "libraries": ReproductionStore.shared.encoded(libraries)])
                ReproductionStore.shared.record("action", mode + ".open")
            }
            .onDisappear { ReproductionStore.shared.record("action", mode + ".leave") }
            .onChange(of: panel) { _, value in
                ReproductionStore.shared.update(["panel": value])
                ReproductionStore.shared.record("action", mode + ".panel", ["panel": value])
            }
            .onChange(of: libraries) { _, value in
                let json = ReproductionStore.shared.encoded(value)
                ReproductionStore.shared.update(["libraries": json])
                ReproductionStore.shared.record("action", mode + ".libraries", ["visible": json])
            }
            .task {
                while !Task.isCancelled {
                    snapshot()
                    ReproductionStore.shared.record("sample", mode + ".state")
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                }
            }
    }
}
