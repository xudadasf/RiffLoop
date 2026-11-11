import XCTest
@testable import RiffLoop

final class ScoreSequencePlanTests: XCTestCase {
    private let first = ScoreSequenceMaterial(name: "first.pdf", sourceDigest: String(repeating: "a", count: 64))
    private let second = ScoreSequenceMaterial(name: "second.png", sourceDigest: String(repeating: "b", count: 64))

    private func region(_ material: ScoreSequenceMaterial, page: Int) -> ScoreSequenceRegionReference {
        ScoreSequenceRegionReference(material: material, pageIndex: page, rotation: 0, regionID: UUID())
    }

    func testRecognitionSettingsValidateAndOldPlansUseStandardDefaults() throws {
        let a = region(first, page: 0)
        var plan = try ScoreSequencePlan(materials: [first], regions: [a])
        let legacy = try JSONEncoder().encode(plan)
        let restored = try JSONDecoder().decode(ScoreSequencePlan.self, from: legacy)
        try restored.validate()
        XCTAssertNil(restored.recognitionSettings)
        XCTAssertEqual(restored.effectiveSettings, .standard)
        XCTAssertEqual(ScoreRecognitionSettings.standard.tuningText, "E2 A2 D3 G3 B3 E4")
        XCTAssertEqual(ScoreRecognitionSettings.parseTuning("Eb2 A2 D3 G3 Bb3 E4"), [39, 45, 50, 55, 58, 64])
        XCTAssertNil(ScoreRecognitionSettings.parseTuning("E2 A2 D3 G3 B3"))
        XCTAssertNil(ScoreRecognitionSettings.parseTuning("E2 A2 D3 G3 B3 X4"))
        XCTAssertNil(ScoreRecognitionSettings.parseTuning("E2 A2 D3 G3 B3 C10"))

        let settings = ScoreRecognitionSettings(tempo: 123, numerator: 3, denominator: 8,
                                                tuning: [38, 45, 50, 55, 59, 64])
        try plan.setRecognitionSettings(settings)
        let reopened = try JSONDecoder().decode(ScoreSequencePlan.self, from: JSONEncoder().encode(plan))
        try reopened.validate()
        XCTAssertEqual(reopened.effectiveSettings, settings)
        XCTAssertEqual(try reopened.recognitionOrder(available: [a]).settings, settings)
        let invalid = ScoreRecognitionSettings(tempo: 0, numerator: 4, denominator: 3,
                                               tuning: [40, 45, 50, 55, 59, 64])
        XCTAssertThrowsError(try plan.setRecognitionSettings(invalid))
        XCTAssertEqual(plan.effectiveSettings, settings)
    }

    func testAcrossFilesAndPagesNumberAssignmentSwapsBoxesAndGapsFollowThem() throws {
        let a = region(first, page: 0), b = region(second, page: 0), c = region(first, page: 2)
        var plan = try ScoreSequencePlan(materials: [first, second], regions: [a, b, c])
        try plan.setGapAfter(0, number: 3)
        try plan.setGapAfter(2, number: 2)
        try plan.assign(number: 3, toPosition: 0)

        XCTAssertEqual(plan.selectedEntries.map(\.number), [3, 2, 1])
        let order = try plan.recognitionOrder(available: Set([a, b, c]))
        XCTAssertEqual(order.regions, [c, b, a])
        XCTAssertEqual(order.gaps, [0, 2], "The final region never adds a blank bar")
    }

    func testSelectionAndAppendingKeepExistingNumbersAndDefaultGaps() throws {
        let a = region(first, page: 0), b = region(first, page: 1), c = region(second, page: 0)
        var plan = try ScoreSequencePlan(materials: [first, second], regions: [a, b])
        try plan.setGapAfter(3, number: 2)
        try plan.setSelected(false, number: 2)
        try plan.append([c])
        XCTAssertEqual(plan.selectedEntries.map(\.number), [1, 3])
        XCTAssertEqual(try plan.recognitionOrder(available: Set([a, c])).gaps, [1])
        try plan.setSelected(true, number: 2)
        XCTAssertEqual(plan.selectedEntries.map(\.number), [1, 2, 3])
        XCTAssertEqual(try plan.recognitionOrder(available: Set([a, b, c])).gaps, [1, 3])
    }

    func testInvalidAssignmentsAndUnselectedNumbersDoNotChangePlan() throws {
        let a = region(first, page: 0), b = region(first, page: 1)
        var plan = try ScoreSequencePlan(materials: [first], regions: [a, b])
        try plan.setSelected(false, number: 2)
        let before = plan
        XCTAssertThrowsError(try plan.assign(number: 2, toPosition: 0))
        XCTAssertThrowsError(try plan.assign(number: 1, toPosition: 1))
        XCTAssertThrowsError(try plan.setGapAfter(-1, number: 1))
        XCTAssertThrowsError(try plan.setGapAfter(100, number: 1))
        XCTAssertThrowsError(try plan.append([a]))
        XCTAssertEqual(plan, before)
    }

    func testOnlyExplicitMaterialsAreAcceptedAndInvalidAppendIsAtomic() throws {
        let a = region(first, page: 0), b = region(second, page: 0)
        XCTAssertThrowsError(try ScoreSequencePlan(materials: [first], regions: [b]))
        var plan = try ScoreSequencePlan(materials: [first], regions: [a])
        let before = plan
        XCTAssertThrowsError(try plan.append([region(first, page: 1), b]))
        XCTAssertEqual(plan, before)
        XCTAssertThrowsError(try ScoreSequencePlan(materials: [], regions: []))
    }

    func testMissingChangedOrDeletedRegionsAreReportedRatherThanSkipped() throws {
        let a = region(first, page: 0), b = region(second, page: 1)
        var plan = try ScoreSequencePlan(materials: [first, second], regions: [a, b])
        let replaced = ScoreSequenceMaterial(name: second.name, sourceDigest: String(repeating: "c", count: 64))
        let wrong = ScoreSequenceRegionReference(material: replaced, pageIndex: b.pageIndex, rotation: b.rotation, regionID: b.regionID)
        XCTAssertThrowsError(try plan.recognitionOrder(available: Set([a, wrong]))) { error in
            XCTAssertEqual(error as? ScoreSequenceError, .unresolvedRegions([2]))
        }
        try plan.setSelected(false, number: 2)
        XCTAssertEqual(try plan.recognitionOrder(available: Set([a])).regions, [a])
        try plan.setSelected(false, number: 1)
        XCTAssertThrowsError(try plan.recognitionOrder(available: [])) { error in
            XCTAssertEqual(error as? ScoreSequenceError, .noSelectedRegions)
        }
    }

    func testSelectedMaterialWithNoRegionsIsNotSilentlyIgnored() throws {
        let a = region(first, page: 0), b = region(second, page: 0)
        var plan = try ScoreSequencePlan(materials: [first, second], regions: [a])
        XCTAssertThrowsError(try plan.recognitionOrder(available: Set([a]))) { error in
            XCTAssertEqual(error as? ScoreSequenceError, .unreviewedMaterials([second.name]))
        }
        try plan.append([b])
        XCTAssertEqual(try plan.recognitionOrder(available: Set([a, b])).regions, [a, b])
    }

    func testNewRegionsRequireExplicitInclusionButExcludedAndUnrelatedRegionsDoNot() throws {
        let adopted = region(first, page: 0)
        let excluded = region(first, page: 0)
        let newlyDrawn = region(first, page: 1)
        let otherMaterial = ScoreSequenceMaterial(name: "other.pdf", sourceDigest: String(repeating: "c", count: 64))
        let unrelated = region(otherMaterial, page: 0)
        var plan = try ScoreSequencePlan(materials: [first], regions: [adopted, excluded])
        try plan.setSelected(false, number: 2)

        // A box that was deliberately excluded has already been reviewed;
        // boxes belonging to an unrelated material are outside this plan.
        XCTAssertEqual(
            try plan.recognitionOrder(available: Set([adopted, excluded, unrelated])).regions,
            [adopted]
        )
        XCTAssertThrowsError(try plan.recognitionOrder(available: Set([adopted, excluded, newlyDrawn, unrelated]))) { error in
            XCTAssertEqual(error as? ScoreSequenceError, .unregisteredRegions([newlyDrawn]))
        }

        try plan.append([newlyDrawn])
        XCTAssertEqual(
            try plan.recognitionOrder(available: Set([adopted, excluded, newlyDrawn, unrelated])).regions,
            [adopted, newlyDrawn]
        )
    }

    func testSeparateTasksPersistWithoutOverwritingEachOther() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = region(first, page: 0), b = region(second, page: 0)
        var one = try ScoreSequencePlan(materials: [first, second], regions: [a, b])
        try one.assign(number: 2, toPosition: 0)
        try one.setGapAfter(0, number: 2)
        let two = try ScoreSequencePlan(materials: [first], regions: [a])
        let oneID = UUID(), twoID = UUID()
        let firstStore = ScoreSequenceStore(id: oneID, folder: folder)
        let secondStore = ScoreSequenceStore(id: twoID, folder: folder)
        try await firstStore.save(one)
        try await secondStore.save(two)
        let restoredOne = try await ScoreSequenceStore(id: oneID, folder: folder).load()
        let restoredTwo = try await ScoreSequenceStore(id: twoID, folder: folder).load()
        XCTAssertEqual(restoredOne, one)
        XCTAssertEqual(restoredTwo, two)
    }

    func testListIncludesOnlyCanonicalRegularPlanNamesAndReportsCorruptPlanOnLoad() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(try ScoreSequenceStore.listIDs(folder: folder).isEmpty)
        let id = UUID(), corruptID = UUID()
        let a = region(first, page: 0)
        try await ScoreSequenceStore(id: id, folder: folder)
            .save(try ScoreSequencePlan(materials: [first], regions: [a]))
        try Data("broken".utf8).write(to: folder.appendingPathComponent(corruptID.uuidString + ".json"))
        try Data("ignored".utf8).write(to: folder.appendingPathComponent("not-a-plan.json"))
        try Data("ignored".utf8).write(to: folder.appendingPathComponent(UUID().uuidString + ".json.bak"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(UUID().uuidString + ".json"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent(UUID().uuidString + ".json"),
            withDestinationURL: folder.appendingPathComponent(id.uuidString + ".json")
        )
        XCTAssertEqual(Set(try ScoreSequenceStore.listIDs(folder: folder)), Set([id, corruptID]))
        do {
            _ = try await ScoreSequenceStore(id: corruptID, folder: folder).load()
            XCTFail("A malformed plan must not be silently treated as empty")
        } catch ScoreSequenceError.invalidPlan { }
    }

    func testDeleteOnlyTheChosenTaskAndKeepOtherTaskAndMaterial() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let material = root.appendingPathComponent("first.pdf")
        let bytes = Data("original material".utf8)
        try bytes.write(to: material)
        let folder = root.appendingPathComponent("plans")
        let firstID = UUID(), secondID = UUID()
        let box = region(first, page: 0)
        let plan = try ScoreSequencePlan(materials: [first], regions: [box])
        let firstStore = ScoreSequenceStore(id: firstID, folder: folder)
        let secondStore = ScoreSequenceStore(id: secondID, folder: folder)
        try await firstStore.save(plan)
        try await secondStore.save(plan)

        try await firstStore.delete()
        try await firstStore.delete()
        let deleted = try await firstStore.load()
        let retained = try await secondStore.load()
        XCTAssertNil(deleted)
        XCTAssertEqual(retained, plan)
        XCTAssertEqual(try Data(contentsOf: material), bytes)
        XCTAssertEqual(try ScoreSequenceStore.listIDs(folder: folder), [secondID])
    }

    func testDeleteRejectsSymbolicLinkWithoutTouchingItsTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.pdf")
        let bytes = Data("material".utf8)
        try bytes.write(to: original)
        let id = UUID()
        let link = root.appendingPathComponent(id.uuidString + ".json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        do {
            try await ScoreSequenceStore(id: id, folder: root).delete()
            XCTFail("A link is not a plan")
        } catch ScoreSequenceError.invalidPlan { }
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }
}
