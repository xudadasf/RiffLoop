import SwiftUI

/// Edits a supplied task. The caller owns task loading and durable storage.
@MainActor
final class ScoreSequenceEditorModel: ObservableObject {
    @Published private(set) var plan: ScoreSequencePlan
    @Published private(set) var isSaving = false
    @Published var message: String?
    @Published var numberInputs: [Int: String]
    @Published var gapInputs: [Int: String]
    private var savedPlan: ScoreSequencePlan?
    private let saveAction: (ScoreSequencePlan) async throws -> Void
    private let offeredRegions: [ScoreSequenceRegionReference]

    init(plan: ScoreSequencePlan, isSaved: Bool, newRegions: [ScoreSequenceRegionReference] = [],
         save: @escaping (ScoreSequencePlan) async throws -> Void) {
        self.plan = plan
        self.savedPlan = isSaved ? plan : nil
        self.saveAction = save
        var seen = Set<ScoreSequenceRegionReference>()
        self.offeredRegions = newRegions.filter { seen.insert($0).inserted }
        self.numberInputs = Dictionary(uniqueKeysWithValues: plan.selectedEntries.enumerated().map { ($0.offset, String($0.element.number)) })
        self.gapInputs = Dictionary(uniqueKeysWithValues: plan.selectedEntries.map { ($0.number, String($0.gapAfter)) })
    }

    private var pendingNumbers: Set<Int> {
        Set(plan.selectedEntries.enumerated().compactMap { numberInputs[$0.offset] == String($0.element.number) ? nil : $0.offset })
    }

    private var pendingGaps: Set<Int> {
        Set(plan.selectedEntries.compactMap { gapInputs[$0.number] == String($0.gapAfter) ? nil : $0.number })
    }

    var hasUnsavedChanges: Bool { savedPlan != plan || !pendingNumbers.isEmpty || !pendingGaps.isEmpty }

    var newRegions: [ScoreSequenceRegionReference] {
        let existing = Set(plan.entries.map(\.reference))
        return offeredRegions.filter { !existing.contains($0) }
    }

    private func syncInputs() {
        numberInputs = Dictionary(uniqueKeysWithValues: plan.selectedEntries.enumerated().map { ($0.offset, String($0.element.number)) })
        gapInputs = Dictionary(uniqueKeysWithValues: plan.selectedEntries.map { ($0.number, String($0.gapAfter)) })
    }

    private func canApply(exceptNumber position: Int? = nil, exceptGap number: Int? = nil) -> Bool {
        guard pendingNumbers.subtracting(position.map { [$0] } ?? []).isEmpty,
              pendingGaps.subtracting(number.map { [$0] } ?? []).isEmpty else {
            message = "请先调整或恢复其他尚未应用的输入。"
            return false
        }
        return true
    }

    func assign(position: Int) {
        guard canApply(exceptNumber: position), let text = numberInputs[position] else { return }
        guard let number = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            message = "请输入已采用区域的顺序表框编号。"
            return
        }
        _ = change { try $0.assign(number: number, toPosition: position) }
    }

    func select(_ selected: Bool, number: Int) {
        guard canApply() else { return }
        _ = change { try $0.setSelected(selected, number: number) }
    }

    func appendNewRegions() {
        guard !isSaving, canApply() else { return }
        let references = newRegions
        guard !references.isEmpty else { return }
        var updated = plan
        do {
            try updated.append(references)
            plan = updated
            syncInputs()
            message = "已将 \(references.count) 个新区域追加到末尾，请保存计划。"
        } catch {
            message = "无法追加区域，请重新打开计划并核对素材。"
        }
    }

    func setGap(number: Int) {
        guard canApply(exceptGap: number), let text = gapInputs[number] else { return }
        guard let gap = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), (0...99).contains(gap) else {
            message = "空白小节请输入 0 到 99 之间的整数；0 表示连续。"
            return
        }
        _ = change { try $0.setGapAfter(gap, number: number) }
    }

    private func change(_ operation: (inout ScoreSequencePlan) throws -> Void) -> Bool {
        guard !isSaving else { return false }
        var updated = plan
        do {
            try operation(&updated)
            plan = updated
            syncInputs()
            return true
        } catch {
            message = "无法调整。请确认编号属于已采用区域，且内容有效。"
            return false
        }
    }

    func save() async {
        guard !isSaving, canApply() else { return }
        isSaving = true
        defer { isSaving = false }
        let snapshot = plan
        do {
            try snapshot.validate()
            try await saveAction(snapshot)
            savedPlan = snapshot
            message = "顺序和间隔已保存。"
        } catch {
            message = "保存失败：\(error.localizedDescription)"
        }
    }
}

struct ScoreSequenceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ScoreSequenceEditorModel
    @State private var confirmDiscard = false
    private let pageNumbers: [ScoreSequenceRegionReference: Int]
    private let materialURLs: [String: URL]

    /// `pageNumbers` maps references to the per-page numbers visible while drawing.
    /// The separately assigned sequence numbers are stable only within this task.
    init(plan: ScoreSequencePlan, isSaved: Bool = true,
         pageNumbers: [ScoreSequenceRegionReference: Int] = [:],
         materialURLs: [String: URL] = [:],
         newRegions: [ScoreSequenceRegionReference] = [],
         save: @escaping (ScoreSequencePlan) async throws -> Void) {
        _model = StateObject(wrappedValue: ScoreSequenceEditorModel(plan: plan, isSaved: isSaved, newRegions: newRegions, save: save))
        self.pageNumbers = pageNumbers
        self.materialURLs = materialURLs
    }

    var body: some View {
        List {
            Section {
                Text("输入另一个已采用的顺序表框编号并点“调整”，可交换两个写入位置。修改空白小节数后点“设置”。")
                Text("顺序表框编号是本任务内的编号，可能与画框页面的页内编号不同。")
                Text("0 表示连续，默认在区域之间插入 1 个空白小节；最后一个区域后不会插入。")
                Text("PDF 缩略图显示首页；区域页码以文字为准。")
                Text("自动分区与识别仍在开发，当前只能保存顺序和间隔。")
                    .foregroundStyle(.secondary)
            }
            if !model.newRegions.isEmpty {
                Section("新增区域") {
                    Text("已发现 \(model.newRegions.count) 个新画的区域。追加后请确认顺序并保存。")
                    Button("追加新区域到末尾") { model.appendNewRegions() }
                }
            }
            Section("已采用 · 写入顺序") {
                if model.plan.selectedEntries.isEmpty {
                    Text("没有采用的区域，请从下方选择。")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(model.plan.selectedEntries.enumerated()), id: \.offset) { index, entry in
                    ScoreSequencePositionRow(
                        position: index, entry: entry, pageNumber: pageNumbers[entry.reference],
                        materialURL: materialURLs[entry.reference.material.name],
                        isLast: index == model.plan.selectedEntries.count - 1,
                        numberText: Binding(get: { model.numberInputs[index] ?? String(entry.number) },
                                            set: { model.numberInputs[index] = $0 }),
                        gapText: Binding(get: { model.gapInputs[entry.number] ?? String(entry.gapAfter) },
                                         set: { model.gapInputs[entry.number] = $0 }),
                        assign: { model.assign(position: index) },
                        setGap: { model.setGap(number: entry.number) },
                        unselect: { model.select(false, number: entry.number) }
                    )
                }
            }
            let unselected = model.plan.entries.filter { !$0.isSelected }
            if !unselected.isEmpty {
                Section("未采用") {
                    ForEach(unselected, id: \.number) { entry in
                        HStack {
                            ScoreMaterialThumbnailView(url: materialURLs[entry.reference.material.name])
                            VStack(alignment: .leading, spacing: 3) {
                                Text("顺序表框 \(entry.number)").font(.headline)
                                Text(sourceDescription(entry, pageNumber: pageNumbers[entry.reference]))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("采用") { model.select(true, number: entry.number) }
                        }
                    }
                }
            }
        }
        .disabled(model.isSaving)
        .navigationTitle("区域顺序与间隔")
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("返回") {
                    if model.hasUnsavedChanges { confirmDiscard = true } else { dismiss() }
                }
                .disabled(model.isSaving)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { Task { await model.save() } }
                    .disabled(model.isSaving)
            }
        }
        .overlay {
            if model.isSaving {
                ProgressView("正在保存…").padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .confirmationDialog("放弃未保存的修改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) { }
        }
        .alert("区域顺序与间隔", isPresented: Binding(
            get: { model.message != nil }, set: { if !$0 { model.message = nil } }
        )) {
            Button("好") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }
}

private func sourceDescription(_ entry: ScoreSequenceEntry, pageNumber: Int?) -> String {
    let prefix = "\(entry.reference.material.name) · 第 \(entry.reference.pageIndex + 1) 页"
    return pageNumber.map { prefix + " · 页内框 \($0)" } ?? prefix + " · 页内框编号待确认"
}

private struct ScoreSequencePositionRow: View {
    let position: Int
    let entry: ScoreSequenceEntry
    let pageNumber: Int?
    let materialURL: URL?
    let isLast: Bool
    @Binding var numberText: String
    @Binding var gapText: String
    let assign: () -> Void
    let setGap: () -> Void
    let unselect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ScoreMaterialThumbnailView(url: materialURL)
                VStack(alignment: .leading, spacing: 4) {
                    Text("写入位置 \(position + 1)").font(.headline)
                    Text(sourceDescription(entry, pageNumber: pageNumber))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消采用", action: unselect)
            }
            HStack {
                Text("顺序表框编号")
                TextField("编号", text: $numberText)
                    .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                    .frame(width: 76)
                Button("调整", action: assign)
                Button("恢复") { numberText = String(entry.number) }
                Spacer()
            }
            HStack {
                Text("之后空白小节")
                TextField("小节数", text: $gapText)
                    .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                    .frame(width: 76)
                Button("设置", action: setGap)
                Button("恢复") { gapText = String(entry.gapAfter) }
                if isLast { Text("当前位于末尾，不插入空白").font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }
}
