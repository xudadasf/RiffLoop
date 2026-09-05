import XCTest
@testable import RiffLoop

final class GpMetronomeSettingsTests: XCTestCase {
    @MainActor
    func testBoostedMetronomeVolumeKeepsZeroAndCapsAtThreeHundredPercent() {
        let model = GpWebViewModel()
        model.setMetronomeVolume(1.5)
        XCTAssertEqual(model.metronomeVolume, 1.5)
        model.setMetronomeVolume(4)
        XCTAssertEqual(model.metronomeVolume, 3)
        model.setMetronomeVolume(-1)
        XCTAssertEqual(model.metronomeVolume, 0)
    }

    func testDefaultAccentsUseStrongDownbeat() {
        XCTAssertEqual(defaultGpBeatAccents(beatsPerMeasure: 4), [.strong, .normal, .normal, .normal])
    }

    func testConfiguredBeatStrengthsStayClearlySeparated() {
        let accents: [GpBeatAccent] = [.strong, .normal, .subAccent, .muted]

        XCTAssertEqual(gpMetronomeGain(pulse: 0, subdivisionFactor: 1, beatAccents: accents), 1)
        XCTAssertEqual(gpMetronomeGain(pulse: 1, subdivisionFactor: 1, beatAccents: accents), 0.34)
        XCTAssertEqual(gpMetronomeGain(pulse: 2, subdivisionFactor: 1, beatAccents: accents), 0.62)
        XCTAssertEqual(gpMetronomeGain(pulse: 3, subdivisionFactor: 1, beatAccents: accents), 0)
    }

    func testSubdivisionPulsesStayQuieterThanWholeBeats() {
        XCTAssertEqual(
            gpMetronomeGain(pulse: 1, subdivisionFactor: 4, beatAccents: [.strong, .normal]),
            0.20
        )
    }
}
