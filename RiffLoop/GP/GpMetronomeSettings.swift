import Foundation

enum GpBeatAccent: String, CaseIterable, Codable, Sendable {
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
        switch self {
        case .strong: .subAccent
        case .subAccent: .normal
        case .normal: .muted
        case .muted: .strong
        }
    }
}

func defaultGpBeatAccents(beatsPerMeasure: Int) -> [GpBeatAccent] {
    guard beatsPerMeasure > 0 else { return [] }
    return [.strong] + Array(repeating: .normal, count: beatsPerMeasure - 1)
}

func gpMetronomeGain(
    pulse: Int,
    subdivisionFactor: Int,
    beatAccents: [GpBeatAccent]
) -> Double {
    let factor = max(1, subdivisionFactor)
    let normalizedPulse = max(0, pulse)
    guard normalizedPulse % factor == 0 else { return 0.20 }
    let beatIndex = normalizedPulse / factor
    let accent = beatAccents.indices.contains(beatIndex)
        ? beatAccents[beatIndex]
        : (normalizedPulse == 0 ? .strong : .normal)
    switch accent {
    case .strong: return 1
    case .subAccent: return 0.62
    case .normal: return 0.34
    case .muted: return 0
    }
}
