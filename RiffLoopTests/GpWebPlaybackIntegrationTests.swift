import SwiftUI
import WebKit
import XCTest
@testable import RiffLoop

@MainActor
final class GpWebPlaybackIntegrationTests: XCTestCase {
    func testLegatoLabelsDoNotOverlapTabRhythmBeams() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        let webView = WKWebView(frame: .zero)
        controller.view.addSubview(webView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legato-layout-\(UUID().uuidString)")
        let resources = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("GpWeb"))
        try FileManager.default.copyItem(at: resources, to: root)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            try? FileManager.default.removeItem(at: root)
        }
        // Exercise production setup and the real SVG renderer. Expose the player only
        // in this temporary test copy; eager rendering lets us inspect every string.
        let scriptURL = root.appendingPathComponent("riffloop-gp.js")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
            .replacingOccurrences(of: "    const synthApi =", with: "    window.riffloopLayoutTestApi = api;\n    const synthApi =")
            .replacingOccurrences(of: "enableLazyLoading: true", with: "enableLazyLoading: false")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        webView.frame = CGRect(x: 0, y: 0, width: 1133, height: 535)
        webView.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
        try await waitForJavaScript(webView, "Boolean(window.riffloopLayoutTestApi)")
        for width in [768, 1133] {
            webView.frame.size.width = CGFloat(width)
            _ = try await webView.evaluateJavaScript("""
                (() => {
                    const api = window.riffloopLayoutTestApi;
                    const bars = [];
                    for (const duration of [16, 32, 64]) {
                        for (let string = 1; string <= 6; string++) {
                            const count = duration === 16 ? 16 : 8;
                            const notes = Array.from({length: count}, (_, i) =>
                                `${i % 2 ? 7 : 5}.${string}${i < count - 1 ? '{h}' : ''}`);
                            const rests = duration === 32 ? ' :4 r r r' : duration === 64 ? ' :8 r r r r r r r' : '';
                            bars.push(`:${duration} ${notes.join(' ')}${rests}`);
                        }
                    }
                    const importer = new alphaTab.importer.AlphaTexImporter();
                    importer.initFromString(bars.join(' | '), api.settings);
                    const score = importer.readScore();
                    score.tracks[0].staves[0].showStandardNotation = false;
                    window.riffloopLayoutRenderFinished = false;
                    const finished = () => {
                        window.riffloopLayoutRenderFinished = true;
                        api.renderFinished.off(finished);
                    };
                    api.renderFinished.on(finished);
                    api.renderScore(score, [0]);
                })();
                """)
            try await waitForJavaScript(webView, """
                window.riffloopLayoutRenderFinished && [...document.querySelectorAll('#score svg text')].filter(e => /^[HP]$/.test(e.textContent)).length === 174
                """)
            let result = try await webView.evaluateJavaScript("""
                (() => {
                    const labels = [...document.querySelectorAll('#score svg text')].filter(e => /^[HP]$/.test(e.textContent));
                    const beams = [...document.querySelectorAll('#score svg rect, #score svg path, #score svg polygon')].filter(e => {
                        const b = e.getBoundingClientRect();
                        return b.width > 10 && b.height > 1.2 && b.height < 4.5 && getComputedStyle(e).fill !== 'rgb(165, 165, 165)';
                    });
                    return {
                        labels: labels.length,
                        beams: beams.length,
                        overlaps: labels.filter(e => {
                            const a = e.getBoundingClientRect();
                            return beams.some(beam => {
                                const b = beam.getBoundingClientRect();
                                return a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top;
                            });
                        }).length
                    };
                })();
                """)
            let metrics = try XCTUnwrap(result as? [String: Int])
            XCTAssertEqual(metrics["labels"], 174, "All H/P labels must remain visible")
            XCTAssertGreaterThan(metrics["beams"] ?? 0, 100, "Rhythm beams must remain visible")
            XCTAssertEqual(metrics["overlaps"], 0, "H/P labels overlap rhythm beams at width \(width)")
        }
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: webView.bounds).image { _ in
            webView.drawHierarchy(in: webView.bounds, afterScreenUpdates: true)
        })
        attachment.name = "Legato labels and rhythm beams on six strings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForJavaScript(_ webView: WKWebView, _ expression: String) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let result = try? await webView.evaluateJavaScript(expression), result as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("WebKit layout condition timed out: \(expression)")
        throw NSError(domain: "GpLegatoLayout", code: 1)
    }

    func testRealWebPlayerReloadReselectAndCountInAtPointNineSpeed() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let model = GpWebViewModel()
        let controller = UIHostingController(rootView: GpWebView(viewModel: model))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let names = ["transport-test-\(UUID().uuidString).gp", "transport-test-\(UUID().uuidString).gp"]
        defer {
            model.pause()
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
            window.isHidden = true
            window.rootViewController = nil
            for name in names { FilePracticeSettingsStore().remove(kind: .guitarPro, fileName: name) }
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "transport", withExtension: "gp", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        for name in names {
            print("GP integration loading \(name)")
            model.loadScore(data: data, fileName: name)
            try await waitUntil("GP readiness: \(model.errorMessage ?? "no error")") { model.playerReady }
            model.setPlaybackSpeed(0.9)
            model.setLoopCountInEnabled(true)
            for bar in [0, 2] {
                print("GP integration selecting bar \(bar), ready=\(model.playerReady), error=\(model.errorMessage ?? "none")")
                defer { print("GP integration final state: tick=\(model.position.currentTick), loops=\(model.completedLoops), playing=\(model.isPlaying), error=\(model.errorMessage ?? "none")") }
                model.pause()
                try await Task.sleep(for: .milliseconds(300))
                model.clearLoop()
                let hit = GpBarHit(index: bar, startTick: Double(bar * 3840), endTick: Double((bar + 1) * 3840))
                model.receive(.pointerDown(hit))
                model.receive(.pointerUp)
                XCTAssertNotNil(model.loopRange)
                try await Task.sleep(for: .milliseconds(300))
                model.togglePlayback()
                // Interrupt the initial prebuffered count-in as well as completed loops.
                try await Task.sleep(for: .milliseconds(250))
                model.pause()
                try await Task.sleep(for: .milliseconds(300))
                model.togglePlayback()
                try await waitUntil("GP must advance after count-in at 0.9x") {
                    model.position.currentTick > hit.startTick + 300
                }
                try await waitUntil("GP must complete and restart its selected range") { model.completedLoops >= 2 }
                XCTAssertNil(model.errorMessage)
                model.pause()
                try await Task.sleep(for: .milliseconds(400))
                XCTAssertFalse(model.isPlaying)
            }
        }
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "GP real WebKit playback after reload and range reselection"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitUntil(_ description: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard condition() else {
            XCTFail(description)
            throw NSError(domain: "GpPlaybackIntegration", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
        }
    }
}
