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
        let data = try JSONEncoder().encode(value)
        ReproductionStore.shared.record("state", "profile.saved", ["kind": kind.rawValue, "file": fileName, "profile": String(decoding: data, as: UTF8.self)])
        defaults.set(data, forKey: key(kind: kind, fileName: fileName))
    }

    func load<Value: Decodable>(
        _ type: Value.Type,
        kind: PracticeKind,
        fileName: String
    ) throws -> Value? {
        guard let data = defaults.data(forKey: key(kind: kind, fileName: fileName)) else {
            ReproductionStore.shared.record("state", "profile.default", ["kind": kind.rawValue, "file": fileName])
            return nil
        }
        ReproductionStore.shared.record("state", "profile.restored", ["kind": kind.rawValue, "file": fileName, "profile": String(decoding: data, as: UTF8.self)])
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
