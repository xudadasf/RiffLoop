import Foundation
import XCTest
@testable import RiffLoop

final class SigningStatusTests: XCTestCase {
    func testReadsValidExpirationDateFromSignedProfileEnvelope() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-13T00:00:00Z"))
        let expiration = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-20T00:00:00Z"))

        XCTAssertEqual(
            SigningStatusSnapshot.parse(profileData: makeProfile(expiration: expiration), now: now),
            SigningStatusSnapshot(kind: .valid, expirationDate: expiration)
        )
    }

    func testMarksProfileAsExpiringSoonWithinTwoDays() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-13T00:00:00Z"))
        let expiration = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-14T12:00:00Z"))

        XCTAssertEqual(
            SigningStatusSnapshot.parse(profileData: makeProfile(expiration: expiration), now: now).kind,
            .expiringSoon
        )
    }

    func testMarksExpiredProfileAsExpired() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-13T00:00:00Z"))
        let expiration = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T23:59:59Z"))

        XCTAssertEqual(
            SigningStatusSnapshot.parse(profileData: makeProfile(expiration: expiration), now: now).kind,
            .expired
        )
    }

    func testMalformedProfileDoesNotClaimSignatureIsValid() {
        XCTAssertEqual(
            SigningStatusSnapshot.parse(profileData: Data("not a profile".utf8), now: Date()).kind,
            .unavailable
        )
    }

    private func makeProfile(expiration: Date) -> Data {
        let plist = try! PropertyListSerialization.data(
            fromPropertyList: ["ExpirationDate": expiration],
            format: .xml,
            options: 0
        )
        var envelope = Data("CMS-prefix".utf8)
        envelope.append(plist)
        envelope.append(Data("CMS-suffix".utf8))
        return envelope
    }
}
