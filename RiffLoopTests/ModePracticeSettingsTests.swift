import CryptoKit
import XCTest
@testable import RiffLoop

final class ModePracticeSettingsTests: XCTestCase {
    func testCurrentGpPreferencesFollowAcrossFilesWithoutCopyingSongContext() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FilePracticeSettingsStore(defaults: defaults)
        var first = GpPracticeProfile()
        first.masterVolume = 3.5
        first.playbackSpeed = 0.8
        first.countInAccents = [.strong, .subAccent, .normal, .muted]
        first.lastPositionTick = 4321
        first.displayedTrack = 2
        first.wholeSongLoopingEnabled = true
        first.speedLadderEnabled = true
        try store.save(first, kind: .guitarPro, fileName: "first.gp")
        var second = try XCTUnwrap(store.load(GpPracticeProfile.self, kind: .guitarPro, fileName: "second.gp"))
        XCTAssertEqual(second.masterVolume, 3.5)
        XCTAssertEqual(second.countInAccents, first.countInAccents)
        XCTAssertEqual(second.lastPositionTick, 0)
        XCTAssertEqual(second.displayedTrack, 0)
        XCTAssertFalse(second.wholeSongLoopingEnabled)
        XCTAssertFalse(second.speedLadderEnabled)
        second.masterVolume = 4
        second.lastPositionTick = 999
        try store.save(second, kind: .guitarPro, fileName: "second.gp")
        let reopened = try XCTUnwrap(store.load(GpPracticeProfile.self, kind: .guitarPro, fileName: "first.gp"))
        XCTAssertEqual(reopened.masterVolume, 4)
        XCTAssertEqual(reopened.lastPositionTick, 4321)
        XCTAssertEqual(reopened.displayedTrack, 2)
    }

    func testLegacyFileSeedsModeOnlyOnceAndNeverRestoresItsLoop() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func legacy(_ name: String, volume: Double) throws {
            var profile = GpPracticeProfile()
            profile.masterVolume = volume
            profile.loopRange = GpLoopBarRange(firstBar: 1, lastBar: 3, startTick: 960, endTick: 3840)
            profile.rangeLoopingEnabled = true
            let hash = SHA256.hash(data: Data("guitarPro:\(name)".utf8)).map { String(format: "%02x", $0) }.joined()
            defaults.set(try JSONEncoder().encode(profile), forKey: "practiceSettings.v1.\(hash)")
        }
        try legacy("first.gp", volume: 1.5)
        try legacy("old.gp", volume: 0.2)
        let store = FilePracticeSettingsStore(defaults: defaults)
        let first = try XCTUnwrap(store.load(GpPracticeProfile.self, kind: .guitarPro, fileName: "first.gp"))
        let old = try XCTUnwrap(store.load(GpPracticeProfile.self, kind: .guitarPro, fileName: "old.gp"))
        XCTAssertEqual(first.masterVolume, 1.5)
        XCTAssertEqual(old.masterVolume, 1.5)
        XCTAssertNil(old.loopRange)
        XCTAssertFalse(old.rangeLoopingEnabled)
    }

    func testPdfKeepsDocumentBindingsButSharesOnlyPdfPreferences() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FilePracticeSettingsStore(defaults: defaults)
        var pdf = PdfPracticeProfile()
        pdf.audioVolume = 1.6
        pdf.audioFileName = "song.mp3"
        pdf.pageIndex = 3
        pdf.pointA = 1; pdf.pointB = 8; pdf.loopEnabled = true; pdf.followLoopEnabled = true
        try store.save(pdf, kind: .pdf, fileName: "first.pdf")
        let next = try XCTUnwrap(store.load(PdfPracticeProfile.self, kind: .pdf, fileName: "next.pdf"))
        XCTAssertEqual(next.audioVolume, 1.6)
        XCTAssertNil(next.audioFileName)
        XCTAssertEqual(next.pageIndex, 0)
        let reopened = try XCTUnwrap(store.load(PdfPracticeProfile.self, kind: .pdf, fileName: "first.pdf"))
        XCTAssertEqual(reopened.audioFileName, "song.mp3")
        XCTAssertEqual(reopened.pageIndex, 3)
        XCTAssertNil(reopened.pointA)
        XCTAssertNil(reopened.pointB)
        XCTAssertFalse(reopened.loopEnabled)
        XCTAssertFalse(reopened.followLoopEnabled)
        XCTAssertNil(try store.load(VideoPracticeProfile.self, kind: .video, fileName: "first.pdf"))
    }
}
