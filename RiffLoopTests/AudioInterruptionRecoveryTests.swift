import AVFAudio
import XCTest
@testable import RiffLoop

@MainActor
final class AudioInterruptionRecoveryTests: XCTestCase {
    func testPermittedEndWhileInactiveWaitsForActivationAndCanBeCancelled() {
        let recovery = AudioInterruptionRecovery()
        var starts = 0
        recovery.onBegan = { { starts += 1 } }
        let began = AVAudioSession.InterruptionType.began.rawValue
        let ended = AVAudioSession.InterruptionType.ended.rawValue
        let allowed = AVAudioSession.InterruptionOptions.shouldResume.rawValue
        recovery.handle(type: began, options: 0, outputs: ["Spark USB"], active: false)
        recovery.handle(type: ended, options: allowed, outputs: ["Spark USB"], active: false)
        XCTAssertEqual(starts, 0)
        recovery.becameActive(outputs: ["Spark USB"])
        recovery.becameActive(outputs: ["Spark USB"])
        XCTAssertEqual(starts, 1)
        for cancel in [true, false] {
            recovery.handle(type: began, options: 0, outputs: ["Spark USB"], active: true)
            recovery.handle(type: ended, options: allowed, outputs: ["Spark USB"], active: false)
            if cancel { recovery.cancel() }
            recovery.becameActive(outputs: cancel ? ["Spark USB"] : ["Speaker"])
            XCTAssertEqual(starts, 1, "Manual pause, background and changed outputs must prevent deferred resume")
        }
    }

    func testOnlyInterruptedPlaybackOnSameOutputResumesOnce() {
        let recovery = AudioInterruptionRecovery()
        var playing = true, starts = 0
        recovery.onBegan = {
            guard playing else { return nil }
            playing = false
            return { playing = true; starts += 1 }
        }
        let began = AVAudioSession.InterruptionType.began.rawValue
        let ended = AVAudioSession.InterruptionType.ended.rawValue
        let allowed = AVAudioSession.InterruptionOptions.shouldResume.rawValue
        recovery.handle(type: began, options: 0, outputs: ["Spark USB"], active: true)
        XCTAssertFalse(playing)
        recovery.handle(type: began, options: 0, outputs: ["Spark USB"], active: true)
        recovery.handle(type: ended, options: allowed, outputs: ["Spark USB"], active: true)
        recovery.handle(type: ended, options: allowed, outputs: ["Spark USB"], active: true)
        XCTAssertTrue(playing)
        XCTAssertEqual(starts, 1)
        for reason in ["user", "disconnect", "differentOutput", "background", "notAllowed"] {
            playing = true
            recovery.handle(type: began, options: 0, outputs: ["Spark USB"], active: true)
            if reason == "user" { recovery.cancel() }
            if reason == "disconnect" { recovery.disconnect() }
            recovery.handle(type: ended, options: reason == "notAllowed" ? 0 : allowed,
                outputs: reason == "differentOutput" ? ["Speaker"] : ["Spark USB"],
                active: reason != "background")
            XCTAssertFalse(playing, reason)
        }
        recovery.handle(type: began, options: 0, outputs: ["Spark USB"], active: true)
        recovery.handle(type: ended, options: allowed, outputs: ["Spark USB"], active: true)
        XCTAssertFalse(playing, "A previously paused player must remain paused")
    }
}
