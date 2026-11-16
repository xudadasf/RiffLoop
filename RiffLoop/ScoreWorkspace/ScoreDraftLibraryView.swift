import SwiftUI

private struct RhythmDraftRow: Identifiable {
    let id: UUID
    let title: String
    let detail: String
}

private struct RhythmDraftSession: Identifiable {
    let id = UUID()
    let model: ScoreDraftV2EditorModel
}

@MainActor
struct ScoreDraftLibraryView: View {
    @EnvironmentObject private var externalOpen: ScoreExternalOpenCoordinator
    @State private var rows: [RhythmDraftRow] = []
    @State private var busy = false
    @State private var message: String?
    @State private var session: RhythmDraftSession?
    private let store = ScoreDraftV2Store()

    var body: some View {
        List {
            Section {
                Text("新建六线谱草稿，逐小节编辑音符、休止、附点、三连音和同拍多弦。保存后可生成 GP 副本并进入练习。")
                Text("当前支持标准定弦、4/4。图片识别、已有 GP 的编辑及延音、滑音等技巧尚未接入。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("新建草稿", systemImage: "plus") { create() }
                    .accessibilityIdentifier("draft.new")
            }
            Section("已保存的草稿") {
                if rows.isEmpty { Text("还没有草稿").foregroundStyle(.secondary) }
                ForEach(rows) { row in
                    Button { Task { await open(row.id) } } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(row.title).foregroundStyle(.primary)
                            Text(row.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .disabled(busy)
        .navigationTitle("草稿编辑")
        .toolbar { Button("刷新", systemImage: "arrow.clockwise") { Task { await refresh() } } }
        .task { await refresh() }
        .fullScreenCover(item: $session, onDismiss: {
            externalOpen.endRegionEditing()
            Task { await refresh() }
        }) { context in
            NavigationStack { ScoreDraftEditorView(model: context.model) }
                .interactiveDismissDisabled()
        }
        .alert("草稿", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
    }

    private func create() {
        do {
            let draft = ScoreDraftV2(title: "新草稿", tempo: 100, bars: [[.beat(.init(duration: 1))]])
            let model = try ScoreDraftV2EditorModel(newDraft: draft, store: store)
            externalOpen.beginRegionEditing()
            session = RhythmDraftSession(model: model)
        } catch { message = error.localizedDescription }
    }

    private func open(_ id: UUID) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let model = try await ScoreDraftV2EditorModel.open(id: id, store: store)
            externalOpen.beginRegionEditing()
            session = RhythmDraftSession(model: model)
        } catch { message = "无法打开草稿：\(error.localizedDescription)" }
    }

    private func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            var loaded: [RhythmDraftRow] = []
            for id in try await store.listIDs() {
                do {
                    let draft = try await store.load(id)
                    loaded.append(.init(id: id, title: draft.title.isEmpty ? "未命名草稿" : draft.title,
                                        detail: "\(draft.bars.count) 小节 · BPM \(draft.tempo)"))
                } catch {
                    loaded.append(.init(id: id, title: "无法读取的草稿", detail: error.localizedDescription))
                }
            }
            rows = loaded
        } catch { message = error.localizedDescription }
    }
}
