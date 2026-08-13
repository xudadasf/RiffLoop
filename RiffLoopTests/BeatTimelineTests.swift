import XCTest
@testable import RiffLoop

final class BeatTimelineTests: XCTestCase {
    func testSubdivisionIntervalsAt120BPM() {
        XCTAssertEqual(makeTimeline(.quarter).eventInterval, 0.5, accuracy: 1e-12)
        XCTAssertEqual(makeTimeline(.eighth).eventInterval, 0.25, accuracy: 1e-12)
        XCTAssertEqual(makeTimeline(.sixteenth).eventInterval, 0.125, accuracy: 1e-12)
        XCTAssertEqual(makeTimeline(.triplet).eventInterval, 1.0 / 6.0, accuracy: 1e-12)
    }

    func testEventsRemainAnchoredToBeatOffset() {
        let timeline = BeatTimeline(
            bpm: 120,
            beatOffset: 12.350,
            subdivision: .quarter
        )

        XCTAssertEqual(timeline.event(at: 0).mediaTime, 12.350, accuracy: 1e-12)
        XCTAssertEqual(timeline.event(at: 20).mediaTime, 22.350, accuracy: 1e-12)
        XCTAssertEqual(timeline.event(at: 100).mediaTime, 62.350, accuracy: 1e-12)
    }

    func testNextEventAtOrAfterMediaTime() {
        let timeline = BeatTimeline(
            bpm: 120,
            beatOffset: 12.350,
            subdivision: .quarter
        )

        XCTAssertEqual(timeline.eventIndex(atOrAfter: 12.350), 0)
        XCTAssertEqual(timeline.eventIndex(atOrAfter: 12.351), 1)
        XCTAssertEqual(timeline.eventIndex(atOrAfter: 13.350), 2)
    }

    func testMeasureAccentRepeatsEveryFourQuarterNotes() {
        let timeline = makeTimeline(.eighth)

        XCTAssertTrue(timeline.event(at: 0).isMeasureAccent)
        XCTAssertFalse(timeline.event(at: 1).isMeasureAccent)
        XCTAssertFalse(timeline.event(at: 7).isMeasureAccent)
        XCTAssertTrue(timeline.event(at: 8).isMeasureAccent)
    }

    func testBPMIsClampedToPrototypeRange() {
        XCTAssertEqual(
            BeatTimeline(bpm: 10, beatOffset: 0, subdivision: .quarter).bpm,
            30
        )
        XCTAssertEqual(
            BeatTimeline(bpm: 500, beatOffset: 0, subdivision: .quarter).bpm,
            300
        )
    }

    func testRhythmTrainingModesUseTheSameTimelineClock() {
        let timeline = BeatTimeline(
            bpm: 120,
            beatOffset: 0,
            subdivision: .eighth,
            quarterNotesPerMeasure: 4
        )

        XCTAssertTrue(timeline.shouldPlay(2, mode: .backbeat))
        XCTAssertTrue(timeline.shouldPlay(6, mode: .backbeat))
        XCTAssertFalse(timeline.shouldPlay(0, mode: .backbeat))
        XCTAssertTrue(timeline.shouldPlay(1, mode: .offbeats))
        XCTAssertFalse(timeline.shouldPlay(2, mode: .offbeats))
        XCTAssertTrue(timeline.shouldPlay(0, mode: .gapBars))
        XCTAssertFalse(timeline.shouldPlay(8, mode: .gapBars))
    }

    private func makeTimeline(_ subdivision: Subdivision) -> BeatTimeline {
        BeatTimeline(bpm: 120, beatOffset: 0, subdivision: subdivision)
    }
}
