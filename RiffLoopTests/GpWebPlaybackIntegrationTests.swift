import SwiftUI
import WebKit
import XCTest
@testable import RiffLoop

@MainActor
final class GpWebPlaybackIntegrationTests: XCTestCase {
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
            window.isHidden = true
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
