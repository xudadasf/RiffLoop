import XCTest
@testable import RiffLoop

final class MetronomeEngineVoiceTests: XCTestCase {
    func testStrongSubAccentAndNormalClicksAreClearlySeparated() {
        let strong = metronomeClickVoice(for: .strong)
        let subAccent = metronomeClickVoice(for: .subAccent)
        let normal = metronomeClickVoice(for: .normal)

        XCTAssertGreaterThanOrEqual(strong.amplitude / subAccent.amplitude, 1.4)
        XCTAssertGreaterThanOrEqual(subAccent.amplitude / normal.amplitude, 1.4)
        XCTAssertGreaterThanOrEqual(strong.frequency - subAccent.frequency, 600)
        XCTAssertGreaterThanOrEqual(subAccent.frequency - normal.frequency, 600)
        XCTAssertLessThan(strong.decay, subAccent.decay)
        XCTAssertLessThan(subAccent.decay, normal.decay)
    }
}
