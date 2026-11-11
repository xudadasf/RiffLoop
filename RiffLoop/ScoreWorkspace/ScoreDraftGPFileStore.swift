import Darwin
import Foundation

enum ScoreDraftGPFileStoreError: LocalizedError {
    case invalidName
    case invalidData
    case cleanupFailed(stagingPath: String, publishedPath: String?, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidName: return "请输入有效的 GP 文件名，不能包含路径或特殊控制字符。"
        case .invalidData: return "GP 数据为空、过大或格式不受支持。"
        case let .cleanupFailed(stagingPath, publishedPath, reason):
            if let publishedPath {
                return "GP 副本已保存到 \(publishedPath)，但暂存文件清理失败：\(stagingPath)。\(reason)"
            }
            return "GP 副本未保存，暂存文件清理失败：\(stagingPath)。\(reason)"
        }
    }
}

/// Publishes new GP copies in the score workspace. It does not replace files,
/// edit existing GP scores, or add anything to the practice library. The only
/// public input is a supported draft; bytes always come from ScoreDraftExporter.
actor ScoreDraftGPFileStore {
    private let folder: URL
    private let fileManager: FileManager
    private let maxBytes = 8 * 1024 * 1024

    init(folder: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.folder = folder ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScoreWorkspace/Exports", isDirectory: true)
    }

    /// A same-directory hard link publishes a completed file atomically and
    /// fails if the destination already exists, even across store instances.
    func create(_ draft: ScoreDraft, fileName: String) async throws -> URL {
        guard Self.validFileName(fileName) else { throw ScoreDraftGPFileStoreError.invalidName }
        try Task.checkCancellation()
        let data = try await ScoreDraftExporter.export(draft)
        try Task.checkCancellation()
        guard data.count <= maxBytes, data.starts(with: [0x50, 0x4b, 0x03, 0x04]) else {
            throw ScoreDraftGPFileStoreError.invalidData
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(fileName, isDirectory: false)
        let staging = folder.appendingPathComponent(".riffloop-export-\(UUID().uuidString).pending")
        let fd = staging.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR) }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            try Task.checkCancellation()
            let linked = staging.path.withCString { source in
                destination.path.withCString { target in link(source, target) }
            }
            guard linked == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            let original = error
            do { try fileManager.removeItem(at: staging) }
            catch {
                throw ScoreDraftGPFileStoreError.cleanupFailed(
                    stagingPath: staging.path, publishedPath: nil,
                    reason: "保存失败：\(original.localizedDescription)；清理失败：\(error.localizedDescription)")
            }
            throw original
        }
        // Once linked, the completed copy remains even if cancellation arrives.
        do { try fileManager.removeItem(at: staging) }
        catch {
            throw ScoreDraftGPFileStoreError.cleanupFailed(
                stagingPath: staging.path, publishedPath: destination.path, reason: error.localizedDescription)
        }
        return destination
    }

    private static func validFileName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("."), name.utf8.count <= 240,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              name.count > 3, name.lowercased().hasSuffix(".gp") else { return false }
        let stem = name.dropLast(3)
        return !stem.isEmpty && !stem.hasSuffix(" ") && !stem.hasSuffix(".")
    }
}
