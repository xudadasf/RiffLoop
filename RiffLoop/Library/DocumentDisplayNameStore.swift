import Combine
import Foundation

@MainActor
final class DocumentDisplayNameStore: ObservableObject {
    @Published private(set) var customNames: [String: String]

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "documentDisplayNames.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        customNames = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }

    func displayName(for kind: PracticeKind, fileName: String) -> String {
        customNames[key(kind: kind, fileName: fileName)] ?? fileName
    }

    func customName(for kind: PracticeKind, fileName: String) -> String? {
        customNames[key(kind: kind, fileName: fileName)]
    }

    func setDisplayName(_ name: String, for kind: PracticeKind, fileName: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let storageKey = key(kind: kind, fileName: fileName)
        if trimmed.isEmpty || trimmed == fileName {
            customNames.removeValue(forKey: storageKey)
        } else {
            customNames[storageKey] = trimmed
        }
        save()
    }

    func removeName(for kind: PracticeKind, fileName: String) {
        customNames.removeValue(forKey: key(kind: kind, fileName: fileName))
        save()
    }

    private func key(kind: PracticeKind, fileName: String) -> String {
        "\(kind.rawValue):\(fileName)"
    }

    private func save() {
        defaults.set(customNames, forKey: storageKey)
    }
}
