import Foundation

/// Experimental transcription candidates. No result here is an OCR accuracy claim.
struct DigitGroupingInput {
    let character: String?
    let x: Double
    let isWithinSource: Bool
}

struct DigitGroupingResult: Equatable {
    struct Group: Equatable {
        let inputIndices: [Int]
        let text: String
        /// Nil means the geometry or fret value must be checked manually.
        let fret: Int?
    }
    enum Issue: String, Equatable {
        case unknownCharacter
        case outsideSource
    }
    struct Unresolved: Equatable {
        let inputIndex: Int
        let reason: Issue
    }
    let groups: [Group]
    let unresolved: [Unresolved]
}

enum DigitGroupingError: Error {
    case invalidGeometry
}

/// Separates digits using the desktop prototype's grouping rules. Unknown and
/// out-of-bounds input is retained as unresolved and acts as a hard separator.
enum DigitGrouping {
    static func group(_ input: [DigitGroupingInput], stringGap: Double) throws -> DigitGroupingResult {
        guard stringGap.isFinite, stringGap > 0,
              input.allSatisfy({ $0.x.isFinite }),
              zip(input, input.dropFirst()).allSatisfy({ $0.0.x <= $0.1.x }) else {
            throw DigitGroupingError.invalidGeometry
        }
        var groups: [[Int]] = []
        var unresolved: [DigitGroupingResult.Unresolved] = []
        var mayJoin = false
        for (index, item) in input.enumerated() {
            guard item.isWithinSource else {
                unresolved.append(.init(inputIndex: index, reason: .outsideSource))
                mayJoin = false
                continue
            }
            guard let char = item.character, char.unicodeScalars.count == 1 else {
                unresolved.append(.init(inputIndex: index, reason: .unknownCharacter))
                mayJoin = false
                continue
            }
            guard char.utf8.count == 1, let digit = char.utf8.first, (48...57).contains(digit) else {
                mayJoin = false
                continue
            }
            if mayJoin, let last = groups.indices.last, let previous = groups[last].last,
               item.x - input[previous].x <= stringGap * 0.95 {
                groups[last].append(index)
            } else {
                groups.append([index])
            }
            mayJoin = true
        }

        var separated: [[Int]] = []
        for group in groups {
            guard group.count > 2 else { separated.append(group); continue }
            let distances = zip(group, group.dropFirst()).map { input[$0.1].x - input[$0.0].x }
            let sorted = distances.sorted()
            let middle = sorted.count / 2
            let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
            let threshold = max(stringGap * 0.7, median * 1.3)
            let cuts = distances.enumerated().compactMap { $0.element >= threshold ? $0.offset + 1 : nil }
            var start = 0
            var pieces: [[Int]] = []
            for end in cuts + [group.count] {
                pieces.append(Array(group[start..<end]))
                start = end
            }
            if !cuts.isEmpty && pieces.allSatisfy({ validFret($0, input: input) != nil }) {
                separated.append(contentsOf: pieces)
            } else {
                separated.append(group)
            }
        }
        return DigitGroupingResult(groups: separated.map { indices in
            let text = indices.compactMap { input[$0].character }.joined()
            return .init(inputIndices: indices, text: text, fret: validFret(indices, input: input))
        }, unresolved: unresolved)
    }

    private static func validFret(_ indices: [Int], input: [DigitGroupingInput]) -> Int? {
        guard (1...2).contains(indices.count) else { return nil }
        let text = indices.compactMap { input[$0].character }.joined()
        guard !(text.count > 1 && text.hasPrefix("0")), let value = Int(text), value <= 36 else { return nil }
        return value
    }
}
