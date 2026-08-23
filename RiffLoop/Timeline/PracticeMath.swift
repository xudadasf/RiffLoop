import Foundation

struct TapTempoTracker {
    private let maximumIntervals: Int
    private let resetAfterMilliseconds: Int64
    private var intervals: [Int64] = []
    private var previousTap: Int64?

    init(maximumIntervals: Int = 6, resetAfterMilliseconds: Int64 = 2_000) {
        self.maximumIntervals = maximumIntervals
        self.resetAfterMilliseconds = resetAfterMilliseconds
    }

    mutating func recordTap(timestampMilliseconds: Int64) -> Double? {
        defer { previousTap = timestampMilliseconds }
        guard
            let previousTap,
            timestampMilliseconds > previousTap,
            timestampMilliseconds - previousTap <= resetAfterMilliseconds
        else {
            intervals.removeAll()
            return nil
        }

        intervals.append(timestampMilliseconds - previousTap)
        if intervals.count > maximumIntervals {
            intervals.removeFirst(intervals.count - maximumIntervals)
        }
        let average = Double(intervals.reduce(0, +)) / Double(intervals.count)
        return min(max(60_000 / average, 30), 300)
    }

    mutating func reset() {
        intervals.removeAll()
        previousTap = nil
    }
}

func snapToNearestBeat(
    _ position: TimeInterval,
    beatOffset: TimeInterval?,
    bpm: Double
) -> TimeInterval {
    guard let beatOffset else { return position }
    let interval = 60 / min(max(bpm, 30), 300)
    let index = ((position - beatOffset) / interval).rounded()
    return max(0, beatOffset + index * interval)
}

struct SpeedLadderUpdate: Equatable, Sendable {
    let completedLoops: Int
    let playbackSpeed: Double
}

func speedLadderRoundInProgress(completedLoops: Int, loopsPerStep: Int) -> Int {
    max(0, completedLoops) % max(1, loopsPerStep) + 1
}

func speedAfterCompletedLoop(
    currentSpeed: Double,
    targetSpeed: Double,
    previousCompletedLoops: Int,
    enabled: Bool,
    loopsPerStep: Int = 3,
    speedStep: Double = 0.05
) -> SpeedLadderUpdate {
    let loops = max(0, previousCompletedLoops) + 1
    let current = min(max(currentSpeed, 0.25), 1.5)
    let target = min(max(targetSpeed, 0.25), 1.5)
    let next = enabled && loops % max(1, loopsPerStep) == 0 && current < target
        ? min(current + min(max(speedStep, 0.01), 0.25), target)
        : current
    return SpeedLadderUpdate(completedLoops: loops, playbackSpeed: next)
}
