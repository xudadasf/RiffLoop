import CryptoKit
import Foundation

struct FilePracticeSettingsStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save<Value: Encodable>(
        _ value: Value,
        kind: PracticeKind,
        fileName: String
    ) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: key(kind: kind, fileName: fileName))
    }

    func load<Value: Decodable>(
        _ type: Value.Type,
        kind: PracticeKind,
        fileName: String
    ) throws -> Value? {
        guard let data = defaults.data(forKey: key(kind: kind, fileName: fileName)) else {
            return nil
        }
        return try JSONDecoder().decode(type, from: data)
    }

    func remove(kind: PracticeKind, fileName: String) {
        defaults.removeObject(forKey: key(kind: kind, fileName: fileName))
    }

    private func key(kind: PracticeKind, fileName: String) -> String {
        let identity = Data("\(kind.rawValue):\(fileName)".utf8)
        let digest = SHA256.hash(data: identity)
        return "practiceSettings.v1.\(digest.map { String(format: "%02x", $0) }.joined())"
    }
}
