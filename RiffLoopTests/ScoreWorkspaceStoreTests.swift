import XCTest
@testable import RiffLoop

final class ScoreWorkspaceStoreTests: XCTestCase {
    func testImportCopiesAndDuplicateNamesDoNotOverwriteSourceOrFirstCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("谱面.pdf")
        let original = Data("source".utf8)
        try original.write(to: source)
        let store = ScoreWorkspaceStore(folder: root.appendingPathComponent("workspace"))

        let first = try await store.importCopy(from: source)
        try Data("updated source".utf8).write(to: source)
        let second = try await store.importCopy(from: source)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), original)
        XCTAssertEqual(try Data(contentsOf: second), Data("updated source".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("updated source".utf8))
        let files = try await store.files()
        XCTAssertEqual(files.count, 2)
    }

    func testDeletingCopyDoesNotDeleteOriginalAndCannotDeleteOutsideWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("image.png")
        try Data("image".utf8).write(to: source)
        let store = ScoreWorkspaceStore(folder: root.appendingPathComponent("workspace"))
        let copy = try await store.importCopy(from: source)

        do {
            try await store.removeCopy(source)
            XCTFail("Must reject deleting an original outside the workspace")
        } catch ScoreWorkspaceError.invalidRemoval {
            // Expected.
        }
        try await store.removeCopy(copy)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }

    func testUnsupportedOrMissingFileDoesNotLeavePartialCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScoreWorkspaceStore(folder: root.appendingPathComponent("workspace"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder.pdf"), withIntermediateDirectories: true)

        for name in ["not-a-score.txt", "missing.pdf", "folder.pdf"] {
            do {
                _ = try await store.importCopy(from: root.appendingPathComponent(name))
                XCTFail("Must reject unsupported or missing input")
            } catch { }
        }
        let files = try await store.files()
        XCTAssertTrue(files.isEmpty)
        let folderContents = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("workspace").path)
        XCTAssertTrue(folderContents.isEmpty)
    }
}
