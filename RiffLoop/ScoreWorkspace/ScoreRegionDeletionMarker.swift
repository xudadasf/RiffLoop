import CryptoKit
import Foundation

/// Call only while holding ScoreMaterialAccess's lock.
enum ScoreRegionDeletionMarker {
    private struct Record: Codable {
        let version: Int
        let nameHash: String
        let sourceDigest: String
    }

    private static func hashName(_ source: URL) -> String {
        let name = source.lastPathComponent.precomposedStringWithCanonicalMapping
        return SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func markerURL(_ source: URL, regions: URL) -> URL {
        regions.appendingPathComponent(".deleting-\(hashName(source)).json")
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    static func begin(source: URL, digest: String, metadata: URL, regions: URL) throws {
        let nameHash = hashName(source)
        guard isDigest(digest), metadata.standardizedFileURL == regions.standardizedFileURL
            .appendingPathComponent("v2-\(nameHash)-\(digest).json") else {
            throw ScoreRegionsError.invalidStoredData
        }
        try FileManager.default.createDirectory(at: regions, withIntermediateDirectories: true)
        let marker = markerURL(source, regions: regions)
        guard !FileManager.default.fileExists(atPath: marker.path) else { throw ScoreRegionsError.invalidStoredData }
        try JSONEncoder().encode(Record(version: 1, nameHash: nameHash, sourceDigest: digest))
            .write(to: marker, options: .atomic)
    }

    private static func read(source: URL, regions: URL) throws -> (URL, URL)? {
        let marker = markerURL(source, regions: regions)
        guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
        let record: Record
        do { record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: marker)) }
        catch { throw ScoreRegionsError.invalidStoredData }
        guard record.version == 1, record.nameHash == hashName(source), isDigest(record.sourceDigest) else {
            throw ScoreRegionsError.invalidStoredData
        }
        return (marker, regions.appendingPathComponent("v2-\(record.nameHash)-\(record.sourceDigest).json"))
    }

    /// A source still present means its deletion did not complete. Keep its regions.
    static func cancelIfSourceExists(source: URL, regions: URL) throws {
        guard let (marker, _) = try read(source: source, regions: regions) else { return }
        guard FileManager.default.fileExists(atPath: source.path) else { throw ScoreRegionsError.sourceChanged }
        try FileManager.default.removeItem(at: marker)
    }

    /// A missing source means deletion completed; finish cleanup before replacement.
    static func finishBeforeImport(source: URL, regions: URL, fileManager: FileManager) throws {
        guard let (marker, metadata) = try read(source: source, regions: regions) else { return }
        guard !fileManager.fileExists(atPath: source.path) else { throw ScoreRegionsError.sourceChanged }
        if fileManager.fileExists(atPath: metadata.path) { try fileManager.removeItem(at: metadata) }
        try fileManager.removeItem(at: marker)
    }
}
