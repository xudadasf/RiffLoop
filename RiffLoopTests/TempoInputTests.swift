import XCTest
@testable import RiffLoop

final class TempoInputTests: XCTestCase {
    func testDraftDoesNotCommitPartialOrOutOfRangeTempo() {
        var draft = TempoDraft(value: 120)
        draft.digit(2)
        XCTAssertNil(draft.value)
        draft.digit(4)
        XCTAssertNil(draft.value)
        draft.digit(0)
        XCTAssertEqual(draft.value, 240)
        draft.digit(1)
        XCTAssertEqual(draft.value, 240)
        draft.clear()
        for digit in [3, 0, 1] { draft.digit(digit) }
        XCTAssertNil(draft.value)
        draft.delete()
        XCTAssertEqual(draft.value, 30)
    }

    func testPasteRejectsMalformedNumbersWithoutChangingTempo() {
        var draft = TempoDraft(value: 120)
        for invalid in ["", "1e2", "12.5", "-60", "NaN", "∞", "120bpm", "29", "301", "999999999999999999999", "١٢٠"] {
            draft.paste(invalid)
            XCTAssertEqual(draft.value, 120, invalid)
            XCTAssertTrue(draft.pasteRejected, invalid)
        }
        draft.paste(" 300\n")
        XCTAssertEqual(draft.value, 300)
        XCTAssertFalse(draft.pasteRejected)
        draft.digit(9)
        XCTAssertEqual(draft.text, "9")
        XCTAssertNil(draft.value)
    }

    func testInvalidStoredTempoDoesNotCrashEditor() {
        XCTAssertEqual(TempoDraft(value: .nan).value, 120)
        XCTAssertEqual(TempoDraft(value: .infinity).value, 120)
        XCTAssertEqual(TempoDraft(value: 999).value, 300)
    }
}
