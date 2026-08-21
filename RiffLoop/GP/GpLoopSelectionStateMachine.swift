import Foundation

struct GpLoopBarRange: Codable, Equatable, Sendable {
    let firstBar: Int
    let lastBar: Int
    let startTick: Double
    let endTick: Double
}

func gpResumeTick(
    savedTick: Double,
    loopRange: GpLoopBarRange?,
    rangeLoopingEnabled: Bool
) -> Double {
    guard
        rangeLoopingEnabled,
        let loopRange,
        !(loopRange.startTick ..< loopRange.endTick).contains(savedTick)
    else { return savedTick }

    return loopRange.startTick
}

enum GpLoopSelectionAction: Equatable, Sendable {
    case none
    case seek(GpBarHit)
    case selectStart(GpLoopBarRange)
    case updatePreview(GpLoopBarRange)
    case commit(GpLoopBarRange)
    case cancelSelection
}

struct GpLoopSelectionStateMachine: Sendable {
    private enum State: Equatable, Sendable {
        case inactive
        case dragging(start: GpBarHit, current: GpBarHit)
    }

    private var state: State = .inactive

    var isDragging: Bool {
        if case .dragging = state { return true }
        return false
    }

    mutating func tap(on bar: GpBarHit) -> GpLoopSelectionAction {
        guard state == .inactive else { return .none }
        return .seek(bar)
    }

    mutating func dragStart(on bar: GpBarHit) -> GpLoopSelectionAction {
        guard
            state == .inactive,
            let range = normalizedRange(from: bar, to: bar)
        else { return .none }
        state = .dragging(start: bar, current: bar)
        return .selectStart(range)
    }

    mutating func dragUpdate(to bar: GpBarHit) -> GpLoopSelectionAction {
        guard
            case let .dragging(start, _) = state,
            let range = normalizedRange(from: start, to: bar)
        else { return .none }
        state = .dragging(start: start, current: bar)
        return .updatePreview(range)
    }

    mutating func dragEnd() -> GpLoopSelectionAction {
        guard case let .dragging(start, current) = state else { return .none }
        state = .inactive
        guard let range = normalizedRange(from: start, to: current) else {
            return .cancelSelection
        }
        return .commit(range)
    }

    mutating func dragCancel() -> GpLoopSelectionAction {
        guard state != .inactive else { return .none }
        state = .inactive
        return .cancelSelection
    }

    private func normalizedRange(from first: GpBarHit, to last: GpBarHit) -> GpLoopBarRange? {
        let firstSelectionStart = first.seekTick ?? first.startTick
        let lastSelectionStart = last.seekTick ?? last.startTick
        let lowerHit = firstSelectionStart <= lastSelectionStart ? first : last
        let upperHit = firstSelectionStart <= lastSelectionStart ? last : first
        let lowerTick = lowerHit.seekTick ?? lowerHit.startTick
        let upperTick = upperHit.seekEndTick ?? upperHit.endTick
        guard
            lowerHit.index >= 0,
            lowerTick.isFinite,
            upperTick.isFinite,
            upperTick > lowerTick
        else { return nil }
        return GpLoopBarRange(
            firstBar: min(lowerHit.index, upperHit.index),
            lastBar: max(lowerHit.index, upperHit.index),
            startTick: lowerTick,
            endTick: upperTick
        )
    }
}
