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

enum TempoStageTransport: Equatable { case gp, standalone }

/// A read-only snapshot in the stage's own unit. Reading it never advances playback.
struct TempoStageReadout: Equatable {
    let index: Int
    let count: Int
    let bpm: Int
    let unit: TempoStageUnit
    let remaining: Int

    init(plan: TempoStagePlan, index: Int, secondsPlayed: Double, loopsCompleted: Int = 0) {
        let stage = plan.stages[index]
        self.index = index
        count = plan.stages.count
        bpm = stage.bpm
        unit = stage.unit
        switch stage.unit {
        case .seconds: remaining = Int(ceil(max(0, Double(stage.length) - max(0, secondsPlayed))))
        case .loops: remaining = max(0, stage.length - loopsCompleted)
        }
    }

    var stageLabel: String { "阶段 \(index + 1)/\(count) · \(bpm) BPM" }

    func summary(for transport: TempoStageTransport) -> String {
        if unit == .loops { return "\(stageLabel) · 剩 \(remaining) 轮" }
        let clock = String(format: "%d:%02d", remaining / 60, remaining % 60)
        let wait = remaining == 0 ? (transport == .gp ? " · 等本轮结束" : " · 等本小节结束") : ""
        return "\(stageLabel) · 剩 \(clock)\(wait)"
    }
}

/// GP advances exclusively on an A/B completion from the player.
struct LoopStageProgress {
    private(set) var index = 0
    private(set) var rounds = 0
    private var direction = 1
    private var elapsed = 0.0
    private var started: TimeInterval?

    var clockRunning: Bool { started != nil }

    /// Prepare a fresh occurrence. The score-playing acknowledgement starts its clock.
    @discardableResult
    mutating func start(at index: Int, in plan: TempoStagePlan) -> Bool {
        guard plan.stages.indices.contains(index) else { return false }
        self = LoopStageProgress()
        self.index = index
        return true
    }

    /// A new A/B range restarts this stage, retaining its place on a bouncing plan.
    /// Playback acknowledgement, rather than selection, starts the new clock.
    mutating func restartCurrentStage() {
        rounds = 0
        elapsed = 0
        started = nil
    }

    private func secondsPlayed(at now: TimeInterval) -> Double {
        elapsed + (started.map { max(0, now - $0) } ?? 0)
    }

    func readout(in plan: TempoStagePlan, now: TimeInterval) -> TempoStageReadout {
        TempoStageReadout(plan: plan, index: index, secondsPlayed: secondsPlayed(at: now), loopsCompleted: rounds)
    }

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
        guard stage.unit == .loops ? rounds >= stage.length : secondsPlayed(at: now) >= Double(stage.length) else { return }
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

    /// The first occurrence is always on the outward leg of a bouncing plan.
    func start(of stage: Int) -> Segment? {
        segments.first { $0.index == stage }
    }

    func position(at time: Double) -> (stage: Int, nextEvent: Int64, elapsedInStage: Double) {
        let time = max(0, time)
        let cycle = floor(time / cycleDuration)
        let local = max(0, time - cycle * cycleDuration)
        let segment = segments.last { $0.start <= local }!
        let elapsedInStage = local - segment.start
        let offset = Int64(ceil(elapsedInStage / segment.interval - 1e-9))
        return (segment.index, Int64(cycle) * cycleEvents + segment.firstEvent + offset, elapsedInStage)
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
