import Foundation

struct ScoreMaterialRemovalResult {
    let cleanupError: String?
}

/// Imported source copies are private to the score workspace, not the practice library.
actor ScoreWorkspaceStore {
    private let folder: URL
    private let fileManager: FileManager
    private let supportedExtensions: Set<String> = ["pdf", "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff"]

    init(folder: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.folder = folder ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScoreWorkspace/Imports", isDirectory: true)
    }

    func files() throws -> [URL] {
        try prepareFolder()
        return try fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard supportedExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func importCopy(from source: URL) throws -> URL {
        guard source.isFileURL, supportedExtensions.contains(source.pathExtension.lowercased()) else {
            throw ScoreWorkspaceError.unsupportedFile
        }
        try prepareFolder()
        let staging = folder.appendingPathComponent(".\(UUID().uuidString).import")
        defer { try? fileManager.removeItem(at: staging) }

        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinatedURL in
            do {
                let values = try coordinatedURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw ScoreWorkspaceError.unsupportedFile
                }
                try self.fileManager.copyItem(at: coordinatedURL, to: staging)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        guard fileManager.fileExists(atPath: staging.path) else { throw ScoreWorkspaceError.importFailed }
        return try ScoreMaterialAccess.synchronized {
            let destination = availableDestination(for: source.lastPathComponent)
            try fileManager.moveItem(at: staging, to: destination)
            ScoreMaterialAccess.advance(destination)
            return destination
        }
    }

    @discardableResult
    func removeCopy(_ url: URL, removal: ScoreRegionsRemoval? = nil) throws -> ScoreMaterialRemovalResult {
        try ScoreMaterialAccess.synchronized {
            let expectedFolder = folder.standardizedFileURL.resolvingSymlinksInPath()
            let target = url.standardizedFileURL
            guard target.deletingLastPathComponent().resolvingSymlinksInPath() == expectedFolder,
                  supportedExtensions.contains(target.pathExtension.lowercased()),
                  let values = try? target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ScoreWorkspaceError.invalidRemoval
            }
            if let removal, (removal.source != target || ScoreMaterialAccess.current(target) != removal.generation) {
                throw ScoreWorkspaceError.sourceChanged
            }
            try fileManager.removeItem(at: target)
            ScoreMaterialAccess.advance(target)
            if let removal, fileManager.fileExists(atPath: removal.metadata.path) {
                do { try fileManager.removeItem(at: removal.metadata) }
                catch { return ScoreMaterialRemovalResult(cleanupError: error.localizedDescription) }
            }
            return ScoreMaterialRemovalResult(cleanupError: nil)
        }
    }

    private func prepareFolder() throws {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func availableDestination(for fileName: String) -> URL {
        let original = URL(fileURLWithPath: fileName)
        let base = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(suffix)).\(ext)")
            suffix += 1
        }
        return candidate
    }
}

enum ScoreWorkspaceError: LocalizedError {
    case unsupportedFile
    case importFailed
    case invalidRemoval
    case sourceChanged

    var errorDescription: String? {
        switch self {
        case .unsupportedFile: "请选择 PDF 或受支持的图片文件。"
        case .importFailed: "无法复制此文件。"
        case .invalidRemoval: "只能删除制谱工作区中的素材副本。"
        case .sourceChanged: "素材已变化，请刷新后重试。"
        }
    }
}
