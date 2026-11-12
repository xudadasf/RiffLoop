import Foundation
import XCTest
@testable import RiffLoop

final class ScoreDraftV2Tests: XCTestCase {
    private func beat(_ duration: Int, dots: Int = 0, notes: [ScoreDraftV2Note] = []) -> ScoreDraftV2Entry {
        .beat(.init(duration: duration, dots: dots, notes: notes))
    }

    func testSharedNodeFixtureDecodesAndRoundTripsWithoutChangingItsFields() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "score-draft-v2", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let draft = try JSONDecoder().decode(ScoreDraftV2.self, from: data)
        XCTAssertThrowsError(try JSONDecoder().decode(ScoreDraft.self, from: data), "V1 must not silently accept v2")
        XCTAssertTrue(draft.isValidForStorage)
        XCTAssertTrue(draft.canExport)
        XCTAssertEqual(draft.barTimings, [.complete, .complete])
        guard case let .beat(first) = draft.bars[0][0], case let .triplet(group) = draft.bars[1][0] else {
            return XCTFail("Expected a dotted chord and explicit triplet")
        }
        XCTAssertEqual(first.dots, 1)
        XCTAssertEqual(first.notes, [.init(string: 1, fret: 0), .init(string: 2, fret: 1)])
        XCTAssertEqual(group.beats.count, 3)
        XCTAssertTrue(group.beats[1].notes.isEmpty)
        let encoded = try JSONEncoder().encode(draft)
        XCTAssertEqual(try JSONDecoder().decode(ScoreDraftV2.self, from: encoded), draft)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: encoded) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    func testIncompleteAndOverfullBarsCanBePreservedButCannotExport() throws {
        let draft = ScoreDraftV2(title: "进行中", tempo: 100,
                                 bars: [[beat(4, notes: [.init(string: 1, fret: 0)])], [beat(1), beat(4)]])
        XCTAssertTrue(draft.isValidForStorage)
        XCTAssertEqual(draft.barTimings, [.incomplete(remaining: 2880), .overflow(extra: 960)])
        XCTAssertFalse(draft.canExport)
        let data = try JSONEncoder().encode(draft)
        XCTAssertEqual(try JSONDecoder().decode(ScoreDraftV2.self, from: data), draft)
    }

    func testShortestTripletsAndDottedNotesHaveExactIntegerTiming() {
        let triplet = ScoreDraftV2Entry.triplet(.init(beats: Array(repeating: .init(duration: 64), count: 3)))
        let tripletBar: [ScoreDraftV2Entry] = [triplet, beat(2), beat(4), beat(8), beat(16), beat(32)]
        let dottedBar: [ScoreDraftV2Entry] = [beat(64, dots: 1), beat(64, dots: 1),
                                               beat(2), beat(4), beat(8), beat(16), beat(64)]
        let draft = ScoreDraftV2(title: "节奏", tempo: 999, bars: [tripletBar, dottedBar])
        XCTAssertEqual(draft.barTimings, [.complete, .complete])
        XCTAssertTrue(draft.canExport)
    }

    func testInvalidConstructedDraftCannotBeEncoded() {
        let note = ScoreDraftV2Note(string: 1, fret: 0)
        let invalidEntries: [ScoreDraftV2Entry] = [
            beat(0), beat(128), beat(4, dots: 2), beat(4, notes: [.init(string: 0, fret: 0)]),
            beat(4, notes: [.init(string: 1, fret: 37)]), beat(4, notes: [note, note]),
            .triplet(.init(beats: [.init(duration: 8), .init(duration: 8)])),
            .triplet(.init(beats: [.init(duration: 8), .init(duration: 8), .init(duration: 16)])),
            .triplet(.init(beats: [.init(duration: 8, dots: 1), .init(duration: 8), .init(duration: 8)])),
            .triplet(.init(beats: Array(repeating: .init(duration: 8), count: 3),
                           tuplet: .init(numerator: 5, denominator: 4)))
        ]
        for entry in invalidEntries {
            let draft = ScoreDraftV2(title: "invalid", tempo: 100, bars: [[entry]])
            XCTAssertFalse(draft.isValidForStorage)
            XCTAssertNil(draft.barTimings)
            XCTAssertFalse(draft.canExport)
            XCTAssertThrowsError(try JSONEncoder().encode(draft))
        }
    }

    func testMalformedUnknownAndV1JSONAreRejected() throws {
        let base = #"{"version":2,"title":"x","tempo":100,"meter":{"numerator":4,"denominator":4},"tuning":[40,45,50,55,59,64],"bars":[[{"duration":1,"dots":0,"notes":[{"string":1,"fret":0}]}]]}"#
        XCTAssertNoThrow(try JSONDecoder().decode(ScoreDraftV2.self, from: Data(base.utf8)))
        let replacements: [(String, String)] = [
            (#""version":2"#, #""version":1"#),
            (#""version":2"#, #""version":2,"unknown":true"#),
            (#""numerator":4"#, #""numerator":3"#),
            (#""numerator":4"#, #""numerator":4,"unknown":true"#),
            (#""tuning":[40,45,50,55,59,64]"#, #""tuning":[40,45,50,55,59,63]"#),
            (#""duration":1"#, #""duration":3"#),
            (#""dots":0"#, #""dots":0,"slide":true"#),
            (#""fret":0"#, #""fret":0,"slide":true"#),
            (#"{"string":1,"fret":0}"#, #"{"string":1,"fret":0},{"string":1,"fret":2}"#),
        ]
        for (old, new) in replacements {
            let corrupted = base.replacingOccurrences(of: old, with: new)
            XCTAssertNotEqual(corrupted, base)
            XCTAssertThrowsError(try JSONDecoder().decode(ScoreDraftV2.self, from: Data(corrupted.utf8)))
        }
        let incompleteTriplet = #"{"version":2,"title":"x","tempo":100,"meter":{"numerator":4,"denominator":4},"tuning":[40,45,50,55,59,64],"bars":[[{"tuplet":{"numerator":3,"denominator":2},"beats":[{"duration":8,"dots":0,"notes":[]},{"duration":8,"dots":0,"notes":[]}]}]]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ScoreDraftV2.self, from: Data(incompleteTriplet.utf8)))
        let group = #"{"version":2,"title":"x","tempo":100,"meter":{"numerator":4,"denominator":4},"tuning":[40,45,50,55,59,64],"bars":[[{"tuplet":{"numerator":3,"denominator":2},"beats":[{"duration":8,"dots":0,"notes":[]},{"duration":8,"dots":0,"notes":[]},{"duration":8,"dots":0,"notes":[]}]}]]}"#
        let incomplete = try JSONDecoder().decode(ScoreDraftV2.self, from: Data(group.utf8))
        XCTAssertEqual(incomplete.barTimings, [.incomplete(remaining: 2880)])
        XCTAssertFalse(incomplete.canExport)
        let unknownRatio = group.replacingOccurrences(of: #""numerator":3"#, with: #""numerator":3,"extra":true"#)
        XCTAssertNotEqual(unknownRatio, group)
        XCTAssertThrowsError(try JSONDecoder().decode(ScoreDraftV2.self, from: Data(unknownRatio.utf8)))
        let dotted = group.replacingOccurrences(of: #""dots":0"#, with: #""dots":1"#)
        XCTAssertThrowsError(try JSONDecoder().decode(ScoreDraftV2.self, from: Data(dotted.utf8)))
        let old = try JSONEncoder().encode(ScoreDraft(title: "旧草稿", tempo: 100, bars: [[.rest(duration: 1)]]))
        XCTAssertThrowsError(try JSONDecoder().decode(ScoreDraftV2.self, from: old), "V2 must not reinterpret v1")
    }

    func testTemporaryExportLimitsPreserveFullEditableDraft() throws {
        let bar = [beat(1)]
        let maxBars = ScoreDraftV2(title: "", tempo: 1, bars: Array(repeating: bar, count: 64))
        XCTAssertTrue(maxBars.canExport)
        XCTAssertEqual(try JSONDecoder().decode(ScoreDraftV2.self, from: JSONEncoder().encode(maxBars)).bars.count, 64)
        let extraBar = ScoreDraftV2(title: "", tempo: 1, bars: Array(repeating: bar, count: 65))
        XCTAssertTrue(extraBar.isValidForStorage)
        XCTAssertFalse(extraBar.canExport)
        XCTAssertEqual(try JSONDecoder().decode(ScoreDraftV2.self, from: JSONEncoder().encode(extraBar)), extraBar)

        let eightBeats = Array(repeating: beat(8), count: 8)
        let maxBeats = ScoreDraftV2(title: "", tempo: 100, bars: Array(repeating: eightBeats, count: 64))
        XCTAssertTrue(maxBeats.canExport)
        let excessBeats = ScoreDraftV2(title: "", tempo: 100,
            bars: [Array(repeating: beat(8), count: 7) + [beat(16), beat(16)]] + Array(repeating: eightBeats, count: 63))
        XCTAssertTrue(excessBeats.isValidForStorage)
        XCTAssertFalse(excessBeats.canExport)
        let decodedBeats = try JSONDecoder().decode(ScoreDraftV2.self, from: JSONEncoder().encode(excessBeats))
        XCTAssertEqual(decodedBeats, excessBeats)
        XCTAssertEqual(decodedBeats.bars.reduce(0) { $0 + $1.count }, 513)

        let fourNotes = (1...4).map { ScoreDraftV2Note(string: $0, fret: 0) }
        let noteBar = [beat(2, notes: fourNotes), beat(2, notes: fourNotes)]
        let maxNotes = ScoreDraftV2(title: "", tempo: 100, bars: Array(repeating: noteBar, count: 64))
        XCTAssertTrue(maxNotes.canExport)
        let extra = [beat(2, notes: fourNotes + [.init(string: 5, fret: 0)]), beat(2, notes: fourNotes)]
        let excessNotes = ScoreDraftV2(title: "", tempo: 100, bars: [extra] + Array(repeating: noteBar, count: 63))
        XCTAssertTrue(excessNotes.isValidForStorage)
        XCTAssertFalse(excessNotes.canExport)
        let decodedNotes = try JSONDecoder().decode(ScoreDraftV2.self, from: JSONEncoder().encode(excessNotes))
        XCTAssertEqual(decodedNotes, excessNotes)
        var count = 0
        for bar in decodedNotes.bars {
            for entry in bar {
                switch entry {
                case let .beat(value): count += value.notes.count
                case let .triplet(value): count += value.beats.reduce(0) { $0 + $1.notes.count }
                }
            }
        }
        XCTAssertEqual(count, 513)
        let tooManyStoredBars = ScoreDraftV2(title: "", tempo: 100, bars: Array(repeating: bar, count: 513))
        XCTAssertFalse(tooManyStoredBars.isValidForStorage)
        XCTAssertThrowsError(try JSONEncoder().encode(tooManyStoredBars))
    }

    func testTitleAndExplicitSettingsFollowV2Contract() {
        var draft = ScoreDraftV2(title: String(repeating: "😀", count: 256), tempo: 100, bars: [[beat(1)]])
        XCTAssertTrue(draft.canExport)
        draft.title += "😀"
        XCTAssertFalse(draft.isValidForStorage)
        draft.title = "valid"
        draft.meter = .init(numerator: 3, denominator: 4)
        XCTAssertFalse(draft.isValidForStorage)
        draft.meter = .init(numerator: 4, denominator: 4)
        draft.tuning[0] = 39
        XCTAssertFalse(draft.isValidForStorage)
    }

    func testStorageResourceLimitsRejectWithoutTruncation() {
        let largeBar = Array(repeating: beat(64), count: 128)
        let maxBeats = ScoreDraftV2(title: "", tempo: 100, bars: Array(repeating: largeBar, count: 256))
        XCTAssertTrue(maxBeats.isValidForStorage) // 32768 beats; bars may be overfull while editing.
        let tooManyBeats = ScoreDraftV2(title: "", tempo: 100, bars: maxBeats.bars + [[beat(1)]])
        XCTAssertFalse(tooManyBeats.isValidForStorage)

        let sixNotes = (1...6).map { ScoreDraftV2Note(string: $0, fret: 0) }
        let chord = beat(64, notes: sixNotes)
        let chordBar = Array(repeating: chord, count: 128)
        let prefix = Array(repeating: chordBar, count: 42)
        let last = Array(repeating: chord, count: 85) + [beat(64, notes: Array(sixNotes.prefix(2)))]
        let maxNotes = ScoreDraftV2(title: "", tempo: 100, bars: prefix + [last])
        XCTAssertTrue(maxNotes.isValidForStorage) // 32768 notes.
        let overflow = Array(repeating: chord, count: 85) + [beat(64, notes: Array(sixNotes.prefix(3)))]
        let tooManyNotes = ScoreDraftV2(title: "", tempo: 100, bars: prefix + [overflow])
        XCTAssertFalse(tooManyNotes.isValidForStorage)
    }
}
