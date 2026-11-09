import ImageIO
import PDFKit
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import RiffLoop

@MainActor
final class ScoreMaterialThumbnailTests: XCTestCase {
    func testImageThumbnailUsesExifOrientationAndKeepsSource() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("photo.jpg")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let original = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 320), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 320))
        }
        let cgImage = try XCTUnwrap(original.cgImage)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [String: Any] = [kCGImagePropertyOrientation as String: 6]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let sourceData = try Data(contentsOf: source)

        let thumbnail = await ScoreMaterialThumbnailLoader.shared.load(source)
        let result = try XCTUnwrap(thumbnail.image?.cgImage)
        XCTAssertLessThanOrEqual(max(result.width, result.height), 160)
        XCTAssertGreaterThan(result.height, result.width, "EXIF rotation must be applied")
        XCTAssertEqual(try Data(contentsOf: source), sourceData)
    }

    func testPdfFirstPageAndInvalidFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("score.pdf")
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            context.beginPage()
            UIColor.black.setFill()
            context.fill(CGRect(x: 20, y: 20, width: 100, height: 100))
        }
        try data.write(to: source)
        let pdf = await ScoreMaterialThumbnailLoader.shared.load(source)
        let image = try XCTUnwrap(pdf.image)
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 160)
        XCTAssertEqual(try Data(contentsOf: source), data)

        let invalid = folder.appendingPathComponent("invalid.jpg")
        try Data("invalid".utf8).write(to: invalid)
        let placeholder = await ScoreMaterialThumbnailLoader.shared.load(invalid)
        XCTAssertNil(placeholder.image)
    }

    func testCachedThumbnailDoesNotSurviveReplacementOrRemoval() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("score.png")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        func png(width: CGFloat, height: CGFloat) throws -> Data {
            let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
                UIColor.blue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            return try XCTUnwrap(image.pngData())
        }
        try png(width: 100, height: 50).write(to: source, options: .atomic)
        let first = await ScoreMaterialThumbnailLoader.shared.load(source)
        let firstImage = try XCTUnwrap(first.image?.cgImage)
        XCTAssertGreaterThan(firstImage.width, firstImage.height)

        let replacement = try png(width: 50, height: 100)
        try replacement.write(to: source, options: .atomic)
        let second = await ScoreMaterialThumbnailLoader.shared.load(source)
        let secondImage = try XCTUnwrap(second.image?.cgImage)
        XCTAssertGreaterThan(secondImage.height, secondImage.width)
        XCTAssertEqual(try Data(contentsOf: source), replacement)

        try FileManager.default.removeItem(at: source)
        let missing = await ScoreMaterialThumbnailLoader.shared.load(source)
        XCTAssertNil(missing.image)
    }
}
