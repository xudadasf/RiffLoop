import Foundation

struct RiffLoopDocumentStore {
    let documentsURL: URL
    private let fileManager: FileManager

    init(
        documentsURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.documentsURL = documentsURL ?? fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
    }

    func prepareDirectories() throws {
        for kind in PracticeKind.allCases {
            try fileManager.createDirectory(
                at: folderURL(for: kind),
                withIntermediateDirectories: true
            )
        }
    }

    func folderURL(for kind: PracticeKind) -> URL {
        documentsURL.appendingPathComponent(kind.folderName, isDirectory: true)
    }

    func files(for kind: PracticeKind) throws -> [URL] {
        try prepareDirectories()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        return try fileManager.contentsOfDirectory(
            at: folderURL(for: kind),
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            guard kind.supportedExtensions.contains(url.pathExtension.lowercased()) else {
                return false
            }
            return (try? url.resourceValues(forKeys: keys).isRegularFile) == true
        }
        .sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    func importFile(from sourceURL: URL, for kind: PracticeKind) throws -> URL {
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard kind.supportedExtensions.contains(fileExtension) else {
            throw RiffLoopDocumentStoreError.unsupportedFile(kind)
        }

        try prepareDirectories()
        let destination = availableDestination(
            in: folderURL(for: kind),
            fileName: sourceURL.lastPathComponent
        )
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    private func availableDestination(in folder: URL, fileName: String) -> URL {
        let proposed = folder.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: proposed.path) else { return proposed }

        let source = URL(fileURLWithPath: fileName)
        let fileExtension = source.pathExtension
        let baseName = source.deletingPathExtension().lastPathComponent
        var suffix = 2

        while true {
            let numberedName = fileExtension.isEmpty
                ? "\(baseName) (\(suffix))"
                : "\(baseName) (\(suffix)).\(fileExtension)"
            let candidate = folder.appendingPathComponent(numberedName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }
}

enum RiffLoopDocumentStoreError: LocalizedError {
    case unsupportedFile(PracticeKind)

    var errorDescription: String? {
        switch self {
        case let .unsupportedFile(kind):
            "所选文件不是受支持的\(kind.title)格式。"
        }
    }
}
