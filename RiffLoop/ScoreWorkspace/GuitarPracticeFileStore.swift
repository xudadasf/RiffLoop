import CryptoKit
import Foundation

/// One owned practice file per editable result, independent of its title.
/// A receipt prevents replacing an imported file or an externally edited GP.
actor GuitarPracticeFileStore {
    private static let lock = NSLock()
    struct Receipt: Codable, Sendable {
        var current: String?
        var pending: String?
        func write(to url: URL) throws { try JSONEncoder().encode(self).write(to: url, options: .atomic) }
    }
    private let folder: URL
    private let receipts: URL
    private let drafts: GuitarDraftStore
    private let writeReceipt: @Sendable (Receipt, URL) throws -> Void
    init(folder: URL, receipts: URL? = nil, drafts: GuitarDraftStore = GuitarDraftStore(),
         writeReceipt: @escaping @Sendable (Receipt, URL) throws -> Void = { try $0.write(to: $1) }) {
        self.folder = folder
        self.drafts = drafts
        self.writeReceipt = writeReceipt
        self.receipts = receipts ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScoreWorkspace/GuitarPublished", isDirectory: true)
    }
    static func fileName(_ id: UUID) -> String { "编辑结果-\(id.uuidString).gp" }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func readRegular(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximum else { throw GuitarDraftStoreError.invalidFile }
        let data = try Data(contentsOf: url)
        guard data.count <= maximum else { throw GuitarDraftStoreError.tooLarge }
        return data
    }
    func editableDocument(for url: URL) async -> GuitarDraftDocument? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("编辑结果-"), let id = UUID(uuidString: String(stem.dropFirst(5))),
              url.lastPathComponent == Self.fileName(id),
              let data = try? readRegular(url, maximum: 8 * 1024 * 1024),
              let bytes = try? readRegular(receipts.appendingPathComponent(id.uuidString + ".json"), maximum: 2048),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: bytes) else { return nil }
        let hash = digest(data)
        guard hash == receipt.current || hash == receipt.pending,
              let draft = try? await drafts.load(id) else { return nil }
        return GuitarDraftDocument(id: id, draft: draft, publishedHash: hash)
    }
    struct Publication: Sendable {
        let url: URL
        let hash: String
    }
    func publish(_ data: Data, id: UUID, replacing expectedHash: String? = nil) throws -> Publication {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard data.count <= 8 * 1024 * 1024, data.starts(with: [0x50,0x4b,0x03,0x04]) else { throw ScoreDraftGPFileStoreError.invalidData }
        let fm = FileManager.default, target = folder.appendingPathComponent(Self.fileName(id))
        if expectedHash != nil || fm.fileExists(atPath: target.path) {
            return try GuitarExistingFile.coordinatingReplacement(at: target) { coordinatedURL in
                guard coordinatedURL.lastPathComponent == target.lastPathComponent else { throw GuitarDraftStoreError.conflict }
                return try write(data, id: id, to: coordinatedURL, replacing: expectedHash)
            }
        }
        return try write(data, id: id, to: target, replacing: nil)
    }
    private func write(_ data: Data, id: UUID, to target: URL, replacing expectedHash: String?) throws -> Publication {
        let fm = FileManager.default
        let receiptURL = receipts.appendingPathComponent(id.uuidString + ".json")
        var receipt: Receipt?
        var ownedHash: String?
        if (try? fm.attributesOfItem(atPath: receiptURL.path)) != nil {
            receipt = try JSONDecoder().decode(Receipt.self, from: readRegular(receiptURL, maximum: 2048))
        }
        if (try? fm.attributesOfItem(atPath: target.path)) != nil {
            let actual = digest(try readRegular(target, maximum: 8 * 1024 * 1024))
            guard let receipt, actual == receipt.current || actual == receipt.pending else { throw GuitarDraftStoreError.conflict }
            ownedHash = actual
        }
        if let expectedHash, ownedHash != expectedHash { throw GuitarDraftStoreError.conflict }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(at: receipts, withIntermediateDirectories: true)
        let newHash = digest(data)
        try writeReceipt(Receipt(current: ownedHash, pending: newHash), receiptURL)
        try data.write(to: target, options: .atomic)
        // At this point the GP contains newHash and its pending receipt is durable.
        // Failure to retire the old hash must not return a stale revision to the editor.
        try? writeReceipt(Receipt(current: newHash, pending: nil), receiptURL)
        return Publication(url: target, hash: newHash)
    }
}

@MainActor
final class GuitarResultSaver {
    static let shared = GuitarResultSaver()
    private var saving = Set<UUID>()
    private let store = GuitarDraftStore()
    private lazy var practice = GuitarPracticeFileStore(folder: RiffLoopDocumentStore().folderURL(for: .guitarPro))

    /// Keep an incomplete editable result, and never claim the practice file
    /// was updated when its round-trip validation did not pass.
    func save(_ draft: GuitarDraft, id: UUID, replacing expected: GuitarDraft, publishedHash: String?) async throws -> (message: String, publishedHash: String?) {
        guard saving.insert(id).inserted else { throw ScoreDraftExportError.busy }
        defer { saving.remove(id) }
        try await store.update(draft, id: id, replacing: expected)
        do {
            let data = try await ScoreDraftExporter.export(draft)
            let result = try await practice.publish(data, id: id, replacing: publishedHash)
            DocumentDisplayNameStore().setDisplayName(draft.title, for: .guitarPro, fileName: result.url.lastPathComponent)
            return ("已保存。同一份曲谱已更新，可继续编辑或到练习列表播放。", result.hash)
        } catch {
            return ("编辑内容已保存；练习谱尚未更新：\(error.localizedDescription) 请继续核对后再保存，不会新增副本。", nil)
        }
    }
}
