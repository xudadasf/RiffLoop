import Combine
import Foundation

struct RecentProject: Codable, Equatable, Identifiable, Sendable {
    let kind: PracticeKind
    let fileName: String
    let lastOpenedAt: Date

    var id: String { "\(kind.rawValue):\(fileName)" }
}

@MainActor
final class RecentProjectsStore: ObservableObject {
    @Published private(set) var projects: [RecentProject]

    private let defaults: UserDefaults
    private let storageKey = "recentProjects.v1"
    private let maximumCount = 30

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if
            let data = defaults.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([RecentProject].self, from: data)
        {
            projects = decoded
        } else {
            projects = []
        }
    }

    func opened(kind: PracticeKind, fileName: String, at date: Date = Date()) {
        let project = RecentProject(kind: kind, fileName: fileName, lastOpenedAt: date)
        projects.removeAll { $0.kind == kind && $0.fileName == fileName }
        projects.insert(project, at: 0)
        if projects.count > maximumCount {
            projects.removeLast(projects.count - maximumCount)
        }
        save()
    }

    func remove(kind: PracticeKind, fileName: String) {
        projects.removeAll { $0.kind == kind && $0.fileName == fileName }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
