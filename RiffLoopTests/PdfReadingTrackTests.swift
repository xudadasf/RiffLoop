import XCTest
@testable import RiffLoop

final class PdfReadingTrackTests: XCTestCase {
    func testTrackNeedsTimeProgressionBeforeItCanAutoFollow() {
        XCTAssertFalse(isUsablePdfReadingTrack([
            PdfReadingPoint(time: 0, pageIndex: 0, verticalProgress: 0),
            PdfReadingPoint(time: 0, pageIndex: 0, verticalProgress: 1),
        ]))
        XCTAssertTrue(isUsablePdfReadingTrack([
            PdfReadingPoint(time: 0, pageIndex: 0, verticalProgress: 0),
            PdfReadingPoint(time: 1, pageIndex: 0, verticalProgress: 1),
        ]))
    }

    func testInterpolatesProgressWithinTheSamePage() {
        let points = [
            PdfReadingPoint(time: 0, pageIndex: 0, verticalProgress: 0),
            PdfReadingPoint(time: 10, pageIndex: 0, verticalProgress: 1),
        ]

        XCTAssertEqual(
            pdfReadingTarget(at: 5, points: points),
            PdfReadingTarget(pageIndex: 0, verticalProgress: 0.5)
        )
    }

    func testStaysOnPreviousPageUntilRecordedPageChange() {
        let points = [
            PdfReadingPoint(time: 0, pageIndex: 0, verticalProgress: 0),
            PdfReadingPoint(time: 9, pageIndex: 0, verticalProgress: 1),
            PdfReadingPoint(time: 10, pageIndex: 1, verticalProgress: 0),
        ]

        XCTAssertEqual(
            pdfReadingTarget(at: 9.5, points: points),
            PdfReadingTarget(pageIndex: 0, verticalProgress: 1)
        )
        XCTAssertEqual(
            pdfReadingTarget(at: 10, points: points),
            PdfReadingTarget(pageIndex: 1, verticalProgress: 0)
        )
    }

    func testRecordingAfterRewindReplacesFuturePoints() {
        let existing = [
            PdfReadingPoint(time: 0, pageIndex: 0, verticalProgress: 0),
            PdfReadingPoint(time: 5, pageIndex: 0, verticalProgress: 0.5),
            PdfReadingPoint(time: 10, pageIndex: 1, verticalProgress: 0),
        ]

        let updated = recordPdfReadingPoint(
            PdfReadingPoint(time: 4, pageIndex: 0, verticalProgress: 0.4),
            in: existing,
            force: true
        )

        XCTAssertEqual(updated.map(\.time), [0, 4])
    }
}
