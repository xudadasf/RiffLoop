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
    case pauseForSelection
    case preview(GpLoopBarRange)
    case commit(GpLoopBarRange)
    case cancelSelection
}

struct GpLoopSelectionStateMachine: Sendable {
    private enum State: Sendable {
        case idle
        case pressing(GpBarHit)
        case selecting(anchor: GpBarHit, current: GpBarHit)
    }

    private var state: State = .idle

    mutating func pointerDown(on bar: GpBarHit) -> GpLoopSelectionAction {
        state = .pressing(bar)
        return .none
    }

    mutating func longPressActivated() -> GpLoopSelectionAction {
        guard case let .pressing(anchor) = state else { return .none }
        state = .selecting(anchor: anchor, current: anchor)
        return .pauseForSelection
    }

    mutating func pointerMoved(to bar: GpBarHit) -> GpLoopSelectionAction {
        switch state {
        case .idle:
            return .none
        case .pressing:
            state = .pressing(bar)
            return .none
        case let .selecting(anchor, _):
            state = .selecting(anchor: anchor, current: bar)
            guard let range = normalizedRange(anchor: anchor, current: bar) else { return .none }
            return .preview(range)
        }
    }

    mutating func pointerUp() -> GpLoopSelectionAction {
        defer { state = .idle }
        switch state {
        case .idle:
            return .none
        case let .pressing(bar):
            return .seek(bar)
        case let .selecting(anchor, current):
            guard let range = normalizedRange(anchor: anchor, current: current) else {
                return .cancelSelection
            }
            return .commit(range)
        }
    }

    mutating func cancel() -> GpLoopSelectionAction {
        guard case .selecting = state else {
            state = .idle
            return .none
        }
        state = .idle
        return .cancelSelection
    }

    private func normalizedRange(anchor: GpBarHit, current: GpBarHit) -> GpLoopBarRange? {
        let first = anchor.index <= current.index ? anchor : current
        let last = anchor.index <= current.index ? current : anchor
        guard
            first.index >= 0,
            last.index >= first.index,
            first.startTick.isFinite,
            last.endTick.isFinite,
            last.endTick > first.startTick
        else { return nil }
        return GpLoopBarRange(
            firstBar: first.index,
            lastBar: last.index,
            startTick: first.startTick,
            endTick: last.endTick
        )
    }
}
