import Foundation

/// Atomic edits of a new rhythm draft; incomplete bars remain saveable.
struct ScoreDraftV2Editor {
    private(set) var draft: ScoreDraftV2

    init(draft: ScoreDraftV2) throws {
        guard draft.isValidForStorage else { throw ScoreDraftEditorError.invalidDraft }
        self.draft = draft
    }

    mutating func setMetadata(title: String, tempo: Int) throws {
        var next = draft
        next.title = title; next.tempo = tempo
        try accept(next)
    }

    mutating func replaceEvent(bar: Int, index: Int, with entry: ScoreDraftV2Entry) throws {
        try position(bar, index)
        var next = draft
        next.bars[bar][index] = entry
        try accept(next)
    }

    mutating func insertEvent(bar: Int, at index: Int, event: ScoreDraftV2Entry) throws {
        guard draft.bars.indices.contains(bar), (0...draft.bars[bar].count).contains(index) else {
            throw ScoreDraftEditorError.invalidPosition
        }
        var next = draft
        next.bars[bar].insert(event, at: index)
        try accept(next)
    }

    mutating func removeEvent(bar: Int, index: Int) throws {
        try position(bar, index)
        guard draft.bars[bar].count > 1 else { throw ScoreDraftEditorError.cannotRemoveLastEvent }
        var next = draft
        next.bars[bar].remove(at: index)
        try accept(next)
    }

    mutating func insertBlankBar(at index: Int) throws {
        guard (0...draft.bars.count).contains(index) else { throw ScoreDraftEditorError.invalidPosition }
        var next = draft
        next.bars.insert([.beat(.init(duration: 1))], at: index)
        try accept(next)
    }

    mutating func removeBar(at index: Int) throws {
        guard draft.bars.indices.contains(index) else { throw ScoreDraftEditorError.invalidPosition }
        guard draft.bars.count > 1 else { throw ScoreDraftEditorError.cannotRemoveLastBar }
        var next = draft
        next.bars.remove(at: index)
        try accept(next)
    }

    private func position(_ bar: Int, _ index: Int) throws {
        guard draft.bars.indices.contains(bar), draft.bars[bar].indices.contains(index) else {
            throw ScoreDraftEditorError.invalidPosition
        }
    }

    private mutating func accept(_ next: ScoreDraftV2) throws {
        guard next.isValidForStorage else { throw ScoreDraftEditorError.invalidDraft }
        draft = next
    }
}

/// Form input stays separate until Apply; malformed frets are never coerced to 0.
struct ScoreDraftBeatInput: Equatable {
    var duration = 4
    var dotted = false
    var frets = Array(repeating: "", count: 6)

    init(_ beat: ScoreDraftV2Beat = .init(duration: 4)) {
        duration = beat.duration; dotted = beat.dots == 1
        for note in beat.notes { frets[note.string - 1] = String(note.fret) }
    }

    func beat() throws -> ScoreDraftV2Beat {
        guard frets.count == 6 else { throw ScoreDraftEditorError.invalidEvent }
        var notes: [ScoreDraftV2Note] = []
        for (index, input) in frets.enumerated() {
            let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { continue }
            guard let fret = Int(value), (0...36).contains(fret) else { throw ScoreDraftEditorError.invalidEvent }
            notes.append(.init(string: index + 1, fret: fret))
        }
        let value = ScoreDraftV2Beat(duration: duration, dots: dotted ? 1 : 0, notes: notes)
        guard value.isValid else { throw ScoreDraftEditorError.invalidEvent }
        return value
    }
}
