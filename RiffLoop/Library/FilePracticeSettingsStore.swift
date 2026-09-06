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
        if Self.isPracticeProfile(Value.self) {
            var object = try Self.object(data)
            let mode = object.filter { Self.modeFields(kind).contains($0.key) }
            defaults.set(try JSONSerialization.data(withJSONObject: mode), forKey: modeKey(kind))
            for field in Self.modeFields(kind) { object.removeValue(forKey: field) }
            Self.clearTransient(&object, kind: kind)
            defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: key(kind: kind, fileName: fileName))
        } else {
            defaults.set(data, forKey: key(kind: kind, fileName: fileName))
        }
    }

    func load<Value: Decodable>(
        _ type: Value.Type,
        kind: PracticeKind,
        fileName: String
    ) throws -> Value? {
        let fileData = defaults.data(forKey: key(kind: kind, fileName: fileName))
        if Self.isPracticeProfile(type) {
            var modeData = defaults.data(forKey: modeKey(kind))
            // First opened legacy file seeds this mode once. Other old files cannot overwrite it.
            if modeData == nil, let fileData {
                let mode = try Self.object(fileData).filter { Self.modeFields(kind).contains($0.key) }
                modeData = try JSONSerialization.data(withJSONObject: mode)
                defaults.set(modeData, forKey: modeKey(kind))
            }
            guard fileData != nil || modeData != nil else { return nil }
            var merged = try Self.defaultObject(kind)
            if let fileData { merged.merge(try Self.object(fileData)) { _, new in new } }
            if let modeData { merged.merge(try Self.object(modeData)) { _, new in new } }
            Self.clearTransient(&merged, kind: kind)
            let data = try JSONSerialization.data(withJSONObject: merged)
            ReproductionStore.shared.record("state", "profile.restored", ["kind": kind.rawValue, "file": fileName,
                "scope": "file context + current mode; transient loops cleared", "profile": String(decoding: data, as: UTF8.self)])
            return try JSONDecoder().decode(type, from: data)
        }
        guard let data = fileData else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    private func modeKey(_ kind: PracticeKind) -> String { "practiceModeSettings.v2." + kind.rawValue }

    private static func isPracticeProfile<T>(_ type: T.Type) -> Bool {
        type == GpPracticeProfile.self || type == VideoPracticeProfile.self || type == PdfPracticeProfile.self
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return value
    }

    private static func defaultObject(_ kind: PracticeKind) throws -> [String: Any] {
        switch kind {
        case .guitarPro: return try object(JSONEncoder().encode(GpPracticeProfile()))
        case .video: return try object(JSONEncoder().encode(VideoPracticeProfile.default))
        case .pdf: return try object(JSONEncoder().encode(PdfPracticeProfile()))
        }
    }

    private static func modeFields(_ kind: PracticeKind) -> Set<String> {
        var common: Set<String> = ["metronomeEnabled", "metronomeVolume", "beatAccents", "loopCountInEnabled",
            "speedLadderTarget", "loopsPerSpeedStep", "speedLadderStep"]
        switch kind {
        case .guitarPro:
            common.formUnion(["scoreZoom", "playbackSpeed", "masterVolume", "backingVolume", "synthEnabled", "backingEnabled",
                "countInEnabled", "countInVolume", "countInAccents", "metronomeSubdivisionFactor"])
        case .video, .pdf:
            common.formUnion(["bpm", "beatsPerMeasure", "beatUnit", "beatGrouping", "subdivision", "rhythmMode", "playbackRate",
                "mediaVolume", "audioVolume", "snapLoopPointsToBeat"])
        }
        return common
    }

    private static func clearTransient(_ value: inout [String: Any], kind: PracticeKind) {
        value["speedLadderEnabled"] = false
        switch kind {
        case .guitarPro:
            value["loopRange"] = NSNull()
            value["rangeLoopingEnabled"] = false
            value["wholeSongLoopingEnabled"] = false
        case .video, .pdf:
            value["pointA"] = NSNull(); value["pointB"] = NSNull(); value["loopEnabled"] = false
            if kind == .pdf { value["followLoopEnabled"] = false }
        }
    }

    func containsFileSettings(kind: PracticeKind, fileName: String) -> Bool {
        defaults.data(forKey: key(kind: kind, fileName: fileName)) != nil
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
