import SwiftUI
import XCTest
@testable import RiffLoop

@MainActor
final class PracticeExperienceTests: XCTestCase {
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
        let video = try makeTransportAudioFixture()
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
        try await capture(AnyView(GpPracticeView(initialURL: gp)), name: "GP-paused-controls", delay: 4)
    }

    private func capture(_ page: AnyView, name: String, delay: Double = 1) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: NavigationStack { page }
            // A standalone UIHostingController has no SwiftUI App/Scene bridge.
            // Supply the actual foreground UIWindowScene state for this host.
            .environment(\.scenePhase, scene.activationState == .foregroundActive ? .active : .inactive)
            .environmentObject(RecentProjectsStore())
            .environmentObject(DocumentDisplayNameStore())
            .preferredColorScheme(.dark))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .seconds(delay))
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "\(name) must stay awake even while paused")
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
