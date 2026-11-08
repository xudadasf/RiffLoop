import XCTest
@testable import RiffLoop

final class ScoreRegionsStoreTests: XCTestCase {
    func testRegionsPersistPerPageAndRotation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("score.pdf")
        try Data("source".utf8).write(to: source)
        let folder = root.appendingPathComponent("regions")
        let store = ScoreRegionsStore(source: source, folder: folder)
        let first = ScoreRegion(x: 0.2, y: 0.1, width: 0.5, height: 0.25)
        let second = ScoreRegion(x: 0, y: 0.4, width: 1, height: 0.2)
        try await store.savePage(index: 0, rotation: 0, regions: [first])
        try await store.savePage(index: 1, rotation: 0, regions: [second])

        let restored = ScoreRegionsStore(source: source, folder: folder)
        let page0 = try await restored.loadPage(index: 0, rotation: 0)
        let page1 = try await restored.loadPage(index: 1, rotation: 0)
        let rotated = try await restored.loadPage(index: 0, rotation: 90)
        XCTAssertEqual(page0, [first])
        XCTAssertEqual(page1, [second])
        XCTAssertTrue(rotated.isEmpty)
    }

    func testInvalidRegionDoesNotReplaceExistingPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("score.png")
        try Data("source".utf8).write(to: source)
        let store = ScoreRegionsStore(source: source, folder: root.appendingPathComponent("regions"))
        let valid = ScoreRegion(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        try await store.savePage(index: 0, rotation: 0, regions: [valid])
        do {
            try await store.savePage(index: 0, rotation: 0, regions: [ScoreRegion(x: 0.8, y: 0, width: 0.3, height: 0.5)])
            XCTFail("A region outside the page must not be saved")
        } catch ScoreRegionsError.invalidPage { }
        let restored = try await store.loadPage(index: 0, rotation: 0)
        XCTAssertEqual(restored, [valid])
    }

    func testDifferentContentAtSamePathDoesNotReuseOldRegions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("score.png")
        try Data("first".utf8).write(to: source)
        let folder = root.appendingPathComponent("regions")
        let store = ScoreRegionsStore(source: source, folder: folder)
        try await store.savePage(index: 0, rotation: 0, regions: [ScoreRegion(x: 0, y: 0, width: 1, height: 1)])
        try Data("second".utf8).write(to: source)
        let changedStore = ScoreRegionsStore(source: source, folder: folder)
        let restored = try await changedStore.loadPage(index: 0, rotation: 0)
        XCTAssertTrue(restored.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), Data("second".utf8))
    }
}
