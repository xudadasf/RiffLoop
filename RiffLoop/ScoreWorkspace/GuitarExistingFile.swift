import Foundation

/// Serialize compare-and-replace across editors. Only open an existing regular
/// library file, and never recreate an original that was deleted while editing.
actor GuitarExistingFile {
    static let shared = GuitarExistingFile()
    private static let maximum = 64 * 1024 * 1024
    static func read(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              url.pathExtension.lowercased() == "gp", let size = values.fileSize,
              size <= maximum else { throw GuitarDraftStoreError.invalidFile }
        let data = try Data(contentsOf: url)
        guard data.count <= maximum, data.starts(with: [0x50, 0x4b, 0x03, 0x04]) else {
            throw GuitarDraftStoreError.invalidFile
        }
        return data
    }
    func replace(_ url: URL, original: Data, edited: Data) throws {
        guard edited.count <= Self.maximum, edited.starts(with: [0x50, 0x4b, 0x03, 0x04]) else {
            throw GuitarDraftStoreError.invalidFile
        }
        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                guard try Self.read(target) == original else { throw GuitarDraftStoreError.conflict }
                if edited != original { try edited.write(to: target, options: .atomic) }
            } catch { failure = error }
        }
        if let failure { throw failure }
        if let coordinationError { throw coordinationError }
    }
}
