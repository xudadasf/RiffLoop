import Foundation

struct TransportAnchor: Equatable, Sendable {
    let mediaTime: TimeInterval
    let hostTime: TimeInterval
    let mediaRate: Double

    func hostTime(forMediaTime targetMediaTime: TimeInterval) -> TimeInterval {
        precondition(mediaRate > 0)
        return hostTime + (targetMediaTime - mediaTime) / mediaRate
    }

    func mediaTime(forHostTime targetHostTime: TimeInterval) -> TimeInterval {
        precondition(mediaRate > 0)
        return mediaTime + (targetHostTime - hostTime) * mediaRate
    }
}
