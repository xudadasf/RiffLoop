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
        for (width, scale) in [(768, 0.656), (1133, 0.656), (768, 0.82), (1133, 0.82), (768, 1.23), (1133, 1.23)] {
            webView.frame.size.width = CGFloat(width)
            _ = try await webView.evaluateJavaScript("""
                (() => {
                    const api = window.riffloopLayoutTestApi;
                    api.settings.display.scale = \(scale);
                    api.updateSettings();
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
                    const scale = window.riffloopLayoutTestApi.settings.display.scale / 0.82;
                    const beams = [...document.querySelectorAll('#score svg rect, #score svg path, #score svg polygon')].filter(e => {
                        const b = e.getBoundingClientRect();
                        return b.width > 10 && b.height > 1.2 * scale && b.height < 4.5 * scale && getComputedStyle(e).fill !== 'rgb(165, 165, 165)';
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
            XCTAssertEqual(metrics["overlaps"], 0, "H/P labels overlap rhythm beams at width \(width), scale \(scale)")
        }
        // A paused player cursor stays at the beginning while the reader scrolls
        // further down. Reflow must not let the renderer drag them back to bar 1.
        _ = try await webView.evaluateJavaScript("""
            (() => {
                const api = window.riffloopLayoutTestApi;
                const viewport = document.getElementById('viewport');
                viewport.scrollTop = api.renderer.boundsLookup.findMasterBarByIndex(10).realBounds.y;
                window.zoomAnchorChecked = false;
                const finished = () => {
                    api.postRenderFinished.off(finished);
                    requestAnimationFrame(() => requestAnimationFrame(() => { window.zoomAnchorChecked = true; }));
                };
                api.postRenderFinished.on(finished);
                window.riffloop.setScoreZoom(1);
            })()
            """)
        try await waitForJavaScript(webView, "window.zoomAnchorChecked")
        try await Task.sleep(for: .milliseconds(150))
        let retainedScroll = try await webView.evaluateJavaScript("document.getElementById('viewport').scrollTop > 50")
        XCTAssertEqual(retainedScroll as? Bool, true, "Zoom must retain the reader's position after queued cursor updates")
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
        let documentFolder = RiffLoopDocumentStore().folderURL(for: .guitarPro)
        try FileManager.default.createDirectory(at: documentFolder, withIntermediateDirectories: true)
        let names = ["transport-test-\(UUID().uuidString).gp", "transport-test-\(UUID().uuidString).gp"]
        defer {
            model.pause()
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
            window.isHidden = true
            window.rootViewController = nil
            for name in names {
                FilePracticeSettingsStore().remove(kind: .guitarPro, fileName: name)
                try? FileManager.default.removeItem(at: documentFolder.appendingPathComponent(name))
            }
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "transport", withExtension: "gp", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        func findWebView(_ view: UIView) -> WKWebView? {
            if let webView = view as? WKWebView { return webView }
            return view.subviews.compactMap { findWebView($0) }.first
        }
        for name in names {
            print("GP integration loading \(name)")
            try data.write(to: documentFolder.appendingPathComponent(name))
            model.loadScore(data: data, fileName: name)
            try await waitUntil("GP readiness: \(model.errorMessage ?? "no error")") { model.playerReady }
            let webView = try XCTUnwrap(findWebView(controller.view))
            _ = try await webView.evaluateJavaScript("""
                if (!window.testPlaybackErrors) {
                    window.testPlaybackErrors = [];
                    window.addEventListener('error', event => window.testPlaybackErrors.push(String(event.message)));
                    window.addEventListener('unhandledrejection', event => window.testPlaybackErrors.push(String(event.reason)));
                }
                """)
            model.setScoreZoom(1.5)
            XCTAssertEqual(model.scoreZoom, 1.5)
            model.setScoreZoom(0.8)
            model.setScoreZoom(1)
            model.setPlaybackSpeed(0.9)
            model.setCountInEnabled(true)
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
                XCTAssertTrue(model.isPlaying)
                model.handleAudioRouteChange(reason: 2)
                XCTAssertFalse(model.isPlaying)
                XCTAssertNil(model.errorMessage)
                try await Task.sleep(for: .milliseconds(300))
                model.togglePlayback()
                try await waitUntil("GP must advance after count-in at 0.9x") {
                    model.position.currentTick > hit.startTick + 300
                }
                let retainedRange = model.loopRange
                model.setScoreZoom(1.3)
                try await waitUntil("GP must complete and restart its selected range after live zoom") { model.completedLoops >= 2 }
                XCTAssertEqual(model.loopRange, retainedRange, "Zoom must preserve the loop")
                XCTAssertEqual(model.playbackSpeed, 0.9, "Zoom must not change tempo")
                model.setScoreZoom(1)
                XCTAssertNil(model.errorMessage)
                model.pause()
                try await Task.sleep(for: .milliseconds(400))
                XCTAssertFalse(model.isPlaying)
            }
        }
        model.pause()
        model.clearLoop()
        model.setCountInEnabled(false)
        model.setPracticeStartBpm(53)
        model.seek(to: 0)
        try await Task.sleep(for: .milliseconds(300))
        let firstBeat = GpBarHit(index: 0, startTick: 0, endTick: 3840, seekTick: 0, seekEndTick: 960)
        model.receive(.pointerDown(firstBeat))
        model.receive(.pointerUp)
        model.setLoopCountInEnabled(true)
        model.setGpStages(.init(stages: [.init(bpm: 240, unit: .loops, length: 1),
                                         .init(bpm: 180, unit: .loops, length: 3)]))
        model.setGpStagesEnabled(true)
        let countInRange = model.loopRange
        model.togglePlayback()
        try await waitUntil("Custom stages with per-loop count-in must complete two real loops") {
            model.completedLoops >= 2 && model.gpProgress.index == 1 &&
                model.isPlaying && !model.gpProgress.clockRunning
        }
        XCTAssertTrue(model.gpStagesEnabled)
        XCTAssertTrue(model.rangeLoopingEnabled)
        XCTAssertEqual(model.loopRange, countInRange)
        XCTAssertEqual(model.currentBpm, 180, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(model.gpProgress.rounds, 1)
        let countInReadout = model.stageReadout(for: .gp)
        XCTAssertGreaterThan(countInReadout.remaining, 0)
        XCTAssertLessThan(countInReadout.remaining, 3)
        try await waitUntil("The next count-in must restart actual score playback at the new stage BPM") {
            model.isPlaying && model.gpProgress.index == 1 && model.gpProgress.clockRunning &&
                model.position.currentTick > firstBeat.startTick + 150 &&
                model.position.currentTick < 960
        }
        XCTAssertEqual(model.currentBpm, 180, accuracy: 0.1)
        XCTAssertEqual(model.loopRange, countInRange)
        XCTAssertNil(model.errorMessage)
        model.pause()
        try await Task.sleep(for: .milliseconds(300))

        model.setLoopCountInEnabled(false)
        model.setGpStages(.init(stages: [.init(bpm: 160, unit: .loops, length: 1),
                                         .init(bpm: 90, unit: .seconds, length: 2)]))
        model.setGpStagesEnabled(true)
        model.togglePlayback()
        try await waitUntil("Custom tempo must switch on a real A/B completion") { model.gpProgress.index == 1 }
        XCTAssertEqual(model.currentBpm, 90, accuracy: 0.1)
        XCTAssertEqual(model.deckStageTransport, .gp)
        XCTAssertTrue(model.gpProgress.clockRunning, "Real score playback must start the stage clock")
        model.pause()
        XCTAssertFalse(model.gpProgress.clockRunning)
        try await Task.sleep(for: .milliseconds(300))
        model.selectStage(1, for: .gp)
        XCTAssertEqual(model.stageReadout(for: .gp).remaining, 2)
        try await waitUntil("Choosing a GP stage must return to A while paused") {
            abs(model.position.currentTick - firstBeat.startTick) < 2
        }
        model.togglePlayback()
        XCTAssertFalse(model.canSelectStage(for: .gp), "Disable selection before the asynchronous Play acknowledgement")
        model.selectStage(0, for: .gp)
        XCTAssertEqual(model.gpProgress.index, 1)
        try await waitUntil("The selected stage must actually play from A") {
            model.isPlaying && model.position.currentTick > firstBeat.startTick + 150
        }
        XCTAssertEqual(model.currentBpm, 90, accuracy: 0.1)
        model.pause()
        try await Task.sleep(for: .milliseconds(300))

        // Keep this interaction check independent of the two-second stage above.
        // The fixture is 120 BPM, with four 960-tick quarter notes in each bar.
        model.setGpStages(.init(stages: [.init(bpm: 160, unit: .loops, length: 20),
                                         .init(bpm: 90, unit: .loops, length: 20)]))
        model.selectStage(1, for: .gp)
        let stageWebView = try XCTUnwrap(findWebView(controller.view))
        let originalRange = try XCTUnwrap(model.loopRange)
        XCTAssertEqual(originalRange, GpLoopBarRange(firstBar: 0, lastBar: 0, startTick: 0, endTick: 960))
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.gpProgress.index, 1)
        try await waitUntil("Prepare stage two at the original A before interacting") {
            abs(model.position.currentTick - originalRange.startTick) < 2
        }
        let replacementBeat = GpBarHit(index: 2, startTick: 7680, endTick: 11520,
                                       seekTick: 8640, seekEndTick: 9600)
        model.receive(.barHit(replacementBeat))
        XCTAssertTrue(model.gpStagesEnabled, "An out-of-range tap must not exit stage practice")
        XCTAssertTrue(model.rangeLoopingEnabled)
        XCTAssertEqual(model.gpProgress.index, 1)
        XCTAssertEqual(model.loopRange, originalRange)

        model.receive(.pointerDown(replacementBeat))
        model.receive(.pointerMove(GpBarHit(index: 2, startTick: 7680, endTick: 11520,
                                          seekTick: 9600, seekEndTick: 10560)))
        XCTAssertNotNil(model.loopPreview)
        model.receive(.pointerCancel)
        XCTAssertNil(model.loopPreview)
        XCTAssertTrue(model.gpStagesEnabled, "Cancelling a range preview must retain stage practice")
        XCTAssertTrue(model.rangeLoopingEnabled)
        XCTAssertEqual(model.loopRange, originalRange)
        XCTAssertEqual(model.gpProgress.index, 1)
        XCTAssertFalse(model.isPlaying)
        try await waitForJavaScript(stageWebView, "JSON.stringify(window.riffloopCommittedBars) === '[0,0,0,960]'")
        let loopsBeforeCancelResume = model.completedLoops
        model.togglePlayback()
        try await waitUntil("After cancelling a preview, the real player must loop the original A/B") {
            model.isPlaying && model.completedLoops > loopsBeforeCancelResume &&
                model.position.currentTick > originalRange.startTick + 150 &&
                model.position.currentTick < originalRange.endTick
        }
        XCTAssertEqual(model.currentBpm, 90, accuracy: 0.1)
        XCTAssertEqual(model.gpProgress.index, 1)
        model.pause()
        try await Task.sleep(for: .milliseconds(300))

        model.receive(.pointerDown(replacementBeat))
        model.receive(.pointerUp)
        let replacementRange = GpLoopBarRange(firstBar: 2, lastBar: 2, startTick: 8640, endTick: 9600)
        XCTAssertEqual(model.loopRange, replacementRange)
        XCTAssertTrue(model.rangeLoopingEnabled)
        XCTAssertTrue(model.gpStagesEnabled, "Committing a new range must retain the selected stage")
        XCTAssertEqual(model.gpProgress.index, 1)
        XCTAssertFalse(model.isPlaying, "Changing A/B must await an explicit resume")
        try await waitForJavaScript(stageWebView, "JSON.stringify(window.riffloopCommittedBars) === '[2,2,8640,9600]'")
        try await waitUntil("Committing the replacement must seek to its new A while paused") {
            abs(model.position.currentTick - replacementRange.startTick) < 2
        }
        let loopsBeforeCommitResume = model.completedLoops
        model.togglePlayback()
        try await waitUntil("After committing, the real player must loop the replacement one-beat range") {
            model.isPlaying && model.completedLoops > loopsBeforeCommitResume &&
                model.position.currentTick > replacementRange.startTick + 150 &&
                model.position.currentTick < replacementRange.endTick
        }
        XCTAssertEqual(model.currentBpm, 90, accuracy: 0.1)
        XCTAssertEqual(model.gpProgress.index, 1)
        XCTAssertNil(model.errorMessage)
        model.pause()
        try await Task.sleep(for: .milliseconds(300))

        let beforeRecovery = model.stageReadout(for: .gp)
        let loopsBeforeRecovery = model.completedLoops
        let errorsBeforeRecovery = try await stageWebView.evaluateJavaScript("window.testPlaybackErrors")
        XCTAssertEqual(errorsBeforeRecovery as? [String], [])
        _ = try await stageWebView.evaluateJavaScript("window.riffloop = undefined")
        model.recoverWebContent()
        try await waitUntil("Automatic recovery must reload the staged score") { model.playerReady }
        XCTAssertTrue(model.gpStagesEnabled)
        XCTAssertTrue(model.rangeLoopingEnabled)
        XCTAssertEqual(model.loopRange, replacementRange)
        XCTAssertEqual(model.stageReadout(for: .gp), beforeRecovery)
        XCTAssertEqual(model.completedLoops, loopsBeforeRecovery)
        XCTAssertFalse(model.isPlaying, "Recovery must never resume audio automatically")
        XCTAssertFalse(model.gpProgress.clockRunning)
        try await waitForJavaScript(stageWebView, "JSON.stringify(window.riffloopCommittedBars) === '[2,2,8640,9600]'")
        _ = try await stageWebView.evaluateJavaScript("""
            window.testPlaybackErrors = [];
            window.addEventListener('error', event => window.testPlaybackErrors.push(String(event.message)));
            window.addEventListener('unhandledrejection', event => window.testPlaybackErrors.push(String(event.reason)));
            """)
        model.togglePlayback()
        try await waitUntil("Recovered stage practice must actually resume and loop the retained range") {
            model.isPlaying && model.completedLoops > loopsBeforeRecovery &&
                model.position.currentTick > replacementRange.startTick + 150 &&
                model.position.currentTick < replacementRange.endTick
        }
        XCTAssertEqual(model.currentBpm, 90, accuracy: 0.1)
        XCTAssertEqual(model.gpProgress.index, 1)
        XCTAssertNil(model.errorMessage)
        model.pause()
        try await Task.sleep(for: .milliseconds(300))
        model.clearLoop()
        model.seek(to: 0)
        try await Task.sleep(for: .milliseconds(300))
        model.setStandaloneBpm(87)
        model.setStandaloneStages(.init(stages: [.init(bpm: 240, unit: .seconds, length: 1),
                                                 .init(bpm: 100, unit: .seconds, length: 10)]))
        model.setStandaloneStagesEnabled(true)
        model.setStandaloneGap(.init(enabled: true, soundBars: 1, silentBars: 1))
        model.toggleStandaloneMetronome()
        try await waitUntil("Standalone clock reaches the next stage without starting GP") { model.playingStandaloneBpm == 100 }

        XCTAssertTrue(model.isStandaloneMetronomePlaying)
        let stationaryTick = model.position.currentTick
        try await waitUntil("The live countdown must use elapsed audio time") { model.stageReadout(for: .standalone).remaining < 10 }
        model.toggleStandaloneMetronome()
        let paused = model.stageReadout(for: .standalone)
        XCTAssertEqual(model.deckStageTransport, .standalone)
        try await Task.sleep(for: .milliseconds(1150))
        XCTAssertEqual(model.stageReadout(for: .standalone), paused, "Pause freezes the stage, even during a silent bar")
        model.toggleStandaloneMetronome()
        try await waitUntil("Resuming continues the same countdown") { model.stageReadout(for: .standalone).remaining < paused.remaining }
        XCTAssertEqual(model.position.currentTick, stationaryTick, "Standalone beats must not advance the score")
        XCTAssertFalse(model.isPlaying)
        model.selectStage(0, for: .standalone)
        XCTAssertEqual(model.playingStandaloneBpm, 100, "An active metronome must reject stage selection")
        model.toggleStandaloneMetronome()
        model.selectStage(1, for: .standalone)
        model.setStandaloneBeats(7)
        model.setStandaloneSubdivision(4)
        model.toggleStandaloneMetronome()
        XCTAssertTrue(model.isStandaloneMetronomePlaying)
        XCTAssertEqual(model.stageReadout(for: .standalone).index, 1)
        XCTAssertEqual(model.stageReadout(for: .standalone).remaining, 10)
        XCTAssertEqual(model.playingStandaloneBpm, 100)
        model.togglePlayback()
        XCTAssertFalse(model.isStandaloneMetronomePlaying)
        try await waitUntil("Normal playback must resume exclusively after standalone practice") {
            model.isPlaying && model.position.currentTick > stationaryTick + 100
        }
        model.receive(.barHit(GpBarHit(index: 2, startTick: 7680, endTick: 11520, seekTick: 8640)))
        try await waitUntil("A tap during playback must seek and continue") {
            model.isPlaying && model.position.currentTick >= 8640
        }
        XCTAssertEqual(model.currentBpm, 53, accuracy: 0.01)
        model.setStandaloneStagesEnabled(false)
        model.setStandaloneGap(.init())
        model.pause()
        model.resetBaseBpm()
        model.setPlaybackSpeed(0.9)
        model.setCountInEnabled(true)
        // The 60 BPM count-in exceeds the 3.5 s stall threshold. A paused seek
        // must receive a fresh playback grace period after the count-in ends.
        model.clearLoop()
        model.setPlaybackSpeed(1)
        model.setBaseBpm(60)
        model.setMetronomeVolume(1)
        model.setCountInEnabled(true)
        for _ in 0..<3 {
            model.seek(to: 3840)
            try await Task.sleep(for: .milliseconds(300))
            model.togglePlayback()
            try await waitUntil("Four-second count-in must resume at the selected beat") {
                model.position.currentTick > 4140 && model.isPlaying
            }
            XCTAssertNil(model.errorMessage)
            model.pause()
            try await Task.sleep(for: .milliseconds(300))
        }
        let webView = try XCTUnwrap(findWebView(controller.view))
        let scriptErrors = try await webView.evaluateJavaScript("window.testPlaybackErrors")
        XCTAssertEqual(scriptErrors as? [String], [], "Range reselection and replacement must not throw script errors")
        // A terminated WebContent process has no bridge while the replacement page
        // is loading. Foreground notifications can arrive inside that gap.
        _ = try await webView.evaluateJavaScript("window.riffloop = undefined")
        model.recoverWebContent()
        model.setSceneActive(false)
        model.setSceneActive(true)
        XCTAssertFalse(model.playerReady)
        try await waitUntil("Terminated WebContent must reload the saved GP") { model.playerReady }
        XCTAssertEqual(try Data(contentsOf: documentFolder.appendingPathComponent(names[1])), data)
        XCTAssertNil(model.errorMessage, "Recovery-time lifecycle updates must not leave a user-visible error")

        // A second termination before playback makes automatic recovery stop. The
        // user-facing instruction to reopen a file must rebuild the dead page.
        _ = try await webView.evaluateJavaScript("window.riffloop = undefined")
        model.recoverWebContent()
        XCTAssertFalse(model.rendererReady)
        XCTAssertNotNil(model.errorMessage)
        model.loadScore(data: data, fileName: names[0])
        try await waitUntil("Reopening a GP after repeated WebContent termination must reload the page") {
            model.playerReady
        }
        XCTAssertNil(model.errorMessage)

        model.setCountInEnabled(false)
        let recoveredTick = model.position.currentTick
        model.togglePlayback()
        try await waitUntil("Recovered WebContent must play without reopening the library") { model.position.currentTick > recoveredTick + 300 }
        model.pause()
        XCTAssertNil(model.errorMessage)

        // Leave before the asynchronous recovery read finishes, then reopen. The
        // old task must neither reload the abandoned page nor replace saved settings.
        model.setBaseBpm(70)
        model.seek(to: 3840)
        try await waitUntil("Save a nonzero practice position before recovery") {
            abs(model.position.currentTick - 3840) < 2
        }
        model.setBaseBpm(70)
        let store = FilePracticeSettingsStore()
        let beforeExit = try XCTUnwrap(store.load(GpPracticeProfile.self, kind: .guitarPro, fileName: names[0]))
        _ = try await webView.evaluateJavaScript("window.riffloop = undefined")
        model.recoverWebContent()
        model.leaveMode()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(model.playerReady, "Leaving must cancel automatic recovery")
        XCTAssertNil(model.errorMessage, "Leaving recovery must not send commands into a missing bridge")
        let afterExit = try XCTUnwrap(store.load(GpPracticeProfile.self, kind: .guitarPro, fileName: names[0]))
        XCTAssertEqual(afterExit.baseBpm, beforeExit.baseBpm)
        XCTAssertEqual(afterExit.lastPositionTick, beforeExit.lastPositionTick)
        model.loadScore(data: data, fileName: names[0])
        try await waitUntil("Reopening after cancelled recovery must retain BPM and position") {
            model.playerReady && abs(model.position.currentTick - beforeExit.lastPositionTick) < 2
        }
        XCTAssertEqual(model.baseBpm, 70)

        // A user file selection supersedes a pending recovery read.
        let nextProfile = try XCTUnwrap(store.load(GpPracticeProfile.self, kind: .guitarPro, fileName: names[1]))
        _ = try await webView.evaluateJavaScript("window.riffloop = undefined")
        model.recoverWebContent()
        model.loadScore(data: data, fileName: names[1])
        try await waitUntil("Selecting another GP during recovery must load the selected file") { model.playerReady }
        XCTAssertEqual(model.baseBpm, nextProfile.baseBpm)
        XCTAssertNil(model.errorMessage)
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "GP real WebKit playback after reload and range reselection"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTimbreChangeKeepsPlaybackPositionLoopAndSavedScore() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let model = GpWebViewModel()
        let controller = UIHostingController(rootView: GpWebView(viewModel: model))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let folder = RiffLoopDocumentStore().folderURL(for: .guitarPro)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "timbre-test-\(UUID().uuidString).gp"
        defer {
            model.pause()
            window.isHidden = true
            window.rootViewController = nil
            FilePracticeSettingsStore().remove(kind: .guitarPro, fileName: name)
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "transport", withExtension: "gp", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        try data.write(to: folder.appendingPathComponent(name))
        model.loadScore(data: data, fileName: name)
        try await waitUntil("GP must be ready before changing timbre") { model.playerReady }
        XCTAssertEqual(model.score?.tracks.first?.canChangeTimbre, true)

        func findWebView(_ view: UIView) -> WKWebView? {
            if let webView = view as? WKWebView { return webView }
            return view.subviews.compactMap { findWebView($0) }.first
        }
        let webView = try XCTUnwrap(findWebView(controller.view))
        _ = try await webView.evaluateJavaScript("""
            (() => {
                window.testTimbrePrograms = [];
                const proto = alphaTab.AlphaTabApiBase.prototype;
                const original = proto.loadMidiForScore;
                proto.loadMidiForScore = function () {
                    if (this.container?.element?.id === 'score' && !this.testTimbreHook) {
                        this.testTimbreHook = true;
                        this.midiLoad.on(midi => window.testTimbrePrograms.push(
                            midi.events.filter(event => event instanceof alphaTab.midi.ProgramChangeEvent
                                && event.track === 0 && (event.channel === 0 || event.channel === 1))
                                .map(event => event.program)
                        ));
                    }
                    return original.call(this);
                };
            })()
            """)
        model.setPlaybackSpeed(0.8)
        model.setTrackVolume(index: 0, volume: 0.6)
        model.receive(.pointerDown(GpBarHit(index: 1, startTick: 3840, endTick: 7680)))
        model.receive(.pointerUp)
        let range = try XCTUnwrap(model.loopRange)
        model.seek(to: 4800)
        try await waitUntil("Seek before changing timbre") { abs(model.position.currentTick - 4800) < 2 }
        model.togglePlayback()
        try await waitUntil("Playback must advance before changing timbre") { model.isPlaying && model.position.currentTick > 5000 }
        let before = model.position.currentTick
        model.setTrackTimbre(index: 0, program: 30)
        XCTAssertFalse(model.isPlaying)
        try await waitUntil("Timbre reload must preserve the playing position") {
            model.playerReady && abs(model.position.currentTick - before) < 400
        }
        XCTAssertEqual(model.loopRange, range)
        XCTAssertEqual(model.playbackSpeed, 0.8)
        XCTAssertEqual(model.trackVolumes[0], 0.6)
        XCTAssertEqual(model.trackTimbres[0], 30)
        let selected = try await webView.evaluateJavaScript("window.testTimbrePrograms.at(-1)") as? [Int]
        XCTAssertEqual(selected, [30, 30])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), data)
        XCTAssertNil(model.errorMessage)

        let pausedTick = model.position.currentTick
        model.togglePlayback()
        try await waitUntil("Playback must resume after changing timbre") {
            model.isPlaying && model.position.currentTick > pausedTick + 100
        }
        model.pause()
        model.loadScore(data: data, fileName: name)
        try await waitUntil("Reopening must restore the chosen timbre") { model.playerReady && model.trackTimbres[0] == 30 }
        let restored = try await webView.evaluateJavaScript("window.testTimbrePrograms.at(-1)") as? [Int]
        XCTAssertEqual(restored, [30, 30])
        model.setTrackTimbre(index: 0, program: -1)
        try await waitUntil("Original timbre must be restored") { model.playerReady && model.trackTimbres[0] == nil }
        let original = try await webView.evaluateJavaScript("window.testTimbrePrograms.at(-1)") as? [Int]
        XCTAssertEqual(original, [25, 25])
        XCTAssertNil(model.errorMessage)

        // The ordinary A/B checks above stay independent of custom-stage recovery.
        // Change timbre only after the real player has completed part of stage two.
        model.setCountInEnabled(false)
        model.setLoopCountInEnabled(false)
        model.receive(.pointerDown(GpBarHit(index: 1, startTick: 3840, endTick: 7680)))
        model.receive(.pointerUp)
        let stagePlan = TempoStagePlan(stages: [.init(bpm: 140, unit: .loops, length: 8),
                                               .init(bpm: 180, unit: .loops, length: 8)])
        model.setGpStages(stagePlan)
        model.setGpStagesEnabled(true)
        model.selectStage(1, for: .gp)
        try await waitUntil("Prepare stage two at A before testing a timbre reload") {
            abs(model.position.currentTick - range.startTick) < 2
        }
        model.togglePlayback()
        try await waitUntil("Stage two must complete a real loop before its timbre changes") {
            model.isPlaying && model.gpProgress.index == 1 && model.gpProgress.rounds >= 1 &&
                model.position.currentTick > range.startTick + 200 && model.position.currentTick < range.endTick
        }
        let stagedReadout = model.stageReadout(for: .gp)
        let stagedLoops = model.completedLoops
        let stagedTick = model.position.currentTick
        XCTAssertGreaterThan(stagedReadout.remaining, 0)
        XCTAssertLessThan(stagedReadout.remaining, 8)
        model.setTrackTimbre(index: 0, program: 30)
        XCTAssertFalse(model.isPlaying)
        try await waitUntil("Timbre replacement must finish with stage two and its position retained") {
            model.playerReady && abs(model.position.currentTick - stagedTick) < 400
        }
        XCTAssertTrue(model.gpStagesEnabled)
        XCTAssertTrue(model.rangeLoopingEnabled)
        XCTAssertEqual(model.loopRange, range)
        XCTAssertEqual(model.gpStages, stagePlan)
        XCTAssertEqual(model.stageReadout(for: .gp), stagedReadout)
        XCTAssertEqual(model.completedLoops, stagedLoops)
        XCTAssertEqual(model.currentBpm, 180, accuracy: 0.1)
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.gpProgress.clockRunning)
        let stagedProgram = try await webView.evaluateJavaScript("window.testTimbrePrograms.at(-1)") as? [Int]
        XCTAssertEqual(stagedProgram, [30, 30])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), data)

        model.togglePlayback()
        try await waitUntil("Stage two must resume and complete another real loop after its timbre changes") {
            model.isPlaying && model.gpProgress.index == 1 && model.completedLoops > stagedLoops &&
                model.position.currentTick > range.startTick + 150 && model.position.currentTick < range.endTick
        }
        XCTAssertTrue(model.gpStagesEnabled)
        XCTAssertEqual(model.loopRange, range)
        XCTAssertEqual(model.currentBpm, 180, accuracy: 0.1)
        XCTAssertLessThan(model.stageReadout(for: .gp).remaining, stagedReadout.remaining)
        XCTAssertNil(model.errorMessage)
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
