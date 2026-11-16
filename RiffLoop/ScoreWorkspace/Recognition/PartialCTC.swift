import Foundation
struct PartialCTCResult: Codable, Equatable {
    struct Run: Codable, Equatable {
        let classID: Int
        let start: Int
        var end: Int
        let character: String?
    }

    /// Nil means at least one class is outside the deliberately partial map.
    let text: String?
    let unknownClasses: [Int]
    /// Inclusive model time steps; these are not yet image coordinates.
    let runs: [Run]
}

enum PartialCTC {
    static func decode(_ indices: [Int], labels: [Int: String], blank: Int = 0) -> PartialCTCResult {
        var previous: Int?
        var pieces: [String] = []
        var unknown = Set<Int>()
        var runs: [PartialCTCResult.Run] = []
        for (time, index) in indices.enumerated() {
            defer { previous = index }
            guard index != blank else { continue }
            if index == previous {
                runs[runs.count - 1].end = time
            } else {
                let character = labels[index]
                runs.append(.init(classID: index, start: time, end: time, character: character))
                if let character { pieces.append(character) } else { unknown.insert(index) }
            }
        }
        return PartialCTCResult(text: unknown.isEmpty ? pieces.joined() : nil,
                                unknownClasses: unknown.sorted(), runs: runs)
    }
}


