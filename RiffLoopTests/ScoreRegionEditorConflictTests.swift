import UIKit
import XCTest
@testable import RiffLoop

@MainActor
final class ScoreRegionEditorConflictTests: XCTestCase {
    func testReplacementDuringRenderingDoesNotShowEditableStalePreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("score.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in }
        try XCTUnwrap(image.pngData()).write(to: input)
        let workspace = ScoreWorkspaceStore(folder: root.appendingPathComponent("imports"))
        let source = try await workspace.importCopy(from: input)
        let folder = root.appendingPathComponent("regions")
        let oldStore = ScoreRegionsStore(source: source, folder: folder)
        let started = expectation(description: "Preview rendering started")
        let finish = DispatchSemaphore(value: 0)
        defer { finish.signal() }
        let model = ScoreRegionEditorModel(source: source, store: oldStore) { url, page in
            started.fulfill()
            finish.wait()
            return ScorePageRenderer.render(source: url, index: page)
        }
        let opening = Task { await model.open() }
        await fulfillment(of: [started], timeout: 10)
        let removal = try await oldStore.prepareRemoval()
        _ = try await workspace.removeCopy(source, removal: removal)
        let replacement = try await workspace.importCopy(from: input)
        XCTAssertEqual(source, replacement)
        finish.signal()
        await opening.value
        XCTAssertNil(model.image)
        XCTAssertTrue(model.regions.isEmpty)
        XCTAssertNotNil(model.message)
    }

    func testConflictingDrawingIsRetainedAndCanBeRetried() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("score.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in }
        try XCTUnwrap(image.pngData()).write(to: source)
        let folder = root.appendingPathComponent("regions")
        let first = ScoreRegionEditorModel(source: source, store: ScoreRegionsStore(source: source, folder: folder))
        let second = ScoreRegionEditorModel(source: source, store: ScoreRegionsStore(source: source, folder: folder))
        await first.open()
        await second.open()
        XCTAssertNotNil(first.image)
        XCTAssertNotNil(second.image)
        let a = ScoreRegion(x: 0, y: 0, width: 0.5, height: 0.5)
        let b = ScoreRegion(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        await first.addRegion(a, onPage: 0)
        await second.addRegion(b, onPage: 0)
        XCTAssertTrue(second.hasPendingChange)
        XCTAssertEqual(second.pendingAddedRegion, b)
        XCTAssertTrue(second.regions.isEmpty)
        await second.open()
        XCTAssertTrue(second.hasPendingChange)
        XCTAssertEqual(second.pendingAddedRegion, b)
        await second.retryPendingChange()
        XCTAssertFalse(second.hasPendingChange)
        XCTAssertNil(second.pendingAddedRegion)
        XCTAssertEqual(second.regions, [a, b])
        let saved = try await ScoreRegionsStore(source: source, folder: folder).loadPage(index: 0, rotation: 0)
        XCTAssertEqual(saved, [a, b])
    }

    func testConflictingDeletionCanBeDiscardedWithoutRemovingNewRegions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("score.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in }
        try XCTUnwrap(image.pngData()).write(to: source)
        let folder = root.appendingPathComponent("regions")
        let store = ScoreRegionsStore(source: source, folder: folder)
        let a = ScoreRegion(x: 0, y: 0, width: 0.5, height: 0.5)
        let b = ScoreRegion(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        try await store.savePage(index: 0, rotation: 0, regions: [a])
        let model = ScoreRegionEditorModel(source: source, store: store)
        await model.open()
        try await ScoreRegionsStore(source: source, folder: folder)
            .savePage(index: 0, rotation: 0, regions: [a, b], replacing: [a])
        await model.removeRegion(a.id)
        XCTAssertTrue(model.hasPendingChange)
        await model.discardPendingChange()
        XCTAssertFalse(model.hasPendingChange)
        XCTAssertEqual(model.regions, [a, b])
    }
}
