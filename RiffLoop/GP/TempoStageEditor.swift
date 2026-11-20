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
        .accessibilityIdentifier(timedOnly ? "stages.edit.standalone" : "stages.edit.gp")
        .sheet(isPresented: $open) {
            TempoStageEditor(plan: plan, bpmRange: bpmRange, timedOnly: timedOnly, apply: apply)
        }
    }
}

private struct TempoStageEditor: View {
    let apply: (TempoStagePlan) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TempoStageDraft

    init(plan: TempoStagePlan, bpmRange: ClosedRange<Int>, timedOnly: Bool, apply: @escaping (TempoStagePlan) -> Void) {
        self.apply = apply
        _draft = State(initialValue: TempoStageDraft(plan: plan, bpmRange: bpmRange, timedOnly: timedOnly))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Picker("循环方向", selection: $draft.order) {
                    Text("首尾相连").tag(TempoStageOrder.wrap)
                    Text("往返循环").tag(TempoStageOrder.bounce)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                GeometryReader { size in
                    if size.size.width >= 460 {
                        HStack(alignment: .top, spacing: 12) {
                            stageList
                            Divider()
                            ScrollView { keypad(compact: false) }
                                .frame(width: min(210, size.size.width * 0.36))
                        }
                    } else {
                        VStack(spacing: 6) {
                            stageList
                            Divider()
                            keypad(compact: true)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 8)
            .background(Color(.systemGroupedBackground))
            .textSelection(.disabled)
            .navigationTitle("自定义阶梯")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { if let plan = draft.plan { apply(plan); dismiss() } }
                        .disabled(draft.plan == nil)
                        .accessibilityIdentifier("stages.save")
                }
            }
        }
    }

    private var stageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(draft.rows.enumerated()), id: \.element.id) { index, row in
                        stageRow(row, number: index + 1).id(row.id)
                    }
                    Button { draft.add() } label: {
                        Label("添加阶段", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("沿用最后一个阶段的数值，并选中新阶段的 BPM")
                    .accessibilityIdentifier("stages.add")
                    Text(draft.timedOnly ? "到时后，弹完整小节再换速。" : "到时或完成指定轮数后，弹完当前 A/B 循环再换速。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .onChange(of: draft.selectedID) { _, id in proxy.scrollTo(id, anchor: .center) }
        }
    }

    private func stageRow(_ row: TempoStageDraft.Row, number: Int) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text("阶段 \(number)").font(.subheadline.bold())
                Spacer()
                if !draft.timedOnly {
                    Menu {
                        Picker("持续方式", selection: Binding(get: { row.unit }, set: { draft.setUnit($0, for: row.id) })) {
                            Text("按秒数").tag(TempoStageUnit.seconds)
                            Text("按循环轮数").tag(TempoStageUnit.loops)
                        }
                    } label: {
                        HStack(spacing: 3) { Text(row.unit == .seconds ? "按秒" : "按轮"); Image(systemName: "chevron.down") }
                            .font(.subheadline).frame(minHeight: 44)
                    }
                    .accessibilityLabel("阶段 \(number) 持续方式")
                }
                Button { draft.remove(row.id) } label: {
                    Image(systemName: "trash").frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(draft.rows.count == 1)
                .accessibilityLabel("删除阶段 \(number)")
            }
            HStack(spacing: 6) {
                cell(.bpm, row: row, number: number)
                cell(.length, row: row, number: number)
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func cell(_ field: TempoStageDraft.Field, row: TempoStageDraft.Row, number: Int) -> some View {
        let selected = draft.selectedID == row.id && draft.field == field
        let valid = draft.valid(field, in: row)
        let title = field == .bpm ? "BPM" : row.lengthLabel
        return Button { draft.select(row.id, field) } label: {
            VStack(spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(row[field].isEmpty ? "—" : row[field]).font(.headline.monospacedDigit())
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(selected ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(!valid ? Color.orange : selected ? Color.accentColor : .clear, lineWidth: 2) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("阶段 \(number) \(title)")
        .accessibilityValue(row[field].isEmpty ? "未填写" : row[field])
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("stages.\(number).\(field.rawValue)")
    }

    private func keypad(compact: Bool) -> some View {
        let row = draft.selected
        let title = draft.field == .bpm ? "BPM" : row.lengthLabel
        let range = draft.activeRange
        return VStack(spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("阶段 \(draft.selectedIndex + 1) · \(title)").font(.subheadline.bold())
                    Text("\(range.lowerBound)–\(range.upperBound)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { draft.backspace() } label: {
                    Image(systemName: "delete.left").frame(width: 44, height: 44)
                }
                .accessibilityLabel("退格").keyboardShortcut(.delete, modifiers: [])
            }
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                let layout = compact ? [[1,2,3,4,5,6], [7,8,9,-1,0,-2]] : [[1,2,3], [4,5,6], [7,8,9], [-1,0,-2]]
                ForEach(layout, id: \.self) { line in
                    GridRow { ForEach(line, id: \.self) { key in padKey(key) } }
                }
            }
            HStack(spacing: 4) {
                Button { draft.move(-1) } label: { Text("上一项").frame(maxWidth: .infinity, minHeight: 44) }
                    .disabled(!draft.canMove(-1)).keyboardShortcut(.leftArrow, modifiers: [])
                Button { draft.move(1) } label: { Text("下一项").frame(maxWidth: .infinity, minHeight: 44) }
                    .disabled(!draft.canMove(1)).keyboardShortcut(.rightArrow, modifiers: [])
                    .accessibilityIdentifier("stages.next")
            }
            .font(.subheadline)
            if draft.field == .length {
                Button(row.unit == .seconds ? "统一所有按秒阶段的秒数" : "统一所有按轮阶段的轮数") { draft.repeatLength() }
                    .font(.footnote).frame(minHeight: 44).disabled(!draft.canRepeatLength)
            }
            if draft.plan == nil {
                Text("橙框数值超出范围或尚未填完，修正后即可保存。")
                    .font(.footnote).foregroundStyle(.orange)
            } else if !compact {
                Text("点数值后直接输入即可替换。用「下一项」连续填写。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func padKey(_ key: Int) -> some View {
        let digit = key >= 0
        let title = digit ? String(key) : key == -1 ? "−1" : "+1"
        let shortcut: Character = digit ? Character(String(key)) : key == -1 ? "-" : "+"
        return Button { if digit { draft.enter(key) } else { draft.nudge(key == -1 ? -1 : 1) } } label: {
            Text(title).font(.title3.monospacedDigit())
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("stages.key.\(key)")
        .keyboardShortcut(KeyEquivalent(shortcut), modifiers: [])
    }
}
