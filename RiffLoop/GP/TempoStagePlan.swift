import Foundation

enum TempoStageUnit: String, Codable, CaseIterable { case seconds, loops }
enum TempoStageOrder: String, Codable, CaseIterable { case wrap, bounce }

struct TempoStage: Codable, Identifiable, Equatable {
    var id = UUID()
    var bpm: Int
    var unit: TempoStageUnit
    var length: Int
}

struct TempoStagePlan: Codable, Equatable {
    var stages: [TempoStage]
    var order: TempoStageOrder = .wrap

    static func initial(bpm: Int, unit: TempoStageUnit, range: ClosedRange<Int> = 30...300) -> Self {
        let first = min(range.upperBound, max(range.lowerBound, bpm))
        let speeds = [first, min(range.upperBound, first + 5), min(range.upperBound, first + 10)]
        var stages: [TempoStage] = []
        for speed in speeds where stages.last?.bpm != speed {
            stages.append(TempoStage(bpm: speed, unit: unit, length: unit == .loops ? 3 : 30))
        }
        return Self(stages: stages)
    }

    func valid(in range: ClosedRange<Int>, timedOnly: Bool) -> Bool {
        !stages.isEmpty && Set(stages.map(\.id)).count == stages.count && stages.allSatisfy {
            range.contains($0.bpm) && (1...9999).contains($0.length) && (!timedOnly || $0.unit == .seconds)
        }
    }
}

/// GP advances exclusively on an A/B completion from the player.
struct LoopStageProgress {
    private(set) var index = 0
    private(set) var rounds = 0
    private var direction = 1
    private var elapsed = 0.0
    private var started: TimeInterval?

    mutating func setPlaying(_ playing: Bool, now: TimeInterval) {
        if playing {
            if started == nil { started = now }
        } else if let start = started {
            elapsed += max(0, now - start)
            started = nil
        }
    }

    mutating func finishLoop(in plan: TempoStagePlan, now: TimeInterval) {
        guard plan.stages.indices.contains(index) else { return }
        rounds += 1
        let stage = plan.stages[index]
        let played = elapsed + (started.map { max(0, now - $0) } ?? 0)
        guard stage.unit == .loops ? rounds >= stage.length : played >= Double(stage.length) else { return }
        if plan.stages.count > 1 {
            if plan.order == .wrap { index = (index + 1) % plan.stages.count }
            else {
                if index == 0 { direction = 1 }
                if index == plan.stages.count - 1 { direction = -1 }
                index += direction
            }
        }
        rounds = 0
        elapsed = 0
        if started != nil { started = now }
    }
}

/// Converts subdivision indices to exact audio times, including changes beyond the scheduler's lookahead.
struct MetronomeStageSchedule {
    struct Segment {
        let index: Int
        let start: Double
        let firstEvent: Int64
        let interval: Double
    }
    let segments: [Segment]
    let cycleDuration: Double
    let cycleEvents: Int64

    init(plan: TempoStagePlan, beats: Int, subdivisions: Int) {
        var order = Array(plan.stages.indices)
        if plan.order == .bounce { order += order.dropFirst().dropLast().reversed() }
        var built: [Segment] = []
        var start = 0.0
        var firstEvent: Int64 = 0
        for index in order {
            let stage = plan.stages[index]
            let barDuration = 60 * Double(beats) / Double(stage.bpm)
            let measures = max(1, ceil(Double(stage.length) / barDuration - 1e-10))
            built.append(Segment(index: index, start: start, firstEvent: firstEvent,
                                 interval: 60 / Double(stage.bpm * subdivisions)))
            start += measures * barDuration
            firstEvent += Int64(measures) * Int64(beats * subdivisions)
        }
        segments = built
        cycleDuration = start
        cycleEvents = firstEvent
    }

    func time(of event: Int64) -> Double {
        let local = event % cycleEvents
        let segment = segments.last { $0.firstEvent <= local }!
        return Double(event / cycleEvents) * cycleDuration + segment.start + Double(local - segment.firstEvent) * segment.interval
    }

    func position(at time: Double) -> (stage: Int, nextEvent: Int64) {
        let time = max(0, time)
        let cycle = floor(time / cycleDuration)
        let local = max(0, time - cycle * cycleDuration)
        let segment = segments.last { $0.start <= local }!
        let offset = Int64(ceil((local - segment.start) / segment.interval - 1e-9))
        return (segment.index, Int64(cycle) * cycleEvents + segment.firstEvent + offset)
    }
}

struct MetronomeGapPattern: Codable, Equatable {
    var enabled = false
    var soundBars = 2
    var silentBars = 1

    var valid: Bool { (1...99).contains(soundBars) && (1...99).contains(silentBars) }

    func sounds(in measure: Int64, startingAt first: Int64 = 0) -> Bool {
        !enabled || measure < first || (measure - first) % Int64(soundBars + silentBars) < Int64(soundBars)
    }
}
