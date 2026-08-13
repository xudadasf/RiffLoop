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

    func pdfAudioFiles() throws -> [URL] {
        try prepareDirectories()
        let extensions = Set(["mp3", "m4a", "wav", "aac", "flac"])
        return try fileManager.contentsOfDirectory(
            at: folderURL(for: .pdf),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { extensions.contains($0.pathExtension.lowercased()) }
        .sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    func importPdfAudio(from sourceURL: URL) throws -> URL {
        let extensions = Set(["mp3", "m4a", "wav", "aac", "flac"])
        guard extensions.contains(sourceURL.pathExtension.lowercased()) else {
            throw RiffLoopDocumentStoreError.unsupportedPdfAudio
        }
        try prepareDirectories()
        let destination = availableDestination(
            in: folderURL(for: .pdf),
            fileName: sourceURL.lastPathComponent
        )
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
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
    case unsupportedPdfAudio

    var errorDescription: String? {
        switch self {
        case let .unsupportedFile(kind):
            "所选文件不是受支持的\(kind.title)格式。"
        case .unsupportedPdfAudio:
            "请选择 MP3、M4A、WAV、AAC 或 FLAC 伴奏。"
        }
    }
}
