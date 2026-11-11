import XCTest
@testable import RiffLoop

@MainActor
final class ScoreExternalOpenCoordinatorTests: XCTestCase {
    func testExternalDocumentOpensImmediatelyOutsideRegionEditor() {
        let coordinator = ScoreExternalOpenCoordinator()
        let first = ExternalDocument(kind: .guitarPro, url: URL(fileURLWithPath: "/first.gp"))
        let second = ExternalDocument(kind: .pdf, url: URL(fileURLWithPath: "/second.pdf"))
        coordinator.receive(first)
        XCTAssertEqual(coordinator.path, [first])
        coordinator.receive(second)
        XCTAssertEqual(coordinator.path, [second])
        XCTAssertTrue(coordinator.pending.isEmpty)
    }

    func testRegionEditorQueuesEveryDocumentUntilExplicitlyOpened() {
        let coordinator = ScoreExternalOpenCoordinator()
        let first = ExternalDocument(kind: .guitarPro, url: URL(fileURLWithPath: "/first.gp"))
        let second = ExternalDocument(kind: .pdf, url: URL(fileURLWithPath: "/second.pdf"))
        coordinator.beginRegionEditing()
        coordinator.receive(first)
        coordinator.receive(second)
        coordinator.openNext()
        XCTAssertTrue(coordinator.path.isEmpty)
        XCTAssertEqual(coordinator.pending, [first, second])

        coordinator.endRegionEditing()
        coordinator.openNext()
        XCTAssertEqual(coordinator.path, [first])
        XCTAssertEqual(coordinator.pending, [second])
        coordinator.openNext()
        XCTAssertEqual(coordinator.path, [second])
        XCTAssertTrue(coordinator.pending.isEmpty)
    }

    func testNewDocumentCannotJumpAheadOfQueuedDocuments() {
        let coordinator = ScoreExternalOpenCoordinator()
        let first = ExternalDocument(kind: .pdf, url: URL(fileURLWithPath: "/first.pdf"))
        let second = ExternalDocument(kind: .guitarPro, url: URL(fileURLWithPath: "/second.gp"))
        coordinator.beginRegionEditing()
        coordinator.receive(first)
        coordinator.endRegionEditing()
        coordinator.receive(second)
        XCTAssertEqual(coordinator.pending, [first, second])
        XCTAssertTrue(coordinator.path.isEmpty)
    }
}
