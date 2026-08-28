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
    private let lastModeStorageKey = "lastProjectsByMode.v1"
    private var lastProjectsByMode: [String: RecentProject] = [:]
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
        if let data = defaults.data(forKey: lastModeStorageKey),
           let decoded = try? JSONDecoder().decode([String: RecentProject].self, from: data) {
            lastProjectsByMode = decoded
        }
        for project in projects where lastProjectsByMode[project.kind.rawValue] == nil {
            lastProjectsByMode[project.kind.rawValue] = project
        }
    }

    func opened(kind: PracticeKind, fileName: String, at date: Date = Date()) {
        let project = RecentProject(kind: kind, fileName: fileName, lastOpenedAt: date)
        lastProjectsByMode[kind.rawValue] = project
        projects.removeAll { $0.kind == kind && $0.fileName == fileName }
        projects.insert(project, at: 0)
        if projects.count > maximumCount {
            projects.removeLast(projects.count - maximumCount)
        }
        save()
    }

    func remove(kind: PracticeKind, fileName: String) {
        projects.removeAll { $0.kind == kind && $0.fileName == fileName }
        if lastProjectsByMode[kind.rawValue]?.fileName == fileName {
            lastProjectsByMode[kind.rawValue] = projects.first { $0.kind == kind }
        }
        save()
    }

    func mostRecent(kind: PracticeKind) -> RecentProject? {
        lastProjectsByMode[kind.rawValue] ?? projects.first { $0.kind == kind }
    }

    func mostRecentValidURL(
        kind: PracticeKind,
        documents: RiffLoopDocumentStore = RiffLoopDocumentStore()
    ) -> URL? {
        let candidates = [lastProjectsByMode[kind.rawValue]].compactMap { $0 }
            + projects.filter { $0.kind == kind }
        let folder = documents.folderURL(for: kind).standardizedFileURL.resolvingSymlinksInPath()
        return candidates.lazy.compactMap { project -> URL? in
            let url = folder.appendingPathComponent(project.fileName).standardizedFileURL.resolvingSymlinksInPath()
            guard url.deletingLastPathComponent() == folder,
                  kind.supportedExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) > 0
            else { return nil }
            return url
        }.first
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        defaults.set(data, forKey: storageKey)
        if let modes = try? JSONEncoder().encode(lastProjectsByMode) {
            defaults.set(modes, forKey: lastModeStorageKey)
        }
    }
}
