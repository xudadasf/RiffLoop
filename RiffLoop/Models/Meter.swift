import Foundation

enum BeatAccent: String, Codable, CaseIterable, Sendable {
    case strong
    case subAccent
    case normal
    case muted

    var label: String {
        switch self {
        case .strong: "强"
        case .subAccent: "次强"
        case .normal: "普通"
        case .muted: "静音"
        }
    }

    var next: Self {
        let values = Self.allCases
        return values[(values.firstIndex(of: self)! + 1) % values.count]
    }
}

enum RhythmMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case click
    case drums
    case backbeat
    case firstBeat
    case gapBars
    case offbeats
    case customAccent

    var id: Self { self }

    var label: String {
        switch self {
        case .click: "普通节拍"
        case .drums: "基础鼓机"
        case .backbeat: "只响 2 / 4 拍"
        case .firstBeat: "只响第一拍"
        case .gapBars: "响一小节 / 停一小节"
        case .offbeats: "只响反拍"
        case .customAccent: "自定义重音"
        }
    }
}

func parseAccentPattern(_ input: String) -> [Int]? {
    let separators = CharacterSet(charactersIn: "+ ,，")
    let values = input
        .components(separatedBy: separators)
        .filter { !$0.isEmpty }
        .compactMap(Int.init)
    let tokenCount = input.components(separatedBy: separators).filter { !$0.isEmpty }.count
    guard
        values.count == tokenCount,
        !values.isEmpty,
        values.count <= 8,
        values.allSatisfy({ (1...16).contains($0) })
    else { return nil }
    return values
}

func parseBeatGrouping(_ input: String, beatsPerMeasure: Int) -> [Int]? {
    let beats = min(max(beatsPerMeasure, 1), 16)
    return parseAccentPattern(input).flatMap { $0.reduce(0, +) == beats ? $0 : nil }
}

func defaultBeatGrouping(beatsPerMeasure: Int, beatUnit: Int) -> [Int] {
    let beats = min(max(beatsPerMeasure, 1), 16)
    switch (beatUnit, beats) {
    case (8, 5): [2, 3]
    case (8, 6): [3, 3]
    case (8, 7): [2, 2, 3]
    case (8, 9): [3, 3, 3]
    case (8, 12): [3, 3, 3, 3]
    default: [beats]
    }
}

func defaultBeatAccents(beatsPerMeasure: Int, grouping: [Int]) -> [BeatAccent] {
    let beats = min(max(beatsPerMeasure, 1), 16)
    let safeGrouping = grouping.allSatisfy { $0 > 0 } && grouping.reduce(0, +) == beats
        ? grouping
        : [beats]
    var starts = Set<Int>()
    var start = 0
    for group in safeGrouping {
        starts.insert(start)
        start += group
    }
    return (0..<beats).map { index in
        index == 0 ? .strong : (starts.contains(index) ? .subAccent : .normal)
    }
}

func effectiveSubdivision(_ selected: Subdivision, rhythmMode: RhythmMode) -> Subdivision {
    if [.offbeats, .customAccent].contains(rhythmMode), selected.eventsPerQuarterNote < 2 {
        return .eighth
    }
    return selected
}
