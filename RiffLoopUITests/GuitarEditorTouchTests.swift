import XCTest

final class GuitarEditorTouchTests: XCTestCase {
    func testHoldAndDragCopiesTwoWholeBars() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["RIFFLOOP_EDITOR_TOUCH_TEST"] = "1"
        app.launch()

        func note(in bar: Int, fret: Int) -> XCUIElement {
            app.buttons["第 \(bar) 小节 第 2 拍位 第 2 弦 \(fret)"]
        }
        let first = note(in: 1, fret: 7)
        let second = note(in: 2, fret: 11)
        XCTAssertTrue(first.waitForExistence(timeout: 25))
        let middle = CGVector(dx: 0.5, dy: 0.5)
        second.coordinate(withNormalizedOffset: middle).press(forDuration: 0.8, thenDragTo: first.coordinate(withNormalizedOffset: middle))
        app.buttons["复制"].tap()
        app.buttons["粘贴"].tap()
        XCTAssertTrue(note(in: 3, fret: 7).waitForExistence(timeout: 10))
        XCTAssertTrue(note(in: 4, fret: 11).exists)

        app.buttons["撤销"].tap()
        XCTAssertTrue(note(in: 3, fret: 7).waitForNonExistence(timeout: 5))
        XCTAssertTrue(note(in: 2, fret: 11).exists)
    }
}
