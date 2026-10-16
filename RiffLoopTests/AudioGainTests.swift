import XCTest
@testable import RiffLoop

final class AudioGainTests: XCTestCase {
    func testNativeMetronomeAppliesSixTimesBoostInsteadOfCappingAtTwo() {
        XCTAssertEqual(metronomeClickBoost(volume: 6), 6)
        XCTAssertEqual(metronomeClickBoost(volume: 10), 6)
        XCTAssertEqual(metronomeClickBoost(volume: 0.4), 1)
        XCTAssertEqual(boostedAudioSample(0.1, gain: metronomeClickBoost(volume: 6)), 0.6, accuracy: 0.001)
        XCTAssertEqual(boostedAudioSample(0.8, gain: metronomeClickBoost(volume: 6)), 1)
    }
    func testBoostIncreasesQuietAudioAndBoundsPeaks() {
        XCTAssertEqual(boostedAudioSample(0.2, gain: 2), 0.4, accuracy: 0.001)
        XCTAssertEqual(boostedAudioSample(-0.2, gain: 2), -0.4, accuracy: 0.001)
        XCTAssertEqual(boostedAudioSample(0.8, gain: 2), 1)
        XCTAssertEqual(boostedAudioSample(-0.8, gain: 2), -1)
        XCTAssertEqual(boostedAudioSample(0, gain: 2), 0)
    }
}
