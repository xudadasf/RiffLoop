import XCTest
@testable import RiffLoop

final class MeterTests: XCTestCase {
    func testValidatesGroupingAgainstBeatsPerMeasure() {
        XCTAssertEqual(parseBeatGrouping("2+2+3", beatsPerMeasure: 7), [2, 2, 3])
        XCTAssertNil(parseBeatGrouping("3+3", beatsPerMeasure: 7))
        XCTAssertNil(parseBeatGrouping("0+7", beatsPerMeasure: 7))
    }

    func testCreatesConventionalCompoundAndOddMeterGroups() {
        XCTAssertEqual(defaultBeatGrouping(beatsPerMeasure: 6, beatUnit: 8), [3, 3])
        XCTAssertEqual(defaultBeatGrouping(beatsPerMeasure: 9, beatUnit: 8), [3, 3, 3])
        XCTAssertEqual(defaultBeatGrouping(beatsPerMeasure: 7, beatUnit: 8), [2, 2, 3])
        XCTAssertEqual(defaultBeatGrouping(beatsPerMeasure: 4, beatUnit: 4), [4])
    }

    func testDerivesAccentsFromGroupStarts() {
        XCTAssertEqual(
            defaultBeatAccents(beatsPerMeasure: 7, grouping: [2, 2, 3]),
            [.strong, .normal, .subAccent, .normal, .subAccent, .normal, .normal]
        )
    }

    func testSubdivisionLabelsFollowBeatUnit() {
        XCTAssertEqual(Subdivision.quarter.label(forBeatUnit: 4), "Quarter")
        XCTAssertEqual(Subdivision.quarter.label(forBeatUnit: 8), "Eighth")
        XCTAssertEqual(Subdivision.eighth.label(forBeatUnit: 8), "Sixteenth")
        XCTAssertEqual(Subdivision.eighth.label(forBeatUnit: 16), "Thirty-second")
    }
}
