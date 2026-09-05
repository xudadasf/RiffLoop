import AVFoundation
import UIKit
import XCTest
@testable import RiffLoop

@MainActor
final class AuditFixtureTests: XCTestCase {
    func testSeedSimulatorOnly() async throws {
        #if targetEnvironment(simulator)
        let store = RiffLoopDocumentStore()
        try store.prepareDirectories()
        let gp = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "transport", withExtension: "gp", subdirectory: "Fixtures"))
        let gpURL = store.folderURL(for: .guitarPro).appendingPathComponent("节奏练习示例.gp")
        try Data(contentsOf: gp).write(to: gpURL)
        let movie = try await makeTransportVideoFixture()
        let movieURL = store.folderURL(for: .video).appendingPathComponent("视频练习示例.mov")
        try Data(contentsOf: movie).write(to: movieURL)
        let pdfURL = store.folderURL(for: .pdf).appendingPathComponent("PDF练习示例.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        try renderer.pdfData { context in
            for page in 1...3 {
                context.beginPage()
                ("RiffLoop · 审查测试谱 第 \(page) 页" as NSString).draw(at: CGPoint(x: 42, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 22)])
                for row in 0..<8 {
                    let y = CGFloat(120 + row * 75)
                    ("\(row * 4 + 1)    1  2  3  4       1  2  3  4" as NSString).draw(at: CGPoint(x: 45, y: y - 20), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
                    for line in 0..<5 {
                        context.cgContext.move(to: CGPoint(x: 45, y: y + CGFloat(line * 6)))
                        context.cgContext.addLine(to: CGPoint(x: 550, y: y + CGFloat(line * 6)))
                        context.cgContext.strokePath()
                    }
                }
            }
        }.write(to: pdfURL)
        let audioURL = store.folderURL(for: .pdf).appendingPathComponent("节拍伴奏示例.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let audio = try AVAudioFile(forWriting: audioURL, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 8)!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][frame] = 0 }
        try audio.write(from: buffer)
        let recent = RecentProjectsStore()
        recent.opened(kind: .pdf, fileName: pdfURL.lastPathComponent)
        recent.opened(kind: .video, fileName: movieURL.lastPathComponent)
        recent.opened(kind: .guitarPro, fileName: gpURL.lastPathComponent)
        UserDefaults.standard.synchronize()
        #else
        throw XCTSkip("Synthetic audit fixtures must never be seeded on a real device")
        #endif
    }
}
