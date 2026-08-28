import XCTest
@testable import RiffLoop

@MainActor
final class RecentProjectsStoreTests: XCTestCase {
    func testEachModeRestoresItsOwnExistingFileAfterRelaunchAndHistoryEviction() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let documents = RiffLoopDocumentStore(documentsURL: root)
        try documents.prepareDirectories()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = RecentProjectsStore(defaults: defaults)
        for (kind, name) in [(PracticeKind.video, "clip.mp4"), (.guitarPro, "score.gp"), (.pdf, "book.pdf")] {
            try Data([1]).write(to: documents.folderURL(for: kind).appendingPathComponent(name))
            store.opened(kind: kind, fileName: name)
        }
        // A long history in one mode must not erase the other two modes' last file.
        for index in 0..<35 { store.opened(kind: .video, fileName: "missing-\(index).mp4") }
        let restored = RecentProjectsStore(defaults: defaults)
        XCTAssertEqual(restored.mostRecentValidURL(kind: .guitarPro, documents: documents)?.lastPathComponent, "score.gp")
        XCTAssertEqual(restored.mostRecentValidURL(kind: .pdf, documents: documents)?.lastPathComponent, "book.pdf")
        XCTAssertNil(restored.mostRecentValidURL(kind: .video, documents: documents))
    }

    func testRestoreSkipsDeletedEmptyAndWrongTypeFiles() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let documents = RiffLoopDocumentStore(documentsURL: root)
        try documents.prepareDirectories()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = RecentProjectsStore(defaults: defaults)
        let folder = documents.folderURL(for: .pdf)
        try Data([1]).write(to: folder.appendingPathComponent("valid.pdf"))
        try Data().write(to: folder.appendingPathComponent("empty.pdf"))
        try Data([1]).write(to: folder.appendingPathComponent("wrong.mp3"))
        for name in ["valid.pdf", "empty.pdf", "wrong.mp3", "deleted.pdf"] {
            store.opened(kind: .pdf, fileName: name)
        }
        XCTAssertEqual(store.mostRecentValidURL(kind: .pdf, documents: documents)?.lastPathComponent, "valid.pdf")
        XCTAssertNil(store.mostRecentValidURL(kind: .guitarPro, documents: documents))
    }

    func testOpeningAnExistingFileMovesItToTheFrontWithoutDuplicating() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = RecentProjectsStore(defaults: defaults)
        store.opened(kind: .video, fileName: "old.mp4", at: Date(timeIntervalSince1970: 10))
        store.opened(kind: .guitarPro, fileName: "same.gp", at: Date(timeIntervalSince1970: 20))

        store.opened(kind: .guitarPro, fileName: "same.gp", at: Date(timeIntervalSince1970: 30))

        XCTAssertEqual(
            store.projects.map(\.fileName),
            ["same.gp", "old.mp4"]
        )
        XCTAssertEqual(store.projects.first?.lastOpenedAt, Date(timeIntervalSince1970: 30))
    }

    func testRemovingARecordDoesNotDeleteItsPhysicalFile() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = RecentProjectsStore(defaults: defaults)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        store.opened(kind: .pdf, fileName: fileURL.lastPathComponent)

        store.remove(kind: .pdf, fileName: fileURL.lastPathComponent)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(store.projects.isEmpty)
    }

    func testMostRecentReturnsNewestProjectForRequestedMode() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = RecentProjectsStore(defaults: defaults)
        store.opened(kind: .video, fileName: "first.mp4", at: Date(timeIntervalSince1970: 10))
        store.opened(kind: .guitarPro, fileName: "song.gp", at: Date(timeIntervalSince1970: 20))
        store.opened(kind: .video, fileName: "latest.mp4", at: Date(timeIntervalSince1970: 30))

        XCTAssertEqual(store.mostRecent(kind: .video)?.fileName, "latest.mp4")
        XCTAssertEqual(store.mostRecent(kind: .guitarPro)?.fileName, "song.gp")
        XCTAssertNil(store.mostRecent(kind: .pdf))
    }
}
