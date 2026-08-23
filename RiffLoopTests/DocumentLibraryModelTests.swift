import XCTest
@testable import RiffLoop

@MainActor
final class DocumentLibraryModelTests: XCTestCase {
    func testDeletingPdfRemovesItsFileAndSettings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settingsStore = FilePracticeSettingsStore(defaults: defaults)
        let documentStore = RiffLoopDocumentStore(documentsURL: root)
        try documentStore.prepareDirectories()
        let pdf = documentStore.folderURL(for: .pdf).appendingPathComponent("练习.pdf")
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: pdf)
        try settingsStore.save(
            PdfPracticeProfile(bpm: 88),
            kind: .pdf,
            fileName: pdf.lastPathComponent
        )
        let model = DocumentLibraryModel(
            kind: .pdf,
            store: documentStore,
            settingsStore: settingsStore
        )

        XCTAssertTrue(model.deleteFile(pdf))

        XCTAssertFalse(FileManager.default.fileExists(atPath: pdf.path))
        XCTAssertNil(
            try settingsStore.load(
                PdfPracticeProfile.self,
                kind: .pdf,
                fileName: pdf.lastPathComponent
            )
        )
    }
}
