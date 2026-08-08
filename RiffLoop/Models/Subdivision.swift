import Foundation

enum Subdivision: String, CaseIterable, Identifiable, Sendable {
    case quarter = "Quarter"
    case eighth = "Eighth"
    case sixteenth = "16th"
    case triplet = "Triplet"

    var id: Self { self }

    var eventsPerQuarterNote: Int {
        switch self {
        case .quarter: 1
        case .eighth: 2
        case .sixteenth: 4
        case .triplet: 3
        }
    }
}

