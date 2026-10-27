import Foundation

/// Shared linear gain range for every practice sound control (100% == 1).
enum PracticeAudioVolume {
    static let maximum: Double = 16
    static let range: ClosedRange<Double> = 0...maximum

    static func clamp<T: BinaryFloatingPoint>(_ value: T) -> T {
        value.isFinite ? min(T(maximum), max(0, value)) : 0
    }
}
