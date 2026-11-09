import ImageIO
import PDFKit
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import RiffLoop

@MainActor
final class ScorePageRendererTests: XCTestCase {
    func testPhotoPreviewMatchesOriginalDrawingForEveryExifOrientation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = makeTestImage()
        let cgImage = try XCTUnwrap(image.cgImage)

        for exif in 1...8 {
            let url = folder.appendingPathComponent("orientation-\(exif).jpg")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
            ))
            let properties: [String: Any] = [
                kCGImagePropertyOrientation as String: exif,
                kCGImageDestinationLossyCompressionQuality as String: 1.0,
            ]
            CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let original = try XCTUnwrap(UIImage(contentsOfFile: url.path))
            let expectedOrientations: [UIImage.Orientation] = [
                .up, .upMirrored, .down, .downMirrored, .leftMirrored, .right, .rightMirrored, .left,
            ]
            XCTAssertEqual(original.imageOrientation, expectedOrientations[exif - 1], "EXIF test image must retain its orientation")
            let raw = try XCTUnwrap(original.cgImage)
            let swapped: Bool
            switch original.imageOrientation {
            case .left, .right, .leftMirrored, .rightMirrored: swapped = true
            default: swapped = false
            }
            let size = CGSize(width: CGFloat(swapped ? raw.height : raw.width),
                              height: CGFloat(swapped ? raw.width : raw.height))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            // This is the original preview path, used as the coordinate reference.
            let reference = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                original.draw(in: CGRect(origin: .zero, size: size))
            }
            let preview = await Task.detached {
                ScorePageRenderer.render(source: url, index: 0)
            }.value
            XCTAssertNil(preview.error, "EXIF \(exif)")
            XCTAssertEqual(preview.pageCount, 1)
            XCTAssertEqual(preview.orientation, original.imageOrientation.rawValue, "EXIF \(exif)")
            let rendered = try XCTUnwrap(preview.image)
            XCTAssertEqual(rendered.size, size, "EXIF \(exif)")
            try assertMatchingSamples(reference, rendered, label: "EXIF \(exif)")
        }
    }

    func testLargeImagePreviewHasBoundedDimensions() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4096, height: 128), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4096, height: 128))
        }
        try XCTUnwrap(image.pngData()).write(to: url)
        let preview = await Task.detached {
            ScorePageRenderer.render(source: url, index: 0)
        }.value
        let result = try XCTUnwrap(preview.image?.cgImage)
        XCTAssertLessThanOrEqual(max(result.width, result.height), 2048)
        XCTAssertEqual(result.width, 2048)
        XCTAssertEqual(result.height, 64)
    }

    func testPdfPageCountAndRotatedPageRejection() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("pages.pdf")
        let document = PDFDocument()
        let first = try XCTUnwrap(PDFPage(image: makeTestImage()))
        let second = try XCTUnwrap(PDFPage(image: makeTestImage()))
        second.rotation = 90
        document.insert(first, at: 0)
        document.insert(second, at: 1)
        XCTAssertTrue(document.write(to: url))
        let written = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(written.page(at: 1)?.rotation, 90)

        let normal = await Task.detached {
            ScorePageRenderer.render(source: url, index: 0)
        }.value
        XCTAssertEqual(normal.pageCount, 2)
        XCTAssertNotNil(normal.image)
        XCTAssertNil(normal.error)
        XCTAssertEqual(normal.orientation, 0)
        let rotated = await Task.detached {
            ScorePageRenderer.render(source: url, index: 1)
        }.value
        XCTAssertEqual(rotated.pageCount, 2)
        XCTAssertNil(rotated.image)
        XCTAssertNotNil(rotated.error)
    }

    func testSmallPdfPreviewIsSharpAndKeepsCropBoxCoordinates() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cropped.pdf")
        let document = PDFDocument()
        let page = try XCTUnwrap(PDFPage(image: makeTestImage()))
        // A nonzero crop origin exercises the mapping from saved normalized
        // regions to the visible page, rather than only testing full pages.
        page.setBounds(CGRect(x: 20, y: 10, width: 80, height: 60), for: .cropBox)
        document.insert(page, at: 0)
        XCTAssertTrue(document.write(to: url))
        let savedDocument = try XCTUnwrap(PDFDocument(url: url))
        let savedPage = try XCTUnwrap(savedDocument.page(at: 0))
        let crop = savedPage.bounds(for: .cropBox)
        XCTAssertEqual(crop.origin.x, 20, accuracy: 0.01)
        XCTAssertEqual(crop.origin.y, 10, accuracy: 0.01)

        let preview = await Task.detached {
            ScorePageRenderer.render(source: url, index: 0)
        }.value
        XCTAssertNil(preview.error)
        let image = try XCTUnwrap(preview.image)
        let bitmap = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(bitmap.width, 2048)
        XCTAssertEqual(bitmap.height, 1536)
        XCTAssertLessThanOrEqual(max(bitmap.width, bitmap.height), 2048)

        // Compare the new preview against PDFKit's established CropBox view.
        // Rasterize both at a fixed scale to compare matching normalized points.
        let sampleSize = CGSize(width: 80, height: 60)
        let reference = savedPage.thumbnail(of: sampleSize, for: .cropBox)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        func resized(_ source: UIImage) -> UIImage {
            UIGraphicsImageRenderer(size: sampleSize, format: format).image { _ in
                source.draw(in: CGRect(origin: .zero, size: sampleSize))
            }
        }
        try assertMatchingSamples(resized(reference), resized(image), label: "PDF CropBox")
    }

    func testLargePdfPagePreviewRemainsBounded() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("large-page.pdf")
        let pageRect = CGRect(x: 0, y: 0, width: 4096, height: 2048)
        let data = UIGraphicsPDFRenderer(bounds: pageRect).pdfData { context in
            context.beginPage()
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4096, height: 2048))
        }
        try data.write(to: url)
        let preview = await Task.detached {
            ScorePageRenderer.render(source: url, index: 0)
        }.value
        XCTAssertNil(preview.error)
        let bitmap = try XCTUnwrap(preview.image?.cgImage)
        XCTAssertEqual(bitmap.width, 2048)
        XCTAssertEqual(bitmap.height, 1024)
    }

    func testSmallPdfThinVectorLineSurvivesPreviewRendering() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 100)).pdfData { context in
            context.beginPage()
            UIColor.black.setStroke()
            let line = UIBezierPath()
            line.lineWidth = 0.15
            line.move(to: CGPoint(x: 50, y: 10))
            line.addLine(to: CGPoint(x: 50, y: 90))
            line.stroke()
        }
        try data.write(to: url)
        let preview = await Task.detached {
            ScorePageRenderer.render(source: url, index: 0)
        }.value
        let bitmap = try XCTUnwrap(preview.image?.cgImage)
        XCTAssertEqual(bitmap.width, 2048)
        XCTAssertEqual(bitmap.height, 1024)
        var pixels = [UInt8](repeating: 255, count: bitmap.width * bitmap.height)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: bitmap.width, height: bitmap.height,
                                          bitsPerComponent: 8, bytesPerRow: bitmap.width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: CGFloat(bitmap.width), height: CGFloat(bitmap.height)))
            return true
        }
        XCTAssertTrue(rendered)
        let row = bitmap.height / 2 * bitmap.width
        let expectedX = bitmap.width / 4
        let linePixels = (expectedX - 4...expectedX + 4).map { pixels[row + $0] }
        let clearPixels = (expectedX - 110...expectedX - 100).map { pixels[row + $0] }
        XCTAssertLessThan(try XCTUnwrap(linePixels.min()), 220)
        XCTAssertGreaterThan(try XCTUnwrap(clearPixels.min()), 245)
    }

    private func makeTestImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80), format: format).image { context in
            let colors: [UIColor] = [.red, .green, .blue, .yellow, .magenta, .cyan]
            for row in 0..<2 {
                for column in 0..<3 {
                    colors[row * 3 + column].setFill()
                    context.fill(CGRect(x: CGFloat(column * 40), y: CGFloat(row * 40), width: 40, height: 40))
                }
            }
        }
    }

    private func assertMatchingSamples(_ first: UIImage, _ second: UIImage, label: String,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let firstImage = try XCTUnwrap(first.cgImage, file: file, line: line)
        let secondImage = try XCTUnwrap(second.cgImage, file: file, line: line)
        XCTAssertEqual(firstImage.width, secondImage.width, label, file: file, line: line)
        XCTAssertEqual(firstImage.height, secondImage.height, label, file: file, line: line)
        guard firstImage.width == secondImage.width, firstImage.height == secondImage.height else { return }
        let width = firstImage.width, height = firstImage.height
        func pixels(_ image: CGImage) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
                return true
            }
            XCTAssertTrue(rendered, file: file, line: line)
            return bytes
        }
        let expected = try pixels(firstImage)
        let actual = try pixels(secondImage)
        for y in [1, 3, 5, 7].map({ height * $0 / 8 }) {
            for x in [1, 3, 5, 7].map({ width * $0 / 8 }) {
                for channel in 0..<3 {
                    let index = (y * width + x) * 4 + channel
                    XCTAssertLessThanOrEqual(abs(Int(expected[index]) - Int(actual[index])), 15,
                                             "\(label): sample \(x),\(y), channel \(channel)",
                                             file: file, line: line)
                }
            }
        }
    }
}
