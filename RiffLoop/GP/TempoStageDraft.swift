import Foundation

/// Edits stay here until Save. Each cell keeps its own unfinished input when focus moves.
struct TempoStageDraft {
    enum Field: String { case bpm, length }
    struct Row: Identifiable {
        var id: UUID
        var bpm: String
        var length: String
        var unit: TempoStageUnit

        init(_ stage: TempoStage) {
            id = stage.id; bpm = String(stage.bpm); length = String(stage.length); unit = stage.unit
        }

        subscript(_ field: Field) -> String {
            get { field == .bpm ? bpm : length }
            set { if field == .bpm { bpm = newValue } else { length = newValue } }
        }

        var lengthLabel: String { unit == .seconds ? "秒数" : "轮数" }
        var stage: TempoStage? {
            guard let bpm = Int(bpm), let length = Int(length) else { return nil }
            return TempoStage(id: id, bpm: bpm, unit: unit, length: length)
        }
    }

    let bpmRange: ClosedRange<Int>
    let timedOnly: Bool
    private(set) var rows: [Row]
    var order: TempoStageOrder
    private(set) var selectedID: UUID
    private(set) var field: Field = .bpm
    private var replaceOnDigit = true

    init(plan: TempoStagePlan, bpmRange: ClosedRange<Int>, timedOnly: Bool) {
        self.bpmRange = bpmRange
        self.timedOnly = timedOnly
        let initial = plan.stages.isEmpty
            ? TempoStagePlan.initial(bpm: bpmRange.lowerBound, unit: timedOnly ? .seconds : .loops, range: bpmRange).stages
            : plan.stages
        rows = initial.map(Row.init)
        selectedID = initial[0].id
        order = plan.order
    }

    // Every removal also moves the selection to a surviving row.
    var selectedIndex: Int { rows.firstIndex { $0.id == selectedID }! }
    var selected: Row { rows[selectedIndex] }
    var activeRange: ClosedRange<Int> { field == .bpm ? bpmRange : 1...9999 }

    var plan: TempoStagePlan? {
        let stages = rows.compactMap(\.stage)
        guard stages.count == rows.count else { return nil }
        let result = TempoStagePlan(stages: stages, order: order)
        return result.valid(in: bpmRange, timedOnly: timedOnly) ? result : nil
    }

    func valid(_ field: Field, in row: Row) -> Bool {
        guard let n = Int(row[field]) else { return false }
        return (field == .bpm ? bpmRange : 1...9999).contains(n)
    }

    mutating func select(_ id: UUID, _ field: Field) {
        guard rows.contains(where: { $0.id == id }) else { return }
        selectedID = id; self.field = field; replaceOnDigit = true
    }

    private var slot: Int { 2 * selectedIndex + (field == .length ? 1 : 0) }
    func canMove(_ offset: Int) -> Bool { (0..<(rows.count * 2)).contains(slot + offset) }
    mutating func move(_ offset: Int) {
        guard canMove(offset) else { return }
        let target = slot + offset
        select(rows[target / 2].id, target.isMultiple(of: 2) ? .bpm : .length)
    }

    mutating func enter(_ digit: Int) {
        guard (0...9).contains(digit) else { return }
        let i = selectedIndex, previous = rows[i][field]
        let text = (replaceOnDigit || previous == "0" ? "" : previous) + String(digit)
        guard text.count <= String(activeRange.upperBound).count else { return }
        rows[i][field] = text
        replaceOnDigit = false
    }

    mutating func backspace() {
        let i = selectedIndex
        rows[i][field] = replaceOnDigit ? "" : String(rows[i][field].dropLast())
        replaceOnDigit = false
    }

    mutating func nudge(_ delta: Int) {
        let i = selectedIndex, range = activeRange
        let n = Int(rows[i][field]).map { $0 + delta } ?? range.lowerBound
        rows[i][field] = String(min(range.upperBound, max(range.lowerBound, n)))
        replaceOnDigit = true
    }

    mutating func add() {
        var row = rows[rows.count - 1]
        row.id = UUID()
        rows.append(row)
        select(row.id, .bpm)
    }

    mutating func remove(_ id: UUID) {
        guard rows.count > 1, let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows.remove(at: i)
        if selectedID == id { select(rows[min(i, rows.count - 1)].id, field) }
    }

    mutating func setUnit(_ unit: TempoStageUnit, for id: UUID) {
        guard !timedOnly, let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].unit = unit
        select(id, .length)
    }

    var canRepeatLength: Bool {
        guard field == .length else { return false }
        let row = selected
        return valid(.length, in: row) && rows.contains { $0.unit == row.unit && $0.length != row.length }
    }

    mutating func repeatLength() {
        guard canRepeatLength else { return }
        let row = selected
        for i in rows.indices where rows[i].unit == row.unit { rows[i].length = row.length }
    }
}
