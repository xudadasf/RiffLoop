import Foundation

struct GpLoopBarRange: Codable, Equatable, Sendable {
    let firstBar: Int
    let lastBar: Int
    let startTick: Double
    let endTick: Double
}

enum GpLoopPickStep: Equatable, Sendable {
    case inactive
    case start
    case end(startBar: Int)
}

enum GpLoopSelectionAction: Equatable, Sendable {
    case none
    case seek(GpBarHit)
    case selectStart(GpLoopBarRange)
    case commit(GpLoopBarRange)
    case rejectEndBeforeStart
    case cancelSelection
}

struct GpLoopSelectionStateMachine: Sendable {
    private enum State: Sendable {
        case inactive
        case awaitingStart
        case awaitingEnd(GpBarHit)
    }

    private var state: State = .inactive

    var step: GpLoopPickStep {
        switch state {
        case .inactive: .inactive
        case .awaitingStart: .start
        case let .awaitingEnd(start): .end(startBar: start.index)
        }
    }

    mutating func setPickingEnabled(_ enabled: Bool) -> GpLoopSelectionAction {
        if enabled {
            state = .awaitingStart
            return .none
        }
        let wasPicking = step != .inactive
        state = .inactive
        return wasPicking ? .cancelSelection : .none
    }

    mutating func tap(on bar: GpBarHit) -> GpLoopSelectionAction {
        switch state {
        case .inactive:
            return .seek(bar)
        case .awaitingStart:
            guard let range = range(from: bar, through: bar) else { return .none }
            state = .awaitingEnd(bar)
            return .selectStart(range)
        case let .awaitingEnd(start):
            guard bar.index >= start.index else { return .rejectEndBeforeStart }
            guard let range = range(from: start, through: bar) else { return .none }
            state = .inactive
            return .commit(range)
        }
    }

    private func range(from first: GpBarHit, through last: GpBarHit) -> GpLoopBarRange? {
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
