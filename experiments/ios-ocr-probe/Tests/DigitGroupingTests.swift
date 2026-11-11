import Foundation
import XCTest
@testable import RiffLoopOCRProbe

private struct DigitGroupReference: Decodable {
    struct Item: Decodable {
        let char: String?
        let x: Double
        let isWithinSource: Bool
    }
    struct Group: Decodable {
        let inputIndices: [Int]
        let text: String
        let fret: Int?
    }
    struct Unresolved: Decodable {
        let inputIndex: Int
        let reason: String
    }
    struct Case: Decodable {
        let name: String
        let gap: Double
        let input: [Item]
        let groups: [Group]
        let unresolved: [Unresolved]
    }
    let cases: [Case]
}

final class DigitGroupingTests: XCTestCase {
    func testGroupingAgainstDesktopSyntheticReference() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "digit_group_reference", withExtension: "json"))
        let reference = try JSONDecoder().decode(DigitGroupReference.self, from: Data(contentsOf: fixture))
        XCTAssertEqual(reference.cases.count, 11)
        for sample in reference.cases {
            let input = sample.input.map {
                DigitGroupingInput(character: $0.char, x: $0.x, isWithinSource: $0.isWithinSource)
            }
            let actual = try DigitGrouping.group(input, stringGap: sample.gap)
            XCTAssertEqual(actual.groups.map(\.inputIndices), sample.groups.map(\.inputIndices), sample.name)
            XCTAssertEqual(actual.groups.map(\.text), sample.groups.map(\.text), sample.name)
            XCTAssertEqual(actual.groups.map(\.fret), sample.groups.map(\.fret), sample.name)
            XCTAssertEqual(actual.unresolved.map(\.inputIndex), sample.unresolved.map(\.inputIndex), sample.name)
            XCTAssertEqual(actual.unresolved.map { $0.reason.rawValue }, sample.unresolved.map(\.reason), sample.name)
        }
    }

    func testInvalidOrUnorderedCoordinatesAreRejected() {
        let valid = DigitGroupingInput(character: "1", x: 5, isWithinSource: true)
        XCTAssertThrowsError(try DigitGrouping.group([valid], stringGap: 0))
        XCTAssertThrowsError(try DigitGrouping.group([valid], stringGap: .infinity))
        XCTAssertThrowsError(try DigitGrouping.group([.init(character: "1", x: .nan, isWithinSource: true)], stringGap: 10))
        XCTAssertThrowsError(try DigitGrouping.group([valid, .init(character: "2", x: 4, isWithinSource: true)], stringGap: 10))
    }

    func testLocatedUnknownClassCannotMergeAdjacentFrets() throws {
        // The unknown model class remains between the two notes all the way
        // through decoding, position mapping, and grouping.
        let decoded = PartialCTC.decode([34, 33, 99, 34], labels: [33: "0", 34: "1"])
        let locations = try CTCLocation.locate(decoded.runs, timeSteps: 4, boundedWidth: 320,
                                                boundedHeight: 48, sourceLeft: 0, sourceRight: 40)
        let input = locations.map {
            DigitGroupingInput(character: $0.run.character, x: $0.x, isWithinSource: $0.isWithinSource)
        }
        let result = try DigitGrouping.group(input, stringGap: 14)
        XCTAssertEqual(result.groups.map(\.fret), [10, 1])
        XCTAssertEqual(result.unresolved, [.init(inputIndex: 2, reason: .unknownCharacter)])
    }

    func testMalformedClassMappingIsUnresolvedAndDoesNotJoinNeighbors() throws {
        let result = try DigitGrouping.group([
            .init(character: "1", x: 0, isWithinSource: true),
            .init(character: "10", x: 4, isWithinSource: true),
            .init(character: "0", x: 8, isWithinSource: true)
        ], stringGap: 14)
        XCTAssertEqual(result.groups.map(\.fret), [1, 0])
        XCTAssertEqual(result.unresolved, [.init(inputIndex: 1, reason: .unknownCharacter)])
    }
}
