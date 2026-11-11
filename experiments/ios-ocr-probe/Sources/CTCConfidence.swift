import Foundation

/// Confidence values are diagnostic only; they do not establish OCR accuracy.
struct CTCConfidenceResult: Equatable {
    enum ReviewReason: String, Equatable {
        case unmappedClass
        case lowCharacterScore
        case lowLineScore
        case uncalibrated
        case ambiguousFret
    }
    struct Item: Equatable {
        let run: PartialCTCResult.Run
        /// The score at the first selected time step, not the maximum of a run.
        let rawFirstScore: Float
        let roundedScore: Double
        let reviewReasons: [ReviewReason]
    }
    let items: [Item]
    let lineScore: Double
}

/// Keep review reasons attached to the grouped fret rather than only to the
/// intermediate characters. Unknown and out-of-bounds entries remain separate.
struct CTCGroupReview: Equatable {
    struct Group: Equatable {
        let value: DigitGroupingResult.Group
        let reasons: [CTCConfidenceResult.ReviewReason]
    }
    struct Unresolved: Equatable {
        let issue: DigitGroupingResult.Unresolved
        let location: CTCLocatedRun
        let confidence: CTCConfidenceResult.Item
    }
    let groups: [Group]
    let unresolved: [Unresolved]

    static func combine(grouping: DigitGroupingResult, locations: [CTCLocatedRun],
                        confidence: CTCConfidenceResult) throws -> CTCGroupReview {
        guard locations.count == confidence.items.count,
              zip(locations, locations.dropFirst()).allSatisfy({ $0.0.run.start < $0.1.run.start }) else {
            throw CTCConfidenceError.invalidInput
        }
        var byStart: [Int: CTCConfidenceResult.Item] = [:]
        for item in confidence.items {
            guard byStart.updateValue(item, forKey: item.run.start) == nil else {
                throw CTCConfidenceError.invalidInput
            }
        }
        var seen = Set<Int>()
        let reasonOrder: [CTCConfidenceResult.ReviewReason] = [
            .unmappedClass, .lowCharacterScore, .lowLineScore, .uncalibrated, .ambiguousFret
        ]
        var lastGroupEnd = -1
        let results = try grouping.groups.map { group -> Group in
            guard let firstIndex = group.inputIndices.first, firstIndex > lastGroupEnd else {
                throw CTCConfidenceError.invalidInput
            }
            // Fail closed even if a caller constructs an incomplete snapshot.
            var reasons: Set<String> = [CTCConfidenceResult.ReviewReason.uncalibrated.rawValue]
            var characters: [String] = []
            var previousIndex: Int?
            for index in group.inputIndices {
                guard locations.indices.contains(index), seen.insert(index).inserted,
                      previousIndex.map({ $0 + 1 == index }) ?? true,
                      locations[index].isWithinSource,
                      let item = byStart[locations[index].run.start], item.run == locations[index].run,
                      let character = item.run.character, character.utf8.count == 1,
                      let digit = character.utf8.first, (48...57).contains(digit) else {
                    throw CTCConfidenceError.invalidInput
                }
                characters.append(character)
                previousIndex = index
                reasons.formUnion(item.reviewReasons.map(\.rawValue))
            }
            let text = characters.joined()
            let fret = (1...2).contains(characters.count) && !(characters.count > 1 && text.hasPrefix("0"))
                ? Int(text).flatMap { $0 <= 36 ? $0 : nil } : nil
            guard group.text == text, group.fret == fret else { throw CTCConfidenceError.invalidInput }
            lastGroupEnd = group.inputIndices.last ?? lastGroupEnd
            if group.fret == nil { reasons.insert(CTCConfidenceResult.ReviewReason.ambiguousFret.rawValue) }
            return Group(value: group, reasons: reasonOrder.filter { reasons.contains($0.rawValue) })
        }
        let unresolved = try grouping.unresolved.map { issue -> Unresolved in
            guard locations.indices.contains(issue.inputIndex), seen.insert(issue.inputIndex).inserted,
                  let item = byStart[locations[issue.inputIndex].run.start],
                  item.run == locations[issue.inputIndex].run else {
                throw CTCConfidenceError.invalidInput
            }
            let location = locations[issue.inputIndex]
            switch issue.reason {
            case .outsideSource:
                guard !location.isWithinSource else { throw CTCConfidenceError.invalidInput }
            case .unknownCharacter:
                guard location.isWithinSource,
                      location.run.character == nil || location.run.character?.unicodeScalars.count != 1 else {
                    throw CTCConfidenceError.invalidInput
                }
            case .nonDigitCharacter:
                guard location.isWithinSource, let character = location.run.character,
                      character.unicodeScalars.count == 1,
                      !(character.utf8.count == 1 && character.utf8.first.map { (48...57).contains($0) } == true) else {
                    throw CTCConfidenceError.invalidInput
                }
            }
            return Unresolved(issue: issue, location: location, confidence: item)
        }
        // Every decoded character must appear either in a group or as an issue.
        for (index, location) in locations.enumerated() {
            guard let item = byStart[location.run.start], item.run == location.run else {
                throw CTCConfidenceError.invalidInput
            }
            guard seen.contains(index) else { throw CTCConfidenceError.invalidInput }
        }
        return CTCGroupReview(groups: results, unresolved: unresolved)
    }
}

enum CTCConfidenceError: Error {
    case invalidInput
}

enum CTCConfidence {
    private static let locale = Locale(identifier: "en_US_POSIX")

    /// Match the desktop's five-decimal display for the same float32 input.
    private static func roundFive(_ value: Double) throws -> Double {
        guard value.isFinite,
              let rounded = Double(String(format: "%.5f", locale: locale, value)) else {
            throw CTCConfidenceError.invalidInput
        }
        return rounded
    }

    static func evaluate(indices: [Int], scores: [Float], labels: [Int: String],
                         blank: Int = 0) throws -> CTCConfidenceResult {
        guard blank >= 0, indices.count == scores.count,
              indices.allSatisfy({ $0 >= 0 }),
              scores.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
            throw CTCConfidenceError.invalidInput
        }
        let runs = PartialCTC.decode(indices, labels: labels, blank: blank).runs
        let rounded = try runs.map { try roundFive(Double(scores[$0.start])) }
        // The desktop uses zero for an empty decoded line, not NaN.
        let mean = rounded.isEmpty ? 0 : rounded.reduce(0, +) / Double(rounded.count)
        // RapidOCR rounds individual float32-derived scores using Python's
        // round(), but its line mean uses NumPy round(), which scales first.
        // These can differ at binary halfway values, so preserve both rules.
        let lineScore = (mean * 100_000).rounded(.toNearestOrEven) / 100_000
        let items = runs.enumerated().map { index, run in
            var reasons: [CTCConfidenceResult.ReviewReason] = []
            if run.character == nil { reasons.append(.unmappedClass) }
            if rounded[index] < 0.8 { reasons.append(.lowCharacterScore) }
            if lineScore < 0.95 { reasons.append(.lowLineScore) }
            // These thresholds are not calibrated accuracy; never treat a
            // candidate as automatically verified in this experiment.
            reasons.append(.uncalibrated)
            return CTCConfidenceResult.Item(run: run, rawFirstScore: scores[run.start],
                                            roundedScore: rounded[index], reviewReasons: reasons)
        }
        return CTCConfidenceResult(items: items, lineScore: lineScore)
    }
}
