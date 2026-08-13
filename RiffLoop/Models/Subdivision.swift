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
        guard let simpleDivision else { return rawValue }

        switch beatUnit * simpleDivision {
        case 2: return "Half"
        case 4: return "Quarter"
        case 8: return "Eighth"
        case 16: return "Sixteenth"
        case 32: return "Thirty-second"
        case 64: return "Sixty-fourth"
        case 128: return "Hundred twenty-eighth"
        default: return rawValue
        }
    }
}
