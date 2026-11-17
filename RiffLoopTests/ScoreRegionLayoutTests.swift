import UIKit
import XCTest
@testable import RiffLoop

@MainActor
final class ScoreRegionLayoutTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var folder: URL!
    private var store: ScoreRegionsStore!
    private let a = ScoreRegion(x: 0.1, y: 0.1, width: 0.3, height: 0.2)
    private let b = ScoreRegion(x: 0.5, y: 0.5, width: 0.3, height: 0.2)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("synthetic.png")
        folder = root.appendingPathComponent("regions")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { _ in }
        try XCTUnwrap(image.pngData()).write(to: source)
        store = ScoreRegionsStore(source: source, folder: folder)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testLegacyOrderAndGapsSurviveWithoutRewritingGeometry() async throws {
        try await store.savePage(index: 1, rotation: 0, regions: [b])
        try await store.savePage(index: 0, rotation: 0, regions: [a])
        let metadata = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        let bytes = try Data(contentsOf: metadata)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(json["layout"], "The fixture is the actual legacy shape with no layout field")
        let saved = try await store.snapshot()
        XCTAssertEqual(saved.pages.map(\.regions), [[a], [b]])
        XCTAssertEqual(saved.layout.map(\.location.regionID), [a.id, b.id])
        XCTAssertEqual(saved.layout.map(\.gapAfter), [1, 1])
        XCTAssertEqual(try Data(contentsOf: metadata), bytes)
    }

    func testCrossPageNumberAndGapDriveRecognitionAndSurviveReload() async throws {
        // Identical UUIDs on distinct pages are valid in old documents.
        try await store.savePage(index: 0, rotation: 0, regions: [a, b])
        try await store.savePage(index: 2, rotation: 90, regions: [a])
        let before = try await store.snapshot()
        let last = try XCTUnwrap(before.layout.last?.location)
        try await store.saveLayout(before.changing(last, number: 1, gapAfter: 0), replacing: before)
        let fresh = try await ScoreRegionsStore(source: source, folder: folder).snapshot()
        XCTAssertEqual(fresh.layout.map(\.location.pageIndex), [2, 0, 0])
        XCTAssertEqual(fresh.layout.map(\.gapAfter), [0, 1, 1])
        XCTAssertEqual(fresh.pages, before.pages)
        let plan = try await ScoreSequenceFactory.makePlan(from: [source], regionsFolder: folder)
        XCTAssertEqual(plan.entries.map(\.number), [1, 2, 3])
        let order = try plan.recognitionOrder(available: Set(plan.entries.map(\.reference)))
        XCTAssertEqual(order.regions.map(\.pageIndex), [2, 0, 0])
        XCTAssertEqual(order.gaps, [0, 1], "Final box does not insert a trailing gap")
    }

    func testDeletingAndAddingPreserveOtherBoxesSettings() async throws {
        try await store.savePage(index: 0, rotation: 0, regions: [a, b])
        var snapshot = try await store.snapshot()
        snapshot = try await store.saveLayout(snapshot.changing(snapshot.layout[1].location, number: 1, gapAfter: 3), replacing: snapshot)
        let c = ScoreRegion(x: 0, y: 0, width: 0.2, height: 0.2)
        try await store.savePage(index: 0, rotation: 0, regions: [b, c], replacing: [a, b])
        let saved = try await store.snapshot()
        XCTAssertEqual(saved.layout.map(\.location.regionID), [b.id, c.id])
        XCTAssertEqual(saved.layout.map(\.gapAfter), [3, 1])
        XCTAssertEqual(saved.pages[0].regions, [b, c])
    }

    func testSavedPlanKeepsItsOwnSettingsWhenNewPlanUsesEditedBoxes() async throws {
        try await store.savePage(index: 0, rotation: 0, regions: [a, b])
        var original = try await ScoreSequenceFactory.makePlan(from: [source], regionsFolder: folder)
        try original.setRecognitionSettings(ScoreRecognitionSettings(tempo: 70, numerator: 3, denominator: 4,
                                                                     tuning: [40, 45, 50, 55, 59, 64]))
        try original.setGapAfter(7, number: 1)
        let planStore = ScoreSequenceStore(id: UUID(), folder: root.appendingPathComponent("plans"))
        try await planStore.save(original)
        let snapshot = try await store.snapshot()
        try await store.saveLayout(snapshot.changing(snapshot.layout[1].location, number: 1, gapAfter: 0), replacing: snapshot)
        let newPlan = try await ScoreSequenceFactory.makePlan(from: [source], regionsFolder: folder)
        XCTAssertEqual(newPlan.entries.map(\.reference.regionID), [b.id, a.id])
        XCTAssertEqual(newPlan.entries.map(\.gapAfter), [0, 1])
        let stored = try await planStore.load()
        XCTAssertEqual(stored, original)
    }

    func testLayoutConflictAndInvalidLayoutsDoNotOverwriteStoredData() async throws {
        try await store.savePage(index: 0, rotation: 0, regions: [a, b])
        let stale = try await store.snapshot()
        let latest = try await store.saveLayout(stale.changing(stale.layout[0].location, number: 1, gapAfter: 4), replacing: stale)
        do {
            try await store.saveLayout(stale.layout, replacing: stale)
            XCTFail("Stale settings must not overwrite another editor")
        } catch ScoreRegionsError.conflict { }
        var invalid = latest.layout
        invalid[0].gapAfter = -1
        for layout in [Array(latest.layout.dropLast()), [latest.layout[0], latest.layout[0]], invalid] {
            do {
                try await store.saveLayout(layout, replacing: latest)
                XCTFail("Incomplete, duplicate or invalid settings must be rejected")
            } catch ScoreRegionsError.invalidPage { }
        }
        let saved = try await store.snapshot()
        XCTAssertEqual(saved, latest)
    }

    func testSelectionKeepsIdentityWhenRenumberingAndDeletesOnlySelectedBox() async throws {
        try await store.savePage(index: 0, rotation: 0, regions: [a, b])
        let model = ScoreRegionEditorModel(source: source, store: store)
        await model.open()
        XCTAssertNil(model.selectedID)
        model.select(b.id)
        model.numberInput = "1"
        model.gapInput = "0"
        await model.applyInputs()
        XCTAssertEqual(model.selectedID, b.id)
        XCTAssertEqual(model.number(for: b.id), 1)
        XCTAssertEqual(model.number(for: a.id), 2)
        XCTAssertEqual(model.gap(for: b.id), 0)
        let prepared = await model.makePlan()
        let plan = try XCTUnwrap(prepared)
        XCTAssertEqual(plan.entries.map(\.reference.regionID), [b.id, a.id])
        XCTAssertEqual(plan.entries.map(\.gapAfter), [0, 1])
        await model.removeRegion(b.id)
        XCTAssertEqual(model.regions, [a])
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(model.number(for: a.id), 1)
        let reopened = ScoreRegionEditorModel(source: source, store: ScoreRegionsStore(source: source, folder: folder))
        await reopened.open()
        XCTAssertEqual(reopened.regions, [a])
    }

    func testUnappliedOrInvalidInputCannotSilentlyDisappear() async throws {
        try await store.savePage(index: 0, rotation: 0, regions: [a, b])
        let model = ScoreRegionEditorModel(source: source, store: store)
        await model.open()
        model.select(a.id)
        model.gapInput = "-1"
        model.select(b.id)
        XCTAssertEqual(model.selectedID, a.id)
        await model.removeRegion(a.id)
        XCTAssertEqual(model.regions, [a, b])
        await model.applyInputs()
        XCTAssertTrue(model.hasUnappliedInputs)
        XCTAssertFalse(model.hasPendingChange)
        let plan = await model.makePlan()
        XCTAssertNil(plan)
        model.resetInputs()
        XCTAssertEqual(model.gapInput, "1")
        model.select(b.id)
        XCTAssertEqual(model.selectedID, b.id)
    }

    func testConflictingLayoutCanRetryWithoutLosingExternalBoxesOrGaps() async throws {
        try await store.savePage(index: 0, rotation: 0, regions: [a, b])
        let model = ScoreRegionEditorModel(source: source, store: store)
        await model.open()
        model.select(b.id)
        model.numberInput = "1"
        model.gapInput = "0"
        let c = ScoreRegion(x: 0, y: 0, width: 0.2, height: 0.2)
        let external = ScoreRegionsStore(source: source, folder: folder)
        try await external.savePage(index: 0, rotation: 0, regions: [a, b, c])
        let latest = try await external.snapshot()
        try await external.saveLayout(latest.changing(latest.layout[0].location, number: 1, gapAfter: 5), replacing: latest)
        await model.applyInputs()
        XCTAssertTrue(model.hasPendingChange)
        XCTAssertEqual(model.numberInput, "1")
        await model.retryPendingChange()
        XCTAssertFalse(model.hasPendingChange)
        XCTAssertEqual(model.snapshot?.layout.map(\.location.regionID), [b.id, a.id, c.id])
        XCTAssertEqual(model.snapshot?.layout.map(\.gapAfter), [0, 5, 1])
    }

    func testPageChangeClearsSelectionAndPendingInputCanBeDiscardedAfterConflict() async throws {
        try await store.savePage(index: 0, rotation: 0, regions: [a])
        try await store.savePage(index: 1, rotation: 0, regions: [b])
        let model = ScoreRegionEditorModel(source: source, store: store) { source, _ in
            let rendered = ScorePageRenderer.render(source: source, index: 0)
            return ScorePagePreview(image: rendered.image, pageCount: 2, orientation: 0, error: nil)
        }
        await model.open()
        model.select(a.id)
        await model.changePage(1)
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(model.regions, [b])
        model.select(b.id)
        model.gapInput = "3"
        await model.changePage(0)
        XCTAssertEqual(model.pageIndex, 1)
        try await store.savePage(index: 1, rotation: 0, regions: [])
        await model.applyInputs()
        XCTAssertTrue(model.hasPendingChange)
        await model.discardPendingChange()
        XCTAssertFalse(model.hasPendingChange)
        XCTAssertNil(model.selectedID)
        XCTAssertTrue(model.regions.isEmpty)
        XCTAssertEqual(model.numberInput, "")
    }
}
