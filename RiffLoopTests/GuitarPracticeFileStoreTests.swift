import CryptoKit
import XCTest
@testable import RiffLoop

final class GuitarPracticeFileStoreTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testExistingGPIsUpdatedInPlaceAndRejectsAStaleSave() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("practice.gp")
        try data(1).write(to: target)
        try await GuitarExistingFile.shared.replace(target, original: data(1), edited: data(2))
        do {
            try await GuitarExistingFile.shared.replace(target, original: data(1), edited: data(3))
            XCTFail("A stale editor overwrote another save")
        } catch GuitarDraftStoreError.conflict { }
        XCTAssertEqual(try GuitarExistingFile.read(target), data(2))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["practice.gp"])
    }
    private func data(_ byte: UInt8) -> Data { Data([0x50,0x4b,0x03,0x04,byte]) }

    func testRepeatedSaveAndTitleChangesHaveOneStableFile() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let gp = root.appendingPathComponent("scores"), receipts = root.appendingPathComponent("receipts")
        let store = GuitarPracticeFileStore(folder: gp, receipts: receipts), id = UUID()
        let first = try await store.publish(data(1), id: id)
        let second = try await store.publish(data(2), id: id)
        let third = try await GuitarPracticeFileStore(folder: gp, receipts: receipts).publish(data(2), id: id)
        XCTAssertEqual(first.url, second.url); XCTAssertEqual(first.url, third.url)
        XCTAssertEqual(try Data(contentsOf: first.url), data(2))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: gp.path).count, 1)
    }

    func testUnownedFileAndExternalEditsAreNeverOverwritten() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GuitarPracticeFileStore(folder: root, receipts: root.appendingPathComponent("receipts"))
        let unownedID = UUID(), unowned = root.appendingPathComponent(GuitarPracticeFileStore.fileName(unownedID))
        try data(9).write(to: unowned)
        do { _ = try await store.publish(data(1), id: unownedID); XCTFail("Must reject an imported file") } catch { }
        XCTAssertEqual(try Data(contentsOf: unowned), data(9))
        let id = UUID(), file = try await store.publish(data(1), id: id).url
        try data(8).write(to: file)
        do { _ = try await store.publish(data(2), id: id); XCTFail("Must preserve external edits") } catch { }
        XCTAssertEqual(try Data(contentsOf: file), data(8))
    }

    func testInterruptedReceiptCanRecoverWithoutAnotherFile() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let receipts = root.appendingPathComponent("receipts"), store = GuitarPracticeFileStore(folder: root, receipts: receipts), id = UUID()
        let file = try await store.publish(data(1), id: id).url
        let old = SHA256.hash(data: data(1)).map { String(format: "%02x", $0) }.joined()
        let pending = SHA256.hash(data: data(2)).map { String(format: "%02x", $0) }.joined()
        try JSONEncoder().encode(GuitarPracticeFileStore.Receipt(current: old, pending: pending))
            .write(to: receipts.appendingPathComponent(id.uuidString + ".json"))
        try data(2).write(to: file)
        let recovered = try await store.publish(data(3), id: id)
        XCTAssertEqual(recovered.url, file); XCTAssertEqual(try Data(contentsOf: file), data(3))
    }

    func testOpeningPublishedFileRejectsStaleOrDeletedLibraryEntry() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = GuitarDraftStore(folder: root.appendingPathComponent("drafts"))
        let store = GuitarPracticeFileStore(folder: root.appendingPathComponent("scores"),
                                            receipts: root.appendingPathComponent("receipts"), drafts: drafts)
        let id = try await drafts.create(GuitarDraft())
        let first = try await store.publish(data(1), id: id)
        let document = await store.editableDocument(for: first.url)
        let openedHash = try XCTUnwrap(document?.publishedHash)
        XCTAssertEqual(openedHash, first.hash)
        let second = try await store.publish(data(2), id: id, replacing: openedHash)
        do {
            _ = try await store.publish(data(3), id: id, replacing: openedHash)
            XCTFail("Another editor's saved change was overwritten")
        } catch GuitarDraftStoreError.conflict { }
        XCTAssertEqual(try Data(contentsOf: second.url), data(2))
        try FileManager.default.removeItem(at: second.url)
        do {
            _ = try await store.publish(data(3), id: id, replacing: second.hash)
            XCTFail("A deleted library file was recreated")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.url.path))
        let republished = try await store.publish(data(3), id: id)
        XCTAssertEqual(republished.url, first.url)
        XCTAssertEqual(try Data(contentsOf: first.url), data(3))
    }

    func testCommittedGPAdvancesEditorHashWhenFinalReceiptCannotBeWritten() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let scores = root.appendingPathComponent("scores"), receipts = root.appendingPathComponent("receipts")
        let store = GuitarPracticeFileStore(folder: scores, receipts: receipts)
        let id = UUID(), first = try await store.publish(data(1), id: id)
        let interrupted = GuitarPracticeFileStore(folder: scores, receipts: receipts) { receipt, url in
            guard receipt.pending != nil else { throw CocoaError(.fileWriteOutOfSpace) }
            try receipt.write(to: url)
        }
        let committed = try await interrupted.publish(data(2), id: id, replacing: first.hash)
        XCTAssertEqual(try Data(contentsOf: committed.url), data(2))
        let pending = try JSONDecoder().decode(GuitarPracticeFileStore.Receipt.self,
                                              from: Data(contentsOf: receipts.appendingPathComponent(id.uuidString + ".json")))
        XCTAssertEqual(pending.current, first.hash)
        XCTAssertEqual(pending.pending, committed.hash)
        let next = try await store.publish(data(3), id: id, replacing: committed.hash)
        XCTAssertEqual(try Data(contentsOf: next.url), data(3))
    }

    func testSymlinkCannotReplaceAnotherScore() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.gp"), id = UUID()
        try data(9).write(to: original)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(GuitarPracticeFileStore.fileName(id)), withDestinationURL: original)
        let store = GuitarPracticeFileStore(folder: root, receipts: root.appendingPathComponent("receipts"))
        do { _ = try await store.publish(data(2), id: id); XCTFail("Must reject links") } catch { }
        XCTAssertEqual(try Data(contentsOf: original), data(9))
    }

    func testRecognitionIdentityUsesContentsRegionOrderAndSettingsNotContainerURL() throws {
        let source = GuitarSource(name: "test.png", digest: String(repeating: "a", count: 64), page: 0,
                                 region: ScoreRegion(x: 0, y: 0, width: 0.5, height: 0.5))
        let first = TabRecognitionRegion(url: URL(fileURLWithPath: "/old/test.png"), source: source, rotation: 0, gapAfter: 0)
        let moved = TabRecognitionRegion(url: URL(fileURLWithPath: "/new/test.png"), source: source, rotation: 0, gapAfter: 0)
        let id = try GuitarRecognitionIdentity.id(regions: [first], settings: .standard)
        XCTAssertEqual(id, try GuitarRecognitionIdentity.id(regions: [moved], settings: .standard))
        let spaced = TabRecognitionRegion(url: first.url, source: source, rotation: 0, gapAfter: 1)
        XCTAssertNotEqual(id, try GuitarRecognitionIdentity.id(regions: [spaced], settings: .standard))
        let slower = ScoreRecognitionSettings(tempo: 70, numerator: 4, denominator: 4, tuning: [40,45,50,55,59,64])
        XCTAssertNotEqual(id, try GuitarRecognitionIdentity.id(regions: [first], settings: slower))
        var cropped = source; cropped.region = ScoreRegion(id: source.region.id, x: 0.1, y: 0, width: 0.4, height: 0.5)
        let changed = TabRecognitionRegion(url: first.url, source: cropped, rotation: 0, gapAfter: 0)
        XCTAssertNotEqual(id, try GuitarRecognitionIdentity.id(regions: [changed], settings: .standard))
        XCTAssertNotEqual(try GuitarRecognitionIdentity.id(regions: [first, changed], settings: .standard),
                          try GuitarRecognitionIdentity.id(regions: [changed, first], settings: .standard))
    }
}
