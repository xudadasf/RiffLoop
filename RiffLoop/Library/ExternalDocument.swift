import Foundation

struct ExternalDocument: Identifiable, Hashable {
    let id = UUID()
    let kind: PracticeKind
    let url: URL

    static func receive(_ url: URL, store: RiffLoopDocumentStore = .init()) throws -> Self {
        guard url.isFileURL,
              let kind = PracticeKind.allCases.first(where: {
                  $0.supportedExtensions.contains(url.pathExtension.lowercased())
              }) else { throw ExternalDocumentError.unsupported }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let folder = store.folderURL(for: kind).standardizedFileURL.resolvingSymlinksInPath()
        let source = url.standardizedFileURL.resolvingSymlinksInPath()
        if source.deletingLastPathComponent() == folder {
            return Self(kind: kind, url: source)
        }
        // Keep external originals and existing practice profiles intact on name collisions.
        return Self(kind: kind, url: try store.importFile(from: url, for: kind))
    }
}

private enum ExternalDocumentError: LocalizedError {
    case unsupported
    var errorDescription: String? { "请选择 GP、GPX、GP3–5、PDF、MP4、MOV 或 M4V 文件。" }
}
