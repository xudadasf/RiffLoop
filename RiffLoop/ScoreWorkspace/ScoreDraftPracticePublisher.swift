import Foundation

enum ScoreDraftPracticePublishError: LocalizedError {
    case noUniqueName

    var errorDescription: String? { "无法为练习副本分配新的文件名，请重试。" }
}

/// Called only after the user chooses to create a separate practice copy.
/// Opening the returned URL is a separate action; existing scores are untouched.
@MainActor
enum ScoreDraftPracticePublisher {
    static func publish(
        _ draft: ScoreDraft,
        documents: RiffLoopDocumentStore = RiffLoopDocumentStore(),
        settings: FilePracticeSettingsStore = FilePracticeSettingsStore(),
        recent: RecentProjectsStore? = nil,
        displayNames: DocumentDisplayNameStore? = nil,
        newIdentifier: () -> UUID = { UUID() }
    ) async throws -> URL {
        let recent = recent ?? RecentProjectsStore()
        let displayNames = displayNames ?? DocumentDisplayNameStore()
        let folder = documents.folderURL(for: .guitarPro)
        let store = ScoreDraftGPFileStore(folder: folder)

        // Use a new identity rather than reusing a filename whose older GP
        // preferences or recent-project record might still exist.
        for _ in 0..<8 {
            try Task.checkCancellation()
            let name = "草稿-\(newIdentifier().uuidString).gp"
            guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path),
                  !settings.containsFileSettings(kind: .guitarPro, fileName: name),
                  displayNames.customName(for: .guitarPro, fileName: name) == nil,
                  !recent.projects.contains(where: { $0.kind == .guitarPro && $0.fileName == name }),
                  recent.mostRecent(kind: .guitarPro)?.fileName != name else { continue }
            do {
                return try await store.create(draft, fileName: name)
            } catch let error as POSIXError where error.code == .EEXIST {
                // Another writer may have claimed the name since the check.
                continue
            }
        }
        throw ScoreDraftPracticePublishError.noUniqueName
    }
}
