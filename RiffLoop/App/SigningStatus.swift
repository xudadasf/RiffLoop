import Foundation

enum SigningStatusKind: Equatable {
    case valid
    case expiringSoon
    case expired
    case unavailable
}

struct SigningStatusSnapshot: Equatable {
    let kind: SigningStatusKind
    let expirationDate: Date?

    static func current(
        bundleURL: URL = Bundle.main.bundleURL,
        now: Date = Date()
    ) -> SigningStatusSnapshot {
        let profileURL = bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: profileURL) else {
            return SigningStatusSnapshot(kind: .unavailable, expirationDate: nil)
        }
        return parse(profileData: data, now: now)
    }

    static func parse(profileData: Data, now: Date) -> SigningStatusSnapshot {
        let plistStart = Data("<plist".utf8)
        let plistEnd = Data("</plist>".utf8)
        guard
            let startRange = profileData.range(of: plistStart),
            let endRange = profileData.range(
                of: plistEnd,
                in: startRange.lowerBound..<profileData.endIndex
            )
        else {
            return SigningStatusSnapshot(kind: .unavailable, expirationDate: nil)
        }

        let plistData = profileData.subdata(in: startRange.lowerBound..<endRange.upperBound)
        guard
            let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
            let dictionary = plist as? [String: Any],
            let expirationDate = dictionary["ExpirationDate"] as? Date
        else {
            return SigningStatusSnapshot(kind: .unavailable, expirationDate: nil)
        }

        let remaining = expirationDate.timeIntervalSince(now)
        let kind: SigningStatusKind
        if remaining <= 0 {
            kind = .expired
        } else if remaining <= 2 * 24 * 60 * 60 {
            kind = .expiringSoon
        } else {
            kind = .valid
        }
        return SigningStatusSnapshot(kind: kind, expirationDate: expirationDate)
    }
}
