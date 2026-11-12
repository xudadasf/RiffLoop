import Foundation

// This is a new, isolated draft format. It neither opens nor rewrites v1 or GP files.
private struct V2Key: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    static func key(_ value: String) -> V2Key { V2Key(stringValue: value)! }
}

private func fields(_ decoder: Decoder, _ expected: Set<String>) throws -> KeyedDecodingContainer<V2Key> {
    let container = try decoder.container(keyedBy: V2Key.self)
    guard Set(container.allKeys.map(\.stringValue)) == expected else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                debugDescription: "Missing or unsupported v2 fields"))
    }
    return container
}

private func boundedArray<T: Decodable>(_ type: T.Type, from container: KeyedDecodingContainer<V2Key>,
                                        key: String, minimum: Int, maximum: Int) throws -> [T] {
    var values = try container.nestedUnkeyedContainer(forKey: .key(key))
    if let count = values.count, !(minimum...maximum).contains(count) {
        throw DecodingError.dataCorrupted(.init(codingPath: values.codingPath, debugDescription: "Invalid v2 array size"))
    }
    var result: [T] = []
    while !values.isAtEnd {
        guard result.count < maximum else {
            throw DecodingError.dataCorrupted(.init(codingPath: values.codingPath, debugDescription: "V2 array too large"))
        }
        result.append(try values.decode(T.self))
    }
    guard result.count >= minimum else {
        throw DecodingError.dataCorrupted(.init(codingPath: values.codingPath, debugDescription: "V2 array too small"))
    }
    return result
}

struct ScoreDraftV2Note: Codable, Equatable, Sendable {
    let string: Int // 1 is high E
    let fret: Int

    init(string: Int, fret: Int) { self.string = string; self.fret = fret }

    init(from decoder: Decoder) throws {
        let container = try fields(decoder, ["string", "fret"])
        string = try container.decode(Int.self, forKey: .key("string"))
        fret = try container.decode(Int.self, forKey: .key("fret"))
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid v2 note"))
        }
    }

    func encode(to encoder: Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Invalid v2 note"))
        }
        var container = encoder.container(keyedBy: V2Key.self)
        try container.encode(string, forKey: .key("string"))
        try container.encode(fret, forKey: .key("fret"))
    }

    var isValid: Bool { (1...6).contains(string) && (0...36).contains(fret) }
}

struct ScoreDraftV2Beat: Codable, Equatable, Sendable {
    let duration: Int
    let dots: Int
    let notes: [ScoreDraftV2Note] // Empty is a rest.

    init(duration: Int, dots: Int = 0, notes: [ScoreDraftV2Note] = []) {
        self.duration = duration; self.dots = dots; self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let container = try fields(decoder, ["duration", "dots", "notes"])
        duration = try container.decode(Int.self, forKey: .key("duration"))
        dots = try container.decode(Int.self, forKey: .key("dots"))
        notes = try boundedArray(ScoreDraftV2Note.self, from: container, key: "notes", minimum: 0, maximum: 6)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid v2 beat"))
        }
    }

    func encode(to encoder: Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Invalid v2 beat"))
        }
        var container = encoder.container(keyedBy: V2Key.self)
        try container.encode(duration, forKey: .key("duration"))
        try container.encode(dots, forKey: .key("dots"))
        try container.encode(notes, forKey: .key("notes"))
    }

    var isValid: Bool {
        [1, 2, 4, 8, 16, 32, 64].contains(duration) && (0...1).contains(dots) &&
            notes.count <= 6 && notes.allSatisfy(\.isValid) && Set(notes.map(\.string)).count == notes.count
    }

    /// Call only after validation. One whole 4/4 bar is 3840 ticks.
    fileprivate func ticks(triplet: Bool) -> Int {
        var value = 3840 / duration
        if dots == 1 { value = value * 3 / 2 }
        if triplet { value = value * 2 / 3 }
        return value
    }
}

struct ScoreDraftV2Ratio: Codable, Equatable, Sendable {
    let numerator: Int
    let denominator: Int

    init(numerator: Int, denominator: Int) { self.numerator = numerator; self.denominator = denominator }

    init(from decoder: Decoder) throws {
        let container = try fields(decoder, ["numerator", "denominator"])
        numerator = try container.decode(Int.self, forKey: .key("numerator"))
        denominator = try container.decode(Int.self, forKey: .key("denominator"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: V2Key.self)
        try container.encode(numerator, forKey: .key("numerator"))
        try container.encode(denominator, forKey: .key("denominator"))
    }
}

struct ScoreDraftV2Triplet: Codable, Equatable, Sendable {
    let tuplet: ScoreDraftV2Ratio
    let beats: [ScoreDraftV2Beat]

    init(beats: [ScoreDraftV2Beat], tuplet: ScoreDraftV2Ratio = .init(numerator: 3, denominator: 2)) {
        self.tuplet = tuplet; self.beats = beats
    }

    init(from decoder: Decoder) throws {
        let container = try fields(decoder, ["tuplet", "beats"])
        tuplet = try container.decode(ScoreDraftV2Ratio.self, forKey: .key("tuplet"))
        beats = try boundedArray(ScoreDraftV2Beat.self, from: container, key: "beats", minimum: 3, maximum: 3)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid v2 triplet"))
        }
    }

    func encode(to encoder: Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Invalid v2 triplet"))
        }
        var container = encoder.container(keyedBy: V2Key.self)
        try container.encode(tuplet, forKey: .key("tuplet"))
        try container.encode(beats, forKey: .key("beats"))
    }

    var isValid: Bool {
        guard tuplet.numerator == 3, tuplet.denominator == 2, beats.count == 3,
              let first = beats.first else { return false }
        return beats.allSatisfy { $0.isValid && $0.dots == 0 && $0.duration == first.duration }
    }
}

enum ScoreDraftV2Entry: Codable, Equatable, Sendable {
    case beat(ScoreDraftV2Beat)
    case triplet(ScoreDraftV2Triplet)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: V2Key.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        if keys == ["duration", "dots", "notes"] { self = .beat(try ScoreDraftV2Beat(from: decoder)) }
        else if keys == ["tuplet", "beats"] { self = .triplet(try ScoreDraftV2Triplet(from: decoder)) }
        else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported v2 entry")) }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .beat(value): try value.encode(to: encoder)
        case let .triplet(value): try value.encode(to: encoder)
        }
    }

    var isValid: Bool {
        switch self {
        case let .beat(value): return value.isValid
        case let .triplet(value): return value.isValid
        }
    }
}

enum ScoreDraftV2BarTiming: Equatable {
    case incomplete(remaining: Int)
    case complete
    case overflow(extra: Int)
}

struct ScoreDraftV2: Codable, Equatable, Sendable {
    let version: Int
    var title: String
    var tempo: Int
    var meter: ScoreDraftV2Ratio
    var tuning: [Int] // low E to high E, in MIDI semitones
    var bars: [[ScoreDraftV2Entry]]

    init(title: String, tempo: Int, bars: [[ScoreDraftV2Entry]]) {
        version = 2
        self.title = title; self.tempo = tempo
        meter = .init(numerator: 4, denominator: 4)
        tuning = [40, 45, 50, 55, 59, 64]
        self.bars = bars
    }

    init(from decoder: Decoder) throws {
        let container = try fields(decoder, ["version", "title", "tempo", "meter", "tuning", "bars"])
        version = try container.decode(Int.self, forKey: .key("version"))
        title = try container.decode(String.self, forKey: .key("title"))
        tempo = try container.decode(Int.self, forKey: .key("tempo"))
        meter = try container.decode(ScoreDraftV2Ratio.self, forKey: .key("meter"))
        tuning = try boundedArray(Int.self, from: container, key: "tuning", minimum: 6, maximum: 6)
        var barArray = try container.nestedUnkeyedContainer(forKey: .key("bars"))
        if let count = barArray.count, !(1...512).contains(count) {
            throw DecodingError.dataCorrupted(.init(codingPath: barArray.codingPath, debugDescription: "Invalid v2 bar count"))
        }
        var decodedBars: [[ScoreDraftV2Entry]] = []
        var totalBeats = 0
        var totalNotes = 0
        while !barArray.isAtEnd {
            guard decodedBars.count < 512 else {
                throw DecodingError.dataCorrupted(.init(codingPath: barArray.codingPath, debugDescription: "Too many v2 bars"))
            }
            var sourceBar = try barArray.nestedUnkeyedContainer()
            if let count = sourceBar.count, !(1...128).contains(count) {
                throw DecodingError.dataCorrupted(.init(codingPath: sourceBar.codingPath, debugDescription: "Invalid v2 bar size"))
            }
            var entries: [ScoreDraftV2Entry] = []
            var barBeats = 0
            while !sourceBar.isAtEnd {
                guard entries.count < 128 else {
                    throw DecodingError.dataCorrupted(.init(codingPath: sourceBar.codingPath, debugDescription: "Too many v2 entries"))
                }
                let entry = try sourceBar.decode(ScoreDraftV2Entry.self)
                guard entry.isValid else {
                    throw DecodingError.dataCorrupted(.init(codingPath: sourceBar.codingPath, debugDescription: "Invalid v2 entry"))
                }
                switch entry {
                case let .beat(value):
                    barBeats += 1; totalNotes += value.notes.count
                case let .triplet(value):
                    barBeats += 3; totalNotes += value.beats.reduce(0) { $0 + $1.notes.count }
                }
                guard barBeats <= 128, totalBeats + barBeats <= 32_768, totalNotes <= 32_768 else {
                    throw DecodingError.dataCorrupted(.init(codingPath: sourceBar.codingPath, debugDescription: "V2 draft exceeds limits"))
                }
                entries.append(entry)
            }
            guard !entries.isEmpty else {
                throw DecodingError.dataCorrupted(.init(codingPath: sourceBar.codingPath, debugDescription: "Empty v2 bar"))
            }
            totalBeats += barBeats
            decodedBars.append(entries)
        }
        bars = decodedBars
        guard isValidForStorage else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid v2 draft"))
        }
    }

    func encode(to encoder: Encoder) throws {
        guard isValidForStorage else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Invalid v2 draft"))
        }
        var container = encoder.container(keyedBy: V2Key.self)
        try container.encode(version, forKey: .key("version"))
        try container.encode(title, forKey: .key("title"))
        try container.encode(tempo, forKey: .key("tempo"))
        try container.encode(meter, forKey: .key("meter"))
        try container.encode(tuning, forKey: .key("tuning"))
        try container.encode(bars, forKey: .key("bars"))
    }

    /// Incomplete or overfull bars can be kept for editing; neither can export.
    var isValidForStorage: Bool {
        guard version == 2, title.utf16.count <= 512, title.unicodeScalars.count <= 256,
              (1...999).contains(tempo), meter.numerator == 4, meter.denominator == 4,
              tuning == [40, 45, 50, 55, 59, 64], (1...512).contains(bars.count) else { return false }
        var beatCount = 0
        var noteCount = 0
        for bar in bars {
            guard (1...128).contains(bar.count) else { return false }
            var barBeats = 0
            for entry in bar {
                guard entry.isValid else { return false }
                switch entry {
                case let .beat(value):
                    barBeats += 1; noteCount += value.notes.count
                case let .triplet(value):
                    barBeats += 3; noteCount += value.beats.reduce(0) { $0 + $1.notes.count }
                }
                guard barBeats <= 128, beatCount + barBeats <= 32_768, noteCount <= 32_768 else { return false }
            }
            beatCount += barBeats
        }
        return true
    }

    var barTimings: [ScoreDraftV2BarTiming]? {
        guard isValidForStorage else { return nil }
        return bars.map { bar in
            let ticks = bar.reduce(0) { result, entry in
                switch entry {
                case let .beat(value): return result + value.ticks(triplet: false)
                case let .triplet(value): return result + value.beats.reduce(0) { $0 + $1.ticks(triplet: true) }
                }
            }
            if ticks < 3840 { return .incomplete(remaining: 3840 - ticks) }
            if ticks > 3840 { return .overflow(extra: ticks - 3840) }
            return .complete
        }
    }

    /// Export bounds are deliberately lower than storage bounds. Exceeding
    /// them never truncates or prevents preserving the editable draft.
    var canExport: Bool {
        guard bars.count <= 64, barTimings?.allSatisfy({ $0 == .complete }) == true else { return false }
        var beatCount = 0
        var noteCount = 0
        for bar in bars {
            for entry in bar {
                switch entry {
                case let .beat(value):
                    beatCount += 1; noteCount += value.notes.count
                case let .triplet(value):
                    beatCount += 3; noteCount += value.beats.reduce(0) { $0 + $1.notes.count }
                }
                if beatCount > 512 || noteCount > 512 { return false }
            }
        }
        return true
    }
}
