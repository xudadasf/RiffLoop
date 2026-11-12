import Foundation
import Combine

enum ScoreDraftCloseDecision: Equatable {
    case waitForOperation
    case confirmDiscard
    case close
}

enum ScoreDraftExportAvailability: Equatable {
    case ready
    case busy
    case unsaved
    case conflict
    case incomplete
    case tooLarge
}

enum ScoreDraftPracticeStateError: LocalizedError {
    case notReady
    case sourceChanged

    var errorDescription: String? {
        switch self {
        case .notReady: "请先保存完整且受支持的草稿，再创建练习副本。"
        case .sourceChanged: "草稿已在其他位置修改，请先核对；本次内容仍保留。"
        }
    }
}

/// State for a future new-draft editor. This does not import GP files, consume
/// recognition results, navigate, or write to the practice library.
@MainActor
final class ScoreDraftEditorModel: ObservableObject {
    typealias SaveAction = @MainActor (UUID, ScoreDraft, ScoreDraft?) async throws -> Void

    @Published private(set) var editor: ScoreDraftEditor
    @Published private(set) var persistedID: UUID?
    @Published private(set) var isSaving = false
    @Published private(set) var isPublishing = false
    @Published private(set) var needsReload = false
    @Published private(set) var titleInput: String
    @Published private(set) var tempoInput: String
    @Published var message: String?

    private var savedDraft: ScoreDraft?
    private let newID: UUID
    private let saveAction: SaveAction
    private let loadAction: @MainActor (UUID) async throws -> ScoreDraft

    private init(draft: ScoreDraft, savedID: UUID?, save: @escaping SaveAction,
                 load: @escaping @MainActor (UUID) async throws -> ScoreDraft) throws {
        editor = try ScoreDraftEditor(draft: draft)
        persistedID = savedID
        savedDraft = savedID == nil ? nil : draft
        newID = UUID()
        titleInput = draft.title
        tempoInput = String(draft.tempo)
        saveAction = save
        loadAction = load
    }

    convenience init(newDraft: ScoreDraft, store: ScoreDraftStore = ScoreDraftStore()) throws {
        try self.init(draft: newDraft, savedID: nil, save: Self.makeSaveAction(store),
                      load: { try await store.load($0) })
    }

    /// Injected for deterministic saving/failure tests; production uses the store.
    convenience init(newDraft: ScoreDraft, save: @escaping SaveAction) throws {
        try self.init(draft: newDraft, savedID: nil, save: save,
                      load: { _ in throw ScoreDraftStoreError.invalidFile })
    }

    static func open(id: UUID, store: ScoreDraftStore = ScoreDraftStore()) async throws -> ScoreDraftEditorModel {
        let draft = try await store.load(id)
        return try ScoreDraftEditorModel(draft: draft, savedID: id, save: makeSaveAction(store),
                                         load: { try await store.load($0) })
    }

    private static func makeSaveAction(_ store: ScoreDraftStore) -> SaveAction {
        { id, draft, expected in
            if let expected {
                try await store.update(draft, id: id, replacing: expected)
            } else {
                try await store.create(draft, id: id)
            }
        }
    }

    var hasPendingMetadata: Bool {
        titleInput != editor.draft.title || tempoInput != String(editor.draft.tempo)
    }

    var hasUnsavedChanges: Bool {
        savedDraft != editor.draft || hasPendingMetadata
    }

    private var isBusy: Bool { isSaving || isPublishing }

    var closeDecision: ScoreDraftCloseDecision {
        if isBusy { return .waitForOperation }
        return hasUnsavedChanges ? .confirmDiscard : .close
    }

    var exportAvailability: ScoreDraftExportAvailability {
        if isBusy { return .busy }
        if needsReload { return .conflict }
        if hasUnsavedChanges { return .unsaved }
        if !editor.draft.isComplete { return .incomplete }
        if editor.draft.bars.count > ScoreDraftExporter.maximumBars ||
            editor.draft.bars.reduce(0, { $0 + $1.count }) > ScoreDraftExporter.maximumEvents { return .tooLarge }
        return .ready
    }

    func setMetadataInput(title: String, tempo: String) {
        guard !isBusy else { return }
        titleInput = title
        tempoInput = tempo
    }

    func restoreMetadataInput() {
        guard !isBusy else { return }
        titleInput = editor.draft.title
        tempoInput = String(editor.draft.tempo)
    }

    @discardableResult
    func applyMetadata() -> Bool {
        guard !isBusy else { return false }
        guard let tempo = Int(tempoInput.trimmingCharacters(in: .whitespacesAndNewlines)), (1...999).contains(tempo) else {
            message = "请输入 1 到 999 的速度。"
            return false
        }
        guard change({ try $0.setMetadata(title: titleInput, tempo: tempo) }) else { return false }
        titleInput = editor.draft.title
        tempoInput = String(editor.draft.tempo)
        return true
    }

    @discardableResult
    func replaceEvent(bar: Int, index: Int, with event: ScoreDraftEvent) -> Bool {
        change { try $0.replaceEvent(bar: bar, index: index, with: event) }
    }

    @discardableResult
    func insertEvent(bar: Int, at index: Int, event: ScoreDraftEvent) -> Bool {
        change { try $0.insertEvent(bar: bar, at: index, event: event) }
    }

    @discardableResult
    func removeEvent(bar: Int, index: Int) -> Bool {
        change { try $0.removeEvent(bar: bar, index: index) }
    }

    @discardableResult
    func insertBlankBar(at index: Int) -> Bool {
        change { try $0.insertBlankBar(at: index) }
    }

    @discardableResult
    func removeBar(at index: Int) -> Bool {
        change { try $0.removeBar(at: index) }
    }

    private func change(_ operation: (inout ScoreDraftEditor) throws -> Void) -> Bool {
        guard !isBusy else { return false }
        var updated = editor
        do {
            try operation(&updated)
            editor = updated
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func save() async {
        guard !isBusy else { return }
        guard !hasPendingMetadata else {
            message = "请先应用或恢复未完成的标题和速度输入。"
            return
        }
        guard !needsReload else {
            message = "草稿已在其他位置修改；可先将本次内容另存为新草稿。"
            return
        }
        guard hasUnsavedChanges else { return }
        isSaving = true
        defer { isSaving = false }
        let snapshot = editor.draft
        let targetID = persistedID ?? newID
        do {
            try await saveAction(targetID, snapshot, savedDraft)
            persistedID = targetID
            savedDraft = snapshot
            needsReload = false
            message = nil
        } catch ScoreDraftStoreError.conflict {
            needsReload = true
            message = "草稿已在其他位置修改，本次编辑仍保留；请先核对后再处理。"
        } catch {
            message = "保存失败，本次编辑仍保留：\(error.localizedDescription)"
        }
    }

    /// A conflict can be resolved without overwriting either version.
    func saveAsNewCopy() async {
        guard !isBusy else { return }
        guard !hasPendingMetadata else {
            message = "请先应用或恢复未完成的标题和速度输入。"
            return
        }
        isSaving = true
        defer { isSaving = false }
        let snapshot = editor.draft
        let targetID = UUID()
        do {
            try await saveAction(targetID, snapshot, nil)
            persistedID = targetID
            savedDraft = snapshot
            needsReload = false
            message = nil
        } catch {
            message = "另存失败，本次编辑仍保留：\(error.localizedDescription)"
        }
    }

    /// Check the saved version again before the caller creates a practice copy.
    /// The editor stays frozen through the action. Another window can still
    /// change its own draft after this check; the action receives this snapshot.
    func publishPractice(using action: @MainActor (ScoreDraft) async throws -> URL) async throws -> URL {
        guard exportAvailability == .ready, let id = persistedID, let snapshot = savedDraft else {
            throw ScoreDraftPracticeStateError.notReady
        }
        isPublishing = true
        defer { isPublishing = false }
        try Task.checkCancellation()
        let current: ScoreDraft
        do { current = try await loadAction(id) }
        catch {
            if error is CancellationError { throw error }
            needsReload = true
            message = "无法读取已保存的草稿，本次内容仍保留：\(error.localizedDescription)"
            throw error
        }
        try Task.checkCancellation()
        guard current == snapshot else {
            needsReload = true
            message = ScoreDraftPracticeStateError.sourceChanged.localizedDescription
            throw ScoreDraftPracticeStateError.sourceChanged
        }
        return try await action(snapshot)
    }
}
