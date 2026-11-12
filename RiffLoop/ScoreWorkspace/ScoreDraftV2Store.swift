import Darwin
import Foundation

enum ScoreDraftV2StoreError: LocalizedError {
    case invalidDraft
    case invalidFile
    case tooLarge
    case conflict
    case cleanupFailed(stagingPath: String, publishedID: UUID?, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidDraft: return "新版草稿无效或包含暂不支持的内容。"
        case .invalidFile: return "新版草稿文件不存在或无法安全读取。"
        case .tooLarge: return "新版草稿文件过大。"
        case .conflict: return "草稿已在其他位置修改，请先核对；本次编辑仍保留。"
        case let .cleanupFailed(path, id, reason):
            if let id {
                return "新版草稿已保存（\(id.uuidString)），但暂存文件清理失败：\(path)。\(reason)"
            }
            return "新版草稿未保存，暂存文件清理失败：\(path)。\(reason)"
        }
    }
}

/// V2 data has its own folder and filename namespace; it never interprets or
/// modifies v1 drafts, GP files, or the practice library. Synchronization is
/// within this app process; cross-process editing is not supported.
actor ScoreDraftV2Store {
    private static let updateLock = NSLock()
    private let folder: URL
    private let fileManager: FileManager
    private let maxBytes = 8 * 1024 * 1024

    init(folder: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.folder = folder ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScoreWorkspace/DraftsV2", isDirectory: true)
    }

    func listIDs() throws -> [UUID] {
        guard fileManager.fileExists(atPath: folder.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]).compactMap { url in
            let filename = url.lastPathComponent
            guard filename.hasPrefix("v2-"), url.pathExtension == "json",
                  let id = UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.dropFirst(3))),
                  filename == "v2-\(id.uuidString).json",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return id
        }.sorted { $0.uuidString < $1.uuidString }
    }

    func load(_ id: UUID) throws -> ScoreDraftV2 {
        let url = fileURL(id)
        // O_NOFOLLOW and fstat inspect the opened object, not an earlier path
        // lookup; reads remain bounded even if the file grows after inspection.
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard fd >= 0 else { throw ScoreDraftV2StoreError.invalidFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_size >= 0 else { throw ScoreDraftV2StoreError.invalidFile }
        guard info.st_size <= off_t(maxBytes) else { throw ScoreDraftV2StoreError.tooLarge }
        var data = Data()
        do {
            while data.count <= maxBytes {
                let remaining = maxBytes + 1 - data.count
                guard let chunk = try handle.read(upToCount: min(64 * 1024, remaining)), !chunk.isEmpty else { break }
                data.append(chunk)
            }
        } catch { throw ScoreDraftV2StoreError.invalidFile }
        guard data.count <= maxBytes else { throw ScoreDraftV2StoreError.tooLarge }
        let draft: ScoreDraftV2
        do { draft = try JSONDecoder().decode(ScoreDraftV2.self, from: data) }
        catch { throw ScoreDraftV2StoreError.invalidDraft }
        guard draft.isValidForStorage else { throw ScoreDraftV2StoreError.invalidDraft }
        return draft
    }

    /// Staging and link are in the same directory; an existing destination,
    /// including a symlink, is never replaced.
    @discardableResult
    func create(_ draft: ScoreDraftV2, id: UUID = UUID()) throws -> UUID {
        let data = try encoded(draft)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = fileURL(id)
        let staging = folder.appendingPathComponent(".v2-\(UUID().uuidString).pending")
        let fd = staging.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR) }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            let result = staging.path.withCString { source in
                destination.path.withCString { target in link(source, target) }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            let original = error
            do { try fileManager.removeItem(at: staging) }
            catch {
                throw ScoreDraftV2StoreError.cleanupFailed(stagingPath: staging.path, publishedID: nil,
                    reason: "保存失败：\(original.localizedDescription)；清理失败：\(error.localizedDescription)")
            }
            throw original
        }
        do { try fileManager.removeItem(at: staging) }
        catch {
            throw ScoreDraftV2StoreError.cleanupFailed(stagingPath: staging.path, publishedID: id,
                                                       reason: error.localizedDescription)
        }
        return id
    }

    /// Reject stale editors instead of overwriting another in-app update.
    func update(_ draft: ScoreDraftV2, id: UUID, replacing expected: ScoreDraftV2) throws {
        let data = try encoded(draft)
        Self.updateLock.lock()
        defer { Self.updateLock.unlock() }
        guard try load(id) == expected else { throw ScoreDraftV2StoreError.conflict }
        try data.write(to: fileURL(id), options: .atomic)
    }

    private func encoded(_ draft: ScoreDraftV2) throws -> Data {
        guard draft.isValidForStorage else { throw ScoreDraftV2StoreError.invalidDraft }
        let data: Data
        do { data = try JSONEncoder().encode(draft) }
        catch { throw ScoreDraftV2StoreError.invalidDraft }
        guard data.count <= maxBytes else { throw ScoreDraftV2StoreError.tooLarge }
        return data
    }

    private func fileURL(_ id: UUID) -> URL {
        folder.appendingPathComponent("v2-\(id.uuidString).json")
    }
}
