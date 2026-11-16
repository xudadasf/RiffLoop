import SwiftUI

private struct DraftEntryContext: Identifiable {
    let id = UUID()
    let bar: Int
    let index: Int
    let inserting: Bool
    let entry: ScoreDraftV2Entry
}

@MainActor
struct ScoreDraftEditorView: View {
    @ObservedObject var model: ScoreDraftV2EditorModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var recent: RecentProjectsStore
    @EnvironmentObject private var displayNames: DocumentDisplayNameStore
    @State private var bar = 0
    @State private var editing: DraftEntryContext?
    @State private var confirmDiscard = false
    @State private var confirmDeleteBar = false
    @State private var generatedURL: URL?
    @State private var practiceOpen = false

    var body: some View {
        List {
            metadata
            Section {
                Picker("小节", selection: $bar) {
                    ForEach(model.editor.draft.bars.indices, id: \.self) { index in Text("第 \(index + 1) 小节").tag(index) }
                }
                Text(timing).foregroundStyle(.secondary).accessibilityIdentifier("draft.barTiming")
                ForEach(model.editor.draft.bars[bar].indices, id: \.self) { index in
                    entryRow(index)
                }
                Menu("在小节末尾插入") { insertionButtons(at: model.editor.draft.bars[bar].count) }
                HStack {
                    Button("后加空白小节") {
                        if model.insertBlankBar(at: bar + 1) { bar += 1 }
                    }
                    Spacer()
                    Button("删除本小节", role: .destructive) { confirmDeleteBar = true }
                        .disabled(model.editor.draft.bars.count == 1)
                }
            } header: { Text("音符与节奏 · 标准定弦 · 4/4") }
            Section {
                Text(exportMessage).foregroundStyle(.secondary)
                Button("生成 GP 练习副本", systemImage: "doc.badge.plus") { Task { await publish() } }
                    .disabled(model.exportAvailability != .ready)
                    .accessibilityIdentifier("draft.publish")
                if let url = generatedURL {
                    Text("已生成：\(url.lastPathComponent)").font(.caption)
                    Button("打开刚生成的副本练习", systemImage: "play.fill") { practiceOpen = true }
                    ShareLink("分享 GP 副本", item: url)
                }
            } header: { Text("保存后使用") }
        }
        .buttonStyle(.borderless)
        .disabled(model.isBusy)
        .navigationTitle(model.editor.draft.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭") {
                    if model.closeDecision == .close { dismiss() }
                    else if model.closeDecision == .confirmDiscard { confirmDiscard = true }
                }.disabled(model.isBusy)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if model.isBusy { ProgressView() }
                Button("保存草稿") { Task { await model.save() } }.disabled(model.isBusy)
                    .accessibilityIdentifier("draft.save")
                Button("另存草稿") { Task { await model.saveAsNewCopy() } }.disabled(model.isBusy)
            }
        }
        .sheet(item: $editing) { context in
            NavigationStack {
                ScoreDraftEntryForm(entry: context.entry) { entry in
                    let success = context.inserting
                        ? model.insertEvent(bar: context.bar, at: context.index, event: entry)
                        : model.replaceEvent(bar: context.bar, index: context.index, with: entry)
                    if success { editing = nil }
                    return success
                }
            }.interactiveDismissDisabled()
        }
        .confirmationDialog("放弃未保存的修改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("放弃并关闭", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) { }
        }
        .confirmationDialog("删除第 \(bar + 1) 小节？", isPresented: $confirmDeleteBar, titleVisibility: .visible) {
            Button("删除小节", role: .destructive) {
                if model.removeBar(at: bar) { bar = min(bar, model.editor.draft.bars.count - 1) }
            }
            Button("取消", role: .cancel) { }
        }
        .alert("草稿", isPresented: Binding(get: { model.message != nil && editing == nil },
                                             set: { if !$0 { model.message = nil } })) {
            Button("好") { model.message = nil }
        } message: { Text(model.message ?? "") }
        .navigationDestination(isPresented: $practiceOpen) {
            if let url = generatedURL { GpPracticeView(initialURL: url) }
        }
    }

    private var metadata: some View {
        Section("曲谱信息") {
            LabeledContent("名称") {
                TextField("名称", text: Binding(get: { model.titleInput }, set: { model.setMetadataInput(title: $0, tempo: model.tempoInput) }))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("速度 BPM") {
                TextField("BPM", text: Binding(get: { model.tempoInput }, set: { model.setMetadataInput(title: model.titleInput, tempo: $0) }))
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
            if model.hasPendingMetadata {
                HStack {
                    Button("应用名称和速度") { _ = model.applyMetadata() }
                    Spacer()
                    Button("恢复原输入") { model.restoreMetadataInput() }
                }
            }
            Text(model.hasUnsavedChanges ? "有未保存修改" : "草稿已保存")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func entryRow(_ index: Int) -> some View {
        let entry = model.editor.draft.bars[bar][index]
        return HStack {
            Button {
                editing = .init(bar: bar, index: index, inserting: false, entry: entry)
            } label: {
                HStack {
                    Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                    Text(Self.label(entry)).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "pencil")
                }.padding(.vertical, 5)
            }.buttonStyle(.borderless)
            Menu {
                insertionButtons(at: index)
                Button("删除此项", role: .destructive) { _ = model.removeEvent(bar: bar, index: index) }
                    .disabled(model.editor.draft.bars[bar].count == 1)
            } label: { Image(systemName: "ellipsis.circle").padding(8) }
        }
    }

    @ViewBuilder private func insertionButtons(at index: Int) -> some View {
        Button("插入音符 / 休止") {
            editing = .init(bar: bar, index: index, inserting: true, entry: .beat(.init(duration: 4)))
        }
        Button("插入一组三连音") {
            editing = .init(bar: bar, index: index, inserting: true,
                            entry: .triplet(.init(beats: Array(repeating: .init(duration: 8), count: 3))))
        }
    }

    private var timing: String {
        guard let timing = model.editor.draft.barTimings?[bar] else { return "小节数据无效" }
        switch timing {
        case .complete: return "4 / 4 拍 · 完整"
        case let .incomplete(remaining): return "还差 \(Self.beats(remaining)) 拍，可先保存草稿"
        case let .overflow(extra): return "超出 \(Self.beats(extra)) 拍，请调整时值或移到下一小节"
        }
    }

    private static func beats(_ ticks: Int) -> String { String(format: "%.3g", Double(ticks) / 960) }

    private var exportMessage: String {
        switch model.exportAvailability {
        case .ready: return "生成的新副本会出现在 GP 练习库。之后修改草稿，需要重新生成副本。"
        case .busy: return "正在保存或生成副本…"
        case .unsaved: return "先应用未完成的输入并保存草稿。"
        case .conflict: return "保存版本已改变，请将本次编辑另存为新草稿。"
        case .incomplete: return "每个小节须正好四拍才能生成 GP；未完成的内容可以保存。"
        case .tooLarge: return "当前导出最多支持 64 小节、512 个音符及 512 个音符或休止位置；完整草稿仍可保存。"
        }
    }

    private func publish() async {
        do {
            let url = try await model.publishPractice { draft in
                try await ScoreDraftPracticePublisher.publish(draft, recent: recent, displayNames: displayNames)
            }
            displayNames.setDisplayName(model.editor.draft.title, for: .guitarPro, fileName: url.lastPathComponent)
            generatedURL = url
        } catch { model.message = error.localizedDescription }
    }

    static func label(_ entry: ScoreDraftV2Entry) -> String {
        func beat(_ value: ScoreDraftV2Beat) -> String {
            let notes = value.notes.isEmpty ? "休止" : value.notes.sorted { $0.string < $1.string }
                .map { "\($0.string)弦 \($0.fret)品" }.joined(separator: " + ")
            return "\(notes) · 1/\(value.duration)\(value.dots == 1 ? " 附点" : "")"
        }
        switch entry {
        case let .beat(value): return beat(value)
        case let .triplet(value): return "三连音 3:2\n" + value.beats.map(beat).joined(separator: " → ")
        }
    }
}

@MainActor
struct ScoreDraftEntryForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var inputs: [ScoreDraftBeatInput]
    @State private var message: String?
    @State private var discard = false
    private let original: [ScoreDraftBeatInput]
    private let triplet: Bool
    let apply: (ScoreDraftV2Entry) -> Bool

    init(entry: ScoreDraftV2Entry, apply: @escaping (ScoreDraftV2Entry) -> Bool) {
        let values: [ScoreDraftBeatInput]
        switch entry {
        case let .beat(beat): triplet = false; values = [ScoreDraftBeatInput(beat)]
        case let .triplet(group): triplet = true; values = group.beats.map(ScoreDraftBeatInput.init)
        }
        original = values; _inputs = State(initialValue: values); self.apply = apply
    }

    var body: some View {
        Form {
            Section {
                Text("填写要发声的弦与品位（0–36），留空的弦不发声。多根弦同时填写就是和弦；全部留空就是休止。")
                    .foregroundStyle(.secondary)
                if triplet {
                    Text("三个等时值的位置组成一组 3:2 三连音，组内可分别填写音符、和弦或休止。")
                    Picker("每个位置的时值", selection: Binding(get: { inputs[0].duration }, set: { duration in
                        for i in inputs.indices { inputs[i].duration = duration }
                    })) { durations }
                    Text("本组三连音共 \(String(format: "%.3g", 8.0 / Double(inputs[0].duration))) 拍（四分音符为一拍）。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(inputs.indices, id: \.self) { index in
                Section(triplet ? "三连音第 \(index + 1) 个位置" : "音符 / 休止") {
                    if !triplet {
                        Picker("时值", selection: $inputs[index].duration) { durations }
                        Toggle("附点（时长增加一半）", isOn: $inputs[index].dotted)
                    }
                    ForEach(0..<6, id: \.self) { string in
                        HStack {
                            Text("第 \(string + 1) 弦\(string == 0 ? "（最细）" : string == 5 ? "（最粗）" : "")")
                            Spacer()
                            TextField("不发声", text: $inputs[index].frets[string])
                                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 100)
                        }
                    }
                    Button("设为休止") { inputs[index].frets = Array(repeating: "", count: 6) }
                }
            }
        }
        .navigationTitle(triplet ? "三连音" : "音符与时值")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { if inputs == original { dismiss() } else { discard = true } }
            }
            ToolbarItem(placement: .confirmationAction) { Button("应用") { commit() } }
        }
        .confirmationDialog("放弃这次输入？", isPresented: $discard, titleVisibility: .visible) {
            Button("放弃输入", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) { }
        }
        .alert("无法应用", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
    }

    @ViewBuilder private var durations: some View {
        ForEach([1,2,4,8,16,32,64], id: \.self) { value in Text("1/\(value)").tag(value) }
    }

    private func commit() {
        do {
            let beats = try inputs.map { try $0.beat() }
            let entry: ScoreDraftV2Entry = triplet ? .triplet(.init(beats: beats)) : .beat(beats[0])
            guard apply(entry) else { message = "无法应用，请检查小节容量和输入；内容仍保留。"; return }
        } catch { message = error.localizedDescription }
    }
}
