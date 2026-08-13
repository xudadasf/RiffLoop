import SwiftUI

@main
struct RiffLoopApp: App {
    @StateObject private var recentProjects = RecentProjectsStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .preferredColorScheme(.dark)
                .environmentObject(recentProjects)
                .task {
                    try? RiffLoopDocumentStore().prepareDirectories()
                }
        }
    }
}
