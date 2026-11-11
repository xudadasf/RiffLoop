import Foundation
import XCTest
@testable import RiffLoopOCRProbe

private struct ConfidenceReference: Decodable {
    struct Item: Decodable {
        let classID: Int
        let start: Int
        let end: Int
        let rawFirstScore: Float
        let roundedScore: Double
    }
    struct Case: Decodable {
        let name: String
        let indices: [Int]
        let scores: [Float]
        let lineScore: Double
        let items: [Item]
    }
    let cases: [Case]
}

final class CTCConfidenceTests: XCTestCase {
    func testFirstFrameAndRoundingAgainstDesktopDecoder() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "confidence_reference", withExtension: "json"))
        let fixture = try JSONDecoder().decode(ConfidenceReference.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.cases.count, 6)
        for sample in fixture.cases {
            // Class 4 is deliberately not mapped and must remain reviewable.
            let result = try CTCConfidence.evaluate(indices: sample.indices, scores: sample.scores,
                                                    labels: [1: "1", 2: "2", 3: ",", 5: " "])
            XCTAssertEqual(result.lineScore, sample.lineScore, accuracy: 0.0000001, sample.name)
            if sample.name == "numpy_mean_tie" { XCTAssertEqual(result.lineScore, 0.89998, accuracy: 0.0000001) }
            XCTAssertEqual(result.items.count, sample.items.count, sample.name)
            for (actual, expected) in zip(result.items, sample.items) {
                XCTAssertEqual(actual.run.classID, expected.classID, sample.name)
                XCTAssertEqual(actual.run.start, expected.start, sample.name)
                XCTAssertEqual(actual.run.end, expected.end, sample.name)
                XCTAssertEqual(actual.rawFirstScore, expected.rawFirstScore, sample.name)
                XCTAssertEqual(actual.roundedScore, expected.roundedScore, accuracy: 0.0000001, sample.name)
                XCTAssertTrue(actual.reviewReasons.contains(.uncalibrated), sample.name)
                if expected.classID == 4 { XCTAssertTrue(actual.reviewReasons.contains(.unmappedClass)) }
                if expected.roundedScore < 0.8 { XCTAssertTrue(actual.reviewReasons.contains(.lowCharacterScore)) }
                if sample.lineScore < 0.95 { XCTAssertTrue(actual.reviewReasons.contains(.lowLineScore)) }
            }
        }
    }

    func testNoScoresAreDroppedAndMalformedInputIsRejected() throws {
        let result = try CTCConfidence.evaluate(indices: [1, 1, 0, 9], scores: [0.2, 0.99, 0.99, 0.99],
                                                labels: [1: "1"])
        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(result.items[0].rawFirstScore, 0.2)
        XCTAssertTrue(result.items[0].reviewReasons.contains(.lowCharacterScore))
        XCTAssertTrue(result.items[1].reviewReasons.contains(.unmappedClass))
        XCTAssertTrue(result.items.allSatisfy { $0.reviewReasons.contains(.uncalibrated) })
        XCTAssertThrowsError(try CTCConfidence.evaluate(indices: [1], scores: [], labels: [:]))
        XCTAssertThrowsError(try CTCConfidence.evaluate(indices: [1], scores: [.nan], labels: [:]))
        XCTAssertThrowsError(try CTCConfidence.evaluate(indices: [1], scores: [1.1], labels: [:]))
        XCTAssertThrowsError(try CTCConfidence.evaluate(indices: [-1], scores: [0.5], labels: [:]))
    }

    func testLowConfidenceAndUnknownSurviveLocationAndGrouping() throws {
        let confidence = try CTCConfidence.evaluate(indices: [1, 2, 9, 1], scores: [0.7, 0.99, 0.99, 0.99],
                                                    labels: [1: "1", 2: "2"])
        let locations = try CTCLocation.locate(confidence.items.map(\.run), timeSteps: 4,
                                                boundedWidth: 320, boundedHeight: 48,
                                                sourceLeft: 0, sourceRight: 40)
        let inputs = locations.map { DigitGroupingInput(character: $0.run.character, x: $0.x,
                                                       isWithinSource: $0.isWithinSource) }
        let grouping = try DigitGrouping.group(inputs, stringGap: 14)
        let review = try CTCGroupReview.combine(grouping: grouping, locations: locations, confidence: confidence)
        XCTAssertEqual(review.groups.map(\.value.fret), [12, 1])
        XCTAssertTrue(review.groups[0].reasons.contains(.lowCharacterScore))
        XCTAssertTrue(review.groups.allSatisfy { $0.reasons.contains(.uncalibrated) })
        XCTAssertEqual(review.unresolved, [.init(inputIndex: 2, reason: .unknownCharacter)])
        XCTAssertThrowsError(try CTCGroupReview.combine(grouping: grouping, locations: [], confidence: confidence))
        let missing = DigitGroupingResult(groups: [], unresolved: [])
        XCTAssertThrowsError(try CTCGroupReview.combine(grouping: missing, locations: locations, confidence: confidence))
        let fabricated = DigitGroupingResult(groups: [.init(inputIndices: [0], text: "9", fret: 9)],
                                             unresolved: grouping.unresolved)
        XCTAssertThrowsError(try CTCGroupReview.combine(grouping: fabricated, locations: locations, confidence: confidence))
        let skippedUnknown = DigitGroupingResult(groups: [.init(inputIndices: [0, 1, 3], text: "121", fret: nil)],
                                                 unresolved: grouping.unresolved)
        XCTAssertThrowsError(try CTCGroupReview.combine(grouping: skippedUnknown, locations: locations, confidence: confidence))
        XCTAssertThrowsError(try CTCGroupReview.combine(grouping: grouping,
                                                       locations: [locations[0], locations[0]],
                                                       confidence: confidence))
    }

    func testAmbiguousFretIsNotTreatedAsVerified() throws {
        let confidence = try CTCConfidence.evaluate(indices: [3, 7], scores: [0.99, 0.99],
                                                    labels: [3: "3", 7: "7"])
        let locations = try CTCLocation.locate(confidence.items.map(\.run), timeSteps: 2,
                                                boundedWidth: 320, boundedHeight: 48,
                                                sourceLeft: 0, sourceRight: 10)
        let inputs = locations.map { DigitGroupingInput(character: $0.run.character, x: $0.x,
                                                       isWithinSource: $0.isWithinSource) }
        let grouping = try DigitGrouping.group(inputs, stringGap: 14)
        let review = try CTCGroupReview.combine(grouping: grouping, locations: locations, confidence: confidence)
        XCTAssertNil(review.groups[0].value.fret)
        XCTAssertTrue(review.groups[0].reasons.contains(.ambiguousFret))
        XCTAssertTrue(review.groups[0].reasons.contains(.uncalibrated))
    }
}
