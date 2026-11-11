import Foundation

/// Coordinates material lifetimes within this app process. Call current and
/// advance only from inside synchronized; this does not coordinate outsiders.
enum ScoreMaterialAccess {
    private static let lock = NSLock()
    private static var generations: [String: UUID] = [:]

    static func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    static func current(_ source: URL) -> UUID {
        let key = source.standardizedFileURL.path
        if let existing = generations[key] { return existing }
        let generation = UUID()
        generations[key] = generation
        return generation
    }

    @discardableResult
    static func advance(_ source: URL) -> UUID {
        let generation = UUID()
        generations[source.standardizedFileURL.path] = generation
        return generation
    }
}
