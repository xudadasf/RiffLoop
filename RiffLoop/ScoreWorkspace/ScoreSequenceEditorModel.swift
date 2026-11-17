import SwiftUI

/// Form values stay independent of list operations and are committed together.
@MainActor
final class ScoreSequenceEditorModel: ObservableObject {
    @Published private(set) var plan: ScoreSequencePlan
    @Published private(set) var isSaving = false
    @Published var message: String?
    @Published private(set) var status: String?
    @Published var tempoInput: String
    @Published var numeratorInput: String
    @Published var denominatorInput: String
    @Published var tuningInput: String
    @Published var uniformGapInput: String
    private var savedPlan: ScoreSequencePlan?
    private var initialGapInput: String
    private let saveAction: (ScoreSequencePlan) async throws -> Void
    private let offeredRegions: [ScoreSequenceRegionReference]

    init(plan: ScoreSequencePlan, isSaved: Bool, newRegions: [ScoreSequenceRegionReference] = [],
         save: @escaping (ScoreSequencePlan) async throws -> Void) {
        self.plan = plan
        self.savedPlan = isSaved ? plan : nil
        self.saveAction = save
        var seen = Set<ScoreSequenceRegionReference>()
        self.offeredRegions = newRegions.filter { seen.insert($0).inserted }
        let settings = plan.effectiveSettings
        tempoInput = String(settings.tempo)
        numeratorInput = String(settings.numerator)
        denominatorInput = String(settings.denominator)
        tuningInput = settings.tuningText
        let gaps = Set(plan.selectedEntries.dropLast().map(\.gapAfter))
        let initial = plan.uniformGapAfter.map(String.init) ?? (gaps.count <= 1 ? String(gaps.first ?? 1) : "")
        uniformGapInput = initial
        initialGapInput = initial
    }

    var preservesLegacyGaps: Bool {
        initialGapInput.isEmpty && uniformGapInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var hasUnsavedChanges: Bool {
        let settings = plan.effectiveSettings
        return savedPlan != plan || Int(tempoInput.trimmingCharacters(in: .whitespacesAndNewlines)) != settings.tempo ||
            Int(numeratorInput.trimmingCharacters(in: .whitespacesAndNewlines)) != settings.numerator ||
            Int(denominatorInput.trimmingCharacters(in: .whitespacesAndNewlines)) != settings.denominator ||
            ScoreRecognitionSettings.parseTuning(tuningInput) != settings.tuning ||
            uniformGapInput.trimmingCharacters(in: .whitespacesAndNewlines) != initialGapInput
    }
    var newRegions: [ScoreSequenceRegionReference] {
        let existing = Set(plan.entries.map(\.reference))
        return offeredRegions.filter { !existing.contains($0) }
    }

    private func change(_ operation: (inout ScoreSequencePlan) throws -> Void) {
        guard !isSaving else { return }
        var updated = plan
        do {
            try operation(&updated)
            plan = updated
            message = nil; status = nil
        } catch { message = "无法调整区域顺序，请重新打开任务核对素材。" }
    }

    func move(number: Int, offset: Int) {
        let selected = plan.selectedEntries
        guard let index = selected.firstIndex(where: { $0.number == number }),
              selected.indices.contains(index + offset) else { return }
        change { try $0.assign(number: number, toPosition: index + offset) }
    }

    func select(_ selected: Bool, number: Int) { change { try $0.setSelected(selected, number: number) } }

    func appendNewRegions() {
        let references = newRegions
        guard !references.isEmpty else { return }
        change { try $0.append(references) }
    }

    /// One validation/one write. Invalid fields never partially replace the plan.
    @discardableResult
    func save() async -> Bool {
        guard !isSaving else { return false }
        message = nil; status = nil
        guard let tempo = Int(tempoInput.trimmingCharacters(in: .whitespacesAndNewlines)), (1...999).contains(tempo) else {
            message = "速度 BPM 请输入 1 到 999。"; return false
        }
        guard let numerator = Int(numeratorInput.trimmingCharacters(in: .whitespacesAndNewlines)), (1...32).contains(numerator),
              let denominator = Int(denominatorInput.trimmingCharacters(in: .whitespacesAndNewlines)),
              [1, 2, 4, 8, 16, 32].contains(denominator) else {
            message = "请检查拍号：分子为 1 到 32，分母为 1、2、4、8、16 或 32。"; return false
        }
        guard let tuning = ScoreRecognitionSettings.parseTuning(tuningInput) else {
            message = "请输入六根弦的音名，例如 E2 A2 D3 G3 B3 E4。"; return false
        }
        let gap: Int?
        if preservesLegacyGaps { gap = nil }
        else {
            guard let value = Int(uniformGapInput.trimmingCharacters(in: .whitespacesAndNewlines)), (0...99).contains(value) else {
                message = "统一空白小节数请输入 0 到 99；0 表示连续连接。"; return false
            }
            gap = value
        }
        isSaving = true
        defer { isSaving = false }
        do {
            var updated = plan
            try updated.setRecognitionSettings(.init(tempo: tempo, numerator: numerator, denominator: denominator, tuning: tuning))
            if let gap { try updated.setUniformGapAfter(gap) }
            try updated.validate()
            try await saveAction(updated)
            plan = updated; savedPlan = updated
            tempoInput = String(tempo); numeratorInput = String(numerator); denominatorInput = String(denominator)
            tuningInput = updated.effectiveSettings.tuningText
            uniformGapInput = gap.map(String.init) ?? ""; initialGapInput = uniformGapInput
            status = "已保存"
            return true
        } catch { message = "保存失败：\(error.localizedDescription)"; return false }
    }
}
