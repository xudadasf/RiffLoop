import Foundation

enum Subdivision: String, CaseIterable, Codable, Identifiable, Sendable {
    case quarter = "Quarter"
    case eighth = "Eighth"
    case sixteenth = "Sixteenth"
    case thirtySecond = "Thirty-second"
    case triplet = "Triplet"
    case quintuplet = "Quintuplet"
    case sextuplet = "Sextuplet"
    case septuplet = "Septuplet"
    case nonuplet = "Nonuplet"
    case quarterNoteTriplet = "Quarter-note Triplet"

    var id: Self { self }

    var eventsInGroup: Int {
        switch self {
        case .quarter: 1
        case .eighth: 2
        case .sixteenth: 4
        case .thirtySecond: 8
        case .triplet: 3
        case .quintuplet: 5
        case .sextuplet: 6
        case .septuplet: 7
        case .nonuplet: 9
        case .quarterNoteTriplet: 3
        }
    }

    var quarterNotesPerGroup: Int {
        self == .quarterNoteTriplet ? 2 : 1
    }

    var eventsPerQuarterNote: Double {
        Double(eventsInGroup) / Double(quarterNotesPerGroup)
    }

    var isTuplet: Bool {
        ![.quarter, .eighth, .sixteenth, .thirtySecond].contains(self)
    }

    func label(forBeatUnit beatUnit: Int) -> String {
        let simpleDivision: Int?
        switch self {
        case .quarter: simpleDivision = 1
        case .eighth: simpleDivision = 2
        case .sixteenth: simpleDivision = 4
        case .thirtySecond: simpleDivision = 8
        default: simpleDivision = nil
        }
        guard let simpleDivision else {
            switch self {
            case .triplet: return "三连音"
            case .quintuplet: return "五连音"
            case .sextuplet: return "六连音"
            case .septuplet: return "七连音"
            case .nonuplet: return "九连音"
            case .quarterNoteTriplet: return "四分音符三连音"
            default: return rawValue
            }
        }

        switch beatUnit * simpleDivision {
        case 2: return "二分音符"
        case 4: return "四分音符"
        case 8: return "八分音符"
        case 16: return "十六分音符"
        case 32: return "三十二分音符"
        case 64: return "六十四分音符"
        case 128: return "一百二十八分音符"
        default: return rawValue
        }
    }
}
