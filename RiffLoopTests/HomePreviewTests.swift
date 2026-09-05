import PDFKit
import AVFoundation
import UIKit
import XCTest
import WebKit
@testable import RiffLoop

@MainActor
final class HomePreviewTests: XCTestCase {
    func testGpPreviewFitsCardAndRecoversAfterInvalidOrRapidReplacement() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 192, height: 128))
        controller.view.addSubview(web)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let root = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("GpWeb"))
        web.loadFileURL(root.appendingPathComponent("preview.html"), allowingReadAccessTo: root)
        try await wait(web, "Boolean(window.renderPreview)")
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "transport", withExtension: "gp", subdirectory: "Fixtures"))
        let base64 = try Data(contentsOf: url).base64EncodedString()
        _ = try await web.evaluateJavaScript("window.renderPreview('broken', 'Unsupported file')")
        try await wait(web, "!document.getElementById('fallback').hidden")
        _ = try await web.evaluateJavaScript("window.renderPreview('\(base64)', 'First'); window.renderPreview('\(base64)', 'Latest')")
        try await wait(web, "document.getElementById('score').style.visibility === 'visible' && document.getElementById('fallback').textContent === 'Latest'")
        let fits = try await web.evaluateJavaScript("""
            (() => {
                const rect = document.getElementById('score').getBoundingClientRect();
                return rect.width > 0 && rect.left >= -1 && rect.right <= innerWidth + 1 &&
                    rect.top >= -1 && rect.bottom <= innerHeight + 1 &&
                    !document.getElementById('score').textContent.includes('RiffLoop-Test') &&
                    preview.settings.player.playerMode === alphaTab.PlayerMode.Disabled;
            })()
            """)
        XCTAssertEqual(fits as? Bool, true, "Preview must fit the card without duplicate title or audio")
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: web.bounds).image { _ in
            web.drawHierarchy(in: web.bounds, afterScreenUpdates: true)
        })
        attachment.name = "GP opening thumbnail at actual card size"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func wait(_ web: WKWebView, _ expression: String) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let value = try? await web.evaluateJavaScript(expression), value as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Preview timed out: \(expression)")
        throw NSError(domain: "PreviewTest", code: 1)
    }

    func testVideoPreviewUsesOpeningFrameInsteadOfLaterContent() async throws {
        let url = try await makeTransportVideoFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let openingImage = await projectOpeningPreview(at: url, kind: .video)
        let preview = try XCTUnwrap(openingImage)
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(try XCTUnwrap(preview.cgImage), in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThan(rgba[0], 200, "The first frame is red; later frames are blue")
        XCTAssertLessThan(rgba[2], 40)
    }

    func testPdfPreviewKeepsTopOfFirstPageInsteadOfCentreOrLastPage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 1200)).pdfData { context in
            context.beginPage()
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 1200))
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            context.beginPage()
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 1200))
        }
        try data.write(to: url)
        let openingImage = await projectOpeningPreview(at: url, kind: .pdf)
        let preview = try XCTUnwrap(openingImage)
        let pixel = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in
            preview.draw(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let image = try XCTUnwrap(pixel.cgImage)
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThan(rgba[0], 220)
        XCTAssertLessThan(rgba[1], 30)
        XCTAssertLessThan(rgba[2], 30)
    }
}

@MainActor
func makeTransportVideoFixture() async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90
    ])
    let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<80 {
        while !input.isReadyForMoreMediaData, writer.status == .writing {
            try await Task.sleep(for: .milliseconds(5))
        }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adapter.pixelBufferPool), &pixelBuffer)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 160, height: 90,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(frame == 0 ? UIColor.red.cgColor : UIColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        XCTAssertTrue(adapter.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "Video fixture encoding failed")
    return url
}
