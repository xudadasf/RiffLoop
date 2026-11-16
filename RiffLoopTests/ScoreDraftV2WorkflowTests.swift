import SwiftUI
import UIKit
import XCTest
@testable import RiffLoop

@MainActor
final class ScoreDraftV2WorkflowTests: XCTestCase {
    func testEditedRhythmDraftPublishesANewPracticeIdentityWithoutChangingExistingData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ScoreDraftV2WorkflowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let documents = RiffLoopDocumentStore(documentsURL: root.appendingPathComponent("Documents"))
        let settings = FilePracticeSettingsStore(defaults: defaults)
        let recent = RecentProjectsStore(defaults: defaults)
        let names = DocumentDisplayNameStore(defaults: defaults)
        let occupied = UUID()
        let oldName = "草稿-\(occupied.uuidString).gp"
        let folder = documents.folderURL(for: .guitarPro)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = folder.appendingPathComponent(oldName)
        let oldBytes = Data("existing score".utf8)
        try oldBytes.write(to: existing)
        try settings.save(GpPracticeProfile(lastPositionTick: 1234), kind: .guitarPro, fileName: oldName)
        recent.opened(kind: .guitarPro, fileName: oldName)
        names.setDisplayName("原曲谱", for: .guitarPro, fileName: oldName)
        let beforeNames = names.customNames
        let beforeRecent = recent.projects
        let beforeProfile = try settings.load(GpPracticeProfile.self, kind: .guitarPro, fileName: oldName)

        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "score-draft-v2", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(ScoreDraftV2.self, from: Data(contentsOf: fixtureURL))
        let store = ScoreDraftV2Store(folder: root.appendingPathComponent("DraftsV2"))
        let model = try ScoreDraftV2EditorModel(newDraft: fixture, store: store)
        var chord = ScoreDraftBeatInput(.init(duration: 4, dots: 1))
        chord.frets = ["5", "6", "", "", "", "0"]
        XCTAssertTrue(model.replaceEvent(bar: 0, index: 0, with: .beat(try chord.beat())))
        await model.save()
        let id = try XCTUnwrap(model.persistedID)
        let reopened = try await ScoreDraftV2EditorModel.open(id: id, store: store)
        XCTAssertEqual(reopened.exportAvailability, .ready)
        var attempts = 0
        let newID = UUID()
        let url = try await reopened.publishPractice { saved in
            try await ScoreDraftPracticePublisher.publish(saved, documents: documents,
                settings: settings, recent: recent, displayNames: names) {
                    attempts += 1
                    return attempts == 1 ? occupied : newID
                }
        }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(url.lastPathComponent, "草稿-\(newID.uuidString).gp")
        XCTAssertTrue(try Data(contentsOf: url).starts(with: [0x50, 0x4b, 0x03, 0x04]))
        XCTAssertEqual(try Data(contentsOf: existing), oldBytes)
        XCTAssertEqual(names.customNames, beforeNames)
        XCTAssertEqual(recent.projects, beforeRecent)
        XCTAssertEqual(try settings.load(GpPracticeProfile.self, kind: .guitarPro, fileName: oldName), beforeProfile)
        XCTAssertFalse(settings.containsFileSettings(kind: .guitarPro, fileName: url.lastPathComponent))
        let retained = try await store.load(id)
        XCTAssertEqual(retained, model.editor.draft)
        let document = try ExternalDocument.receive(url, store: documents)
        XCTAssertEqual(document.kind, .guitarPro)
        XCTAssertEqual(document.url.resolvingSymlinksInPath(), url.resolvingSymlinksInPath())
    }

    func testEditorAndEntryFormsRenderOnIPadWithoutActivatingPlayback() async throws {
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "score-draft-v2", withExtension: "json", subdirectory: "Fixtures"))
        let draft = try JSONDecoder().decode(ScoreDraftV2.self, from: Data(contentsOf: fixtureURL))
        let model = try ScoreDraftV2EditorModel(newDraft: draft) { _, _, _ in }
        let suite = "ScoreDraftV2Screenshots.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pages: [(String, AnyView)] = [
            ("Draft-editor-iPad", AnyView(ScoreDraftEditorView(model: model))),
            ("Draft-chord-form-iPad", AnyView(ScoreDraftEntryForm(entry: draft.bars[0][0]) { _ in true })),
            ("Draft-triplet-form-iPad", AnyView(ScoreDraftEntryForm(entry: draft.bars[1][0]) { _ in true }))
        ]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousAwake = UIApplication.shared.isIdleTimerDisabled
        for (name, page) in pages {
            let window = UIWindow(windowScene: scene)
            let controller = UIHostingController(rootView: AnyView(NavigationStack { page }
                .environmentObject(RecentProjectsStore(defaults: defaults))
                .environmentObject(DocumentDisplayNameStore(defaults: defaults))
                .preferredColorScheme(.dark)))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(700))
            controller.view.layoutIfNeeded()
            XCTAssertGreaterThan(controller.view.bounds.width, 700)
            let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            controller.rootView = AnyView(Color.clear)
            try await Task.sleep(for: .milliseconds(100))
            window.isHidden = true
            window.rootViewController = nil
        }
        XCTAssertEqual(UIApplication.shared.isIdleTimerDisabled, previousAwake)
        XCTAssertTrue(model.hasUnsavedChanges)
    }
}
