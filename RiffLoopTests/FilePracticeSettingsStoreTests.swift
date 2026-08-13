import XCTest
@testable import RiffLoop

final class FilePracticeSettingsStoreTests: XCTestCase {
    private struct ExampleSettings: Codable, Equatable {
        let bpm: Double
        let position: Double
    }

    func testSettingsRoundTripIsIsolatedByModeAndFileName() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = FilePracticeSettingsStore(defaults: defaults)
        let expected = ExampleSettings(bpm: 65, position: 42)

        try store.save(expected, kind: .video, fileName: "练习.mp4")

        XCTAssertEqual(
            try store.load(ExampleSettings.self, kind: .video, fileName: "练习.mp4"),
            expected
        )
        XCTAssertNil(
            try store.load(ExampleSettings.self, kind: .video, fileName: "另一个.mp4")
        )
        XCTAssertNil(
            try store.load(ExampleSettings.self, kind: .pdf, fileName: "练习.mp4")
        )
    }
}
