import XCTest

/// The CI runner copies transport.gp into the ordinary GP library before this
/// suite. No launch argument or release-app fixture path bypasses file loading.
final class GpPanelLayoutTests: XCTestCase {
    private let fixtureName = "gp-panel-layout-fixture.gp"
    private let panels = ["loop", "metronome", "sound", "tracks", "standalone"]
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        // CI also removes this isolated app installation in an always-run step,
        // so a failed assertion cannot leak fixture/settings into other suites.
    }

    func testLoadedGpPanelsStayInsideMiniViewportAndKeepPlaybackRunning() throws {
        let gp = app.buttons["home.practice.guitarPro"]
        for _ in 0..<5 where !gp.isHittable { app.swipeUp() }
        XCTAssertTrue(gp.isHittable)
        gp.tap()
        let files = app.buttons["选择文件"]
        XCTAssertTrue(files.waitForExistence(timeout: 15))
        files.tap()
        let file = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND NOT label BEGINSWITH %@", fixtureName, "更多：")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), "CI must install the fixture in Documents/GP")
        file.tap()
        let play = app.buttons["gp.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 40))
        wait("The real GP player becomes ready", timeout: 40) { play.isEnabled }
        XCTAssertTrue(app.webViews.staticTexts["RiffLoop-Test"].firstMatch.waitForExistence(timeout: 15))
        capture("GP-loaded-mini")

        // This is deliberately the first layout assertion: a fixed 540-point
        // panel overflows the mini's remaining score area even before stages.
        for panel in panels {
            open(panel)
            assertPanelFits(panel)
            capture("GP-panel-\(panel)-mini")
        }

        open("loop")
        let bpm = app.buttons["输入节拍速度"]
        reveal(bpm, in: "loop")
        XCTAssertTrue(bpm.isEnabled)
        bpm.tap()
        let apply = app.buttons["应用"]
        XCTAssertTrue(app.staticTexts["节拍速度"].waitForExistence(timeout: 5))
        XCTAssertTrue(apply.isHittable)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        assertInside(apply.frame, app.frame, "BPM keypad Apply")
        capture("GP-panel-bpm-keypad-mini")
        app.buttons["取消"].tap()
        assertPanelFits("loop")

        let edit = app.buttons["stages.edit.gp"]
        reveal(edit, in: "loop")
        edit.tap()
        let save = app.buttons["stages.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        let firstBpm = app.buttons["stages.1.bpm"]
        XCTAssertTrue(firstBpm.isHittable)
        let originalBpm = try XCTUnwrap(firstBpm.value as? String)
        firstBpm.tap()
        app.buttons["stages.key.9"].tap()
        app.buttons["stages.key.0"].tap()
        XCTAssertEqual(firstBpm.value as? String, "90")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertTrue(app.buttons["取消"].isHittable)
        assertInside(save.frame, app.frame, "Stage editor Save")
        capture("GP-panel-stage-editor-mini")
        app.buttons["取消"].tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertEqual(firstBpm.value as? String, originalBpm, "Cancel must not change the practice stage")
        app.buttons["取消"].tap()
        closePanel()

        try selectVisibleTabRange()
        open("loop")
        let enable = app.switches["启用自定义阶梯"]
        reveal(enable, in: "loop")
        XCTAssertTrue(enable.isEnabled, "The touch-selected A/B range must enable stages")
        if enable.value as? String != "1" { enable.tap() }
        assertPanelFits("loop")
        capture("GP-panel-loop-stages-paused-mini")
        closePanel()
        let stage = app.buttons["gp.deck.stage"]
        let selector = app.buttons["gp.deck.stage.select"]
        XCTAssertTrue(stage.waitForExistence(timeout: 5))
        XCTAssertTrue(selector.isHittable)
        XCTAssertGreaterThanOrEqual(selector.frame.height, 44)
        XCTAssertLessThanOrEqual(stage.frame.maxX, selector.frame.minX + 1)
        assertInside(selector.frame, element("gp.deck").frame, "Stage selector")
        capture("GP-panel-stages-enabled-mini")

        // Keep the transport playing while opening/changing controls. The real
        // player integration tests separately cover audio and loop timing.
        play.tap()
        wait("Playback starts") { play.label.contains("暂停") }
        let elapsed = element("gp.elapsed")
        XCTAssertTrue(elapsed.exists)
        let firstTime = elapsed.label
        wait("Playback time advances", timeout: 8) { elapsed.label != firstTime }
        for panel in ["loop", "sound", "metronome", "tracks", "loop"] {
            open(panel)
            assertPanelFits(panel)
            XCTAssertTrue(play.label.contains("暂停"), "Panel \(panel) must keep GP playing")
        }
        let afterSwitchTime = elapsed.label
        wait("Playback continues after panel switches", timeout: 8) { elapsed.label != afterSwitchTime }
        capture("GP-panel-switching-during-playback-mini")
        play.tap()
        wait("Pause remains available") { play.label.contains("播放") }
        closePanel()
        app.buttons["gp.stop"].tap()
        removeFixtureThroughLibrary()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func wait(_ description: String, timeout: TimeInterval = 5, until predicate: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, description)
    }

    private func open(_ panel: String) {
        let container = element("gp.panel.\(panel)")
        if !container.exists {
            let button = app.buttons[panel == "standalone" ? "gp.standalone.settings" : "gp.tool.\(panel)"]
            XCTAssertTrue(button.isHittable, "Panel switch \(panel) must remain available")
            button.tap()
        }
        XCTAssertTrue(container.waitForExistence(timeout: 5))
    }

    private func closePanel() {
        let close = app.buttons["gp.panel.close"]
        XCTAssertTrue(close.isHittable)
        close.tap()
        wait("Panel closes") { !self.app.buttons["gp.panel.close"].exists }
    }

    private func assertPanelFits(_ panel: String, file: StaticString = #filePath, line: UInt = #line) {
        let container = element("gp.panel.\(panel)")
        let viewport = element("gp.viewport")
        let deck = element("gp.deck")
        XCTAssertTrue(viewport.exists && deck.exists, file: file, line: line)
        assertInside(deck.frame, app.frame, "Transport deck inside screen", file: file, line: line)
        assertInside(container.frame, viewport.frame, "\(panel) inside score viewport", file: file, line: line)
        assertDisjoint(container.frame, deck.frame, "\(panel) / transport deck", file: file, line: line)
        assertDisjoint(container.frame, app.navigationBars.firstMatch.frame, "\(panel) / navigation", file: file, line: line)
        XCTAssertTrue(element("gp.sync.mark").isHittable, "The sync marker must remain available", file: file, line: line)
        for id in ["gp.status", "gp.sync.mark"] {
            XCTAssertTrue(element(id).exists, "Loaded GP must keep \(id)", file: file, line: line)
            assertInside(element(id).frame, viewport.frame, id, file: file, line: line)
            assertDisjoint(container.frame, element(id).frame, "\(panel) / \(id)", file: file, line: line)
        }
        for other in panels where other != panel {
            XCTAssertFalse(element("gp.panel.\(other)").exists, "Only the current panel should remain", file: file, line: line)
        }
        XCTAssertTrue(app.buttons["gp.panel.close"].isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(app.buttons["gp.panel.close"].frame.height, 44, file: file, line: line)
    }

    private func assertInside(_ inner: CGRect, _ outer: CGRect, _ message: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(inner.width, 0, message, file: file, line: line)
        XCTAssertGreaterThan(inner.height, 0, message, file: file, line: line)
        XCTAssertGreaterThanOrEqual(inner.minX, outer.minX - 1, message, file: file, line: line)
        XCTAssertGreaterThanOrEqual(inner.minY, outer.minY - 1, message, file: file, line: line)
        XCTAssertLessThanOrEqual(inner.maxX, outer.maxX + 1, message, file: file, line: line)
        XCTAssertLessThanOrEqual(inner.maxY, outer.maxY + 1, message, file: file, line: line)
    }

    private func assertDisjoint(_ first: CGRect, _ second: CGRect, _ message: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let overlap = first.intersection(second)
        XCTAssertTrue(overlap.isNull || overlap.width <= 1 || overlap.height <= 1,
                      "\(message): \(first) intersects \(second)", file: file, line: line)
    }

    private func reveal(_ control: XCUIElement, in panel: String) {
        let container = element("gp.panel.\(panel)")
        for _ in 0..<7 where !control.isHittable {
            // Drag only inside the form, leaving its fixed heading/close button.
            container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                .press(forDuration: 0.05, thenDragTo: container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        }
        XCTAssertTrue(control.isHittable, "The panel must scroll to \(control.identifier)")
    }

    private func selectVisibleTabRange() throws {
        // Match frets on one TAB line, excluding a bar-number 3 above the staff.
        let starts = app.webViews.staticTexts.matching(identifier: "3").allElementsBoundByIndex.filter(\.isHittable)
        let ends = app.webViews.staticTexts.matching(identifier: "8").allElementsBoundByIndex.filter(\.isHittable)
        var pairs: [(XCUIElement, XCUIElement)] = []
        for start in starts {
            for end in ends where abs(start.frame.midY - end.frame.midY) < 4 && end.frame.midX > start.frame.midX + 40 {
                pairs.append((start, end))
            }
        }
        pairs.sort {
            abs($0.0.frame.midY - $1.0.frame.midY) > 4 ? $0.0.frame.midY < $1.0.frame.midY : $0.0.frame.midX < $1.0.frame.midX
        }
        let pair = try XCTUnwrap(pairs.first, "The imported GP must expose a visible TAB range")
        let center = CGVector(dx: 0.5, dy: 0.5)
        pair.0.coordinate(withNormalizedOffset: center).press(forDuration: 0.8,
            thenDragTo: pair.1.coordinate(withNormalizedOffset: center))
        XCTAssertTrue(app.buttons["退出区间循环"].firstMatch.waitForExistence(timeout: 5))
    }

    private func removeFixtureThroughLibrary() {
        app.buttons["选择文件"].tap()
        let more = app.buttons["更多：\(fixtureName)"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        app.buttons["删除文件"].tap()
        app.buttons["删除 \(fixtureName)"].tap()
        wait("The fixture is removed through the normal library") { !more.exists }
        app.buttons["关闭"].tap()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
