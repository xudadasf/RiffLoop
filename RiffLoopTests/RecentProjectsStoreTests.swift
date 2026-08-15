import XCTest
@testable import RiffLoop

@MainActor
final class RecentProjectsStoreTests: XCTestCase {
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
