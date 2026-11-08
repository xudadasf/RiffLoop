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
        try data.write(to: metadataURL, options: [.atomic])
    }

    /// Call when deleting the workspace's source copy, not when leaving the editor.
    func removeSavedData() throws {
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            try FileManager.default.removeItem(at: metadataURL)
        }
    }

    private var metadataURL: URL {
        let pathHash = SHA256.hash(data: Data(source.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(pathHash + ".json")
    }

    private func readDocument() throws -> ScoreRegionsDocument {
        let sourceDigest = try digestForSource()
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return ScoreRegionsDocument(version: 1, sourceDigest: sourceDigest, pages: [])
        }
        let doc: ScoreRegionsDocument
        do {
            doc = try JSONDecoder().decode(ScoreRegionsDocument.self, from: Data(contentsOf: metadataURL))
        } catch {
            throw ScoreRegionsError.invalidStoredData
        }
        guard doc.version == 1,
              doc.pages.allSatisfy({ $0.index >= 0 && $0.regions.allSatisfy(\.isValid) }),
              Set(doc.pages.map(\.index)).count == doc.pages.count else {
            throw ScoreRegionsError.invalidStoredData
        }
        guard doc.sourceDigest == sourceDigest else {
            return ScoreRegionsDocument(version: 1, sourceDigest: sourceDigest, pages: [])
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
