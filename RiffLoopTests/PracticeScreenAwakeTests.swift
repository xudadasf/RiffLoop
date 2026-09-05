import UIKit
import XCTest
@testable import RiffLoop

@MainActor
final class PracticeScreenAwakeTests: XCTestCase {
    func testOpeningAnotherFileCannotReleaseItsScreenAwakeRequest() {
        let old = UUID(), next = UUID()
        defer {
            PracticeScreenAwakeCoordinator.setActive(false, owner: old)
            PracticeScreenAwakeCoordinator.setActive(false, owner: next)
        }
        PracticeScreenAwakeCoordinator.setActive(true, owner: old)
        PracticeScreenAwakeCoordinator.setActive(true, owner: next)
        PracticeScreenAwakeCoordinator.setActive(false, owner: old)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        PracticeScreenAwakeCoordinator.setActive(false, owner: next)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
    }
}
