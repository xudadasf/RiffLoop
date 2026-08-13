import Foundation

struct BeatEvent: Equatable, Sendable {
    let index: Int64
    let mediaTime: TimeInterval
    let isMeasureAccent: Bool
    let isGroupAccent: Bool
}

struct BeatTimeline: Equatable, Sendable {
    let bpm: Double
    let beatOffset: TimeInterval
    let subdivision: Subdivision
    let quarterNotesPerMeasure: Int
    let beatGrouping: [Int]
    let beatAccents: [BeatAccent]
    let accentPattern: [Int]

    init(
        bpm: Double,
        beatOffset: TimeInterval,
        subdivision: Subdivision,
        quarterNotesPerMeasure: Int = 4,
        beatGrouping: [Int]? = nil,
        beatAccents: [BeatAccent]? = nil,
        accentPattern: [Int] = [3, 3, 2]
    ) {
        self.bpm = min(max(bpm, 30), 300)
        self.beatOffset = beatOffset
        self.subdivision = subdivision
        self.quarterNotesPerMeasure = min(max(quarterNotesPerMeasure, 1), 16)
        let grouping = beatGrouping ?? [self.quarterNotesPerMeasure]
        self.beatGrouping = grouping.reduce(0, +) == self.quarterNotesPerMeasure
            && grouping.allSatisfy { $0 > 0 } ? grouping : [self.quarterNotesPerMeasure]
        self.beatAccents = beatAccents?.count == self.quarterNotesPerMeasure
            ? beatAccents!
            : defaultBeatAccents(
                beatsPerMeasure: self.quarterNotesPerMeasure,
                grouping: self.beatGrouping
            )
        self.accentPattern = accentPattern.filter { $0 > 0 }.isEmpty ? [3, 3, 2] : accentPattern
    }

    var eventInterval: TimeInterval {
        60 / bpm / subdivision.eventsPerQuarterNote
    }

    var eventsPerMeasure: Int {
        max(1, Int((subdivision.eventsPerQuarterNote * Double(quarterNotesPerMeasure)).rounded()))
    }

    func eventIndex(atOrAfter mediaTime: TimeInterval) -> Int64 {
        let position = (mediaTime - beatOffset) / eventInterval
        return Int64(ceil(position - 1e-9))
    }

    func event(at index: Int64) -> BeatEvent {
        BeatEvent(
            index: index,
            mediaTime: beatOffset + Double(index) * eventInterval,
            isMeasureAccent: eventIndexInMeasure(index) == 0,
            isGroupAccent: positiveModulo(index, Int64(subdivision.eventsInGroup)) == 0
        )
    }

    func measureIndex(_ index: Int64) -> Int64 {
        Int64(floor(Double(index) / Double(eventsPerMeasure)))
    }

    func eventIndexInMeasure(_ index: Int64) -> Int {
        Int(positiveModulo(index, Int64(eventsPerMeasure)))
    }

    func beatIndex(_ index: Int64) -> Int {
        let position = Double(eventIndexInMeasure(index)) / subdivision.eventsPerQuarterNote
        return min(max(Int(floor(position + 1e-9)), 0), quarterNotesPerMeasure - 1)
    }

    func isBeatBoundary(_ index: Int64) -> Bool {
        let position = Double(eventIndexInMeasure(index)) / subdivision.eventsPerQuarterNote
        return abs(position - position.rounded()) < 1e-6
    }

    func beatAccent(_ index: Int64) -> BeatAccent {
        beatAccents[beatIndex(index)]
    }

    func shouldPlay(_ index: Int64, mode: RhythmMode) -> Bool {
        switch mode {
        case .click, .drums:
            return !isBeatBoundary(index) || beatAccent(index) != .muted
        case .backbeat:
            return isBeatBoundary(index) && [1, 3].contains(beatIndex(index))
                && beatAccent(index) != .muted
        case .firstBeat:
            return eventIndexInMeasure(index) == 0 && beatAccent(index) != .muted
        case .gapBars:
            return positiveModulo(measureIndex(index), 2) == 0
        case .offbeats:
            return eighthNoteIndex(index).map { positiveModulo($0, 2) != 0 } ?? false
        case .customAccent:
            guard let eighth = eighthNoteIndex(index) else { return false }
            let length = Int64(accentPattern.reduce(0, +))
            let position = positiveModulo(eighth, length)
            var start: Int64 = 0
            for group in accentPattern {
                if position == start { return true }
                start += Int64(group)
            }
            return false
        }
    }

    private func eighthNoteIndex(_ index: Int64) -> Int64? {
        let position = Double(index) * 2 / subdivision.eventsPerQuarterNote
        let rounded = position.rounded()
        return abs(position - rounded) < 1e-6 ? Int64(rounded) : nil
    }
}

private func positiveModulo(_ value: Int64, _ divisor: Int64) -> Int64 {
    let remainder = value % divisor
    return remainder >= 0 ? remainder : remainder + divisor
}
