import Foundation

struct BeatEvent: Equatable, Sendable {
    let index: Int64
    let mediaTime: TimeInterval
    let isMeasureAccent: Bool
}

struct BeatTimeline: Equatable, Sendable {
    let bpm: Double
    let beatOffset: TimeInterval
    let subdivision: Subdivision
    let quarterNotesPerMeasure: Int

    init(
        bpm: Double,
        beatOffset: TimeInterval,
        subdivision: Subdivision,
        quarterNotesPerMeasure: Int = 4
    ) {
        self.bpm = min(max(bpm, 30), 300)
        self.beatOffset = beatOffset
        self.subdivision = subdivision
        self.quarterNotesPerMeasure = max(1, quarterNotesPerMeasure)
    }

    var eventInterval: TimeInterval {
        60 / bpm / Double(subdivision.eventsPerQuarterNote)
    }

    func eventIndex(atOrAfter mediaTime: TimeInterval) -> Int64 {
        let position = (mediaTime - beatOffset) / eventInterval
        return Int64(ceil(position - 1e-9))
    }

    func event(at index: Int64) -> BeatEvent {
        let eventsPerMeasure = subdivision.eventsPerQuarterNote * quarterNotesPerMeasure
        let normalizedRemainder = ((index % Int64(eventsPerMeasure)) + Int64(eventsPerMeasure))
            % Int64(eventsPerMeasure)

        return BeatEvent(
            index: index,
            mediaTime: beatOffset + Double(index) * eventInterval,
            isMeasureAccent: normalizedRemainder == 0
        )
    }
}

