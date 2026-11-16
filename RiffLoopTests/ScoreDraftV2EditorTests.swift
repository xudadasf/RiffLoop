import XCTest
@testable import RiffLoop

final class ScoreDraftV2EditorTests: XCTestCase {
    func testFretsKeepStringOrderAndDistinguishOpenStringFromRest() throws {
        var input = ScoreDraftBeatInput()
        XCTAssertTrue(try input.beat().notes.isEmpty)
        input.frets = ["0", "1", "", "", "", " 3 "]
        input.dotted = true
        let chord = try input.beat()
        XCTAssertEqual(chord.notes, [.init(string: 1, fret: 0), .init(string: 2, fret: 1), .init(string: 6, fret: 3)])
        XCTAssertEqual(chord.dots, 1)
        XCTAssertEqual(try ScoreDraftBeatInput(chord).beat(), chord)
        for invalid in ["-1", "37", "1.5", "abc"] {
            input.frets[0] = invalid
            XCTAssertThrowsError(try input.beat(), invalid)
        }
    }

    func testRhythmEditsReportActualCapacityWithoutPaddingOrTruncation() throws {
        var editor = try ScoreDraftV2Editor(draft: ScoreDraftV2(title: "练习", tempo: 100,
            bars: [[.beat(.init(duration: 1))]]))
        let chord = ScoreDraftV2Entry.beat(.init(duration: 4, dots: 1,
            notes: [.init(string: 1, fret: 12), .init(string: 2, fret: 13)]))
        try editor.replaceEvent(bar: 0, index: 0, with: chord)
        XCTAssertEqual(editor.draft.barTimings, [.incomplete(remaining: 2400)])
        let triplet = ScoreDraftV2Entry.triplet(.init(beats: [
            .init(duration: 8, notes: [.init(string: 6, fret: 3)]),
            .init(duration: 8), .init(duration: 8, notes: [.init(string: 1, fret: 15)])]))
        try editor.insertEvent(bar: 0, at: 1, event: triplet)
        try editor.insertEvent(bar: 0, at: 2, event: .beat(.init(duration: 4, dots: 1)))
        XCTAssertEqual(editor.draft.barTimings, [.complete])
        XCTAssertTrue(editor.draft.canExport)
        try editor.insertEvent(bar: 0, at: 3, event: .beat(.init(duration: 8)))
        XCTAssertEqual(editor.draft.barTimings, [.overflow(extra: 480)])
        XCTAssertEqual(editor.draft.bars[0].count, 4)
        XCTAssertFalse(editor.draft.canExport)
        try editor.removeEvent(bar: 0, index: 3)
        try editor.insertBlankBar(at: 1)
        XCTAssertEqual(editor.draft.barTimings, [.complete, .complete])
        try editor.removeBar(at: 0)
        XCTAssertEqual(editor.draft.bars, [[.beat(.init(duration: 1))]])
    }

    func testRejectedEditsAreAtomicIncludingTripletAndChordLimits() throws {
        let original = ScoreDraftV2(title: "保留", tempo: 100, bars: [[.beat(.init(duration: 1))]])
        var editor = try ScoreDraftV2Editor(draft: original)
        let duplicate = ScoreDraftV2Entry.beat(.init(duration: 4,
            notes: [.init(string: 1, fret: 1), .init(string: 1, fret: 2)]))
        XCTAssertThrowsError(try editor.replaceEvent(bar: 0, index: 0, with: duplicate))
        XCTAssertThrowsError(try editor.insertEvent(bar: 0, at: 1, event:
            .triplet(.init(beats: [.init(duration: 8), .init(duration: 16), .init(duration: 8)]))))
        XCTAssertThrowsError(try editor.removeBar(at: 0))
        XCTAssertThrowsError(try editor.removeEvent(bar: 0, index: 0))
        XCTAssertThrowsError(try editor.insertBlankBar(at: -1))
        XCTAssertThrowsError(try editor.setMetadata(title: "无效", tempo: 0))
        XCTAssertEqual(editor.draft, original)
        let full = ScoreDraftV2(title: "容量", tempo: 100,
            bars: [Array(repeating: .beat(.init(duration: 64)), count: 126)])
        var fullEditor = try ScoreDraftV2Editor(draft: full)
        XCTAssertThrowsError(try fullEditor.insertEvent(bar: 0, at: 126, event:
            .triplet(.init(beats: Array(repeating: .init(duration: 64), count: 3)))))
        XCTAssertEqual(fullEditor.draft, full)
    }
}

@MainActor
final class ScoreDraftV2EditorModelTests: XCTestCase {
    private func complete() -> ScoreDraftV2 {
        ScoreDraftV2(title: "练习", tempo: 100, bars: [[.beat(.init(duration: 1))]])
    }

    func testPendingInputIncompleteRhythmAndOversizeRemainRecoverable() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ScoreDraftV2Store(folder: folder)
        let model = try ScoreDraftV2EditorModel(newDraft: complete(), store: store)
        model.setMetadataInput(title: "保留输入", tempo: "oops")
        XCTAssertFalse(model.applyMetadata())
        await model.save()
        XCTAssertNil(model.persistedID)
        XCTAssertEqual(model.closeDecision, .confirmDiscard)
        model.restoreMetadataInput()
        XCTAssertTrue(model.replaceEvent(bar: 0, index: 0, with: .beat(.init(duration: 4, dots: 1))))
        await model.save()
        XCTAssertEqual(model.exportAvailability, .incomplete)
        let id = try XCTUnwrap(model.persistedID)
        let reopened = try await ScoreDraftV2EditorModel.open(id: id, store: store)
        XCTAssertEqual(reopened.editor.draft, model.editor.draft)
        XCTAssertEqual(reopened.closeDecision, .close)
        let large = ScoreDraftV2(title: "完整长谱", tempo: 100,
            bars: Array(repeating: [.beat(.init(duration: 1))], count: 65))
        let oversized = try ScoreDraftV2EditorModel(newDraft: large, store: store)
        await oversized.save()
        XCTAssertEqual(oversized.exportAvailability, .tooLarge)
        let largeID = try XCTUnwrap(oversized.persistedID)
        let saved = try await store.load(largeID)
        XCTAssertEqual(saved, large)
    }

    func testConflictBlocksPublicationAndSaveAsCopyPreservesBothVersions() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ScoreDraftV2Store(folder: folder)
        let original = complete()
        let id = try await store.create(original)
        let model = try await ScoreDraftV2EditorModel.open(id: id, store: store)
        var external = original
        external.title = "其他窗口"
        try await store.update(external, id: id, replacing: original)
        var called = false
        do {
            _ = try await model.publishPractice { _ in called = true; return folder }
            XCTFail("Changed source must block publication")
        } catch ScoreDraftPracticeStateError.sourceChanged { }
        XCTAssertFalse(called)
        XCTAssertEqual(model.exportAvailability, .conflict)
        await model.saveAsNewCopy()
        XCTAssertEqual(model.exportAvailability, .ready)
        XCTAssertNotEqual(model.persistedID, id)
        let existing = try await store.load(id)
        XCTAssertEqual(existing, external)
        let copy = try await store.load(XCTUnwrap(model.persistedID))
        XCTAssertEqual(copy, original)
        XCTAssertTrue(model.replaceEvent(bar: 0, index: 0, with: .beat(.init(duration: 4))))
        do {
            _ = try await model.publishPractice { _ in called = true; return folder }
            XCTFail("Unsaved edits must block publication")
        } catch ScoreDraftPracticeStateError.notReady { }
        XCTAssertFalse(called)
    }

    func testSavingFreezesInputAndFailedSaveCanRetryWithoutLosingWork() async throws {
        struct Failure: Error { }
        var attempts = 0
        let started = expectation(description: "save started")
        var release: CheckedContinuation<Void, Never>?
        defer { release?.resume() }
        let original = complete()
        let model = try ScoreDraftV2EditorModel(newDraft: original) { _, snapshot, _ in
            XCTAssertEqual(snapshot, original)
            attempts += 1
            if attempts == 1 {
                await withCheckedContinuation { release = $0; started.fulfill() }
                throw Failure()
            }
        }
        let saving = Task { await model.save() }
        await fulfillment(of: [started], timeout: 10)
        XCTAssertEqual(model.closeDecision, .waitForOperation)
        XCTAssertFalse(model.insertBlankBar(at: 1))
        model.setMetadataInput(title: "不能变化", tempo: "120")
        XCTAssertEqual(model.titleInput, original.title)
        await model.saveAsNewCopy()
        let continuation = try XCTUnwrap(release)
        release = nil
        continuation.resume()
        await saving.value
        XCTAssertNil(model.persistedID)
        XCTAssertTrue(model.hasUnsavedChanges)
        await model.save()
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertNil(model.message)
    }

    func testPublishingFreezesEditsAndReleasesStateOnFailure() async throws {
        struct Failure: Error { }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try ScoreDraftV2EditorModel(newDraft: complete(), store: ScoreDraftV2Store(folder: folder))
        await model.save()
        do {
            _ = try await model.publishPractice { snapshot in
                XCTAssertEqual(snapshot, self.complete())
                XCTAssertEqual(model.closeDecision, .waitForOperation)
                XCTAssertEqual(model.exportAvailability, .busy)
                XCTAssertFalse(model.removeBar(at: 0))
                XCTAssertFalse(model.insertBlankBar(at: 1))
                await model.saveAsNewCopy()
                throw Failure()
            }
            XCTFail("Failure should reach caller")
        } catch is Failure { }
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.exportAvailability, .ready)
    }
}
