import XCTest
@testable import RiffLoop

@MainActor
final class ScoreSequenceEditorModelTests: XCTestCase {
    private func samplePlan(count: Int = 2) throws -> ScoreSequencePlan {
        let material = ScoreSequenceMaterial(name: "sample.pdf", sourceDigest: String(repeating: "a", count: 64))
        let regions = (0..<count).map {
            ScoreSequenceRegionReference(material: material, pageIndex: $0, rotation: 0, regionID: UUID())
        }
        return try ScoreSequencePlan(materials: [material], regions: regions)
    }

    func testSettingsAndGlobalGapSaveTogetherWithoutApply() async throws {
        let plan = try samplePlan(count: 3)
        var saved: ScoreSequencePlan?
        let model = ScoreSequenceEditorModel(plan: plan, isSaved: true) { saved = $0 }
        XCTAssertFalse(model.hasUnsavedChanges)
        model.tempoInput = "120"; model.numeratorInput = "3"; model.denominatorInput = "8"
        model.tuningInput = "D2 A2 D3 G3 B3 E4"; model.uniformGapInput = "2"
        let success = await model.save()
        XCTAssertTrue(success)
        let result = try XCTUnwrap(saved)
        XCTAssertEqual(result.effectiveSettings.tempo, 120)
        XCTAssertEqual(result.effectiveSettings.tuning, [38, 45, 50, 55, 59, 64])
        XCTAssertEqual(result.uniformGapAfter, 2)
        XCTAssertEqual(result.entries.map(\.gapAfter), [2, 2, 2])
        XCTAssertEqual(try result.recognitionOrder(available: Set(result.entries.map(\.reference))).gaps, [2, 2])
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertNil(model.message, "A normal save must not open a modal")
        let reopened = try JSONDecoder().decode(ScoreSequencePlan.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(reopened, result)
    }

    func testPendingSettingsSurviveReorderAndSelectionWithoutBlocking() async throws {
        let plan = try samplePlan(count: 3)
        var saved: ScoreSequencePlan?
        let model = ScoreSequenceEditorModel(plan: plan, isSaved: true) { saved = $0 }
        model.tempoInput = "70"; model.uniformGapInput = "0"
        model.move(number: 2, offset: -1)
        XCTAssertEqual(model.plan.selectedEntries.map(\.number), [2, 1, 3])
        model.select(false, number: 1)
        XCTAssertEqual(model.plan.selectedEntries.map(\.number), [2, 3])
        XCTAssertEqual(model.tempoInput, "70")
        XCTAssertEqual(model.uniformGapInput, "0")
        XCTAssertNil(model.message)
        await model.save()
        XCTAssertEqual(saved?.effectiveSettings.tempo, 70)
        XCTAssertEqual(saved?.entries.map(\.gapAfter), [0, 0, 0])
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testInvalidFieldsNeverPartiallySaveAndCorrectingThemNeedsNoRestore() async throws {
        let plan = try samplePlan()
        var writes: [ScoreSequencePlan] = []
        let model = ScoreSequenceEditorModel(plan: plan, isSaved: true) { writes.append($0) }
        model.tempoInput = "70"; model.uniformGapInput = "100"
        var success = await model.save()
        XCTAssertFalse(success)
        XCTAssertEqual(model.plan, plan)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertTrue(model.message?.contains("0 到 99") == true)
        model.uniformGapInput = "0"; model.tuningInput = "invalid"
        success = await model.save()
        XCTAssertFalse(success)
        XCTAssertTrue(writes.isEmpty)
        model.tuningInput = plan.effectiveSettings.tuningText
        success = await model.save()
        XCTAssertTrue(success)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes[0].effectiveSettings.tempo, 70)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testSaveFailureKeepsFormAndRetrySavesIt() async throws {
        struct SaveFailure: Error { }
        var fail = true
        var saved: ScoreSequencePlan?
        let model = ScoreSequenceEditorModel(plan: try samplePlan(), isSaved: true) {
            if fail { throw SaveFailure() }; saved = $0
        }
        model.tempoInput = "70"; model.uniformGapInput = "3"
        let failed = await model.save()
        XCTAssertFalse(failed)
        XCTAssertEqual(model.tempoInput, "70"); XCTAssertEqual(model.uniformGapInput, "3")
        XCTAssertTrue(model.hasUnsavedChanges); XCTAssertFalse(model.isSaving)
        fail = false
        let success = await model.save()
        XCTAssertTrue(success); XCTAssertEqual(saved?.uniformGapAfter, 3)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testAppendPreservesTypedSettingsAndCannotDuplicate() async throws {
        let plan = try samplePlan()
        let material = try XCTUnwrap(plan.materials.first)
        let added = ScoreSequenceRegionReference(material: material, pageIndex: 3, rotation: 0, regionID: UUID())
        let model = ScoreSequenceEditorModel(plan: plan, isSaved: true, newRegions: [added, added]) { _ in }
        model.tempoInput = "70"; model.uniformGapInput = "2"
        model.appendNewRegions()
        model.appendNewRegions()
        XCTAssertEqual(model.plan.entries.count, 3)
        XCTAssertEqual(model.tempoInput, "70")
        XCTAssertEqual(model.uniformGapInput, "2")
        XCTAssertTrue(model.newRegions.isEmpty)
        await model.save()
        XCTAssertEqual(model.plan.entries.map(\.gapAfter), [2, 2, 2])
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testLegacyMixedGapsRemainUntilUserChoosesUniformValue() async throws {
        var plan = try samplePlan(count: 3)
        try plan.setGapAfter(0, number: 1); try plan.setGapAfter(3, number: 2)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        json.removeValue(forKey: "uniformGapAfter")
        let legacy = try JSONDecoder().decode(ScoreSequencePlan.self, from: JSONSerialization.data(withJSONObject: json))
        let model = ScoreSequenceEditorModel(plan: legacy, isSaved: true) { _ in }
        XCTAssertTrue(model.preservesLegacyGaps)
        XCTAssertFalse(model.hasUnsavedChanges)
        model.tempoInput = "70"
        await model.save()
        XCTAssertEqual(model.plan.entries.map(\.gapAfter), [0, 3, 1])
        model.uniformGapInput = "2"
        await model.save()
        XCTAssertEqual(model.plan.entries.map(\.gapAfter), [2, 2, 2])
        XCTAssertEqual(model.plan.uniformGapAfter, 2)
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
