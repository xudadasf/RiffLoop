import SwiftUI
import WebKit
import XCTest
@testable import RiffLoop

@MainActor
final class GpScoreSwitchIntegrationTests: XCTestCase {
    func testOldScoreAndBackingMessagesCannotReplaceNewScore() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let model = GpWebViewModel()
        let controller = UIHostingController(rootView: GpWebView(viewModel: model))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let folder = RiffLoopDocumentStore().folderURL(for: .guitarPro)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let firstName = "switch-first-\(UUID().uuidString).gp"
        let secondName = "switch-second-\(UUID().uuidString).gp"
        defer {
            model.leaveMode()
            window.isHidden = true
            window.rootViewController = nil
            for name in [firstName, secondName] {
                FilePracticeSettingsStore().remove(kind: .guitarPro, fileName: name)
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }
        func waitUntil(_ description: String, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTFail("Timed out: \(description)")
            throw NSError(domain: "GpScoreSwitchIntegration", code: 1)
        }
        func findWebView(_ view: UIView) -> WKWebView? {
            if let webView = view as? WKWebView { return webView }
            return view.subviews.compactMap { findWebView($0) }.first
        }
        try await waitUntil("renderer ready") { model.rendererReady }
        let webView = try XCTUnwrap(findWebView(controller.view))
        // Construct two different small scores without importing any user material.
        let generatedScores = try await webView.evaluateJavaScript("""
            (() => {
                const settings = new alphaTab.Settings();
                const make = (text, title) => {
                    const importer = new alphaTab.importer.AlphaTexImporter();
                    importer.initFromString(text, settings);
                    const score = importer.readScore();
                    score.title = title;
                    const bytes = new alphaTab.exporter.Gp7Exporter().export(score, settings);
                    return btoa(Array.from(bytes, byte => String.fromCharCode(byte)).join(''));
                };
                return [make(':4 3.3 5.3 7.3 8.3', 'First test score'),
                        make(':4 0.6 2.6 4.6 5.6 | 0.6 2.6 4.6 5.6', 'Second test score')];
            })()
            """)
        let encoded = try XCTUnwrap(generatedScores as? [String])
        XCTAssertEqual(encoded.count, 2)
        guard encoded.count == 2 else { return }
        let first = try XCTUnwrap(Data(base64Encoded: encoded[0]))
        let second = try XCTUnwrap(Data(base64Encoded: encoded[1]))
        try first.write(to: folder.appendingPathComponent(firstName))
        try second.write(to: folder.appendingPathComponent(secondName))
        model.loadScore(data: first, fileName: firstName)
        let firstID = try XCTUnwrap(model.scoreLoadID)
        try await waitUntil("first score ready") { model.playerReady && model.score?.title == "First test score" }
        model.loadScore(data: second, fileName: secondName)
        try await waitUntil("second score ready") { model.playerReady && model.score?.title == "Second test score" }
        XCTAssertNotEqual(model.scoreLoadID, firstID)
        // Simulate the old score's bridge messages arriving after selection of B.
        _ = try await webView.evaluateJavaScript("""
            window.webkit.messageHandlers.riffloop.postMessage({event:'scoreLoaded', scoreLoadID:'\(firstID)',
                payload:{title:'STALE', artist:'', bars:1, hasBackingTrack:true, tracks:[]}});
            window.webkit.messageHandlers.riffloop.postMessage({event:'backingAudioLoaded', scoreLoadID:'\(firstID)',
                payload:{mimeType:'audio/wav', data:'AAE=', syncPoints:[]}});
            window.webkit.messageHandlers.riffloop.postMessage({event:'backingAudioLoaded', scoreLoadID:'\(firstID)',
                payload:{mimeType:'audio/wav', data:'invalid-base64', syncPoints:[]}});
            """)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.score?.title, "Second test score")
        XCTAssertNil(model.errorMessage, "Stale backing must not reach the new file's native audio player")
        model.togglePlayback()
        try await waitUntil("second score must play") { model.isPlaying && model.position.currentTick > 100 }
        XCTAssertEqual(model.score?.title, "Second test score")
    }
}
