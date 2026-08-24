import SwiftUI

@main
struct RiffLoopApp: App {
    @StateObject private var recentProjects = RecentProjectsStore()
    @StateObject private var displayNames = DocumentDisplayNameStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .preferredColorScheme(.dark)
                .environmentObject(recentProjects)
                .environmentObject(displayNames)
                .task {
                    try? RiffLoopDocumentStore().prepareDirectories()
                }
        }
    }
}
