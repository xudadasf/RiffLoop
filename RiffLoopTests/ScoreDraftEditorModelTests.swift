import XCTest
@testable import RiffLoop

@MainActor
final class ScoreDraftEditorModelTests: XCTestCase {
    private func draft() -> ScoreDraft {
        ScoreDraft(title: "练习", tempo: 100, bars: [[.note(string: 1, fret: 0, duration: 4)]])
    }

    func testIncompleteDraftCanBeSavedButNotExportedAndInputsArePreserved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScoreDraftStore(folder: root)
        let model = try ScoreDraftEditorModel(newDraft: draft(), store: store)
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertEqual(model.closeDecision, .confirmDiscard)
        XCTAssertEqual(model.exportAvailability, .unsaved)

        model.setMetadataInput(title: "更名", tempo: "无效")
        XCTAssertFalse(model.applyMetadata())
        await model.save()
        XCTAssertNil(model.persistedID)
        XCTAssertEqual(model.titleInput, "更名")
        XCTAssertEqual(model.tempoInput, "无效")
        XCTAssertEqual(model.editor.draft, draft())

        model.setMetadataInput(title: "更名", tempo: "120")
        XCTAssertTrue(model.applyMetadata())
        await model.save()
        let id = try XCTUnwrap(model.persistedID)
        let saved = try await store.load(id)
        XCTAssertEqual(saved.title, "更名")
        XCTAssertEqual(saved.tempo, 120)
        XCTAssertFalse(saved.isComplete)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(model.closeDecision, .close)
        XCTAssertEqual(model.exportAvailability, .incomplete)
        do {
            _ = try await model.publishPractice { _ in root.appendingPathComponent("unexpected.gp") }
            XCTFail("Incomplete bars cannot be published")
        } catch ScoreDraftPracticeStateError.notReady { }

        model.setMetadataInput(title: "未应用", tempo: "120")
        XCTAssertEqual(model.closeDecision, .confirmDiscard)
        XCTAssertEqual(model.exportAvailability, .unsaved)
        model.restoreMetadataInput()
        XCTAssertEqual(model.closeDecision, .close)
    }

    func testConflictingSaveKeepsCurrentEditsAndTheOtherSavedDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScoreDraftStore(folder: root)
        let original = draft()
        let id = try await store.create(original)
        let model = try await ScoreDraftEditorModel.open(id: id, store: store)
        XCTAssertTrue(model.replaceEvent(bar: 0, index: 0, with: .note(string: 1, fret: 5, duration: 4)))
        var other = original
        other.bars[0][0] = .note(string: 1, fret: 7, duration: 4)
        try await store.update(other, id: id, replacing: original)

        await model.save()
        XCTAssertEqual(model.editor.draft.bars[0][0], .note(string: 1, fret: 5, duration: 4))
        let retained = try await store.load(id)
        XCTAssertEqual(retained, other)
        XCTAssertEqual(model.closeDecision, .confirmDiscard)
        XCTAssertEqual(model.exportAvailability, .conflict)
        XCTAssertNotNil(model.message)
        await model.saveAsNewCopy()
        let copyID = try XCTUnwrap(model.persistedID)
        XCTAssertNotEqual(copyID, id)
        let copy = try await store.load(copyID)
        XCTAssertEqual(copy.bars[0][0], .note(string: 1, fret: 5, duration: 4))
        let originalAfterCopy = try await store.load(id)
        XCTAssertEqual(originalAfterCopy, other)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testSavingFreezesEditsAndPreventsLeavingUntilComplete() async throws {
        let started = expectation(description: "save started")
        var release: CheckedContinuation<Void, Never>?
        defer { release?.resume() }
        var written: ScoreDraft?
        let model = try ScoreDraftEditorModel(newDraft: draft()) { _, snapshot, _ in
            await withCheckedContinuation { continuation in
                release = continuation
                started.fulfill()
            }
            written = snapshot
        }
        let saving = Task { await model.save() }
        await fulfillment(of: [started], timeout: 10)
        XCTAssertTrue(model.isSaving)
        XCTAssertEqual(model.closeDecision, .waitForOperation)
        XCTAssertEqual(model.exportAvailability, .busy)
        XCTAssertFalse(model.replaceEvent(bar: 0, index: 0, with: .note(string: 1, fret: 5, duration: 4)))
        model.setMetadataInput(title: "不应改动", tempo: "120")
        XCTAssertEqual(model.titleInput, "练习")
        XCTAssertEqual(model.tempoInput, "100")
        await model.save()
        let continuation = try XCTUnwrap(release)
        release = nil
        continuation.resume()
        await saving.value
        XCTAssertEqual(written, draft())
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(model.closeDecision, .close)
    }

    func testCompleteButOversizedDraftIsNotOfferedForExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fullBar = Array(repeating: ScoreDraftEvent.rest(duration: 64), count: 64)
        let large = ScoreDraft(title: "大草稿", tempo: 100, bars: Array(repeating: fullBar, count: 9))
        XCTAssertTrue(large.isComplete)
        let model = try ScoreDraftEditorModel(newDraft: large, store: ScoreDraftStore(folder: root))
        await model.save()
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(model.exportAvailability, .tooLarge)
        XCTAssertEqual(model.closeDecision, .close)
    }

    func testBarLimitAllowsSavingButBlocksOversizedExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScoreDraftStore(folder: root)
        let boundary = ScoreDraft(title: "上限", tempo: 100,
                                  bars: Array(repeating: [.rest(duration: 1)], count: 64))
        let allowed = try ScoreDraftEditorModel(newDraft: boundary, store: store)
        await allowed.save()
        XCTAssertEqual(allowed.exportAvailability, .ready)
        let oversized = ScoreDraft(title: "超限", tempo: 100,
                                   bars: Array(repeating: [.rest(duration: 1)], count: 65))
        let blocked = try ScoreDraftEditorModel(newDraft: oversized, store: store)
        await blocked.save()
        let id = try XCTUnwrap(blocked.persistedID)
        let saved = try await store.load(id)
        XCTAssertEqual(saved, oversized)
        XCTAssertEqual(blocked.exportAvailability, .tooLarge)
    }

    func testSaveFailureKeepsEditsForRetry() async throws {
        struct Failure: Error { }
        let model = try ScoreDraftEditorModel(newDraft: draft()) { _, _, _ in throw Failure() }
        XCTAssertTrue(model.replaceEvent(bar: 0, index: 0, with: .note(string: 1, fret: 8, duration: 4)))
        await model.save()
        XCTAssertNil(model.persistedID)
        XCTAssertEqual(model.editor.draft.bars[0][0], .note(string: 1, fret: 8, duration: 4))
        XCTAssertEqual(model.closeDecision, .confirmDiscard)
        XCTAssertNotNil(model.message)
    }

    func testPracticeRequiresSavedMatchingSnapshotAndNoPendingInputs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScoreDraftStore(folder: root)
        let original = ScoreDraft(title: "练习", tempo: 100, bars: [[.note(string: 1, fret: 0, duration: 1)]])
        let id = try await store.create(original)
        let model = try await ScoreDraftEditorModel.open(id: id, store: store)
        let output = root.appendingPathComponent("practice.gp")
        var received: ScoreDraft?
        model.setMetadataInput(title: "未应用", tempo: "100")
        do {
            _ = try await model.publishPractice { snapshot in received = snapshot; return output }
            XCTFail("Pending input must block practice")
        } catch ScoreDraftPracticeStateError.notReady { }
        XCTAssertNil(received)
        model.restoreMetadataInput()
        model.setMetadataInput(title: "练习", tempo: "120")
        do {
            _ = try await model.publishPractice { snapshot in received = snapshot; return output }
            XCTFail("Unapplied BPM must block practice")
        } catch ScoreDraftPracticeStateError.notReady { }
        XCTAssertNil(received)
        model.restoreMetadataInput()
        XCTAssertTrue(model.replaceEvent(bar: 0, index: 0, with: .note(string: 1, fret: 3, duration: 1)))
        do {
            _ = try await model.publishPractice { snapshot in received = snapshot; return output }
            XCTFail("Unsaved notes must block practice")
        } catch ScoreDraftPracticeStateError.notReady { }
        XCTAssertNil(received)
        XCTAssertTrue(model.replaceEvent(bar: 0, index: 0, with: .note(string: 1, fret: 0, duration: 1)))

        var other = original
        other.bars[0][0] = .note(string: 1, fret: 5, duration: 1)
        try await store.update(other, id: id, replacing: original)
        do {
            _ = try await model.publishPractice { snapshot in received = snapshot; return output }
            XCTFail("A changed saved version must not be published")
        } catch ScoreDraftPracticeStateError.sourceChanged { }
        XCTAssertNil(received)
        XCTAssertEqual(model.editor.draft, original)
        XCTAssertEqual(model.exportAvailability, .conflict)

        await model.saveAsNewCopy()
        XCTAssertEqual(model.exportAvailability, .ready)
        let result = try await model.publishPractice { snapshot in received = snapshot; return output }
        XCTAssertEqual(result, output)
        XCTAssertEqual(received, original)
    }

    func testPracticePublicationFreezesEditsAndLeaving() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScoreDraftStore(folder: root)
        let complete = ScoreDraft(title: "练习", tempo: 100, bars: [[.rest(duration: 1)]])
        let model = try ScoreDraftEditorModel(newDraft: complete, store: store)
        await model.save()
        let started = expectation(description: "publication started")
        var release: CheckedContinuation<Void, Never>?
        defer { release?.resume() }
        let output = root.appendingPathComponent("practice.gp")
        var publishedSnapshot: ScoreDraft?
        let publishing = Task {
            try await model.publishPractice { snapshot in
                publishedSnapshot = snapshot
                await withCheckedContinuation { continuation in
                    release = continuation
                    started.fulfill()
                }
                return output
            }
        }
        await fulfillment(of: [started], timeout: 10)
        XCTAssertTrue(model.isPublishing)
        XCTAssertEqual(model.closeDecision, .waitForOperation)
        XCTAssertEqual(model.exportAvailability, .busy)
        XCTAssertFalse(model.replaceEvent(bar: 0, index: 0, with: .note(string: 1, fret: 1, duration: 1)))
        model.setMetadataInput(title: "不应改动", tempo: "120")
        XCTAssertEqual(model.titleInput, "练习")
        let id = try XCTUnwrap(model.persistedID)
        var otherWindow = complete
        otherWindow.title = "另一窗口的更新"
        try await store.update(otherWindow, id: id, replacing: complete)
        let continuation = try XCTUnwrap(release)
        release = nil
        continuation.resume()
        let result = try await publishing.value
        XCTAssertEqual(result, output)
        XCTAssertEqual(publishedSnapshot, complete)
        let latest = try await store.load(id)
        XCTAssertEqual(latest, otherWindow)
        XCTAssertEqual(model.closeDecision, .close)
    }
}
