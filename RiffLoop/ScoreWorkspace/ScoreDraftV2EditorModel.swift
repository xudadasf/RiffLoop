import Foundation
import Combine

/// Editor state for new rhythm drafts. Existing GP files and v1 drafts are not rewritten.
@MainActor
final class ScoreDraftV2EditorModel: ObservableObject {
    typealias SaveAction = @MainActor (UUID, ScoreDraftV2, ScoreDraftV2?) async throws -> Void

    @Published private(set) var editor: ScoreDraftV2Editor
    @Published private(set) var persistedID: UUID?
    @Published private(set) var isSaving = false
    @Published private(set) var isPublishing = false
    @Published private(set) var needsReload = false
    @Published private(set) var titleInput: String
    @Published private(set) var tempoInput: String
    @Published var message: String?

    private var savedDraft: ScoreDraftV2?
    private let newID: UUID
    private let saveAction: SaveAction
    private let loadAction: @MainActor (UUID) async throws -> ScoreDraftV2

    private init(draft: ScoreDraftV2, savedID: UUID?, save: @escaping SaveAction,
                 load: @escaping @MainActor (UUID) async throws -> ScoreDraftV2) throws {
        editor = try ScoreDraftV2Editor(draft: draft)
        persistedID = savedID
        savedDraft = savedID == nil ? nil : draft
        newID = UUID()
        titleInput = draft.title
        tempoInput = String(draft.tempo)
        saveAction = save
        loadAction = load
    }

    convenience init(newDraft: ScoreDraftV2, store: ScoreDraftV2Store = ScoreDraftV2Store()) throws {
        try self.init(draft: newDraft, savedID: nil, save: Self.makeSaveAction(store),
                      load: { try await store.load($0) })
    }

    /// Injected for deterministic saving/failure tests; production uses the store.
    convenience init(newDraft: ScoreDraftV2, save: @escaping SaveAction) throws {
        try self.init(draft: newDraft, savedID: nil, save: save,
                      load: { _ in throw ScoreDraftV2StoreError.invalidFile })
    }

    static func open(id: UUID, store: ScoreDraftV2Store = ScoreDraftV2Store()) async throws -> ScoreDraftV2EditorModel {
        let draft = try await store.load(id)
        return try ScoreDraftV2EditorModel(draft: draft, savedID: id, save: makeSaveAction(store),
                                         load: { try await store.load($0) })
    }

    private static func makeSaveAction(_ store: ScoreDraftV2Store) -> SaveAction {
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

    var isBusy: Bool { isSaving || isPublishing }

    var closeDecision: ScoreDraftCloseDecision {
        if isBusy { return .waitForOperation }
        return hasUnsavedChanges ? .confirmDiscard : .close
    }

    var exportAvailability: ScoreDraftExportAvailability {
        if isBusy { return .busy }
        if needsReload { return .conflict }
        if hasUnsavedChanges { return .unsaved }
        if editor.draft.barTimings?.allSatisfy({ $0 == .complete }) != true { return .incomplete }
        if !editor.draft.canExport { return .tooLarge }
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
    func replaceEvent(bar: Int, index: Int, with event: ScoreDraftV2Entry) -> Bool {
        change { try $0.replaceEvent(bar: bar, index: index, with: event) }
    }

    @discardableResult
    func insertEvent(bar: Int, at index: Int, event: ScoreDraftV2Entry) -> Bool {
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

    private func change(_ operation: (inout ScoreDraftV2Editor) throws -> Void) -> Bool {
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
        } catch ScoreDraftV2StoreError.conflict {
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
    func publishPractice(using action: @MainActor (ScoreDraftV2) async throws -> URL) async throws -> URL {
        guard exportAvailability == .ready, let id = persistedID, let snapshot = savedDraft else {
            throw ScoreDraftPracticeStateError.notReady
        }
        isPublishing = true
        defer { isPublishing = false }
        try Task.checkCancellation()
        let current: ScoreDraftV2
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
