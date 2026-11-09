import XCTest
@testable import RiffLoop

@MainActor
final class ScoreSequenceEditorModelTests: XCTestCase {
    private func samplePlan() throws -> ScoreSequencePlan {
        let material = ScoreSequenceMaterial(name: "sample.pdf", sourceDigest: String(repeating: "a", count: 64))
        let regions = (0..<2).map { page in
            ScoreSequenceRegionReference(material: material, pageIndex: page, rotation: 0, regionID: UUID())
        }
        return try ScoreSequencePlan(materials: [material], regions: regions)
    }

    func testPendingInputsCannotBeSilentlyDroppedBySaveOrSelection() async throws {
        let plan = try samplePlan()
        var saved: [ScoreSequencePlan] = []
        let model = ScoreSequenceEditorModel(plan: plan, isSaved: true) { saved.append($0) }
        XCTAssertFalse(model.hasUnsavedChanges)
        model.numberInputs[0] = "2"
        XCTAssertTrue(model.hasUnsavedChanges)
        await model.save()
        XCTAssertTrue(saved.isEmpty)
        model.select(false, number: 1)
        XCTAssertEqual(model.plan, plan)
        model.assign(position: 0)
        XCTAssertEqual(model.plan.selectedEntries.map(\.number), [2, 1])
        await model.save()
        XCTAssertEqual(saved.last?.selectedEntries.map(\.number), [2, 1])
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testInvalidGapPreservesPlanAndSaveFailureKeepsChanges() async throws {
        let plan = try samplePlan()
        struct SaveFailure: Error { }
        let model = ScoreSequenceEditorModel(plan: plan, isSaved: false) { _ in throw SaveFailure() }
        model.gapInputs[1] = "100"
        model.setGap(number: 1)
        XCTAssertEqual(model.plan, plan)
        XCTAssertTrue(model.hasUnsavedChanges)
        model.gapInputs[1] = "0"
        model.setGap(number: 1)
        XCTAssertEqual(model.plan.selectedEntries[0].gapAfter, 0)
        await model.save()
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertNotNil(model.message)
    }

    func testAppendNewRegionsPreservesExistingPlanAndRequiresSave() async throws {
        var plan = try samplePlan()
        try plan.assign(number: 2, toPosition: 0)
        try plan.setGapAfter(0, number: 2)
        let original = plan.entries
        let material = try XCTUnwrap(plan.materials.first)
        let firstNew = ScoreSequenceRegionReference(material: material, pageIndex: 2, rotation: 0, regionID: UUID())
        let secondNew = ScoreSequenceRegionReference(material: material, pageIndex: 3, rotation: 0, regionID: UUID())
        var saved: ScoreSequencePlan?
        let offered = [original[0].reference, firstNew, firstNew, secondNew]
        let model = ScoreSequenceEditorModel(plan: plan, isSaved: true, newRegions: offered) { saved = $0 }

        XCTAssertEqual(model.newRegions, [firstNew, secondNew])
        model.numberInputs[0] = "1"
        model.appendNewRegions()
        XCTAssertEqual(model.plan.entries, original, "Pending input must not be discarded by appending")
        XCTAssertEqual(model.newRegions.count, 2)
        model.numberInputs[0] = String(original[0].number)

        model.appendNewRegions()
        XCTAssertEqual(Array(model.plan.entries.prefix(original.count)), original)
        XCTAssertEqual(model.plan.entries.map(\.number), [2, 1, 3, 4])
        XCTAssertEqual(model.plan.entries.suffix(2).map(\.reference), [firstNew, secondNew])
        XCTAssertEqual(model.plan.entries.suffix(2).map(\.gapAfter), [1, 1])
        XCTAssertTrue(model.newRegions.isEmpty)
        XCTAssertTrue(model.hasUnsavedChanges)
        model.appendNewRegions()
        XCTAssertEqual(model.plan.entries.count, 4, "Repeated taps cannot duplicate regions")
        await model.save()
        let savedPlan = try XCTUnwrap(saved)
        XCTAssertFalse(model.hasUnsavedChanges)
        let reopened = ScoreSequenceEditorModel(plan: savedPlan, isSaved: true, newRegions: offered) { _ in }
        XCTAssertTrue(reopened.newRegions.isEmpty, "Already appended references must not be offered again")
    }

    func testInvalidNewRegionDoesNotPartiallyAppend() throws {
        let plan = try samplePlan()
        let material = try XCTUnwrap(plan.materials.first)
        let valid = ScoreSequenceRegionReference(material: material, pageIndex: 2, rotation: 0, regionID: UUID())
        let other = ScoreSequenceMaterial(name: "other.pdf", sourceDigest: String(repeating: "b", count: 64))
        let invalid = ScoreSequenceRegionReference(material: other, pageIndex: 0, rotation: 0, regionID: UUID())
        let model = ScoreSequenceEditorModel(plan: plan, isSaved: true, newRegions: [valid, invalid]) { _ in }
        model.appendNewRegions()
        XCTAssertEqual(model.plan, plan)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(model.newRegions, [valid, invalid])
        XCTAssertNotNil(model.message)
    }
}
