import Foundation

struct ImportedMediaStore {
    func copyIntoSandbox(_ sourceURL: URL) throws -> URL {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let importsDirectory = applicationSupport.appendingPathComponent("Imports", isDirectory: true)
        try fileManager.createDirectory(at: importsDirectory, withIntermediateDirectories: true)

        let destination = importsDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(sourceURL.pathExtension)
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }
}

