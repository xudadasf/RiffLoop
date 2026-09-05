import SwiftUI

@main
struct RiffLoopApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recentProjects = RecentProjectsStore()
    @StateObject private var displayNames = DocumentDisplayNameStore()

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
                    ReproductionRecorder.shared.start()
                    try? RiffLoopDocumentStore().prepareDirectories()
                }
        }
    }
}
