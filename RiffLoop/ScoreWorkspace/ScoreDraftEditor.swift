import Foundation

enum ScoreDraftEditorError: LocalizedError {
    case invalidDraft
    case invalidPosition
    case invalidEvent
    case cannotRemoveLastEvent
    case cannotRemoveLastBar
    case limitReached

    var errorDescription: String? {
        switch self {
        case .invalidDraft: "草稿无效或包含暂不支持的内容。"
        case .invalidPosition: "所选小节或音符不存在。"
        case .invalidEvent: "弦号、品位或时值不受支持。"
        case .cannotRemoveLastEvent: "每小节至少保留一个音符或休止符。"
        case .cannotRemoveLastBar: "草稿至少保留一个小节。"
        case .limitReached: "已达到草稿的小节或音符数量上限。"
        }
    }
}

enum ScoreDraftBarTiming: Equatable {
    case incomplete(remaining: Int)
    case complete
    case overflow(extra: Int)
}

/// Edits only the app's limited, newly created draft model. It does not import
/// GP files or write to the practice library. Timing is measured in 1/64 notes.
struct ScoreDraftEditor {
    private(set) var draft: ScoreDraft

    init(draft: ScoreDraft) throws {
        guard draft.isValid else { throw ScoreDraftEditorError.invalidDraft }
        self.draft = draft
    }

    func timing(of bar: Int) throws -> ScoreDraftBarTiming {
        guard draft.bars.indices.contains(bar) else { throw ScoreDraftEditorError.invalidPosition }
        let length = draft.bars[bar].reduce(0) { $0 + 64 / $1.duration }
        if length < 64 { return .incomplete(remaining: 64 - length) }
        if length > 64 { return .overflow(extra: length - 64) }
        return .complete
    }

    mutating func setMetadata(title: String, tempo: Int) throws {
        var updated = draft
        updated.title = title
        updated.tempo = tempo
        guard updated.isValid else { throw ScoreDraftEditorError.invalidDraft }
        draft = updated
    }

    mutating func replaceEvent(bar: Int, index: Int, with event: ScoreDraftEvent) throws {
        try checkEventPosition(bar: bar, index: index)
        guard event.isValid else { throw ScoreDraftEditorError.invalidEvent }
        draft.bars[bar][index] = event
    }

    mutating func insertEvent(bar: Int, at index: Int, event: ScoreDraftEvent) throws {
        guard draft.bars.indices.contains(bar), (0...draft.bars[bar].count).contains(index) else {
            throw ScoreDraftEditorError.invalidPosition
        }
        guard event.isValid else { throw ScoreDraftEditorError.invalidEvent }
        guard draft.bars[bar].count < 128 else { throw ScoreDraftEditorError.limitReached }
        draft.bars[bar].insert(event, at: index)
    }

    mutating func removeEvent(bar: Int, index: Int) throws {
        try checkEventPosition(bar: bar, index: index)
        guard draft.bars[bar].count > 1 else { throw ScoreDraftEditorError.cannotRemoveLastEvent }
        draft.bars[bar].remove(at: index)
    }

    /// A separator is a full 4/4 bar of silence, inserted at the requested position.
    mutating func insertBlankBar(at index: Int) throws {
        guard (0...draft.bars.count).contains(index) else { throw ScoreDraftEditorError.invalidPosition }
        guard draft.bars.count < 512 else { throw ScoreDraftEditorError.limitReached }
        draft.bars.insert([.rest(duration: 1)], at: index)
    }

    mutating func removeBar(at index: Int) throws {
        guard draft.bars.indices.contains(index) else { throw ScoreDraftEditorError.invalidPosition }
        guard draft.bars.count > 1 else { throw ScoreDraftEditorError.cannotRemoveLastBar }
        draft.bars.remove(at: index)
    }

    private func checkEventPosition(bar: Int, index: Int) throws {
        guard draft.bars.indices.contains(bar), draft.bars[bar].indices.contains(index) else {
            throw ScoreDraftEditorError.invalidPosition
        }
    }
}
