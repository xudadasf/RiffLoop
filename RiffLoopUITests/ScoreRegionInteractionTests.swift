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
        XCTAssertTrue(app.buttons["region.back"].isHittable)
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

    func testNumberPersistsAndContinueToRecognitionSettings() {
        let id = UUID().uuidString
        var app = launch(id: id)
        app.buttons[secondID].tap()
        replace(app.textFields["region.number"], with: "1")
        app.buttons["region.apply"].tap()
        expect(app.buttons[secondID], "label == %@", "方框 1")
        expect(app.buttons[firstID], "label == %@", "方框 2")
        XCTAssertFalse(app.textFields["region.gap"].exists)
        capture(app, name: "Selected-box-number")
        app.terminate()
        app = launch(id: id)
        app.buttons[secondID].tap()
        expect(app.textFields["region.number"], "value == %@", "1")
        app.buttons["region.next"].tap()
        XCTAssertTrue(app.navigationBars["区域顺序与间隔"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["识别并进入编辑"].exists)
        let back = app.buttons["sequence.back"]
        XCTAssertTrue(back.exists && back.isHittable, "Recognition settings must have a visible return control")
        capture(app, name: "Region-next-recognition-settings")
        back.tap()
        let discard = app.buttons["放弃修改"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        // iPad confirmation popovers omit the cancel-role button. Dismissing
        // their outside region is the native way to continue editing.
        if app.buttons["继续编辑"].exists {
            app.buttons["继续编辑"].tap()
        } else {
            let outside = app.otherElements["PopoverDismissRegion"]
            XCTAssertTrue(outside.exists)
            outside.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.98)).tap()
        }
        XCTAssertTrue(discard.waitForNonExistence(timeout: 5))
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.tap()
        XCTAssertTrue(app.buttons["region.next"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["region.back"].isHittable, "Region Return must remain visible after closing settings")
        expect(app.buttons[secondID], "label == %@", "方框 1")
        capture(app, name: "Returned-to-region-with-saved-settings")
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

    func testSettingsSaveTogetherRowButtonsStayIndependentAndRecognitionOpensEditor() {
        let app = launch()
        app.buttons["region.next"].tap()
        XCTAssertTrue(app.textFields["sequence.tempo"].waitForExistence(timeout: 10))
        replace(app.textFields["sequence.tempo"], with: "70")
        replace(app.textFields["sequence.numerator"], with: "6")
        replace(app.textFields["sequence.denominator"], with: "8")
        replace(app.textFields["sequence.gap"], with: "2")
        app.buttons["sequence.save"].tap()
        XCTAssertTrue(app.staticTexts["已保存"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(app.staticTexts["sequence.message"].exists)
        expect(app.textFields["sequence.tempo"], "value == %@", "70")
        expect(app.textFields["sequence.gap"], "value == %@", "2")
        capture(app, name: "One-save-for-settings-and-global-gap")
        let down = app.buttons["sequence.down.1"]
        for _ in 0..<4 { if down.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(down.isHittable)
        down.tap()
        XCTAssertTrue(app.staticTexts["第 2 段 · 框 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sequence.exclude.1"].exists)
        XCTAssertTrue(app.buttons["sequence.exclude.2"].exists, "Move must not trigger another row action")
        app.buttons["sequence.recognize"].tap()
        let bars = app.webViews.buttons["小节 / 复制"]
        XCTAssertTrue(bars.waitForExistence(timeout: 90), "Recognition must save pending order and open the real editor")
        bars.tap()
        let count = app.webViews.textFields["插入空白小节数"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        replace(count, with: "2")
        app.webViews.buttons["在本小节前插入"].tap()
        XCTAssertTrue(app.webViews.buttons["在本小节前插入"].waitForNonExistence(timeout: 5))
        let save = app.webViews.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "保存草稿")).firstMatch
        XCTAssertTrue(save.exists)
        save.tap()
        XCTAssertTrue(app.webViews.buttons["已保存"].waitForExistence(timeout: 10))
        capture(app, name: "Recognition-editor-local-blank-measures")
    }

    func testDoubleTapResizesEachCornerAndPersistsAfterRelaunch() {
        let id = UUID().uuidString
        var app = launch(id: id)
        app.buttons[firstID].doubleTap()
        let names = ["topLeft", "topRight", "bottomLeft", "bottomRight"]
        for name in names {
            let handle = app.otherElements["region.corner.\(name)"]
            XCTAssertTrue(handle.waitForExistence(timeout: 5))
            XCTAssertTrue(handle.isHittable)
            let before = app.buttons[firstID].frame
            let point = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let dx: CGFloat = name.hasSuffix("Left") ? -12 : 12
            let dy: CGFloat = name.hasPrefix("top") ? -10 : 10
            point.press(forDuration: 0.15, thenDragTo: point.withOffset(CGVector(dx: dx, dy: dy)))
            let condition = NSPredicate { _, _ in app.buttons[self.firstID].frame.width > before.width + 4 }
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: condition, evaluatedWith: app)], timeout: 8), .completed)
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "region-")).count, 2)
            XCTAssertFalse(app.alerts.firstMatch.exists)
        }
        capture(app, name: "Four-corner-resize")
        app.buttons["region.resize"].tap()
        let saved = app.buttons[firstID].frame
        app.terminate()
        app = launch(id: id)
        XCTAssertEqual(app.buttons[firstID].frame.width, saved.width, accuracy: 2)
        XCTAssertEqual(app.buttons[firstID].frame.height, saved.height, accuracy: 2)
        XCTAssertEqual(app.buttons[firstID].frame.minX, saved.minX, accuracy: 2)
        XCTAssertEqual(app.buttons[firstID].frame.minY, saved.minY, accuracy: 2)
        app.buttons["放大"].tap()
        app.buttons[firstID].doubleTap()
        XCTAssertTrue(app.otherElements["region.corner.topLeft"].waitForExistence(timeout: 5))
        capture(app, name: "Resized-box-reopened-and-zoomed")
    }
}
