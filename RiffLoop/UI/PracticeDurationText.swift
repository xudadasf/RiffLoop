import Foundation

enum PracticeDurationText {
    static func compact(_ duration: TimeInterval) -> String {
        let minutes = seconds(duration) / 60
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    static func detailed(_ duration: TimeInterval) -> String {
        let value = seconds(duration)
        return "\(value / 3600)h \(value / 60 % 60)m \(value % 60)s"
    }

    private static func seconds(_ duration: TimeInterval) -> Int {
        duration.isFinite ? Int(max(0, min(duration, Double(Int.max / 2)))) : 0
    }
}
