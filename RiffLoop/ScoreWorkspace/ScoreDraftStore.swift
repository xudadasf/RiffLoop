import Darwin
import Foundation

private struct DraftKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    static func key(_ value: String) -> DraftKey { DraftKey(stringValue: value)! }
}

/// The limited new-draft format currently supported by the experimental GP
/// exporter. It is not an importer for existing GP files.
enum ScoreDraftEvent: Codable, Equatable, Sendable {
    case note(string: Int, fret: Int, duration: Int)
    case rest(duration: Int)

    var duration: Int {
        switch self {
        case let .note(_, _, duration), let .rest(duration): return duration
        }
    }

    var isValid: Bool {
        guard [1, 2, 4, 8, 16, 32, 64].contains(duration) else { return false }
        switch self {
        case let .note(string, fret, _): return (1...6).contains(string) && (0...36).contains(fret)
        case .rest: return true
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DraftKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        let duration = try container.decode(Int.self, forKey: .key("duration"))
        if keys == ["rest", "duration"] {
            guard try container.decode(Bool.self, forKey: .key("rest")) else {
                throw DecodingError.dataCorruptedError(forKey: .key("rest"), in: container,
                                                       debugDescription: "Invalid rest")
            }
            self = .rest(duration: duration)
        } else if keys == ["string", "fret", "duration"] {
            self = .note(string: try container.decode(Int.self, forKey: .key("string")),
                         fret: try container.decode(Int.self, forKey: .key("fret")), duration: duration)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unsupported draft event"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DraftKey.self)
        try container.encode(duration, forKey: .key("duration"))
        switch self {
        case let .note(string, fret, _):
            try container.encode(string, forKey: .key("string"))
            try container.encode(fret, forKey: .key("fret"))
        case .rest:
            try container.encode(true, forKey: .key("rest"))
        }
    }
}

/// Drafts are currently 4/4, standard guitar tuning, single notes and rests.
/// Incomplete bars can be saved for continued editing but cannot be exported.
struct ScoreDraft: Codable, Equatable, Sendable {
    let version: Int
    var title: String
    var tempo: Int
    var bars: [[ScoreDraftEvent]]

    init(title: String, tempo: Int, bars: [[ScoreDraftEvent]]) {
        version = 1
        self.title = title
        self.tempo = tempo
        self.bars = bars
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DraftKey.self)
        guard Set(container.allKeys.map(\.stringValue)) == ["version", "title", "tempo", "bars"] else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unsupported draft fields"))
        }
        version = try container.decode(Int.self, forKey: .key("version"))
        title = try container.decode(String.self, forKey: .key("title"))
        tempo = try container.decode(Int.self, forKey: .key("tempo"))
        bars = try container.decode([[ScoreDraftEvent]].self, forKey: .key("bars"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DraftKey.self)
        try container.encode(version, forKey: .key("version"))
        try container.encode(title, forKey: .key("title"))
        try container.encode(tempo, forKey: .key("tempo"))
        try container.encode(bars, forKey: .key("bars"))
    }

    var isValid: Bool {
        version == 1 && title.count <= 256 && (1...999).contains(tempo) &&
            (1...512).contains(bars.count) && bars.allSatisfy {
                (1...128).contains($0.count) && $0.allSatisfy(\.isValid)
            }
    }

    var isComplete: Bool {
        isValid && bars.allSatisfy { bar in bar.reduce(0) { $0 + 64 / $1.duration } == 64 }
    }
}

enum ScoreDraftStoreError: LocalizedError {
    case invalidDraft
    case invalidFile
    case tooLarge
    case conflict

    var errorDescription: String? {
        switch self {
        case .invalidDraft: "草稿内容无效或包含暂不支持的内容。"
        case .invalidFile: "草稿文件不存在或无法安全读取。"
        case .tooLarge: "草稿文件过大。"
        case .conflict: "草稿已在其他位置修改，请重新打开后再保存。"
        }
    }
}

/// Separate from imported material and from the practice library.
actor ScoreDraftStore {
    // All instances in this app share the same lock. Drafts live in the app's
    // private container; cross-process editing is not currently supported.
    private static let updateLock = NSLock()
    private let folder: URL
    private let fileManager: FileManager
    private let maxBytes = 8 * 1024 * 1024

    init(folder: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.folder = folder ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScoreWorkspace/Drafts", isDirectory: true)
    }

    func listIDs() throws -> [UUID] {
        guard fileManager.fileExists(atPath: folder.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: folder,
                                                   includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                   options: [.skipsHiddenFiles]).compactMap { url in
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  url.lastPathComponent == id.uuidString + ".json",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return id
        }.sorted { $0.uuidString < $1.uuidString }
    }

    func load(_ id: UUID) throws -> ScoreDraft {
        let url = fileURL(id)
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) }
        catch { throw ScoreDraftStoreError.invalidFile }
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
            throw ScoreDraftStoreError.invalidFile
        }
        guard size <= maxBytes else { throw ScoreDraftStoreError.tooLarge }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw ScoreDraftStoreError.invalidFile }
        guard data.count <= maxBytes else { throw ScoreDraftStoreError.tooLarge }
        let draft: ScoreDraft
        do { draft = try JSONDecoder().decode(ScoreDraft.self, from: data) }
        catch { throw ScoreDraftStoreError.invalidDraft }
        guard draft.isValid else { throw ScoreDraftStoreError.invalidDraft }
        return draft
    }

    /// Publish a completed stage using an exclusive same-directory link. Unlike
    /// a replacing rename, link cannot overwrite an existing destination.
    @discardableResult
    func create(_ draft: ScoreDraft, id: UUID = UUID()) throws -> UUID {
        let data = try encoded(draft)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = fileURL(id)
        let staging = folder.appendingPathComponent(".\(UUID().uuidString).pending")
        let fd = staging.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR) }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? fileManager.removeItem(at: staging) }
        try handle.write(contentsOf: data)
        try handle.close()
        let linked = staging.path.withCString { source in
            destination.path.withCString { target in link(source, target) }
        }
        guard linked == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return id
    }

    /// Reject stale editors instead of overwriting another in-app update.
    func update(_ draft: ScoreDraft, id: UUID, replacing expected: ScoreDraft) throws {
        let data = try encoded(draft)
        Self.updateLock.lock()
        defer { Self.updateLock.unlock() }
        guard try load(id) == expected else { throw ScoreDraftStoreError.conflict }
        try data.write(to: fileURL(id), options: .atomic)
    }

    private func encoded(_ draft: ScoreDraft) throws -> Data {
        guard draft.isValid else { throw ScoreDraftStoreError.invalidDraft }
        let data = try JSONEncoder().encode(draft)
        guard data.count <= maxBytes else { throw ScoreDraftStoreError.tooLarge }
        return data
    }

    private func fileURL(_ id: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString + ".json")
    }
}
