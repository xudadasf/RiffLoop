import UIKit
import XCTest
@testable import RiffLoop

@MainActor
final class ScorePhotoImportTests: XCTestCase {
    func testImageContentDeterminesExtensionAndSourceIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let bytes = try XCTUnwrap(image.pngData())
        let source = root.appendingPathComponent("picker-item.bin")
        try bytes.write(to: source)

        let first = try ScorePhotoImport.copyForImport(from: source, temporaryFolder: root)
        let second = try ScorePhotoImport.copyForImport(from: source, temporaryFolder: root)

        XCTAssertEqual(first.temporaryURL.pathExtension, "png")
        XCTAssertNotEqual(first.temporaryURL, second.temporaryURL)
        XCTAssertEqual(try Data(contentsOf: first.temporaryURL), bytes)
        XCTAssertEqual(try Data(contentsOf: second.temporaryURL), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testInvalidImageIsRejectedWithoutCreatingCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("not-a-photo.jpg")
        try Data("not an image".utf8).write(to: source)

        XCTAssertThrowsError(try ScorePhotoImport.copyForImport(from: source, temporaryFolder: root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["not-a-photo.jpg"])
    }

    func testPickerCopyCanBeImportedAndRemovedWithoutAffectingSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let bytes = try XCTUnwrap(image.pngData())
        let source = root.appendingPathComponent("picker.bin")
        try bytes.write(to: source)
        let photo = try ScorePhotoImport.copyForImport(from: source, temporaryFolder: root)
        let store = ScoreWorkspaceStore(folder: root.appendingPathComponent("workspace"))

        let imported = try await store.importCopy(from: photo.temporaryURL)
        try FileManager.default.removeItem(at: photo.temporaryURL)
        XCTAssertEqual(try Data(contentsOf: imported), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        try await store.removeCopy(imported)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
}
