import Foundation

struct GpLoopBarRange: Codable, Equatable, Sendable {
    let firstBar: Int
    let lastBar: Int
    let startTick: Double
    let endTick: Double
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
    private enum State: Sendable {
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
        let lowerHit = first.index <= last.index ? first : last
        let upperHit = first.index <= last.index ? last : first
        guard
            lowerHit.index >= 0,
            lowerHit.startTick.isFinite,
            upperHit.endTick.isFinite,
            upperHit.endTick > lowerHit.startTick
        else { return nil }
        return GpLoopBarRange(
            firstBar: lowerHit.index,
            lastBar: upperHit.index,
            startTick: lowerHit.startTick,
            endTick: upperHit.endTick
        )
    }
}
