import XCTest
@testable import RiffLoop

final class ExternalDocumentTests: XCTestCase {
    func testIncomingFormatsAreCopiedWithoutReplacingExistingPracticeFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RiffLoopDocumentStore(documentsURL: root.appendingPathComponent("Documents"))
        for kind in PracticeKind.allCases {
            for ext in kind.supportedExtensions {
                let source = root.appendingPathComponent("练习.\(ext.uppercased())")
                try Data([1, 2, 3]).write(to: source)
                let first = try ExternalDocument.receive(source, store: store)
                let second = try ExternalDocument.receive(source, store: store)
                XCTAssertEqual(first.kind, kind)
                XCTAssertNotEqual(first.url, second.url)
                XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
                XCTAssertEqual(try Data(contentsOf: first.url), Data([1, 2, 3]))
                XCTAssertEqual(try ExternalDocument.receive(first.url, store: store).url, first.url)
            }
        }
        XCTAssertThrowsError(try ExternalDocument.receive(URL(string: "https://example.com/test.pdf")!, store: store))
    }
}
