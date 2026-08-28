import AVFoundation
import XCTest
@testable import RiffLoop

@MainActor
final class PracticeViewModelTests: XCTestCase {
    func testPausedSeekThenPlayUsesNewPosition() async throws {
        let url = try await makeTransportVideoFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PracticeViewModel()
        model.openMedia(at: url)
        defer { model.pause() }
        model.togglePlayback()
        try await waitForTransport { model.currentTime > 0.25 }
        model.pause()
        XCTAssertGreaterThan(model.duration, 7)
        model.seek(to: 5)
        try await waitForTransport { abs(model.currentTime - 5) < 0.05 }
        model.togglePlayback()
        try await waitForTransport { model.player.timeControlStatus == .playing }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertGreaterThan(model.player.currentTime().seconds, 5)
        XCTAssertLessThan(model.player.currentTime().seconds, 6)
    }

    func testPlayImmediatelyAfterSeekKeepsLatestTarget() async throws {
        let url = try makeTransportAudioFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PracticeViewModel()
        model.openMedia(at: url)
        defer { model.pause() }
        model.togglePlayback()
        try await waitForTransport { model.currentTime > 0.25 }
        model.pause()
        XCTAssertGreaterThan(model.duration, 7)
        model.seek(to: 2)
        model.seek(to: 5)
        model.togglePlayback()
        try await waitForTransport { model.player.timeControlStatus == .playing }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertGreaterThan(model.player.currentTime().seconds, 5)
    }

    func testDisabledLoopDoesNotOverrideSeekOnResume() async throws {
        let url = try makeTransportAudioFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PracticeViewModel()
        model.openMedia(at: url)
        defer { model.pause() }
        model.togglePlayback()
        try await waitForTransport { model.currentTime > 0.25 }
        model.pause()
        XCTAssertGreaterThan(model.duration, 7)
        model.pointA = 1
        model.pointB = 2
        model.loopEnabled = false
        model.seek(to: 5)
        try await waitForTransport { abs(model.currentTime - 5) < 0.05 }
        model.togglePlayback()
        try await waitForTransport { model.player.timeControlStatus == .playing }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertGreaterThan(model.player.currentTime().seconds, 5)
    }

    func testRapidSkipsKeepPlayingAndPauseCancelsPendingResume() async throws {
        let url = try makeTransportAudioFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PracticeViewModel()
        model.openMedia(at: url)
        defer { model.pause() }
        model.togglePlayback()
        try await waitForTransport { model.currentTime > 0.25 }
        model.skip(by: 5)
        model.skip(by: -5)
        model.skip(by: 5)
        try await waitForTransport { model.player.currentTime().seconds > 5 && model.player.rate > 0 }
        XCTAssertTrue(model.isPlaying)
        model.seek(to: 2)
        model.pause()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.player.rate, 0)
        XCTAssertEqual(model.currentTime, 2, accuracy: 0.05)
        model.togglePlayback()
        try await waitForTransport { model.player.timeControlStatus == .playing }
        XCTAssertGreaterThanOrEqual(model.player.currentTime().seconds, 1.95)
        XCTAssertLessThan(model.player.currentTime().seconds, 3)
    }

    func testLoopAtFileEndIgnoresPreviousRoundsEndNotification() async throws {
        let url = try makeTransportAudioFixture(duration: 1.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PracticeViewModel()
        model.metronomeEnabled = false
        model.openMedia(at: url)
        defer { model.pause() }
        try await waitForTransport { model.isMediaReady }
        model.pointA = 0.25
        model.pointB = 1.5
        model.setLoopEnabled(true)
        model.togglePlayback()
        try await waitForTransport(timeout: 6) { model.completedLoops >= 2 }
        XCTAssertTrue(model.isPlaying)
    }
}

@MainActor
func waitForTransport(
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ predicate: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(predicate(), "Transport condition timed out", file: file, line: line)
}

func makeTransportAudioFixture(duration: Double = 8) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(44_100 * duration))!
    buffer.frameLength = buffer.frameCapacity
    buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
    let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
    try audioFile.write(from: buffer)
    return url
}
