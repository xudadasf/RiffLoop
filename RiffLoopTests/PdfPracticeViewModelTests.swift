import AVFoundation
import XCTest
import UIKit
@testable import RiffLoop

@MainActor
final class PdfPracticeViewModelTests: XCTestCase {
    func testRecordingDraftDoesNotOverwriteSavedTrackAndCancelRestoresIt() async throws {
        let pdf = try makePdf(named: "\(UUID().uuidString).pdf")
        let store = FilePracticeSettingsStore()
        let original = PdfPracticeProfile(readingPoints: [
            PdfReadingPoint(time: 0, pageIndex: 0, verticalProgress: 0),
            PdfReadingPoint(time: 20, pageIndex: 0, verticalProgress: 1)
        ], readingStartCue: "原起点", followLoopEnabled: true)
        try store.save(original, kind: .pdf, fileName: pdf.lastPathComponent)
        let model = PdfPracticeViewModel()
        defer {
            model.pause()
            try? FileManager.default.removeItem(at: pdf)
            store.remove(kind: .pdf, fileName: pdf.lastPathComponent)
        }
        XCTAssertTrue(model.openPdf(at: pdf))
        model.startReadingTrackRecording()
        try await Task.sleep(for: .milliseconds(300))
        model.setVerticalProgress(0.4)
        model.updateAudioSettings() // Unrelated autosaves must retain the original.
        let during = try store.load(PdfPracticeProfile.self, kind: .pdf, fileName: pdf.lastPathComponent)
        XCTAssertEqual(during?.readingPoints, original.readingPoints)
        XCTAssertEqual(during?.readingStartCue, original.readingStartCue)
        XCTAssertEqual(during?.followLoopEnabled, true)
        XCTAssertFalse(model.hasUsableReadingTrack, "Draft must not be playable as a saved track")
        model.cancelReadingTrackRecording()
        XCTAssertEqual(model.readingPoints, original.readingPoints)
        XCTAssertEqual(model.readingStartCue, original.readingStartCue)
        XCTAssertTrue(model.followLoopEnabled)
        XCTAssertTrue(model.hasUsableReadingTrack)
    }

    func testLeavingAndSwitchingPdfDiscardDraftAndPreserveOriginal() async throws {
        let pdf = try makePdf(named: "\(UUID().uuidString).pdf")
        let other = try makePdf(named: "\(UUID().uuidString).pdf")
        let store = FilePracticeSettingsStore()
        let original = PdfPracticeProfile(readingPoints: [
            PdfReadingPoint(time: 0, pageIndex: 0, verticalProgress: 0),
            PdfReadingPoint(time: 10, pageIndex: 0, verticalProgress: 0.9)
        ])
        try store.save(original, kind: .pdf, fileName: pdf.lastPathComponent)
        let model = PdfPracticeViewModel()
        defer {
            model.pause()
            for url in [pdf, other] {
                try? FileManager.default.removeItem(at: url)
                store.remove(kind: .pdf, fileName: url.lastPathComponent)
            }
        }
        XCTAssertTrue(model.openPdf(at: pdf))
        model.startReadingTrackRecording()
        model.pause() // The view calls pause on disappearance/background/interruption.
        XCTAssertEqual(model.readingPoints, original.readingPoints)
        model.startReadingTrackRecording()
        try await Task.sleep(for: .milliseconds(250))
        model.setVerticalProgress(0.3)
        XCTAssertTrue(model.openPdf(at: other))
        XCTAssertTrue(model.readingPoints.isEmpty)
        XCTAssertTrue(model.openPdf(at: pdf))
        XCTAssertEqual(model.readingPoints, original.readingPoints)
        XCTAssertNil(model.readingStartCue, "A draft cue must not leak into a previously uncued track")
    }

    func testExplicitSaveReplacesTrackAndConfirmedDeletePersists() async throws {
        let pdf = try makePdf(named: "\(UUID().uuidString).pdf")
        let store = FilePracticeSettingsStore()
        let model = PdfPracticeViewModel()
        defer {
            model.pause()
            try? FileManager.default.removeItem(at: pdf)
            store.remove(kind: .pdf, fileName: pdf.lastPathComponent)
        }
        XCTAssertTrue(model.openPdf(at: pdf))
        model.startReadingTrackRecording()
        try await Task.sleep(for: .milliseconds(350))
        model.setVerticalProgress(0.8)
        model.finishReadingTrackRecording()
        let saved = model.readingPoints
        XCTAssertTrue(model.hasUsableReadingTrack)
        XCTAssertTrue(model.openPdf(at: pdf))
        XCTAssertEqual(model.readingPoints, saved)
        model.deleteReadingTrack() // UI must request confirmation before this action.
        XCTAssertTrue(model.openPdf(at: pdf))
        XCTAssertTrue(model.readingPoints.isEmpty)
        XCTAssertNil(model.readingStartCue)
    }

    func testSeekingDuringSilentFollowWithBoundAudioKeepsReadingClockRunning() async throws {
        let pdf = try makePdf(named: "\(UUID().uuidString).pdf")
        let audio = try makeTransportAudioFixture()
        let store = FilePracticeSettingsStore()
        let model = PdfPracticeViewModel()
        defer {
            model.pause()
            try? FileManager.default.removeItem(at: pdf)
            try? FileManager.default.removeItem(at: audio)
            store.remove(kind: .pdf, fileName: pdf.lastPathComponent)
        }
        try store.save(PdfPracticeProfile(metronomeEnabled: false, readingPoints: [
            PdfReadingPoint(time: 0, pageIndex: 0, verticalProgress: 0),
            PdfReadingPoint(time: 4, pageIndex: 0, verticalProgress: 1)
        ]), kind: .pdf, fileName: pdf.lastPathComponent)
        XCTAssertTrue(model.openPdf(at: pdf))
        model.bindAudio(at: audio)
        model.startAutoFollowFromBeginning()
        try await waitForTransport { model.isAudioPlaying && model.currentTime > 0.1 }
        model.pauseAudio()
        model.seek(to: 1)
        try await waitForTransport { model.currentTime > 1.2 }
        XCTAssertTrue(model.isFollowingTransportActive)
        XCTAssertFalse(model.isAudioPlaying)
        XCTAssertFalse(model.isMetronomePlaying)
        XCTAssertGreaterThan(model.verticalProgress, 0.25)
    }

    func testRecordingStartsMetronomeAndSavesUsableTrack() async throws {
        let pdf = try makePdf(named: "\(UUID().uuidString).pdf")
        let model = PdfPracticeViewModel()
        defer {
            model.pause()
            try? FileManager.default.removeItem(at: pdf)
            FilePracticeSettingsStore().remove(kind: .pdf, fileName: pdf.lastPathComponent)
        }
        XCTAssertTrue(model.openPdf(at: pdf))
        model.startReadingTrackRecording()
        XCTAssertTrue(model.isMetronomePlaying)
        try await Task.sleep(for: .milliseconds(500))
        model.setVerticalProgress(0.8)
        model.finishReadingTrackRecording()
        XCTAssertTrue(model.hasUsableReadingTrack)
        XCTAssertNotNil(model.readingStartCue)
        XCTAssertTrue(model.isMetronomePlaying)
        model.toggleReadingFollowPlayback()
        XCTAssertTrue(model.isFollowingTransportActive)
        model.toggleMetronomePlayback()
        let time = model.currentTime
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(model.isMetronomePlaying)
        XCTAssertTrue(model.isFollowingTransportActive)
        XCTAssertGreaterThan(model.currentTime, time)
        model.toggleMetronomePlayback()
        model.toggleReadingFollowPlayback()
        XCTAssertFalse(model.isAutoFollowing)
        XCTAssertTrue(model.isMetronomePlaying, "Stopping follow must keep the independent metronome running")
    }

    func testSilentFollowingWorksWithoutAudioAndStopsOnPause() async throws {
        let pdf = try makePdf(named: "\(UUID().uuidString).pdf")
        let store = FilePracticeSettingsStore()
        defer {
            try? FileManager.default.removeItem(at: pdf)
            store.remove(kind: .pdf, fileName: pdf.lastPathComponent)
        }
        try store.save(PdfPracticeProfile(metronomeEnabled: false, readingPoints: [
            PdfReadingPoint(time: 0, pageIndex: 0, verticalProgress: 0),
            PdfReadingPoint(time: 2, pageIndex: 0, verticalProgress: 1)
        ]), kind: .pdf, fileName: pdf.lastPathComponent)
        let model = PdfPracticeViewModel()
        XCTAssertTrue(model.openPdf(at: pdf))
        model.startAutoFollowFromBeginning()
        defer { model.pause() }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(model.isFollowingTransportActive)
        XCTAssertFalse(model.isMetronomePlaying)
        XCTAssertGreaterThan(model.verticalProgress, 0)
        model.pause()
        let time = model.currentTime
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(time, model.currentTime)
    }
    func testFiftyAudioFollowLoopsThenInterruptionStopsTransport() async throws {
        let pdf = try makePdf(named: "\(UUID().uuidString).pdf")
        let audio = try makeTransportAudioFixture(duration: 1.5)
        let store = FilePracticeSettingsStore()
        defer {
            try? FileManager.default.removeItem(at: pdf)
            try? FileManager.default.removeItem(at: audio)
            store.remove(kind: .pdf, fileName: pdf.lastPathComponent)
        }
        try store.save(PdfPracticeProfile(metronomeEnabled: false, readingPoints: [
            PdfReadingPoint(time: 0.4, pageIndex: 0, verticalProgress: 0),
            PdfReadingPoint(time: 1.5, pageIndex: 0, verticalProgress: 0.8)
        ], followLoopEnabled: true), kind: .pdf, fileName: pdf.lastPathComponent)
        let model = PdfPracticeViewModel()
        XCTAssertTrue(model.openPdf(at: pdf))
        model.bindAudio(at: audio)
        model.startAutoFollowFromBeginning()
        defer { model.pause() }
        try await waitForTransport { model.isAudioPlaying && model.currentTime >= 0.4 }
        var previous = model.currentTime
        var rounds = 0
        try await waitForTransport(timeout: 100) {
            if model.currentTime < previous - 0.2 { rounds += 1 }
            previous = model.currentTime
            return rounds >= 50
        }
        XCTAssertTrue(model.isFollowingTransportActive)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        try await waitForTransport { !model.isPlaying }
        let stoppedTime = model.currentTime
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.player.rate, 0)
        XCTAssertEqual(model.currentTime, stoppedTime)
    }

    func testMetronomeOnlyFollowLoopsWithoutAnAudioItem() async throws {
        let pdf = try makePdf(named: "\(UUID().uuidString).pdf")
        let store = FilePracticeSettingsStore()
        defer {
            try? FileManager.default.removeItem(at: pdf)
            store.remove(kind: .pdf, fileName: pdf.lastPathComponent)
        }
        try store.save(PdfPracticeProfile(readingPoints: [
            PdfReadingPoint(time: 1, pageIndex: 0, verticalProgress: 0),
            PdfReadingPoint(time: 1.5, pageIndex: 0, verticalProgress: 0.8)
        ], followLoopEnabled: true), kind: .pdf, fileName: pdf.lastPathComponent)
        let model = PdfPracticeViewModel()
        XCTAssertTrue(model.openPdf(at: pdf))
        model.startAutoFollowFromBeginning()
        defer { model.pause() }
        try await waitForTransport { model.isPlaying }
        try await Task.sleep(for: .seconds(2))
        XCTAssertGreaterThanOrEqual(model.currentTime, 0.9)
        XCTAssertLessThan(model.currentTime, 1.6, "The metronome clock must return to the first reading point every round")
        XCTAssertTrue(model.isFollowingTransportActive)
        model.setFollowLoopEnabled(false)
        try await waitForTransport { model.currentTime > 1.7 }
        model.pause()
        let pausedTime = model.currentTime
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.currentTime, pausedTime)
    }

    func testFollowLoopsAtAudioEndAndPauseStopsFurtherRounds() async throws {
        let pdf = try makePdf(named: "\(UUID().uuidString).pdf")
        let audio = try makeTransportAudioFixture(duration: 1.5)
        let store = FilePracticeSettingsStore()
        defer {
            try? FileManager.default.removeItem(at: pdf)
            try? FileManager.default.removeItem(at: audio)
            store.remove(kind: .pdf, fileName: pdf.lastPathComponent)
        }
        try store.save(PdfPracticeProfile(metronomeEnabled: false, readingPoints: [
            PdfReadingPoint(time: 0.4, pageIndex: 0, verticalProgress: 0),
            PdfReadingPoint(time: 1.5, pageIndex: 0, verticalProgress: 0.8)
        ], followLoopEnabled: true), kind: .pdf, fileName: pdf.lastPathComponent)
        let model = PdfPracticeViewModel()
        XCTAssertTrue(model.openPdf(at: pdf))
        model.bindAudio(at: audio)
        model.startAutoFollowFromBeginning()
        defer { model.pause() }
        // Do not count the initial 0 -> first-point seek as a completed round.
        try await waitForTransport { model.isAudioPlaying && model.currentTime >= 0.4 }
        var previous = model.currentTime
        var rounds = 0
        try await waitForTransport(timeout: 6) {
            if model.currentTime < previous - 0.2 { rounds += 1 }
            previous = model.currentTime
            return rounds >= 2
        }
        XCTAssertTrue(model.isFollowingTransportActive)
        model.pause()
        model.stopReadingFollowPlayback()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.currentTime, 0.4, accuracy: 0.05)
        XCTAssertEqual(model.requestedProgress, 0)
    }

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
                audioVolume: 99,
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
        XCTAssertEqual(viewModel.audioVolume, 2)
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
