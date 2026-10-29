import SwiftUI
import WebKit
import XCTest
@testable import RiffLoop

@MainActor
final class PracticeExperienceTests: XCTestCase {
    func testCompactIndependentControlsAndHomeSummaryRender() async throws {
        let model = GpWebViewModel()
        model.setStandaloneVolume(6)
        try await capture(AnyView(GpStandaloneMetronomeControls(viewModel: model)
            .frame(width: 340, height: 340).background(Color(.systemGroupedBackground))),
            name: "GP-compact-independent-metronome-600", expectAwake: false)
        try await capture(AnyView(HomeView()), name: "Home-compact-practice-calendar", expectAwake: false)
    }

    func testSelectedDayDurationBubbleRendersInsideFixedHeader() async throws {
        let suite = "HistoryBubble.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = PracticeHistoryStore(defaults: defaults)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let noon = Calendar.current.startOfDay(for: yesterday).addingTimeInterval(12 * 3600)
        history.record(seconds: 7625, endingAt: noon)
        let selected = try XCTUnwrap(history.calendarDays(weeks: 4).first {
            Calendar.current.isDate($0.date, inSameDayAs: noon)
        })
        try await capture(AnyView(PracticeHistoryCard(history: history, selectedDay: .constant(selected))
            .frame(width: 340)), name: "Home-selected-day-inline-duration-bubble", expectAwake: false)
    }

    func testTempoKeypadRendersWithoutSystemKeyboard() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: TempoKeypad(value: 120, apply: { _ in }, cancel: {})
            .preferredColorScheme(.dark))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(300))
        func hasTextInput(_ view: UIView) -> Bool {
            view is UITextField || view is UITextView || view.subviews.contains(where: hasTextInput)
        }
        XCTAssertFalse(hasTextInput(controller.view), "The digit pad must never summon iPad's alphabetic keyboard")
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        })
        attachment.name = "BPM numeric keypad"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPracticePagesRenderAndKeepPausedFilesAwake() async throws {
        let pdf = FileManager.default.temporaryDirectory.appendingPathComponent("practice-preview-\(UUID().uuidString).pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        let data = renderer.pdfData { context in
            context.beginPage()
            ("RiffLoop · PDF 练习" as NSString).draw(at: CGPoint(x: 45, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            for row in 0..<8 {
                let y = CGFloat(120 + row * 75)
                ("\(row * 4 + 1)    1  2  3  4       1  2  3  4" as NSString).draw(at: CGPoint(x: 45, y: y - 20), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
                for line in 0..<5 {
                    context.cgContext.move(to: CGPoint(x: 45, y: y + CGFloat(line * 6)))
                    context.cgContext.addLine(to: CGPoint(x: 550, y: y + CGFloat(line * 6)))
                    context.cgContext.strokePath()
                }
            }
        }
        try data.write(to: pdf)
        let video = try await makeTransportVideoFixture()
        let gp = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "transport", withExtension: "gp", subdirectory: "Fixtures"))
        defer {
            try? FileManager.default.removeItem(at: pdf)
            try? FileManager.default.removeItem(at: video)
            FilePracticeSettingsStore().remove(kind: .pdf, fileName: pdf.lastPathComponent)
            FilePracticeSettingsStore().remove(kind: .video, fileName: video.lastPathComponent)
            FilePracticeSettingsStore().remove(kind: .guitarPro, fileName: gp.lastPathComponent)
        }
        try await capture(AnyView(PdfPracticeView(initialURL: pdf)), name: "PDF-paused-independent-controls")
        try await capture(AnyView(PracticeView(initialURL: video)), name: "Video-paused-controls")
        try await capture(AnyView(GpPracticeView(initialURL: gp)), name: "GP-paused-controls", waitForGpScore: true)
    }

    private func capture(_ page: AnyView, name: String, delay: Double = 1, expectAwake: Bool = true, waitForGpScore: Bool = false) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: AnyView(NavigationStack { page }
            // A standalone UIHostingController has no SwiftUI App/Scene bridge.
            // Supply the actual foreground UIWindowScene state for this host.
            .environment(\.scenePhase, scene.activationState == .foregroundActive ? .active : .inactive)
            .environmentObject(RecentProjectsStore())
            .environmentObject(DocumentDisplayNameStore())
            .preferredColorScheme(.dark)))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .seconds(delay))
        if waitForGpScore {
            // WebKit startup varies on shared CI runners. Screen-awake policy is
            // meaningful after a score has loaded, not after an arbitrary sleep.
            let rendered = try await waitForRenderedGpScore(in: controller.view)
            XCTAssertTrue(rendered, "GP fixture must render before checking its paused screen-awake policy")
        }
        XCTAssertEqual(UIApplication.shared.isIdleTimerDisabled, expectAwake, "\(name) screen-awake policy")
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // Exercise SwiftUI removal while the hosting window is still alive, as
        // navigating back does. Destroying UIKit first skips that transition.
        controller.rootView = AnyView(Color.clear)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "Leaving \(name) must release screen awake")
    }

    private func waitForRenderedGpScore(in root: UIView) async throws -> Bool {
        func webView(in view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap { webView(in: $0) }.first
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if let web = webView(in: root),
               let result = try? await web.evaluateJavaScript("Boolean(document.querySelector('#score svg'))"),
               result as? Bool == true {
                return true
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

}
