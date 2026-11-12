import Foundation
import WebKit
import XCTest
@testable import RiffLoop

@MainActor
final class ScoreDraftV2ExporterTests: XCTestCase {
    func testSharedFixtureExportsAndReopensWithRhythmAndChords() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "score-draft-v2", withExtension: "json", subdirectory: "Fixtures"))
        let original = try JSONDecoder().decode(ScoreDraftV2.self, from: Data(contentsOf: fixture))
        XCTAssertTrue(original.canExport)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ScoreDraftV2Store(folder: folder)
        let id = try await store.create(original)
        let reopened = try await ScoreDraftV2Store(folder: folder).load(id)
        XCTAssertEqual(reopened, original)
        let bytes = try await ScoreDraftExporter.export(reopened)
        XCTAssertTrue(bytes.starts(with: [0x50, 0x4b, 0x03, 0x04]))
        let retained = try await store.load(id)
        XCTAssertEqual(retained, original)

        // A separate offline WebKit instance reads the actual returned bytes.
        let root = try XCTUnwrap(Bundle.main.resourceURL)
        let page = try XCTUnwrap(Bundle.main.url(forResource: "ScoreDraft", withExtension: "html"))
        let verifier = WKWebView(frame: .zero)
        defer { verifier.stopLoading() }
        verifier.loadFileURL(page, allowingReadAccessTo: root)
        let deadline = Date().addingTimeInterval(60)
        var ready = false
        while Date() < deadline {
            if let value = try? await evaluate("typeof alphaTab !== 'undefined'", in: verifier), value as? Bool == true {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(ready, "Offline GP reader did not load")
        guard ready else { return }
        let result = try await evaluate("""
            (() => {
            const bytes = Uint8Array.from(atob('\(bytes.base64EncodedString())'), c => c.charCodeAt(0));
            const titleBytes = Uint8Array.from(atob('\(Data(original.title.utf8).base64EncodedString())'), c => c.charCodeAt(0));
            const title = new TextDecoder('utf-8', { fatal: true }).decode(titleBytes);
            const score = alphaTab.importer.ScoreLoader.loadScoreFromBytes(bytes, new alphaTab.Settings());
            const staff = score.tracks[0].staves[0];
            const first = staff.bars[0].voices[0].beats;
            const second = staff.bars[1].voices[0].beats;
            const notes = beat => beat.notes.map(n => [7 - n.string, n.fret, n.realValue]).sort((a,b) => a[0] - b[0]);
            return score.title === title && score.tempo === 123 && score.tracks.length === 1 &&
                score.masterBars.length === 2 && score.masterBars[1].start === 3840 &&
                score.masterBars.every(b => b.timeSignatureNumerator === 4 && b.timeSignatureDenominator === 4) &&
                JSON.stringify(staff.stringTuning.tunings) === JSON.stringify([64,59,55,50,45,40]) &&
                first.length === 3 && first[0].duration === 4 && first[0].dots === 1 &&
                first[0].playbackStart === 0 && first[0].playbackDuration === 1440 &&
                JSON.stringify(notes(first[0])) === JSON.stringify([[1,0,64],[2,1,60]]) &&
                first[1].playbackStart === 1440 && first[1].playbackDuration === 480 &&
                JSON.stringify(notes(first[1])) === JSON.stringify([[6,3,43]]) &&
                first[2].isRest && first[2].playbackStart === 1920 && first[2].playbackDuration === 1920 &&
                second.length === 4 && second.slice(0,3).every((b,i) =>
                    b.duration === 8 && b.dots === 0 && b.tupletNumerator === 3 && b.tupletDenominator === 2 &&
                    b.playbackStart === i * 320 && b.playbackDuration === 320 &&
                    b.tupletGroup === second[0].tupletGroup && b.tupletGroup.beats.length === 3) &&
                JSON.stringify(notes(second[0])) === JSON.stringify([[1,12,76],[2,13,72]]) &&
                second[1].isRest && JSON.stringify(notes(second[2])) === JSON.stringify([[1,15,79]]) &&
                second[3].isRest && second[3].duration === 2 && second[3].dots === 1 &&
                second[3].playbackStart === 960 && second[3].playbackDuration === 2880;
            })()
            """, in: verifier)
        XCTAssertEqual(result as? Bool, true)
    }

    func testInvalidIncompleteAndOverfullDraftsCannotExport() async throws {
        let empty = ScoreDraftV2(title: "未完成", tempo: 100, bars: [[.beat(.init(duration: 4))]])
        let overflow = ScoreDraftV2(title: "超出", tempo: 100, bars: [[.beat(.init(duration: 1)), .beat(.init(duration: 4))]])
        let badChord = ScoreDraftV2(title: "重复弦", tempo: 100,
            bars: [[.beat(.init(duration: 1, notes: [.init(string: 1, fret: 0), .init(string: 1, fret: 2)]))]])
        let badTriplet = ScoreDraftV2(title: "不完整三连音", tempo: 100,
            bars: [[.triplet(.init(beats: [.init(duration: 8), .init(duration: 8)]))]])
        for draft in [empty, overflow, badChord, badTriplet] {
            do {
                _ = try await ScoreDraftExporter.export(draft)
                XCTFail("Invalid, incomplete or overfull drafts must not yield GP data")
            } catch ScoreDraftExportError.incomplete { }
        }
    }

    func testOversizedCompleteDraftsAreRejectedWithoutTruncation() async throws {
        let whole = ScoreDraftV2Entry.beat(.init(duration: 1))
        let tooManyBars = ScoreDraftV2(title: "65 bars", tempo: 100, bars: Array(repeating: [whole], count: 65))
        let eighth = ScoreDraftV2Entry.beat(.init(duration: 8))
        let sixteenth = ScoreDraftV2Entry.beat(.init(duration: 16))
        let eightBeats = Array(repeating: eighth, count: 8)
        let tooManyBeats = ScoreDraftV2(title: "513 beats", tempo: 100,
            bars: [Array(repeating: eighth, count: 7) + [sixteenth, sixteenth]] + Array(repeating: eightBeats, count: 63))
        let four = (1...4).map { ScoreDraftV2Note(string: $0, fret: 0) }
        let noteBar: [ScoreDraftV2Entry] = [.beat(.init(duration: 2, notes: four)), .beat(.init(duration: 2, notes: four))]
        let extra: [ScoreDraftV2Entry] = [.beat(.init(duration: 2, notes: four + [.init(string: 5, fret: 0)])),
                                         .beat(.init(duration: 2, notes: four))]
        let tooManyNotes = ScoreDraftV2(title: "513 notes", tempo: 100, bars: [extra] + Array(repeating: noteBar, count: 63))
        for draft in [tooManyBars, tooManyBeats, tooManyNotes] {
            XCTAssertTrue(draft.isValidForStorage)
            XCTAssertEqual(draft.barTimings?.allSatisfy { $0 == .complete }, true)
            XCTAssertFalse(draft.canExport)
            let data = try JSONEncoder().encode(draft)
            do {
                _ = try await ScoreDraftExporter.export(draft)
                XCTFail("Oversized drafts must not be shortened and exported")
            } catch ScoreDraftExportError.tooLarge { }
            XCTAssertEqual(try JSONDecoder().decode(ScoreDraftV2.self, from: data), draft)
        }
    }

    func testV1AndV2ShareOneExportGate() async throws {
        let v1 = ScoreDraft(title: "v1", tempo: 100, bars: [[.rest(duration: 1)]])
        let v2 = ScoreDraftV2(title: "v2", tempo: 100, bars: [[.beat(.init(duration: 1))]])
        let first = Task { try await ScoreDraftExporter.export(v1) }
        let second = Task { try await ScoreDraftExporter.export(v2) }
        var successes = 0
        var busy = 0
        for task in [first, second] {
            do {
                let data = try await task.value
                XCTAssertFalse(data.isEmpty)
                successes += 1
            }
            catch ScoreDraftExportError.busy { busy += 1 }
        }
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(busy, 1)
    }

    private func evaluate(_ script: String, in web: WKWebView) async throws -> Any? {
        try await ScoreDraftWebReply.wait(timeout: 30) { completion in
            web.evaluateJavaScript(script, completionHandler: completion)
        }
    }
}
