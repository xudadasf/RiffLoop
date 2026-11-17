import XCTest

final class ScoreRegionInteractionTests: XCTestCase {
    func testDeleteRegionThroughVisibleControls() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["RIFFLOOP_REGION_UI_TEST_CASE"] = UUID().uuidString
        app.launch()
        let remove = app.buttons["删除区域 1"]
        XCTAssertTrue(remove.waitForExistence(timeout: 20))
        remove.tap()
        let confirm = app.buttons["删除区域"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete must present an actionable confirmation")
        confirm.tap()
        XCTAssertTrue(app.buttons["删除区域 2"].waitForNonExistence(timeout: 5), "Deleting the first of two regions must leave exactly one")
        XCTAssertTrue(app.buttons["删除区域 1"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
    }
}
