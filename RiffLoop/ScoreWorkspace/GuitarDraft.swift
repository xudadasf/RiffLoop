import Foundation

struct GuitarCurvePoint: Codable, Equatable, Sendable {
    var offset: Int
    var value: Int
}

struct GuitarNote: Codable, Equatable, Sendable {
    /// Guitar convention: 1 is the highest string. Unknown frets stay nil.
    var string: Int
    var fret: Int?
    var effects: [String: Double] = [:]
    var bend: [GuitarCurvePoint] = []
    var review: [String] = []
}

struct GuitarBeat: Codable, Equatable, Sendable {
    var duration: Int = 4
    var dots: Int = 0
    var tupletNumerator: Int = 1
    var tupletDenominator: Int = 1
    var notes: [GuitarNote] = []
    var effects: [String: Double] = [:]
    var whammy: [GuitarCurvePoint] = []
    var tremolo: Int = 0
    var text: String = ""
    var review: [String] = []

    var ticks: Double {
        if (effects["graceType"] ?? 0) > 0 { return 0 }
        return 3840 / Double(duration) * (2 - pow(0.5, Double(dots))) * Double(tupletDenominator) / Double(tupletNumerator)
    }
}

struct GuitarSource: Codable, Equatable, Sendable {
    var name: String
    var digest: String
    var page: Int
    var region: ScoreRegion
    var referenceTop: Double? = nil

    var isValid: Bool {
        region.isValid && page >= 0 && name.count <= 512 && digest.count == 64 &&
            (referenceTop.map { $0.isFinite && (0...region.y).contains($0) } ?? true)
    }
}

struct GuitarBar: Codable, Equatable, Sendable {
    var beats: [GuitarBeat] = [GuitarBeat(duration: 1)]
    var review: [String] = []
    var repeatStart: Bool = false
    var repeatCount: Int = 0
    var alternateEndings: Int = 0
    var section: String = ""
    var numerator: Int?
    var denominator: Int?
    var tempo: Int?
    var source: GuitarSource?
}

/// A separate, versioned editable document. No mutation of original images or GP files.
struct GuitarDraft: Codable, Equatable, Sendable {
    var version: Int = 3
    var title: String = "电吉他草稿"
    var tempo: Int = 100
    var numerator: Int = 4
    var denominator: Int = 4
    var tuning: [Int] = [40, 45, 50, 55, 59, 64]
    var capo: Int = 0
    var program: Int = 27
    var bars: [GuitarBar] = [GuitarBar()]

    func expectedTicks(_ bar: GuitarBar) -> Double {
        Double(bar.numerator ?? numerator) * 3840 / Double(bar.denominator ?? denominator)
    }
    var isComplete: Bool {
        isValidForStorage && bars.allSatisfy { abs($0.beats.reduce(0) { $0 + $1.ticks } - expectedTicks($0)) < 0.01 }
    }
    var isValidForStorage: Bool {
        let durations = [1, 2, 4, 8, 16, 32, 64]
        let denominators = [1, 2, 4, 8, 16, 32]
        guard version == 3, title.count <= 512, (1...999).contains(tempo), (1...32).contains(numerator),
              denominators.contains(denominator), tuning.count == 6, tuning.allSatisfy({ (0...127).contains($0) }),
              (0...24).contains(capo), (0...127).contains(program), (1...512).contains(bars.count),
              bars.reduce(0, { $0 + $1.beats.count }) <= 32768 else { return false }
        func curve(_ points: [GuitarCurvePoint]) -> Bool {
            points.count <= 32 && points.count != 1 && points.allSatisfy { (0...60).contains($0.offset) && (-24...24).contains($0.value) } &&
                zip(points, points.dropFirst()).allSatisfy { $0.0.offset <= $0.1.offset }
        }
        func messages(_ values: [String]) -> Bool { values.count <= 64 && values.allSatisfy { $0.count <= 512 } }
        func effects(_ values: [String: Double]) -> Bool { values.count <= 64 && values.allSatisfy { $0.key.count <= 64 && $0.value.isFinite && abs($0.value) <= 10000 } }
        return bars.allSatisfy { bar in
            (1...128).contains(bar.beats.count) && messages(bar.review) && bar.section.count <= 512 &&
            (0...99).contains(bar.repeatCount) && (0...255).contains(bar.alternateEndings) &&
            (1...32).contains(bar.numerator ?? numerator) && denominators.contains(bar.denominator ?? denominator) &&
            (1...999).contains(bar.tempo ?? tempo) &&
            (bar.source?.isValid ?? true) &&
            bar.beats.allSatisfy { beat in
                durations.contains(beat.duration) && (0...2).contains(beat.dots) &&
                (1...16).contains(beat.tupletNumerator) && (1...16).contains(beat.tupletDenominator) &&
                beat.notes.count <= 6 && Set(beat.notes.map(\.string)).count == beat.notes.count &&
                effects(beat.effects) && messages(beat.review) && curve(beat.whammy) &&
                [0, 8, 16, 32, 64].contains(beat.tremolo) && beat.text.count <= 512 &&
                beat.notes.allSatisfy { (1...6).contains($0.string) && ($0.fret.map { (0...36).contains($0) } ?? true) &&
                    effects($0.effects) && messages($0.review) && curve($0.bend) }
            }
        }
    }

    /// Preserve all candidate notes. Unknown rhythm is explicit and editable.
    static func placeholder(settings: ScoreRecognitionSettings, source: GuitarSource?, reason: String) -> GuitarBar {
        GuitarBar(beats: (0..<settings.numerator).map { _ in GuitarBeat(duration: settings.denominator) }, review: [reason], source: source)
    }
}
