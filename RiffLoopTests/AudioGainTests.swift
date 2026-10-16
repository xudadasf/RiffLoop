import AVFoundation
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
    func testNativeClickBuffersGainEnergyWithoutHardClipping() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        for accent in [BeatAccent.strong, .subAccent, .normal] {
            let voice = metronomeClickVoice(for: accent)
            var previousRMS = 0.0
            for volume in [Float(1), 1.5, 2, 4, 6] {
                let buffer = MetronomeEngine.makeClick(frequency: voice.frequency,
                    amplitude: voice.amplitude, decay: voice.decay, duration: 0.035,
                    format: format, boost: metronomeClickBoost(volume: volume))
                let channels = try XCTUnwrap(buffer.floatChannelData)
                let samples = Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
                let peak = samples.map { abs($0) }.max() ?? 0
                let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
                XCTAssertTrue(samples.allSatisfy { $0.isFinite })
                XCTAssertLessThanOrEqual(peak, 0.980001, "Boosted clicks must not hit a hard full-scale ceiling")
                XCTAssertGreaterThan(rms, previousRMS, "Higher settings must still raise signal energy")
                for index in samples.indices { XCTAssertEqual(channels[1][index], samples[index]) }
                print("NativeClickAudit accent=\(accent) volume=\(volume) peak=\(peak) rms=\(rms)")
                previousRMS = rms
            }
        }
    }

    func testMetronomeSoftKneePreservesQuietSamplesAndBoundsInvalidInput() {
        XCTAssertEqual(limitedMetronomeSample(0.1, gain: 6), 0.6, accuracy: 0.00001)
        XCTAssertEqual(limitedMetronomeSample(0, gain: 6), 0)
        XCTAssertEqual(limitedMetronomeSample(0.8, gain: 0), 0)
        XCTAssertEqual(limitedMetronomeSample(.nan, gain: 6), 0)
        XCTAssertEqual(limitedMetronomeSample(0.1, gain: .infinity), 0)
        let positive = limitedMetronomeSample(0.8, gain: 6)
        XCTAssertLessThan(positive, 1)
        XCTAssertEqual(limitedMetronomeSample(-0.8, gain: 6), -positive)
        XCTAssertEqual(limitedMetronomeSample(0.75, gain: 1), 0.75)
    }

    func testBoostIncreasesQuietAudioAndBoundsPeaks() {
        XCTAssertEqual(boostedAudioSample(0.2, gain: 2), 0.4, accuracy: 0.001)
        XCTAssertEqual(boostedAudioSample(-0.2, gain: 2), -0.4, accuracy: 0.001)
        XCTAssertEqual(boostedAudioSample(0.8, gain: 2), 1)
        XCTAssertEqual(boostedAudioSample(-0.8, gain: 2), -1)
        XCTAssertEqual(boostedAudioSample(0, gain: 2), 0)
    }
}
