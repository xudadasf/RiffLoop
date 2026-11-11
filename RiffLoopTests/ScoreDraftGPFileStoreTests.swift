import WebKit
import XCTest
@testable import RiffLoop

@MainActor
final class ScoreDraftGPFileStoreTests: XCTestCase {
    private func draft(fret: Int = 5) -> ScoreDraft {
        ScoreDraft(title: "保存练习", tempo: 123, bars: [[
            .note(string: 1, fret: fret, duration: 2), .rest(duration: 2)
        ]])
    }

    func testInvalidNamesFailBeforeExportAndCreateNoFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScoreDraftGPFileStore(folder: root)
        let incomplete = ScoreDraft(title: "未完成", tempo: 100, bars: [[.rest(duration: 4)]])
        for name in ["", ".gp", "../score.gp", "/score.gp", "a\\b.gp", "a:b.gp",
                     "曲谱.txt", "曲谱 .gp", "曲谱..gp", "bad\nname.gp", String(repeating: "x", count: 241) + ".gp"] {
            do {
                _ = try await store.create(incomplete, fileName: name)
                XCTFail("Invalid name must fail before exporting: \(name)")
            } catch ScoreDraftGPFileStoreError.invalidName { }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testSaveCreatesReadableGPCopyAndNeverReplacesExistingFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("原谱.gp")
        let originalBytes = Data("do not replace".utf8)
        try originalBytes.write(to: original)
        let store = ScoreDraftGPFileStore(folder: root)

        let job = Task { try await store.create(draft(), fileName: "新草稿.gp") }
        let saved = try await job.value
        job.cancel()
        let bytes = try Data(contentsOf: saved)
        XCTAssertTrue(bytes.starts(with: [0x50, 0x4b, 0x03, 0x04]))
        try await assertSavedScore(bytes)

        do {
            _ = try await store.create(draft(fret: 6), fileName: "原谱.gp")
            XCTFail("An existing file must never be overwritten")
        } catch let error as POSIXError { XCTAssertEqual(error.code, .EEXIST) }
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertEqual(try Data(contentsOf: saved), bytes)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set(["原谱.gp", "新草稿.gp"]))
    }

    func testIncompleteDraftAndExistingSymlinkCannotDamageOtherFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.txt")
        let originalBytes = Data("keep".utf8)
        try originalBytes.write(to: original)
        let link = root.appendingPathComponent("link.gp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let store = ScoreDraftGPFileStore(folder: root)
        do {
            _ = try await store.create(ScoreDraft(title: "未完成", tempo: 100, bars: [[.rest(duration: 4)]]), fileName: "未完成.gp")
            XCTFail("Incomplete drafts cannot be saved as GP")
        } catch ScoreDraftExportError.incomplete { }
        do {
            _ = try await store.create(draft(), fileName: "link.gp")
            XCTFail("An existing symlink must not be replaced")
        } catch let error as POSIXError { XCTAssertEqual(error.code, .EEXIST) }
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set(["original.txt", "link.gp"]))
    }

    func testCancelledBeforeExportCreatesNoCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScoreDraftGPFileStore(folder: root)
        let job = Task { try await store.create(draft(), fileName: "取消.gp") }
        job.cancel()
        do {
            _ = try await job.value
            XCTFail("Cancellation before export must not publish a file")
        } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testCleanupFailureReportsWhetherCopyWasPublished() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("existing.gp")
        let original = Data("keep".utf8)
        try original.write(to: existing)
        let store = ScoreDraftGPFileStore(folder: root, fileManager: FailGPStagingCleanupFileManager())
        do {
            _ = try await store.create(draft(), fileName: "existing.gp")
            XCTFail("A staging cleanup error must be reported")
        } catch let ScoreDraftGPFileStoreError.cleanupFailed(staging, published, _) {
            XCTAssertNil(published)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staging))
        }
        XCTAssertEqual(try Data(contentsOf: existing), original)

        let new = root.appendingPathComponent("new.gp")
        do {
            _ = try await store.create(draft(), fileName: "new.gp")
            XCTFail("A published copy with failed cleanup must be reported")
        } catch let ScoreDraftGPFileStoreError.cleanupFailed(staging, published, _) {
            XCTAssertEqual(published, new.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staging))
        }
        XCTAssertTrue(try Data(contentsOf: new).starts(with: [0x50, 0x4b, 0x03, 0x04]))
        XCTAssertEqual(try Data(contentsOf: existing), original)
    }

    func testConcurrentSameNameCreatesExactlyOneCompleteCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = [ScoreDraftGPFileStore(folder: root), ScoreDraftGPFileStore(folder: root)]
        let drafts = [draft(fret: 5), draft(fret: 6)]
        let outcomes = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for index in 0..<2 {
                group.addTask {
                    for attempt in 0..<361 {
                        do {
                            _ = try await stores[index].create(drafts[index], fileName: "相同.gp")
                            return 1
                        } catch ScoreDraftExportError.busy {
                            guard attempt < 360 else { return -2 }
                            do { try await Task.sleep(for: .milliseconds(250)) }
                            catch { return -3 }
                        } catch let error as POSIXError where error.code == .EEXIST {
                            return 0
                        } catch { return -1 }
                    }
                    return -2
                }
            }
            var result: [Int] = []
            for await value in group { result.append(value) }
            return result.sorted()
        }
        XCTAssertEqual(outcomes, [0, 1])
        let saved = root.appendingPathComponent("相同.gp")
        let bytes = try Data(contentsOf: saved)
        try await assertSavedScore(bytes, allowedFrets: [5, 6])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["相同.gp"])
    }

    private func assertSavedScore(_ bytes: Data, allowedFrets: [Int] = [5]) async throws {
        let root = try XCTUnwrap(Bundle.main.resourceURL)
        let page = try XCTUnwrap(Bundle.main.url(forResource: "ScoreDraft", withExtension: "html"))
        let web = WKWebView(frame: .zero)
        defer { web.stopLoading() }
        web.loadFileURL(page, allowingReadAccessTo: root)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let ready = try? await evaluate("typeof alphaTab !== 'undefined'", in: web), ready as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let allowed = allowedFrets.map { String($0) }.joined(separator: ",")
        let result = try await evaluate("""
            (() => {
            const bytes = Uint8Array.from(atob('\(bytes.base64EncodedString())'), c => c.charCodeAt(0));
            const titleBytes = Uint8Array.from(atob('\(Data("保存练习".utf8).base64EncodedString())'), c => c.charCodeAt(0));
            const title = new TextDecoder('utf-8', { fatal: true }).decode(titleBytes);
            const score = alphaTab.importer.ScoreLoader.loadScoreFromBytes(bytes, new alphaTab.Settings());
            const beats = score.tracks[0].staves[0].bars[0].voices[0].beats;
            return score.title === title && score.tempo === 123 && score.tracks.length === 1 && beats.length === 2 &&
                beats[0].notes.length === 1 && [\(allowed)].includes(beats[0].notes[0].fret) &&
                beats[0].notes[0].string === 6 && beats[0].playbackDuration === 1920 &&
                beats[1].isRest && beats[1].playbackDuration === 1920;
            })()
            """, in: web)
        XCTAssertEqual(result as? Bool, true, "The saved copy must re-open with its notes and timing")
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

private final class FailGPStagingCleanupFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        if URL.lastPathComponent.hasPrefix(".riffloop-export-") { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: URL)
    }
}
