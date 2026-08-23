import XCTest
import UIKit
@testable import RiffLoop

@MainActor
final class PdfPracticeViewModelTests: XCTestCase {
    func testManualSpeedKeepsLadderTargetReachable() {
        let viewModel = PdfPracticeViewModel()

        viewModel.setPlaybackRate(1.25)
        viewModel.setSpeedLadderTarget(0.8)

        XCTAssertEqual(viewModel.playbackRate, 1.25)
        XCTAssertEqual(viewModel.speedLadderTarget, 1.25)
    }

    func testInvalidPdfDoesNotBecomeTheOpenDocument() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("not a PDF".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let viewModel = PdfPracticeViewModel()

        XCTAssertFalse(viewModel.openPdf(at: url))
        XCTAssertNil(viewModel.pdfFileName)
        XCTAssertNil(viewModel.document)
    }

    func testOpeningPdfWithoutBackingClearsPreviousPdfTransport() throws {
        let firstPdf = try makePdf(named: "\(UUID().uuidString)-first.pdf")
        let secondPdf = try makePdf(named: "\(UUID().uuidString)-second.pdf")
        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp3")
        try Data([0, 1, 2, 3]).write(to: audio)
        defer {
            try? FileManager.default.removeItem(at: firstPdf)
            try? FileManager.default.removeItem(at: secondPdf)
            try? FileManager.default.removeItem(at: audio)
        }
        let viewModel = PdfPracticeViewModel()

        XCTAssertTrue(viewModel.openPdf(at: firstPdf))
        viewModel.bindAudio(at: audio, restoringPosition: 42)
        XCTAssertNotNil(viewModel.player.currentItem)
        XCTAssertEqual(viewModel.currentTime, 42)

        XCTAssertTrue(viewModel.openPdf(at: secondPdf))
        XCTAssertNil(viewModel.player.currentItem)
        XCTAssertNil(viewModel.audioFileName)
        XCTAssertEqual(viewModel.currentTime, 0)
        XCTAssertEqual(viewModel.duration, 0)
    }

    func testDeletingOpenPdfDoesNotRecreateRemovedSettings() throws {
        let pdf = try makePdf(named: "\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: pdf) }
        let settingsStore = FilePracticeSettingsStore()
        let viewModel = PdfPracticeViewModel()
        XCTAssertTrue(viewModel.openPdf(at: pdf))
        settingsStore.remove(kind: .pdf, fileName: pdf.lastPathComponent)

        XCTAssertTrue(viewModel.pdfWasDeleted(at: pdf))
        viewModel.pause()

        XCTAssertNil(
            try settingsStore.load(
                PdfPracticeProfile.self,
                kind: .pdf,
                fileName: pdf.lastPathComponent
            )
        )
    }

    func testOpeningPdfClampsPersistedTransportValues() throws {
        let pdf = try makePdf(named: "\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: pdf) }
        let settingsStore = FilePracticeSettingsStore()
        try settingsStore.save(
            PdfPracticeProfile(
                playbackRate: 0,
                audioVolume: 2,
                bpm: 999,
                synchronizationOffset: 2,
                metronomeVolume: -1
            ),
            kind: .pdf,
            fileName: pdf.lastPathComponent
        )
        defer { settingsStore.remove(kind: .pdf, fileName: pdf.lastPathComponent) }
        let viewModel = PdfPracticeViewModel()

        XCTAssertTrue(viewModel.openPdf(at: pdf))

        XCTAssertEqual(viewModel.playbackRate, 0.25)
        XCTAssertEqual(viewModel.audioVolume, 1)
        XCTAssertEqual(viewModel.bpm, 300)
        XCTAssertEqual(viewModel.synchronizationOffset, 0.5)
        XCTAssertEqual(viewModel.metronomeVolume, 0)
    }

    private func makePdf(named name: String) throws -> URL {
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: 200, height: 200)
        )
        let data = renderer.pdfData { context in
            context.beginPage()
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
