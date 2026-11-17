import XCTest
@testable import RiffLoop

@MainActor
final class ScoreSequenceInteractionRegressionTests: XCTestCase {
    func testSaveCommitsValidFormWithoutSeparateApplyStep() async throws {
        let material = ScoreSequenceMaterial(name: "form.png", sourceDigest: String(repeating: "a", count: 64))
        let reference = ScoreSequenceRegionReference(material: material, pageIndex: 0, rotation: 0, regionID: UUID())
        let plan = try ScoreSequencePlan(materials: [material], regions: [reference])
        var saved: ScoreSequencePlan?
        let model = ScoreSequenceEditorModel(plan: plan, isSaved: true) { saved = $0 }
        model.tempoInput = "70"
        model.numeratorInput = "6"
        model.denominatorInput = "8"
        await model.save()
        XCTAssertEqual(saved?.effectiveSettings.tempo, 70, "Save must consume valid pending inputs")
        XCTAssertEqual(saved?.effectiveSettings.numerator, 6)
        XCTAssertEqual(saved?.effectiveSettings.denominator, 8)
        XCTAssertFalse(model.hasUnsavedChanges)
    }
}
