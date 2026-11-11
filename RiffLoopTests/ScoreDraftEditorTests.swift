import XCTest
@testable import RiffLoop

final class ScoreDraftEditorTests: XCTestCase {
    func testEditFretAndTimingWithoutChangingOtherEvents() throws {
        let original = ScoreDraft(title: "练习", tempo: 100, bars: [[
            .note(string: 6, fret: 2, duration: 4),
            .note(string: 5, fret: 3, duration: 4),
            .rest(duration: 2)
        ]])
        var editor = try ScoreDraftEditor(draft: original)
        try editor.replaceEvent(bar: 0, index: 0, with: .note(string: 6, fret: 5, duration: 8))
        XCTAssertEqual(try editor.timing(of: 0), .incomplete(remaining: 8))
        XCTAssertFalse(editor.draft.isComplete)
        try editor.insertEvent(bar: 0, at: 1, event: .note(string: 6, fret: 7, duration: 8))
        XCTAssertEqual(try editor.timing(of: 0), .complete)
        XCTAssertTrue(editor.draft.isComplete)
        XCTAssertEqual(editor.draft.bars[0], [
            .note(string: 6, fret: 5, duration: 8), .note(string: 6, fret: 7, duration: 8),
            .note(string: 5, fret: 3, duration: 4), .rest(duration: 2)
        ])
        XCTAssertEqual(original.bars[0][0], .note(string: 6, fret: 2, duration: 4))
    }

    func testTimingOverflowAndBlankSeparatorKeepOrder() throws {
        let first: ScoreDraftEvent = .note(string: 1, fret: 0, duration: 1)
        let second: ScoreDraftEvent = .note(string: 2, fret: 12, duration: 1)
        var editor = try ScoreDraftEditor(draft: ScoreDraft(title: "片段", tempo: 90, bars: [[first], [second]]))
        try editor.insertBlankBar(at: 1)
        XCTAssertEqual(editor.draft.bars, [[first], [.rest(duration: 1)], [second]])
        XCTAssertEqual(try editor.timing(of: 1), .complete)
        try editor.insertEvent(bar: 0, at: 1, event: .note(string: 1, fret: 1, duration: 4))
        XCTAssertEqual(try editor.timing(of: 0), .overflow(extra: 16))
        XCTAssertFalse(editor.draft.isComplete)
        try editor.removeEvent(bar: 0, index: 1)
        try editor.removeBar(at: 1)
        XCTAssertEqual(editor.draft.bars, [[first], [second]])
        XCTAssertTrue(editor.draft.isComplete)
    }

    func testInvalidOperationsNeverChangeTheDraft() throws {
        let original = ScoreDraft(title: "保留", tempo: 100, bars: [[.rest(duration: 1)]])
        var editor = try ScoreDraftEditor(draft: original)
        XCTAssertThrowsError(try editor.replaceEvent(bar: 0, index: 0, with: .note(string: 7, fret: 0, duration: 4)))
        XCTAssertThrowsError(try editor.insertEvent(bar: 0, at: 1, event: .rest(duration: 3)))
        XCTAssertThrowsError(try editor.insertEvent(bar: -1, at: 0, event: .rest(duration: 4)))
        XCTAssertThrowsError(try editor.removeEvent(bar: 0, index: 0))
        XCTAssertThrowsError(try editor.removeBar(at: 0))
        XCTAssertThrowsError(try editor.insertBlankBar(at: 2))
        XCTAssertThrowsError(try editor.setMetadata(title: "变更", tempo: 0))
        XCTAssertThrowsError(try editor.timing(of: 1))
        XCTAssertEqual(editor.draft, original)
    }

    func testLimitsAndUnsupportedInitialDraftAreRejected() throws {
        let empty = ScoreDraft(title: "空", tempo: 100, bars: [[]])
        XCTAssertThrowsError(try ScoreDraftEditor(draft: empty))
        let invalid = ScoreDraft(title: "错误时值", tempo: 100, bars: [[.rest(duration: 0)]])
        XCTAssertThrowsError(try ScoreDraftEditor(draft: invalid))
        let fullBar = Array(repeating: ScoreDraftEvent.rest(duration: 64), count: 128)
        var editor = try ScoreDraftEditor(draft: ScoreDraft(title: "上限", tempo: 100, bars: [fullBar]))
        let original = editor.draft
        XCTAssertThrowsError(try editor.insertEvent(bar: 0, at: 0, event: .rest(duration: 64)))
        XCTAssertEqual(editor.draft, original)
        let fullScore = ScoreDraft(title: "上限", tempo: 100,
                                   bars: Array(repeating: [.rest(duration: 1)], count: 512))
        var fullEditor = try ScoreDraftEditor(draft: fullScore)
        XCTAssertThrowsError(try fullEditor.insertBlankBar(at: 512))
        XCTAssertEqual(fullEditor.draft, fullScore)
    }

    func testEditedDraftCanBeSavedReopenedAndConflictsDoNotDiscardEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScoreDraftStore(folder: root)
        let original = ScoreDraft(title: "练习", tempo: 100, bars: [[.note(string: 1, fret: 0, duration: 1)]])
        let id = try await store.create(original)
        var editor = try ScoreDraftEditor(draft: original)
        try editor.replaceEvent(bar: 0, index: 0, with: .note(string: 1, fret: 7, duration: 1))
        try await store.update(editor.draft, id: id, replacing: original)
        let saved = try await store.load(id)
        XCTAssertEqual(saved, editor.draft)

        var staleEditor = try ScoreDraftEditor(draft: original)
        try staleEditor.replaceEvent(bar: 0, index: 0, with: .note(string: 1, fret: 5, duration: 1))
        do {
            try await store.update(staleEditor.draft, id: id, replacing: original)
            XCTFail("An outdated edit must not replace the saved draft")
        } catch ScoreDraftStoreError.conflict { }
        XCTAssertEqual(staleEditor.draft.bars[0][0], .note(string: 1, fret: 5, duration: 1))
        let retained = try await store.load(id)
        XCTAssertEqual(retained, saved)
    }
}
