import SwiftUI

struct ScoreSequenceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var externalOpen: ScoreExternalOpenCoordinator
    @StateObject private var model: ScoreSequenceEditorModel
    @State private var confirmDiscard = false
    @State private var recognizing = false
    @State private var recognitionProgress = ""
    @State private var recognitionTask: Task<Void, Never>?
    @State private var generated: GuitarDraftDocument?
    private enum Input { case tempo, numerator, denominator, tuning, gap }
    @FocusState private var editingInput: Input?
    private let pageNumbers: [ScoreSequenceRegionReference: Int]
    private let materialURLs: [String: URL]

    init(plan: ScoreSequencePlan, isSaved: Bool = true,
         pageNumbers: [ScoreSequenceRegionReference: Int] = [:], materialURLs: [String: URL] = [:],
         newRegions: [ScoreSequenceRegionReference] = [], save: @escaping (ScoreSequencePlan) async throws -> Void) {
        _model = StateObject(wrappedValue: ScoreSequenceEditorModel(plan: plan, isSaved: isSaved, newRegions: newRegions, save: save))
        self.pageNumbers = pageNumbers
        self.materialURLs = materialURLs
    }

    var body: some View {
        List {
            Section("识别设置") {
                HStack {
                    Text("速度 BPM")
                    TextField("100", text: $model.tempoInput).frame(maxWidth: 90).focused($editingInput, equals: .tempo).accessibilityIdentifier("sequence.tempo")
                    Text("拍号")
                    TextField("4", text: $model.numeratorInput).frame(maxWidth: 65).focused($editingInput, equals: .numerator).accessibilityIdentifier("sequence.numerator")
                    Text("/")
                    TextField("4", text: $model.denominatorInput).frame(maxWidth: 65).focused($editingInput, equals: .denominator).accessibilityIdentifier("sequence.denominator")
                }.keyboardType(.numberPad)
                TextField("E2 A2 D3 G3 B3 E4", text: $model.tuningInput)
                    .focused($editingInput, equals: .tuning)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .accessibilityIdentifier("sequence.tuning")
                Text("调弦从第 6 弦到第 1 弦，音名用空格分开。BPM 和拍号由你设置。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("统一空白小节")
                    TextField("小节数", text: $model.uniformGapInput).keyboardType(.numberPad).frame(maxWidth: 90)
                        .focused($editingInput, equals: .gap)
                        .accessibilityIdentifier("sequence.gap")
                    Text("0 表示连续").font(.caption).foregroundStyle(.secondary)
                }
                Text("在每两个区域之间插入相同数量的空白小节，末尾不追加。具体位置的增删，识别后到核对编辑页的“小节”中操作。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.preservesLegacyGaps {
                    Text("旧任务含不同间隔，暂按原设置保留。填写上方数值即可统一替换。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.newRegions.isEmpty {
                Section("新增区域") {
                    Button("追加 \(model.newRegions.count) 个新区域到末尾") { model.appendNewRegions() }
                }
            }
            Section("连接顺序") {
                Text("新任务按画框页的编号排列；需要微调时点上移或下移。PDF 缩略图显示首页，以文字页码为准。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.plan.selectedEntries.isEmpty { Text("请从下方选择需要采用的区域。") }
                ForEach(Array(model.plan.selectedEntries.enumerated()), id: \.element.number) { index, entry in
                    HStack {
                        ScoreMaterialThumbnailView(url: materialURLs[entry.reference.material.name])
                        VStack(alignment: .leading, spacing: 4) {
                            Text("第 \(index + 1) 段 · 框 \(entry.number)").font(.headline)
                            Text(sourceDescription(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button("上移") { model.move(number: entry.number, offset: -1) }
                            .disabled(index == 0).accessibilityIdentifier("sequence.up.\(entry.number)")
                        Button("下移") { model.move(number: entry.number, offset: 1) }
                            .disabled(index == model.plan.selectedEntries.count - 1)
                            .accessibilityIdentifier("sequence.down.\(entry.number)")
                        Button("不采用") { model.select(false, number: entry.number) }
                            .accessibilityIdentifier("sequence.exclude.\(entry.number)")
                    }
                    .accessibilityElement(children: .contain).accessibilityIdentifier("sequence.row.\(entry.number)")
                }
            }
            let unselected = model.plan.entries.filter { !$0.isSelected }
            if !unselected.isEmpty {
                Section("未采用") {
                    ForEach(unselected, id: \.number) { entry in
                        HStack {
                            Text("框 \(entry.number) · \(sourceDescription(entry))")
                            Spacer()
                            Button("采用") { model.select(true, number: entry.number) }
                                .accessibilityIdentifier("sequence.include.\(entry.number)")
                        }
                    }
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        // Explicit styles prevent List from forwarding one tap to all row buttons.
        .buttonStyle(.bordered)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button("返回", systemImage: "chevron.left") {
                    editingInput = nil
                    if model.hasUnsavedChanges { confirmDiscard = true } else { dismiss() }
                }
                .buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("sequence.back")
                Spacer()
            }.padding(.horizontal).padding(.vertical, 4).background(.bar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                if let message = model.message {
                    Text(message).font(.callout).foregroundStyle(.red).accessibilityIdentifier("sequence.message")
                }
                HStack {
                    Text(model.hasUnsavedChanges ? "识别时会自动保存当前设置" : (model.status ?? "设置已保存"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("识别并进入编辑") { startRecognition() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(model.plan.selectedEntries.isEmpty).accessibilityIdentifier("sequence.recognize")
                }
            }.padding().background(.bar)
        }
        .disabled(model.isSaving || recognizing)
        .navigationTitle("区域顺序与间隔").navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { editingInput = nil; Task { await model.save() } }
                    .disabled(model.isSaving || recognizing).accessibilityIdentifier("sequence.save")
            }
        }
        .overlay {
            if recognizing {
                VStack(spacing: 12) {
                    ProgressView(recognitionProgress)
                    Button("停止识别并保留草稿") { recognitionTask?.cancel() }.buttonStyle(.bordered)
                }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).disabled(false)
            } else if model.isSaving {
                ProgressView("正在保存…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .fullScreenCover(item: $generated) { GuitarDraftEditorView(document: $0) }
        .interactiveDismissDisabled(recognizing || model.hasUnsavedChanges)
        .onChange(of: recognizing) { _, active in
            if active { externalOpen.beginRegionEditing() }
            else if generated == nil { externalOpen.endRegionEditing() }
        }
        .confirmationDialog("放弃未保存的修改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) { }
        }
    }

    private func sourceDescription(_ entry: ScoreSequenceEntry) -> String {
        let prefix = "\(entry.reference.material.name) · 第 \(entry.reference.pageIndex + 1) 页"
        return pageNumbers[entry.reference].map { prefix + " · 素材框 \($0)" } ?? prefix
    }

    private func startRecognition() {
        guard !recognizing, !model.isSaving else { return }
        editingInput = nil
        recognizing = true
        recognitionProgress = "正在保存设置…"
        recognitionTask = Task {
            defer { recognizing = false; recognitionTask = nil }
            guard await model.save() else { return }
            let plan = model.plan
            do {
                recognitionProgress = "正在核对素材和区域…"
                let regions = try await TabRecognitionPipeline.regions(plan: plan, materialURLs: materialURLs)
                let draft = try await TabRecognitionPipeline.shared.recognize(regions: regions, settings: plan.effectiveSettings) { current, total in
                    await MainActor.run { recognitionProgress = "正在识别第 \(current) / \(total) 个区域…" }
                }
                let id = try await GuitarDraftStore().create(draft)
                generated = .init(id: id, draft: draft)
            } catch { model.message = "识别未完成：\(error.localizedDescription)" }
        }
    }
}
