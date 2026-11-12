import XCTest
@testable import RiffLoop

final class ScoreDraftV2StoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func draft() -> ScoreDraftV2 {
        let chord = ScoreDraftV2Entry.beat(.init(duration: 4, dots: 1, notes: [
            .init(string: 1, fret: 3), .init(string: 2, fret: 5)
        ]))
        let triplet = ScoreDraftV2Entry.triplet(.init(beats: [
            .init(duration: 8, notes: [.init(string: 3, fret: 7)]),
            .init(duration: 8), .init(duration: 8, notes: [.init(string: 4, fret: 9)])
        ]))
        return ScoreDraftV2(title: "新版草稿", tempo: 120, bars: [[chord, triplet]])
    }

    func testIncompleteOverfullAndLongDraftsArePreservedWithoutTruncation() async throws {
        let quarter = ScoreDraftV2Entry.beat(.init(duration: 4))
        let whole = ScoreDraftV2Entry.beat(.init(duration: 1))
        let long = ScoreDraftV2(title: "长草稿", tempo: 100,
                                bars: [[quarter], [whole, quarter]] + Array(repeating: [whole], count: 65))
        XCTAssertTrue(long.isValidForStorage)
        XCTAssertFalse(long.canExport)
        XCTAssertEqual(Array(try XCTUnwrap(long.barTimings).prefix(2)),
                       [.incomplete(remaining: 2880), .overflow(extra: 960)])
        let store = ScoreDraftV2Store(folder: root)
        let id = try await store.create(long)
        let reopened = try await ScoreDraftV2Store(folder: root).load(id)
        XCTAssertEqual(reopened, long)
        XCTAssertEqual(reopened.bars.count, 67)
        XCTAssertFalse(reopened.canExport)
    }

    func testV1AndV2WithSameIDRemainIndependentIncludingSharedFolder() async throws {
        let id = UUID()
        let old = ScoreDraft(title: "旧草稿", tempo: 100, bars: [[.rest(duration: 1)]])
        let newer = draft()
        let v1 = ScoreDraftStore(folder: root)
        let v2 = ScoreDraftV2Store(folder: root)
        try await v1.create(old, id: id)
        try await v2.create(newer, id: id)
        let oldBefore = try Data(contentsOf: root.appendingPathComponent(id.uuidString + ".json"))
        var changed = newer
        changed.title = "新版修改"
        try await v2.update(changed, id: id, replacing: newer)
        let oldAfter = try await v1.load(id)
        let newAfter = try await v2.load(id)
        let oldIDs = try await v1.listIDs()
        let newIDs = try await v2.listIDs()
        XCTAssertEqual(oldAfter, old)
        XCTAssertEqual(newAfter, changed)
        XCTAssertEqual(oldIDs, [id])
        XCTAssertEqual(newIDs, [id])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(id.uuidString + ".json")), oldBefore)
    }

    func testOverExportBeatAndChordNoteLimitsAreStoredCompletely() async throws {
        let eighth = ScoreDraftV2Entry.beat(.init(duration: 8))
        let sixteenth = ScoreDraftV2Entry.beat(.init(duration: 16))
        let firstBar = Array(repeating: eighth, count: 7) + [sixteenth, sixteenth]
        let otherBar = Array(repeating: eighth, count: 8)
        let overBeats = ScoreDraftV2(title: "513 个节拍", tempo: 100,
            bars: [firstBar] + Array(repeating: otherBar, count: 63))
        XCTAssertTrue(overBeats.isValidForStorage)
        XCTAssertFalse(overBeats.canExport)
        let store = ScoreDraftV2Store(folder: root)
        let beatID = try await store.create(overBeats)
        let reopenedBeats = try await store.load(beatID)
        XCTAssertEqual(reopenedBeats, overBeats)
        XCTAssertEqual(reopenedBeats.bars.reduce(0) { $0 + $1.count }, 513)

        let chord = ScoreDraftV2Entry.beat(.init(duration: 8, notes: (1...6).map {
            ScoreDraftV2Note(string: $0, fret: $0)
        }))
        let overNotes = ScoreDraftV2(title: "576 个音符", tempo: 100,
            bars: Array(repeating: Array(repeating: chord, count: 8), count: 12))
        XCTAssertTrue(overNotes.isValidForStorage)
        XCTAssertFalse(overNotes.canExport)
        let noteID = try await store.create(overNotes)
        let reopenedNotes = try await store.load(noteID)
        XCTAssertEqual(reopenedNotes, overNotes)
        let noteCount = reopenedNotes.bars.flatMap { $0 }.reduce(0) { count, entry in
            switch entry {
            case let .beat(value): return count + value.notes.count
            case let .triplet(group): return count + group.beats.reduce(0) { $0 + $1.notes.count }
            }
        }
        XCTAssertEqual(noteCount, 576)
    }

    func testMalformedUnknownAndV1DataAreNeverOverwritten() async throws {
        let store = ScoreDraftV2Store(folder: root)
        let original = draft()
        let id = try await store.create(original)
        let path = root.appendingPathComponent("v2-\(id.uuidString).json")
        let valid = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["unknown"] = true
        let unknown = try JSONSerialization.data(withJSONObject: object)
        let v1 = try JSONEncoder().encode(ScoreDraft(title: "旧", tempo: 100, bars: [[.rest(duration: 1)]]))
        for bytes in [unknown, v1, Data("not json".utf8)] {
            try bytes.write(to: path)
            do { _ = try await store.load(id); XCTFail("Invalid content must be rejected") }
            catch ScoreDraftV2StoreError.invalidDraft { }
            do { try await store.update(original, id: id, replacing: original); XCTFail("Invalid content must not be replaced") }
            catch ScoreDraftV2StoreError.invalidDraft { }
            XCTAssertEqual(try Data(contentsOf: path), bytes)
        }
        var invalid = original
        invalid.tempo = 0
        do { try await store.create(invalid); XCTFail("Invalid draft must not be created") }
        catch ScoreDraftV2StoreError.invalidDraft { }
    }

    func testRawSizeLimitIsCheckedBeforeDecoding() async throws {
        let id = UUID()
        let path = root.appendingPathComponent("v2-\(id.uuidString).json")
        try Data(repeating: 0x78, count: 8 * 1024 * 1024 + 1).write(to: path)
        let store = ScoreDraftV2Store(folder: root)
        do { _ = try await store.load(id); XCTFail("Oversized input must be rejected") }
        catch ScoreDraftV2StoreError.tooLarge { }
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.intValue, 8 * 1024 * 1024 + 1)
    }

    func testSymlinkIsNeverReadReplacedOrFollowed() async throws {
        let original = root.appendingPathComponent("original.txt")
        let bytes = Data("keep".utf8)
        try bytes.write(to: original)
        let id = UUID()
        let link = root.appendingPathComponent("v2-\(id.uuidString).json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let store = ScoreDraftV2Store(folder: root)
        do { _ = try await store.load(id); XCTFail("Symlinks cannot be read") }
        catch ScoreDraftV2StoreError.invalidFile { }
        do { try await store.update(draft(), id: id, replacing: draft()); XCTFail("Symlinks cannot be replaced") }
        catch ScoreDraftV2StoreError.invalidFile { }
        do { try await store.create(draft(), id: id); XCTFail("Existing links cannot be replaced") }
        catch let error as POSIXError { XCTAssertEqual(error.code, .EEXIST) }
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        let ids = try await store.listIDs()
        XCTAssertTrue(ids.isEmpty)
    }

    func testDirectoryCannotBeReadAsDraftOrReplaced() async throws {
        let id = UUID()
        let path = root.appendingPathComponent("v2-\(id.uuidString).json", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        let store = ScoreDraftV2Store(folder: root)
        do { _ = try await store.load(id); XCTFail("A directory is not a draft") }
        catch ScoreDraftV2StoreError.invalidFile { }
        do { try await store.update(draft(), id: id, replacing: draft()); XCTFail("A directory must not be replaced") }
        catch ScoreDraftV2StoreError.invalidFile { }
        do { try await store.create(draft(), id: id); XCTFail("A directory must not be replaced") }
        catch let error as POSIXError { XCTAssertEqual(error.code, .EEXIST) }
        let values = try path.resourceValues(forKeys: [.isDirectoryKey])
        XCTAssertTrue(values.isDirectory == true)
    }

    func testConcurrentEditorsCannotOverwriteTheSameSnapshot() async throws {
        let id = UUID()
        let firstStore = ScoreDraftV2Store(folder: root)
        let secondStore = ScoreDraftV2Store(folder: root)
        let original = draft()
        try await firstStore.create(original, id: id)
        var first = original
        var second = original
        first.title = "并发一"
        second.title = "并发二"
        let drafts = [first, second]
        let stores = [firstStore, secondStore]
        let outcomes = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for index in 0..<2 {
                group.addTask {
                    do { try await stores[index].update(drafts[index], id: id, replacing: original); return 1 }
                    catch ScoreDraftV2StoreError.conflict { return 0 }
                    catch { return -1 }
                }
            }
            var results: [Int] = []
            for await result in group { results.append(result) }
            return results.sorted()
        }
        XCTAssertEqual(outcomes, [0, 1])
        let saved = try await firstStore.load(id)
        XCTAssertTrue(drafts.contains(saved))
    }

    func testConcurrentCreatesCannotReplaceExistingDraft() async throws {
        let id = UUID()
        var second = draft()
        second.title = "第二份"
        let drafts = [draft(), second]
        let stores = [ScoreDraftV2Store(folder: root), ScoreDraftV2Store(folder: root)]
        let outcomes = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for index in 0..<2 {
                group.addTask {
                    do { try await stores[index].create(drafts[index], id: id); return 1 }
                    catch let error as POSIXError where error.code == .EEXIST { return 0 }
                    catch { return -1 }
                }
            }
            var results: [Int] = []
            for await result in group { results.append(result) }
            return results.sorted()
        }
        XCTAssertEqual(outcomes, [0, 1])
        let saved = try await stores[0].load(id)
        XCTAssertTrue(drafts.contains(saved))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["v2-\(id.uuidString).json"])
    }

    func testCleanupFailureReportsWhetherDraftWasPublished() async throws {
        let store = ScoreDraftV2Store(folder: root, fileManager: FailV2StagingCleanupFileManager())
        let id = UUID()
        do { try await store.create(draft(), id: id); XCTFail("Cleanup failure must be reported") }
        catch let ScoreDraftV2StoreError.cleanupFailed(staging, published, _) {
            XCTAssertEqual(published, id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staging))
        }
        let saved = try await ScoreDraftV2Store(folder: root).load(id)
        XCTAssertEqual(saved, draft())
        do { try await store.create(draft(), id: id); XCTFail("Duplicate plus cleanup failure must be reported") }
        catch let ScoreDraftV2StoreError.cleanupFailed(staging, published, _) {
            XCTAssertNil(published)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staging))
        }
        let retained = try await ScoreDraftV2Store(folder: root).load(id)
        XCTAssertEqual(retained, saved)
    }
}

private final class FailV2StagingCleanupFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        if URL.lastPathComponent.hasPrefix(".v2-") { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: URL)
    }
}
