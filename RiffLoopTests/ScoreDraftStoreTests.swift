import XCTest
@testable import RiffLoop

final class ScoreDraftStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func completeDraft() -> ScoreDraft {
        ScoreDraft(title: "草稿", tempo: 120, bars: [[
            .note(string: 6, fret: 0, duration: 4), .rest(duration: 4),
            .note(string: 5, fret: 3, duration: 2)
        ]])
    }

    func testCreateReopenAndEditPreserveUnrelatedFiles() async throws {
        let folder = root.appendingPathComponent("Drafts")
        let original = root.appendingPathComponent("original.gp")
        let practice = root.appendingPathComponent("practice.gp")
        try Data("original".utf8).write(to: original)
        try Data("practice".utf8).write(to: practice)
        let store = ScoreDraftStore(folder: folder)
        let draft = completeDraft()
        XCTAssertTrue(draft.isComplete)
        let id = try await store.create(draft)
        let reopened = try await ScoreDraftStore(folder: folder).load(id)
        XCTAssertEqual(reopened, draft)
        var changed = draft
        changed.bars[0][0] = .note(string: 6, fret: 5, duration: 4)
        try await store.update(changed, id: id, replacing: draft)
        let saved = try await store.load(id)
        XCTAssertEqual(saved, changed)
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: practice), Data("practice".utf8))
        let ids = try await store.listIDs()
        XCTAssertEqual(ids, [id])
    }

    func testIncompleteDraftIsSavedButNotReadyToExport() async throws {
        let store = ScoreDraftStore(folder: root)
        let draft = ScoreDraft(title: "未完成", tempo: 100,
                               bars: [[.note(string: 1, fret: 0, duration: 4)]])
        XCTAssertTrue(draft.isValid)
        XCTAssertFalse(draft.isComplete)
        let id = try await store.create(draft)
        let reopened = try await store.load(id)
        XCTAssertEqual(reopened, draft)
        XCTAssertFalse(reopened.isComplete)
    }

    func testCreateNeverReplacesExistingDraftAndInvalidUpdateKeepsIt() async throws {
        let store = ScoreDraftStore(folder: root)
        let id = UUID()
        let draft = completeDraft()
        try await store.create(draft, id: id)
        var changed = draft
        changed.title = "不同内容"
        do {
            try await store.create(changed, id: id)
            XCTFail("Creating with an existing ID must fail")
        } catch let error as POSIXError {
            XCTAssertEqual(error.code, .EEXIST)
        }
        changed.tempo = 0
        do {
            try await store.update(changed, id: id, replacing: draft)
            XCTFail("Invalid content must not replace a draft")
        } catch ScoreDraftStoreError.invalidDraft { }
        let retained = try await store.load(id)
        XCTAssertEqual(retained, draft)
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(entries, [id.uuidString + ".json"])
    }

    func testUnknownFieldsAndCorruptionCannotBeOverwritten() async throws {
        let store = ScoreDraftStore(folder: root)
        let id = try await store.create(completeDraft())
        let url = root.appendingPathComponent(id.uuidString + ".json")
        let samples = [
            #"{"version":1,"title":"x","tempo":100,"bars":[[{"rest":true,"duration":1}]],"unknown":1}"#,
            #"{"version":1,"title":"x","tempo":100,"bars":[[{"string":1,"fret":0,"duration":1,"slide":true}]]}"#,
            #"{"version":1,"title":"x","tempo":100,"bars":[[{"rest":false,"duration":1}]]}"#,
            #"{"version":1,"title":"x","tempo":100,"bars":[[{"rest":true,"duration":0}]]}"#,
            "not json"
        ]
        for sample in samples {
            let bytes = Data(sample.utf8)
            try bytes.write(to: url)
            do {
                _ = try await store.load(id)
                XCTFail("Unknown or corrupt content must be rejected")
            } catch ScoreDraftStoreError.invalidDraft { }
            do {
                try await store.update(completeDraft(), id: id, replacing: completeDraft())
                XCTFail("Unknown or corrupt content must not be replaced")
            } catch ScoreDraftStoreError.invalidDraft { }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testSymbolicLinkCannotBeLoadedOrUpdated() async throws {
        let source = root.appendingPathComponent("other.txt")
        let bytes = Data("keep this file".utf8)
        try bytes.write(to: source)
        let id = UUID()
        let link = root.appendingPathComponent(id.uuidString + ".json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let store = ScoreDraftStore(folder: root)
        do {
            _ = try await store.load(id)
            XCTFail("Links must not be read as drafts")
        } catch ScoreDraftStoreError.invalidFile { }
        do {
            try await store.update(completeDraft(), id: id, replacing: completeDraft())
            XCTFail("Links must not be replaced")
        } catch ScoreDraftStoreError.invalidFile { }
        do {
            try await store.create(completeDraft(), id: id)
            XCTFail("Creating a draft must not replace an existing link")
        } catch let error as POSIXError {
            XCTAssertEqual(error.code, .EEXIST)
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let ids = try await store.listIDs()
        XCTAssertTrue(ids.isEmpty)
    }

    func testTwoEditorsCannotOverwriteNewerDraft() async throws {
        let id = UUID()
        let firstStore = ScoreDraftStore(folder: root)
        let secondStore = ScoreDraftStore(folder: root)
        let original = completeDraft()
        try await firstStore.create(original, id: id)
        var first = original
        var second = original
        first.title = "第一份修改"
        second.title = "另一份修改"
        try await firstStore.update(first, id: id, replacing: original)
        do {
            try await secondStore.update(second, id: id, replacing: original)
            XCTFail("A stale editor must not overwrite a newer draft")
        } catch ScoreDraftStoreError.conflict { }
        let retained = try await firstStore.load(id)
        XCTAssertEqual(retained, first)
    }

    func testConcurrentEditorsCannotBothReplaceTheSameSnapshot() async throws {
        let id = UUID()
        let firstStore = ScoreDraftStore(folder: root)
        let secondStore = ScoreDraftStore(folder: root)
        let original = completeDraft()
        try await firstStore.create(original, id: id)
        var first = original
        var second = original
        first.title = "并发修改一"
        second.title = "并发修改二"
        let candidates = [first, second]
        let stores = [firstStore, secondStore]
        let outcomes = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for index in 0..<2 {
                group.addTask {
                    do {
                        try await stores[index].update(candidates[index], id: id, replacing: original)
                        return 1
                    } catch ScoreDraftStoreError.conflict {
                        return 0
                    } catch {
                        return -1
                    }
                }
            }
            var result: [Int] = []
            for await value in group { result.append(value) }
            return result.sorted()
        }
        XCTAssertEqual(outcomes, [0, 1])
        let retained = try await firstStore.load(id)
        XCTAssertTrue(candidates.contains(retained))
    }
}
