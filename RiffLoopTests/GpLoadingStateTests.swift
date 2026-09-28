import WebKit
import XCTest
@testable import RiffLoop

@MainActor
final class GpLoadingStateTests: XCTestCase {
    func testLeavingOrBackgroundingDuringLoadPreservesSavedProfile() throws {
        let suite = "GpLoadingStateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FilePracticeSettingsStore(defaults: defaults)
        let name = "loading-test.gp"
        for leave in [false, true] {
            let expected = GpPracticeProfile(baseBpm: 70, lastPositionTick: 9121,
                totalPracticeMilliseconds: 3420776, totalCompletedLoops: 123)
            try store.save(expected, kind: .guitarPro, fileName: name)
            let model = GpWebViewModel(settingsStore: store)
            model.loadScore(data: Data(), fileName: name)
            if leave { model.leaveMode() } else { model.setSceneActive(false) }
            let saved = try XCTUnwrap(store.load(GpPracticeProfile.self, kind: .guitarPro, fileName: name))
            XCTAssertEqual(saved.baseBpm, 70)
            XCTAssertEqual(saved.lastPositionTick, 9121)
            XCTAssertEqual(saved.totalPracticeMilliseconds, 3420776)
            XCTAssertEqual(saved.totalCompletedLoops, 123)
        }
    }

    func testSwitchingFilesBeforeLoadCompletesPreservesBothProfiles() throws {
        let suite = "GpLoadingStateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FilePracticeSettingsStore(defaults: defaults)
        try store.save(GpPracticeProfile(baseBpm: 70, lastPositionTick: 9121), kind: .guitarPro, fileName: "first.gp")
        try store.save(GpPracticeProfile(baseBpm: 80, lastPositionTick: 3840), kind: .guitarPro, fileName: "second.gp")
        let model = GpWebViewModel(settingsStore: store)
        model.loadScore(data: Data(), fileName: "first.gp")
        model.loadScore(data: Data(), fileName: "second.gp")
        model.leaveMode()
        let first = try XCTUnwrap(store.load(GpPracticeProfile.self, kind: .guitarPro, fileName: "first.gp"))
        let second = try XCTUnwrap(store.load(GpPracticeProfile.self, kind: .guitarPro, fileName: "second.gp"))
        XCTAssertEqual(first.baseBpm, 70)
        XCTAssertEqual(first.lastPositionTick, 9121)
        XCTAssertEqual(second.baseBpm, 80)
        XCTAssertEqual(second.lastPositionTick, 3840)
    }

    func testLeavingAnUnavailableWebPageDoesNotDispatchCleanupCommands() async throws {
        let webView = WKWebView()
        webView.loadHTMLString("<html><body>Recovering</body></html>", baseURL: nil)
        for _ in 0..<100 {
            if let ready = try? await webView.evaluateJavaScript("document.readyState === 'complete'"),
               ready as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try await webView.evaluateJavaScript("window.riffloop = undefined")
        let model = GpWebViewModel()
        model.attach(webView: webView)
        model.recoverWebContent()
        model.leaveMode()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(model.errorMessage, "Leaving while the bridge is unavailable must not create command errors")
    }
}
