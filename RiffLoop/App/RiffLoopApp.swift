import SwiftUI

@main
@MainActor
struct RiffLoopApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recentProjects = RecentProjectsStore()
    @StateObject private var displayNames = DocumentDisplayNameStore()

    init() { ReproductionRecorder.shared.start() }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .preferredColorScheme(.dark)
                .environmentObject(recentProjects)
                .environmentObject(displayNames)
                .onChange(of: scenePhase) { _, phase in
                    ReproductionRecorder.shared.setActive(phase == .active)
                    ReproductionStore.shared.record("lifecycle", "scene.phase", ["phase": String(describing: phase)])
                }
                .task {
                    try? RiffLoopDocumentStore().prepareDirectories()
                }
        }
    }
}
