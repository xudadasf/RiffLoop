import Foundation
import CryptoKit

/// Coordinates use the top-left origin of the orientation-corrected page as displayed.
struct ScoreRegion: Codable, Identifiable, Equatable, Sendable {
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

struct ScoreRegionsSnapshot: Equatable {
    let sourceDigest: String
    let pages: [ScoreRegionsPage]
    /// Array position is the displayed number, shared by every page of this material.
    let layout: [ScoreRegionLayoutEntry]

    func number(for location: ScoreRegionLocation) -> Int? {
        layout.firstIndex { $0.location == location }.map { $0 + 1 }
    }

    func changing(_ location: ScoreRegionLocation, number: Int, gapAfter: Int) throws -> [ScoreRegionLayoutEntry] {
        guard (1...max(1, layout.count)).contains(number), (0...99).contains(gapAfter),
              let index = layout.firstIndex(where: { $0.location == location }) else {
            throw ScoreRegionsError.invalidPage
        }
        var updated = layout
        updated.remove(at: index)
        updated.insert(ScoreRegionLayoutEntry(location: location, gapAfter: gapAfter), at: number - 1)
        return updated
    }
}

/// A UUID may occur on another PDF page in legacy documents.
struct ScoreRegionLocation: Codable, Equatable, Hashable {
    let pageIndex: Int
    let rotation: Int
    let regionID: UUID
}

struct ScoreRegionLayoutEntry: Codable, Equatable {
    let location: ScoreRegionLocation
    var gapAfter: Int
}

struct ScoreRegionsRemoval {
    let generation: UUID
    let source: URL
    let metadata: URL
    let sourceDigest: String
}

private struct ScoreRegionsDocument: Codable {
    let version: Int
    let sourceDigest: String
    var pages: [ScoreRegionsPage]
    var layout: [ScoreRegionLayoutEntry]? = nil

    var defaultLayout: [ScoreRegionLayoutEntry] {
        pages.sorted { $0.index < $1.index }.flatMap { page in
            page.regions.map {
                ScoreRegionLayoutEntry(location: ScoreRegionLocation(pageIndex: page.index,
                    rotation: page.rotation, regionID: $0.id), gapAfter: 1)
            }
        }
    }

    var snapshot: ScoreRegionsSnapshot {
        ScoreRegionsSnapshot(sourceDigest: sourceDigest, pages: pages.sorted { $0.index < $1.index },
                             layout: layout ?? defaultLayout)
    }
}

enum ScoreRegionsError: LocalizedError {
    case invalidPage
    case unreadableSource
    case invalidStoredData
    case conflict
    case sourceChanged

    var errorDescription: String? {
        switch self {
        case .invalidPage: "区域坐标无效，未保存。"
        case .unreadableSource: "无法读取素材，不能保存区域。"
        case .invalidStoredData: "已保存的区域数据无法读取。"
        case .conflict: "其他窗口已修改此页，请重新读取后保存。"
        case .sourceChanged: "素材已被删除或重新导入，请重新打开素材。"
        }
    }
}

actor ScoreRegionsStore {
    private let source: URL
    private let folder: URL
    private var digest: String?
    private var generation: UUID?

    init(source: URL, folder: URL? = nil) {
        self.source = source
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScoreWorkspace/Regions", isDirectory: true)
    }

    func loadPage(index: Int, rotation: Int) throws -> [ScoreRegion] {
        guard index >= 0 else { throw ScoreRegionsError.invalidPage }
        return try ScoreMaterialAccess.synchronized {
            let doc = try readDocument()
            guard let page = doc.pages.first(where: { $0.index == index && $0.rotation == rotation }) else { return [] }
            return page.regions
        }
    }

    /// Bind before rendering so a replacement during rendering invalidates the preview.
    func bindSource() throws {
        try ScoreMaterialAccess.synchronized { _ = try readDocument() }
    }

    /// Old documents retain page/drawing order and the original one-measure gap.
    func snapshot() throws -> ScoreRegionsSnapshot {
        try ScoreMaterialAccess.synchronized {
            let document = try readDocument()
            return document.snapshot
        }
    }

    @discardableResult
    func savePage(index: Int, rotation: Int, regions: [ScoreRegion], replacing expected: [ScoreRegion]? = nil) throws -> ScoreRegionsSnapshot {
        guard index >= 0, regions.allSatisfy(\.isValid), Set(regions.map(\.id)).count == regions.count else {
            throw ScoreRegionsError.invalidPage
        }
        return try ScoreMaterialAccess.synchronized {
            var doc = try readDocument()
            if let expected {
                let current = doc.pages.first { $0.index == index }
                guard (current == nil || current?.rotation == rotation),
                      (current?.regions ?? []) == expected else { throw ScoreRegionsError.conflict }
            }
            doc.pages.removeAll { $0.index == index }
            doc.pages.append(ScoreRegionsPage(index: index, rotation: rotation, regions: regions))
            if let layout = doc.layout {
                let valid = Set(doc.defaultLayout.map(\.location))
                let retained = layout.filter { valid.contains($0.location) }
                let known = Set(retained.map(\.location))
                doc.layout = retained + doc.defaultLayout.filter { !known.contains($0.location) }
            }
            try write(doc)
            return doc.snapshot
        }
    }

    @discardableResult
    func saveLayout(_ layout: [ScoreRegionLayoutEntry], replacing expected: ScoreRegionsSnapshot) throws -> ScoreRegionsSnapshot {
        try ScoreMaterialAccess.synchronized {
            var doc = try readDocument()
            guard doc.snapshot == expected else { throw ScoreRegionsError.conflict }
            guard Self.validLayout(layout, for: doc) else { throw ScoreRegionsError.invalidPage }
            doc.layout = layout
            try write(doc)
            return doc.snapshot
        }
    }

    private func write(_ document: ScoreRegionsDocument) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: metadataURL(for: document.sourceDigest), options: [.atomic])
    }

    private static func validLayout(_ layout: [ScoreRegionLayoutEntry], for document: ScoreRegionsDocument) -> Bool {
        let locations = layout.map(\.location)
        return Set(locations).count == locations.count &&
            Set(locations) == Set(document.defaultLayout.map(\.location)) &&
            layout.allSatisfy { (0...99).contains($0.gapAfter) }
    }

    /// Call before deleting the source, while its content is still readable.
    func prepareRemoval() throws -> ScoreRegionsRemoval {
        try ScoreMaterialAccess.synchronized {
            let document = try readDocument()
            guard let generation else { throw ScoreRegionsError.unreadableSource }
            return ScoreRegionsRemoval(generation: generation,
                                       source: source.standardizedFileURL,
                                       metadata: metadataURL(for: document.sourceDigest),
                                       sourceDigest: document.sourceDigest)
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

    private func readDocument() throws -> ScoreRegionsDocument {
        let currentGeneration = ScoreMaterialAccess.current(source)
        if let generation, generation != currentGeneration { throw ScoreRegionsError.sourceChanged }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw generation == nil ? ScoreRegionsError.unreadableSource : ScoreRegionsError.sourceChanged
        }
        if generation == nil { generation = currentGeneration }
        try ScoreRegionDeletionMarker.cancelIfSourceExists(source: source, regions: folder)
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
              doc.pages.allSatisfy({ page in
                  page.index >= 0 && page.regions.allSatisfy(\.isValid) &&
                      Set(page.regions.map(\.id)).count == page.regions.count
              }),
              Set(doc.pages.map(\.index)).count == doc.pages.count else {
            throw ScoreRegionsError.invalidStoredData
        }
        if let layout = doc.layout, !Self.validLayout(layout, for: doc) {
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
