import XCTest

final class ScoreRegionInteractionTests: XCTestCase {
    private let firstID = "region-00000000-0000-0000-0000-000000000001"
    private let secondID = "region-00000000-0000-0000-0000-000000000002"

    private func launch(id: String = UUID().uuidString) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["RIFFLOOP_REGION_UI_TEST_CASE"] = id
        app.launch()
        XCTAssertTrue(app.buttons["region.delete"].waitForExistence(timeout: 20))
        return app
    }

    private func expect(_ element: XCUIElement, _ predicate: String, _ value: String) {
        let condition = NSPredicate(format: predicate, value)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: condition, evaluatedWith: element)], timeout: 8), .completed)
    }

    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + text)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        // App-only snapshots crop the rotated window incorrectly on iPad.
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testDeleteOnlySelectedBoxThroughOneSharedButton() {
        let app = launch()
        let remove = app.buttons["region.delete"]
        XCTAssertFalse(remove.isEnabled)
        XCTAssertEqual(app.buttons.matching(identifier: "region.delete").count, 1)
        app.buttons[firstID].tap()
        expect(app.buttons[firstID], "value CONTAINS %@", "已选中")
        app.buttons[secondID].tap()
        expect(app.buttons[secondID], "value CONTAINS %@", "已选中")
        remove.tap()
        let confirm = app.buttons["region.confirmDelete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertTrue(app.buttons[firstID].exists)
        XCTAssertTrue(app.buttons[secondID].exists)
        remove.tap()
        confirm.tap()
        XCTAssertTrue(app.buttons[secondID].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons[firstID].exists)
        XCTAssertFalse(remove.isEnabled)
        capture(app, name: "Only-selected-box-deleted")
    }

    func testNumberAndGapPersistAndContinueToRecognitionSettings() {
        let id = UUID().uuidString
        var app = launch(id: id)
        app.buttons[secondID].tap()
        replace(app.textFields["region.number"], with: "1")
        replace(app.textFields["region.gap"], with: "0")
        app.buttons["region.apply"].tap()
        expect(app.buttons[secondID], "label == %@", "方框 1")
        expect(app.buttons[firstID], "label == %@", "方框 2")
        expect(app.buttons[secondID], "value CONTAINS %@", "后接 0")
        capture(app, name: "Selected-box-number-and-gap")
        app.terminate()
        app = launch(id: id)
        app.buttons[secondID].tap()
        expect(app.textFields["region.number"], "value == %@", "1")
        expect(app.textFields["region.gap"], "value == %@", "0")
        app.buttons["region.next"].tap()
        XCTAssertTrue(app.navigationBars["区域顺序与间隔"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["识别并进入编辑"].exists)
        capture(app, name: "Region-next-recognition-settings")
    }

    func testDrawingModeStillAllowsSelectionAndZoomDoesNotCreateExtraBoxes() {
        let app = launch()
        let drawing = app.switches["region.drawing"]
        print("Drawing switch frame: \(drawing.frame), initial value: \(drawing.value ?? "nil")")
        // SwiftUI includes the label in the switch's accessibility element;
        // tap its control end, and verify the mode before testing the drag.
        drawing.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        expect(drawing, "value == %@", "1")
        app.buttons[firstID].tap()
        expect(app.buttons[firstID], "value CONTAINS %@", "已选中")
        let boxes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "region-"))
        XCTAssertEqual(boxes.count, 2, "A tap in drawing mode must only select")
        let canvas = app.otherElements["region.canvas"]
        XCTAssertTrue(canvas.exists)
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.8))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.94))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "count == 3"), evaluatedWith: boxes)], timeout: 8), .completed)
        drawing.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        expect(drawing, "value == %@", "0")
        app.buttons["放大"].tap()
        app.buttons[firstID].tap()
        expect(app.buttons[firstID], "value CONTAINS %@", "已选中")
        XCTAssertEqual(boxes.count, 3)
        capture(app, name: "Draw-select-and-zoom")
    }
}
