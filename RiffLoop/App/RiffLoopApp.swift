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
            appContent
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

    @ViewBuilder private var appContent: some View {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["RIFFLOOP_REGION_UI_TEST_CASE"],
           let id = UUID(uuidString: value) {
            ScoreRegionUITestFixture(id: id)
        } else {
            HomeView()
        }
        #else
        HomeView()
        #endif
    }
}
