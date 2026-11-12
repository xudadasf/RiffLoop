import XCTest
@testable import RiffLoop

@MainActor
final class ScoreDraftPracticePublisherTests: XCTestCase {
    func testPracticeCopyUsesFreshIdentityAndPreservesExistingFilesAndSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "ScoreDraftPracticePublisherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let documents = RiffLoopDocumentStore(documentsURL: root.appendingPathComponent("Documents"))
        let settings = FilePracticeSettingsStore(defaults: defaults)
        let recent = RecentProjectsStore(defaults: defaults)
        let displayNames = DocumentDisplayNameStore(defaults: defaults)
        let folder = documents.folderURL(for: .guitarPro)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("已有谱.gp")
        let source = root.appendingPathComponent("制谱源.gp")
        let originalBytes = Data("existing practice score".utf8)
        let sourceBytes = Data("existing exported draft".utf8)
        try originalBytes.write(to: original)
        try sourceBytes.write(to: source)

        let candidates = (0..<5).map { _ in UUID() }
        func name(_ id: UUID) -> String { "草稿-\(id.uuidString).gp" }
        var oldProfile = GpPracticeProfile()
        oldProfile.lastPositionTick = 1234
        try settings.save(oldProfile, kind: .guitarPro, fileName: name(candidates[0]))
        displayNames.setDisplayName("旧显示名称", for: .guitarPro, fileName: name(candidates[1]))
        recent.opened(kind: .guitarPro, fileName: name(candidates[2]))
        let existing = folder.appendingPathComponent(name(candidates[3]))
        try originalBytes.write(to: existing)
        let beforeProfile = try settings.load(GpPracticeProfile.self, kind: .guitarPro, fileName: name(candidates[0]))
        let beforeNames = displayNames.customNames
        let beforeRecent = recent.projects
        var index = 0
        let draft = ScoreDraft(title: "新练习", tempo: 120, bars: [[.note(string: 1, fret: 5, duration: 1)]])
        let model = try ScoreDraftEditorModel(newDraft: draft, store: ScoreDraftStore(folder: root.appendingPathComponent("Drafts")))
        await model.save()
        XCTAssertEqual(model.exportAvailability, .ready)

        let published = try await model.publishPractice { saved in
            try await ScoreDraftPracticePublisher.publish(
                saved, documents: documents, settings: settings, recent: recent, displayNames: displayNames
            ) {
                defer { index += 1 }
                return candidates[index]
            }
        }

        XCTAssertEqual(published.standardizedFileURL.deletingLastPathComponent(), folder.standardizedFileURL)
        XCTAssertEqual(published.lastPathComponent, name(candidates[4]))
        XCTAssertTrue(try Data(contentsOf: published).starts(with: [0x50, 0x4b, 0x03, 0x04]))
        let practiceDocument = try ExternalDocument.receive(published, store: documents)
        XCTAssertEqual(practiceDocument.kind, .guitarPro)
        XCTAssertEqual(practiceDocument.url.resolvingSymlinksInPath(), published.resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: existing), originalBytes)
        XCTAssertEqual(try settings.load(GpPracticeProfile.self, kind: .guitarPro, fileName: name(candidates[0])), beforeProfile)
        XCTAssertFalse(settings.containsFileSettings(kind: .guitarPro, fileName: published.lastPathComponent))
        XCTAssertEqual(displayNames.customNames, beforeNames)
        XCTAssertEqual(recent.projects, beforeRecent)
    }

    func testNoUniqueNameDoesNotCreatePracticeFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ScoreDraftPracticePublisherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let documents = RiffLoopDocumentStore(documentsURL: root)
        let settings = FilePracticeSettingsStore(defaults: defaults)
        let recent = RecentProjectsStore(defaults: defaults)
        let names = DocumentDisplayNameStore(defaults: defaults)
        let identifier = UUID()
        let occupied = "草稿-\(identifier.uuidString).gp"
        try settings.save(GpPracticeProfile(lastPositionTick: 5), kind: .guitarPro, fileName: occupied)
        let draft = ScoreDraft(title: "练习", tempo: 100, bars: [[.rest(duration: 1)]])
        do {
            _ = try await ScoreDraftPracticePublisher.publish(
                draft, documents: documents, settings: settings, recent: recent, displayNames: names
            ) { identifier }
            XCTFail("A reused practice identity must be rejected")
        } catch ScoreDraftPracticePublishError.noUniqueName { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: documents.folderURL(for: .guitarPro).path))
        XCTAssertTrue(settings.containsFileSettings(kind: .guitarPro, fileName: occupied))
    }
}
