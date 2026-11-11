import XCTest
@testable import RiffLoop

final class ScoreRegionsStoreTests: XCTestCase {
    func testRemovalReportsRegionCleanupFailureAfterDeletingSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("score.png")
        try Data("source".utf8).write(to: input)
        let workspace = ScoreWorkspaceStore(folder: root.appendingPathComponent("imports"), fileManager: FailRegionCleanupFileManager())
        let source = try await workspace.importCopy(from: input)
        let folder = root.appendingPathComponent("regions")
        let regions = ScoreRegionsStore(source: source, folder: folder)
        try await regions.savePage(index: 0, rotation: 0, regions: [ScoreRegion(x: 0, y: 0, width: 1, height: 1)])
        let removal = try await regions.prepareRemoval()
        let result = try await workspace.removeCopy(source, removal: removal)
        XCTAssertNotNil(result.cleanupError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
        let reimported = try await workspace.importCopy(from: input)
        XCTAssertEqual(reimported, source)
        let restored = try await ScoreRegionsStore(source: reimported, folder: folder).loadPage(index: 0, rotation: 0)
        XCTAssertEqual(restored.count, 1, "Failed cleanup can leave regions for a same-name, same-content import")
    }

    func testRemovedMaterialCannotBeSavedByAnOpenEditor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("score.png")
        try Data("source".utf8).write(to: input)
        let workspace = ScoreWorkspaceStore(folder: root.appendingPathComponent("imports"))
        let source = try await workspace.importCopy(from: input)
        let regions = ScoreRegionsStore(source: source, folder: root.appendingPathComponent("regions"))
        let original = ScoreRegion(x: 0, y: 0, width: 0.5, height: 0.5)
        try await regions.savePage(index: 0, rotation: 0, regions: [original], replacing: [])
        let removal = try await regions.prepareRemoval()
        let result = try await workspace.removeCopy(source, removal: removal)
        XCTAssertNil(result.cleanupError)
        do {
            try await regions.savePage(index: 0, rotation: 0, regions: [original], replacing: [original])
            XCTFail("A removed material must not accept region writes")
        } catch ScoreRegionsError.sourceChanged { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("regions").path).isEmpty)
    }

    func testSameNameReimportInvalidatesOldEditorAndOldCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("score.png")
        try Data("same bytes".utf8).write(to: input)
        let workspace = ScoreWorkspaceStore(folder: root.appendingPathComponent("imports"))
        let source = try await workspace.importCopy(from: input)
        let folder = root.appendingPathComponent("regions")
        let old = ScoreRegionsStore(source: source, folder: folder)
        let oldRegion = ScoreRegion(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        try await old.savePage(index: 0, rotation: 0, regions: [oldRegion], replacing: [])
        let removal = try await old.prepareRemoval()
        let result = try await workspace.removeCopy(source, removal: removal)
        XCTAssertNil(result.cleanupError)
        let reimported = try await workspace.importCopy(from: input)
        XCTAssertEqual(source, reimported)
        let new = ScoreRegionsStore(source: reimported, folder: folder)
        let initial = try await new.loadPage(index: 0, rotation: 0)
        XCTAssertTrue(initial.isEmpty)
        let region = ScoreRegion(x: 0, y: 0, width: 0.5, height: 0.5)
        try await new.savePage(index: 0, rotation: 0, regions: [region], replacing: [])
        do {
            try await old.savePage(index: 0, rotation: 0, regions: [], replacing: [])
            XCTFail("An editor for the removed copy cannot modify its replacement")
        } catch ScoreRegionsError.sourceChanged { }
        do {
            _ = try await workspace.removeCopy(source, removal: removal)
            XCTFail("Old removal must not remove the reimported copy or its regions")
        } catch ScoreWorkspaceError.sourceChanged { }
        let retained = try await new.loadPage(index: 0, rotation: 0)
        XCTAssertEqual(retained, [region])
    }

    func testStaleWindowCannotReplaceSamePage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("score.png")
        try Data("source".utf8).write(to: source)
        let first = ScoreRegionsStore(source: source, folder: root.appendingPathComponent("regions"))
        let second = ScoreRegionsStore(source: source, folder: root.appendingPathComponent("regions"))
        let a = ScoreRegion(x: 0, y: 0, width: 0.5, height: 0.5)
        let b = ScoreRegion(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        let firstSnapshot = try await first.loadPage(index: 0, rotation: 0)
        let staleSnapshot = try await second.loadPage(index: 0, rotation: 0)
        try await first.savePage(index: 0, rotation: 0, regions: [a], replacing: firstSnapshot)
        do {
            try await second.savePage(index: 0, rotation: 0, regions: [b], replacing: staleSnapshot)
            XCTFail("An outdated page must not overwrite a newer one")
        } catch ScoreRegionsError.conflict { }
        let saved = try await second.loadPage(index: 0, rotation: 0)
        XCTAssertEqual(saved, [a])
    }

    func testSimultaneousWritesOnDifferentPagesPreserveBoth() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("score.pdf")
        try Data("source".utf8).write(to: source)
        let folder = root.appendingPathComponent("regions")
        let first = ScoreRegionsStore(source: source, folder: folder)
        let second = ScoreRegionsStore(source: source, folder: folder)
        let a = ScoreRegion(x: 0, y: 0, width: 0.5, height: 0.5)
        let b = ScoreRegion(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        async let writeA: Void = first.savePage(index: 0, rotation: 0, regions: [a], replacing: [])
        async let writeB: Void = second.savePage(index: 1, rotation: 0, regions: [b], replacing: [])
        _ = try await (writeA, writeB)
        let page0 = try await first.loadPage(index: 0, rotation: 0)
        let page1 = try await first.loadPage(index: 1, rotation: 0)
        XCTAssertEqual(page0, [a])
        XCTAssertEqual(page1, [b])
    }

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

    func testStableKeySurvivesContainerPathChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldFolder = root.appendingPathComponent("old/Imports")
        let newFolder = root.appendingPathComponent("new/Imports")
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        let oldSource = oldFolder.appendingPathComponent("score.png")
        let newSource = newFolder.appendingPathComponent("score.png")
        let data = Data("same copied source".utf8)
        try data.write(to: oldSource)
        try data.write(to: newSource)
        let regionsFolder = root.appendingPathComponent("Regions")
        let region = ScoreRegion(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        try await ScoreRegionsStore(source: oldSource, folder: regionsFolder)
            .savePage(index: 0, rotation: 0, regions: [region])
        let restored = try await ScoreRegionsStore(source: newSource, folder: regionsFolder)
            .loadPage(index: 0, rotation: 0)
        XCTAssertEqual(restored, [region])
    }

    func testSnapshotSortsPagesAndPreservesBoxOrderAndFingerprint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("score.pdf")
        try Data("source".utf8).write(to: source)
        let store = ScoreRegionsStore(source: source, folder: root.appendingPathComponent("regions"))
        let first = ScoreRegion(x: 0, y: 0, width: 0.5, height: 0.5)
        let second = ScoreRegion(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        try await store.savePage(index: 2, rotation: 0, regions: [second])
        try await store.savePage(index: 0, rotation: 0, regions: [second, first])
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.sourceDigest, "41cf6794ba4200b839c53531555f0f3998df4cbb01a4d5cb0b94e3ca5e23947d")
        XCTAssertEqual(snapshot.pages.map(\.index), [0, 2])
        XCTAssertEqual(snapshot.pages[0].regions, [second, first])
        XCTAssertEqual(snapshot.pages[1].regions, [second])
    }

    func testSnapshotRejectsDuplicateBoxIDsInStoredData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("score.pdf")
        try Data("source".utf8).write(to: source)
        let folder = root.appendingPathComponent("regions")
        let store = ScoreRegionsStore(source: source, folder: folder)
        try await store.savePage(index: 0, rotation: 0, regions: [ScoreRegion(x: 0, y: 0, width: 1, height: 1)])
        let url = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var pages = try XCTUnwrap(document["pages"] as? [[String: Any]])
        var regions = try XCTUnwrap(pages[0]["regions"] as? [[String: Any]])
        regions.append(regions[0])
        pages[0]["regions"] = regions
        document["pages"] = pages
        try JSONSerialization.data(withJSONObject: document).write(to: url)
        do {
            _ = try await store.snapshot()
            XCTFail("A corrupted page must not produce ambiguous box references")
        } catch ScoreRegionsError.invalidStoredData { }
    }

    func testIdenticalContentsWithDifferentNamesKeepIndependentRegions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.png")
        let second = root.appendingPathComponent("second.png")
        let data = Data("identical content".utf8)
        try data.write(to: first)
        try data.write(to: second)
        let folder = root.appendingPathComponent("regions")
        let region = ScoreRegion(x: 0, y: 0, width: 1, height: 1)
        try await ScoreRegionsStore(source: first, folder: folder)
            .savePage(index: 0, rotation: 0, regions: [region])
        let secondRegions = try await ScoreRegionsStore(source: second, folder: folder)
            .loadPage(index: 0, rotation: 0)
        XCTAssertTrue(secondRegions.isEmpty)
    }

    func testRemoveMetadataAfterSourceDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("score.png")
        try Data("source".utf8).write(to: source)
        let folder = root.appendingPathComponent("regions")
        let store = ScoreRegionsStore(source: source, folder: folder)
        try await store.savePage(index: 0, rotation: 0, regions: [ScoreRegion(x: 0, y: 0, width: 1, height: 1)])
        let removal = try await store.prepareRemoval()
        let result = try await ScoreWorkspaceStore(folder: root).removeCopy(source, removal: removal)
        XCTAssertNil(result.cleanupError)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    func testRemovalPreservesRegionsFromOtherContentAtSameName() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("score.png")
        let folder = root.appendingPathComponent("regions")
        let firstRegion = ScoreRegion(x: 0, y: 0, width: 0.5, height: 0.5)
        try Data("first version".utf8).write(to: source)
        try await ScoreRegionsStore(source: source, folder: folder)
            .savePage(index: 0, rotation: 0, regions: [firstRegion])
        try Data("replacement version".utf8).write(to: source)
        let replacementStore = ScoreRegionsStore(source: source, folder: folder)
        try await replacementStore.savePage(index: 0, rotation: 0,
                                            regions: [ScoreRegion(x: 0.5, y: 0.5, width: 0.5, height: 0.5)])
        let removal = try await replacementStore.prepareRemoval()
        let result = try await ScoreWorkspaceStore(folder: root).removeCopy(source, removal: removal)
        XCTAssertNil(result.cleanupError)
        try Data("first version".utf8).write(to: source)
        let restored = try await ScoreRegionsStore(source: source, folder: folder).loadPage(index: 0, rotation: 0)
        XCTAssertEqual(restored, [firstRegion])
    }
}

private final class FailRegionCleanupFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        if URL.pathExtension == "json" { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: URL)
    }
}
