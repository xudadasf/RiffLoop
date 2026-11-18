import XCTest

final class GuitarEditorTouchTests: XCTestCase {
    func testHoldAndDragCopiesTwoWholeBars() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["RIFFLOOP_EDITOR_TOUCH_TEST"] = "1"
        app.launch()

        let web=app.webViews
        // Touch the printed frets, as a player would. WebKit exposes these SVG
        // numbers as static text independently of the transparent hit targets.
        let first = web.staticTexts["7"].firstMatch
        let second = web.staticTexts["11"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 25))
        let middle = CGVector(dx: 0.5, dy: 0.5)
        second.coordinate(withNormalizedOffset: middle).press(forDuration: 0.8, thenDragTo: first.coordinate(withNormalizedOffset: middle))
        XCTAssertTrue(web.staticTexts["已选第 1–2 小节"].waitForExistence(timeout: 5))
        web.buttons["复制"].tap()
        web.buttons["粘贴"].tap()
        XCTAssertTrue(web.staticTexts["已选第 3–4 小节"].waitForExistence(timeout: 10))
        web.buttons["撤销"].tap()
        XCTAssertTrue(web.staticTexts["已选第 1–2 小节"].waitForExistence(timeout: 5))
    }
}
