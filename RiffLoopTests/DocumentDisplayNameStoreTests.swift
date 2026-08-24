import Foundation
import XCTest
@testable import RiffLoop

@MainActor
final class DocumentDisplayNameStoreTests: XCTestCase {
    func testFallsBackToPhysicalFileNameAndPersistsCustomName() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = DocumentDisplayNameStore(defaults: defaults)

        XCTAssertEqual(
            store.displayName(for: .video, fileName: "67f51592.MP4"),
            "67f51592.MP4"
        )

        store.setDisplayName("  右手练习  ", for: .video, fileName: "67f51592.MP4")

        XCTAssertEqual(
            DocumentDisplayNameStore(defaults: defaults)
                .displayName(for: .video, fileName: "67f51592.MP4"),
            "右手练习"
        )
    }

    func testEmptyNameRestoresPhysicalFileNameWithoutAffectingOtherModes() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = DocumentDisplayNameStore(defaults: defaults)
        store.setDisplayName("视频名称", for: .video, fileName: "练习.dat")
        store.setDisplayName("PDF 名称", for: .pdf, fileName: "练习.dat")

        store.setDisplayName("  ", for: .video, fileName: "练习.dat")

        XCTAssertEqual(store.displayName(for: .video, fileName: "练习.dat"), "练习.dat")
        XCTAssertEqual(store.displayName(for: .pdf, fileName: "练习.dat"), "PDF 名称")
    }
}
