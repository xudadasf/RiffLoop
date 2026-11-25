import XCTest

final class TempoStageEntryTests: XCTestCase {
    func testContinuousEntryUsingRealStandaloneSettingsAndDeck() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()
        let gp = app.buttons["home.practice.guitarPro"]
        for _ in 0..<5 where !gp.isHittable { app.swipeUp() }
        XCTAssertTrue(gp.isHittable); gp.tap()
        let settings = app.buttons["gp.standalone.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 12)); settings.tap()
        let edit = app.buttons["stages.edit.standalone"]
        XCTAssertTrue(edit.waitForExistence(timeout: 6)); edit.tap()
        let save = app.buttons["stages.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 6))
        let field: (Int, String) -> XCUIElement = { app.buttons["stages.\($0).\($1)"] }
        let typeDigits: (String) -> Void = { digits in
            for digit in digits { app.buttons["stages.key.\(digit)"].tap() }
        }
        field(1, "bpm").tap(); typeDigits("87")
        let next = app.buttons["stages.next"]
        next.tap(); typeDigits("45")
        next.tap(); typeDigits("9"); XCTAssertFalse(save.isEnabled)
        typeDigits("2"); XCTAssertTrue(save.isEnabled)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(field(2, "bpm").value as? String, "92")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Continuous-stage-entry-iPad-mini"; shot.lifetime = .keepAlways; add(shot)
        save.tap(); XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap(); XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertEqual(field(1, "bpm").value as? String, "87")
        XCTAssertEqual(field(1, "length").value as? String, "45")
        field(1, "bpm").tap(); typeDigits("99"); app.buttons["取消"].tap()
        let enable = app.switches["stages.standalone.enabled"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        if (enable.value as? String) != "1" { enable.tap() }
        app.buttons["完成"].tap()
        let deck = app.buttons["gp.deck.stage"]
        XCTAssertTrue(deck.waitForExistence(timeout: 5))
        XCTAssertTrue(deck.label.contains("87 BPM"), deck.label)
        XCTAssertTrue(deck.label.contains("0:45"), deck.label)
        let select = app.buttons["gp.deck.stage.select"]
        XCTAssertTrue(select.isHittable)
        XCTAssertGreaterThanOrEqual(select.frame.height, 44)
        XCTAssertLessThanOrEqual(select.frame.maxX, app.frame.maxX)
        XCTAssertLessThanOrEqual(deck.frame.maxX, select.frame.minX + 1)
        select.tap()
        let second = app.buttons["stages.select.standalone.2"]
        XCTAssertTrue(second.waitForExistence(timeout: 5)); second.tap()
        XCTAssertTrue(deck.label.contains("阶段 2/"), deck.label)
        XCTAssertTrue(deck.label.contains("92 BPM"), deck.label)
        XCTAssertEqual(select.value as? String, "阶段 2")
        let selectionShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        selectionShot.name = "Stage-selector-iPad-mini"; selectionShot.lifetime = .keepAlways; add(selectionShot)
        select.tap()
        app.buttons["stages.select.standalone.1"].tap()
        XCTAssertTrue(deck.label.contains("87 BPM"), deck.label)
        XCTAssertTrue(deck.label.contains("0:45"), deck.label)
    }
}
