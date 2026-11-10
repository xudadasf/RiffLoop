import XCTest
@testable import RiffLoopOCRProbe

final class CTCLocationTests: XCTestCase {
    // Values from ctc_location_reference.py, using the desktop RapidOCR decoder.
    // All input is generated; no user image or trained model is used.
    func testDesktopPositionParityForPaddingAndVaryingWidths() throws {
        let cases: [(Int, Int, Int, [Double])] = [
            (200, 40, 40, [10, 30, 36.66666666666667, 43.333333333333336,
                           56.666666666666664, 70, 270]),
            (560, 40, 84, [10, 17.142857142857142, 19.523809523809526,
                           21.904761904761905, 26.666666666666668, 31.428571428571427,
                           207.61904761904762]),
            (288, 32, 54, [10, 21.11111111111111, 24.814814814814817,
                           28.51851851851852, 35.925925925925924, 43.333333333333336,
                           206.2962962962963]),
            (800, 32, 150, [10, 14, 15.333333333333332, 16.666666666666668,
                            19.333333333333336, 22, 208.66666666666666]),
            (201, 40, 40, [10, 29.900497512437813, 36.533996683250415,
                           43.16749585406302, 56.43449419568823, 69.70149253731344,
                           268.70646766169153]),
        ]
        let labels = [1: "1", 2: "2", 3: ",", 4: "X", 5: " "]
        for (width, height, timeSteps, expected) in cases {
            var sequence = [Int](repeating: 0, count: timeSteps)
            sequence.replaceSubrange(0..<10, with: [1, 1, 0, 1, 3, 2, 5, 4, 0, 2])
            sequence[timeSteps - 1] = 1
            let decoded = PartialCTC.decode(sequence, labels: labels)
            let located = try CTCLocation.locate(decoded.runs, timeSteps: timeSteps,
                                                  boundedWidth: width, boundedHeight: height,
                                                  sourceLeft: 10, sourceRight: 210)
            XCTAssertEqual(located.map(\.run.start), [0, 3, 4, 5, 7, 9, timeSteps - 1])
            XCTAssertEqual(located.map(\.run.character), ["1", "1", ",", "2", "X", "2", "1"])
            XCTAssertEqual(located.count, expected.count)
            for (point, x) in zip(located, expected) { XCTAssertEqual(point.x, x, accuracy: 1e-10) }
            XCTAssertEqual(located.last?.isWithinSource, width > 201)
        }
    }

    func testUnknownClassIsPreservedAndInvalidInputsAreRejected() throws {
        let decoded = PartialCTC.decode([1, 0, 9, 0, 1], labels: [1: "1"])
        let located = try CTCLocation.locate(decoded.runs, timeSteps: 5, boundedWidth: 200,
                                              boundedHeight: 40, sourceLeft: 0, sourceRight: 200)
        XCTAssertEqual(located.map(\.run.classID), [1, 9, 1])
        XCTAssertNil(located[1].run.character)
        var paddingBoundary = [Int](repeating: 0, count: 40)
        paddingBoundary[30] = 1
        let edge = try CTCLocation.locate(PartialCTC.decode(paddingBoundary, labels: [1: "1"]).runs,
                                           timeSteps: 40, boundedWidth: 200, boundedHeight: 40,
                                           sourceLeft: 10, sourceRight: 210)
        XCTAssertEqual(edge.first?.x, 210)
        XCTAssertEqual(edge.first?.isWithinSource, false)
        XCTAssertThrowsError(try CTCLocation.locate(decoded.runs, timeSteps: 5, boundedWidth: 0,
                                                     boundedHeight: 40, sourceLeft: 0, sourceRight: 200))
        XCTAssertThrowsError(try CTCLocation.locate(decoded.runs, timeSteps: 2, boundedWidth: 200,
                                                     boundedHeight: 40, sourceLeft: 0, sourceRight: 200))
        XCTAssertThrowsError(try CTCLocation.locate(decoded.runs, timeSteps: 5, boundedWidth: 200,
                                                     boundedHeight: 40, sourceLeft: .nan, sourceRight: 200))
        XCTAssertEqual(try CTCLocation.locate([], timeSteps: 5, boundedWidth: 200, boundedHeight: 40,
                                               sourceLeft: 0, sourceRight: 200), [])
    }
}
