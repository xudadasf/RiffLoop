import WebKit
import XCTest
@testable import RiffLoop

@MainActor
final class ScoreDraftExporterTests: XCTestCase {
    func testOfflineExportReopensWithNotesRestsAndTempo() async throws {
        let original = ScoreDraft(title: "练习 ' \\\n<草稿>", tempo: 123, bars: [
            [.note(string: 1, fret: 11, duration: 4), .rest(duration: 4),
             .note(string: 6, fret: 0, duration: 2)],
            [.rest(duration: 1)],
        ])
        var editor = try ScoreDraftEditor(draft: original)
        try editor.replaceEvent(bar: 0, index: 0, with: .note(string: 1, fret: 12, duration: 4))
        let draft = editor.draft
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try await ScoreDraftStore(folder: folder).create(draft)
        let reopened = try await ScoreDraftStore(folder: folder).load(id)
        XCTAssertEqual(reopened, draft)
        let bytes = try await ScoreDraftExporter.export(reopened)
        XCTAssertTrue(bytes.starts(with: [0x50, 0x4b, 0x03, 0x04]))

        // Verify the returned bytes in a second WebKit instance, rather than
        // trusting that a nonempty result is a readable score.
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
        let verified = try await evaluate("""
            (() => {
            const encoded = '\(bytes.base64EncodedString())';
            const titleBytes = Uint8Array.from(atob('\(Data(draft.title.utf8).base64EncodedString())'), c => c.charCodeAt(0));
            const expectedTitle = new TextDecoder('utf-8', { fatal: true }).decode(titleBytes);
            const bytes = Uint8Array.from(atob(encoded), c => c.charCodeAt(0));
            const score = alphaTab.importer.ScoreLoader.loadScoreFromBytes(bytes, new alphaTab.Settings());
            const staff = score.tracks[0].staves[0];
            const first = staff.bars[0].voices[0].beats;
            const second = staff.bars[1].voices[0].beats;
            return score.title === expectedTitle && score.tempo === 123 && score.tracks.length === 1 &&
                score.masterBars.length === 2 && score.masterBars.every(b =>
                    b.timeSignatureNumerator === 4 && b.timeSignatureDenominator === 4) &&
                JSON.stringify(staff.stringTuning.tunings) === JSON.stringify([64,59,55,50,45,40]) &&
                first.length === 3 && first[0].notes.length === 1 &&
                first[0].notes[0].string === 6 && first[0].notes[0].fret === 12 &&
                first[0].playbackStart === 0 && first[0].playbackDuration === 960 &&
                first[1].isRest && first[1].playbackStart === 960 && first[1].playbackDuration === 960 &&
                first[2].notes.length === 1 && first[2].notes[0].string === 1 && first[2].notes[0].fret === 0 &&
                first[2].playbackStart === 1920 && first[2].playbackDuration === 1920 &&
                second.length === 1 && second[0].isRest && second[0].playbackDuration === 3840;
            })()
            """, in: verifier)
        XCTAssertEqual(verified as? Bool, true)
    }

    func testIncompleteOrInvalidDraftCannotExport() async throws {
        let drafts = [
            ScoreDraft(title: "未完成", tempo: 100, bars: [[.note(string: 1, fret: 0, duration: 4)]]),
            ScoreDraft(title: "无效", tempo: 100, bars: [[.note(string: 7, fret: 0, duration: 1)]]),
        ]
        for draft in drafts {
            do {
                _ = try await ScoreDraftExporter.export(draft)
                XCTFail("Incomplete or invalid draft must not yield GP data")
            } catch ScoreDraftExportError.incomplete { }
        }
    }

    private func evaluate(_ script: String, in web: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            web.evaluateJavaScript(script, completionHandler: { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            })
        }
    }
}
