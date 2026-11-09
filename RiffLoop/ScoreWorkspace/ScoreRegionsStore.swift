import Foundation
import CryptoKit

/// Coordinates use the top-left origin of the orientation-corrected page as displayed.
struct ScoreRegion: Codable, Identifiable, Equatable {
    let id: UUID
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(id: UUID = UUID(), x: Double, y: Double, width: Double, height: Double) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) &&
            x >= 0 && y >= 0 && width > 0 && height > 0 &&
            x + width <= 1.000_000_1 && y + height <= 1.000_000_1
    }
}

struct ScoreRegionsPage: Codable, Equatable {
    /// PDF page index, or 0 for an image. PDF rotation is checked on restore.
    let index: Int
    let rotation: Int
    var regions: [ScoreRegion]
}

private struct ScoreRegionsDocument: Codable {
    let version: Int
    let sourceDigest: String
    var pages: [ScoreRegionsPage]
}

enum ScoreRegionsError: LocalizedError {
    case invalidPage
    case unreadableSource
    case invalidStoredData

    var errorDescription: String? {
        switch self {
        case .invalidPage: "区域坐标无效，未保存。"
        case .unreadableSource: "无法读取素材，不能保存区域。"
        case .invalidStoredData: "已保存的区域数据无法读取。"
        }
    }
}

actor ScoreRegionsStore {
    private let source: URL
    private let folder: URL
    private var digest: String?

    init(source: URL, folder: URL? = nil) {
        self.source = source
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScoreWorkspace/Regions", isDirectory: true)
    }

    func loadPage(index: Int, rotation: Int) throws -> [ScoreRegion] {
        guard index >= 0 else { throw ScoreRegionsError.invalidPage }
        let doc = try readDocument()
        guard let page = doc.pages.first(where: { $0.index == index && $0.rotation == rotation }) else { return [] }
        return page.regions
    }

    func savePage(index: Int, rotation: Int, regions: [ScoreRegion]) throws {
        guard index >= 0, regions.allSatisfy(\.isValid), Set(regions.map(\.id)).count == regions.count else {
            throw ScoreRegionsError.invalidPage
        }
        var doc = try readDocument()
        doc.pages.removeAll { $0.index == index }
        doc.pages.append(ScoreRegionsPage(index: index, rotation: rotation, regions: regions))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(doc)
        try data.write(to: metadataURL(for: doc.sourceDigest), options: [.atomic])
    }

    /// Call before deleting the source, while its content is still readable.
    func prepareRemoval() throws -> String {
        try readDocument().sourceDigest
    }

    /// Call only after the source is removed, using the fingerprint prepared above.
    func removeSavedData(for sourceDigest: String) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: folder.path) else { return }
        guard Self.isDigest(sourceDigest) else { throw ScoreRegionsError.invalidStoredData }
        let url = metadataURL(for: sourceDigest)
        if manager.fileExists(atPath: url.path) {
            let doc = try decodeDocument(at: url)
            guard doc.sourceDigest == sourceDigest else { throw ScoreRegionsError.invalidStoredData }
            try manager.removeItem(at: url)
        }
    }

    private var materialNameHash: String {
        Self.sha256(Data(source.lastPathComponent.precomposedStringWithCanonicalMapping.utf8))
    }

    private func metadataURL(for sourceDigest: String) -> URL {
        folder.appendingPathComponent("v2-\(materialNameHash)-\(sourceDigest).json")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private func readDocument() throws -> ScoreRegionsDocument {
        let sourceDigest = try digestForSource()
        let manager = FileManager.default
        let currentURL = metadataURL(for: sourceDigest)
        if manager.fileExists(atPath: currentURL.path) {
            let doc = try decodeDocument(at: currentURL)
            guard doc.sourceDigest == sourceDigest else { throw ScoreRegionsError.invalidStoredData }
            return doc
        }
        return ScoreRegionsDocument(version: 1, sourceDigest: sourceDigest, pages: [])
    }

    private func decodeDocument(at url: URL) throws -> ScoreRegionsDocument {
        let doc: ScoreRegionsDocument
        do {
            doc = try JSONDecoder().decode(ScoreRegionsDocument.self, from: Data(contentsOf: url))
        } catch {
            throw ScoreRegionsError.invalidStoredData
        }
        guard doc.version == 1,
              doc.pages.allSatisfy({ $0.index >= 0 && $0.regions.allSatisfy(\.isValid) }),
              Set(doc.pages.map(\.index)).count == doc.pages.count else {
            throw ScoreRegionsError.invalidStoredData
        }
        return doc
    }

    private func digestForSource() throws -> String {
        if let digest { return digest }
        guard let stream = InputStream(url: source) else { throw ScoreRegionsError.unreadableSource }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                if let error = stream.streamError { throw error }
                throw ScoreRegionsError.unreadableSource
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        let result = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        digest = result
        return result
    }
}
