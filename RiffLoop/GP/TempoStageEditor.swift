import SwiftUI

struct TempoStageEditorButton: View {
    let plan: TempoStagePlan
    let bpmRange: ClosedRange<Int>
    let timedOnly: Bool
    let apply: (TempoStagePlan) -> Void
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack {
                Label("编辑阶段", systemImage: "slider.horizontal.3")
                Spacer()
                Text("\(plan.stages.count) 个阶段").foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $open) {
            TempoStageEditor(plan: plan, bpmRange: bpmRange, timedOnly: timedOnly, apply: apply)
        }
    }
}

private struct TempoStageEditor: View {
    struct Row: Identifiable {
        var id: UUID
        var bpm: String
        var length: String
        var unit: TempoStageUnit

        init(_ stage: TempoStage) {
            id = stage.id
            bpm = String(stage.bpm)
            length = String(stage.length)
            unit = stage.unit
        }

        var value: TempoStage? {
            guard let bpm = Int(bpm), let length = Int(length) else { return nil }
            return TempoStage(id: id, bpm: bpm, unit: unit, length: length)
        }
    }

    let bpmRange: ClosedRange<Int>
    let timedOnly: Bool
    let apply: (TempoStagePlan) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row]
    @State private var order: TempoStageOrder

    init(plan: TempoStagePlan, bpmRange: ClosedRange<Int>, timedOnly: Bool, apply: @escaping (TempoStagePlan) -> Void) {
        self.bpmRange = bpmRange
        self.timedOnly = timedOnly
        self.apply = apply
        _rows = State(initialValue: plan.stages.map(Row.init))
        _order = State(initialValue: plan.order)
    }

    private var result: TempoStagePlan? {
        let stages = rows.compactMap(\.value)
        let plan = TempoStagePlan(stages: stages, order: order)
        return stages.count == rows.count && plan.valid(in: bpmRange, timedOnly: timedOnly) ? plan : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("循环方向", selection: $order) {
                        Text("首尾相连").tag(TempoStageOrder.wrap)
                        Text("往返循环").tag(TempoStageOrder.bounce)
                    }.pickerStyle(.segmented)
                } footer: {
                    Text(timedOnly ? "达到设定秒数后，下一小节第一拍换速。" : "达到设定的秒数或轮数后，下一轮 A/B 循环换速。")
                }
                ForEach($rows) { $row in
                    Section {
                        LabeledContent("BPM") {
                            TextField("BPM", text: $row.bpm).keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing).accessibilityLabel("阶段 BPM")
                        }
                        if !timedOnly {
                            Picker("持续方式", selection: $row.unit) {
                                Text("时间").tag(TempoStageUnit.seconds)
                                Text("循环次数").tag(TempoStageUnit.loops)
                            }.pickerStyle(.segmented)
                        }
                        let label = row.unit == .seconds ? "持续秒数" : "循环次数"
                        LabeledContent(label) {
                            TextField(label, text: $row.length).keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing).accessibilityLabel(label)
                        }
                    } header: {
                        HStack {
                            Text("阶段 \((rows.firstIndex { $0.id == row.id } ?? 0) + 1)")
                            Spacer()
                            Button("删除") {
                                let id = row.id
                                rows.removeAll { $0.id == id }
                            }
                                .disabled(rows.count == 1)
                        }
                    }
                }
                Section {
                    Button {
                        guard var next = rows.last else { return }
                        next.id = UUID()
                        rows.append(next)
                    } label: { Label("添加阶段", systemImage: "plus") }
                    if result == nil {
                        Text("请输入 \(bpmRange.lowerBound)–\(bpmRange.upperBound) BPM，秒数或轮数为 1–9999 的整数。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("自定义阶梯")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { if let result { apply(result); dismiss() } }
                        .disabled(result == nil)
                }
            }
        }
    }
}
