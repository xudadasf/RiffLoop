import XCTest
@testable import RiffLoop

final class AudioGainTests: XCTestCase {
    func testBoostIncreasesQuietAudioAndBoundsPeaks() {
        XCTAssertEqual(boostedAudioSample(0.2, gain: 2), 0.4, accuracy: 0.001)
        XCTAssertEqual(boostedAudioSample(-0.2, gain: 2), -0.4, accuracy: 0.001)
        XCTAssertEqual(boostedAudioSample(0.8, gain: 2), 1)
        XCTAssertEqual(boostedAudioSample(-0.8, gain: 2), -1)
        XCTAssertEqual(boostedAudioSample(0, gain: 2), 0)
    }
}
