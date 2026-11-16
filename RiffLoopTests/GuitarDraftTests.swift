import XCTest
@testable import RiffLoop

final class GuitarDraftTests: XCTestCase {
    func testMeterUnknownNotesAndStorageRoundTrip() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = GuitarDraftStore(folder: folder)
        var draft = GuitarDraft(tempo: 70, numerator: 3, denominator: 4,
                               bars: [GuitarBar(beats: [GuitarBeat(notes: [GuitarNote(string: 1, fret: nil, review: ["待核对"])]), GuitarBeat(duration: 2)])])
        XCTAssertTrue(draft.isComplete)
        let id = try await store.create(draft)
        let restored = try await store.load(id)
        XCTAssertEqual(restored, draft)
        XCTAssertNil(restored.bars[0].beats[0].notes[0].fret)
        draft.bars[0].beats[0].notes[0].fret = 13
        try await store.update(draft, id: id, replacing: restored)
        do { try await store.update(restored, id: id, replacing: restored); XCTFail("Stale editor must not replace current edits") } catch { }
        let current = try await store.load(id)
        XCTAssertEqual(current, draft)
    }

    func testDefaultAndUnevenRhythmRemainEditable() {
        var draft = GuitarDraft()
        XCTAssertTrue(draft.isComplete)
        draft.bars[0].beats.append(GuitarBeat(notes: [GuitarNote(string: 6, fret: 0)]))
        XCTAssertTrue(draft.isValidForStorage)
        XCTAssertFalse(draft.isComplete)
        draft.bars[0].beats[0].notes = [GuitarNote(string: 1, fret: 13), GuitarNote(string: 1, fret: 11)]
        XCTAssertFalse(draft.isValidForStorage)
    }

    func testAllMetersHaveCompleteFallbackWithoutInventedNotes() {
        for numerator in [1,3,4,6,7,12,32] { for denominator in [1,2,4,8,16,32] {
            let settings = ScoreRecognitionSettings(tempo: 100, numerator: numerator, denominator: denominator, tuning: [40,45,50,55,59,64])
            let bar = GuitarDraft.placeholder(settings: settings, source: nil, reason: "未识别")
            let draft = GuitarDraft(numerator: numerator, denominator: denominator, bars: [bar])
            XCTAssertTrue(draft.isComplete)
            XCTAssertEqual(bar.beats.flatMap(\.notes).count, 0)
            XCTAssertEqual(bar.review, ["未识别"])
        } }
    }
}
