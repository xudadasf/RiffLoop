import XCTest

final class FullPageAudit: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.riffloop.prototype")
    var sequence = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }

    func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 1)
        sequence += 1
        let stem = String(format: "%02d", sequence) + "-" + name
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = stem
        image.lifetime = .keepAlways
        add(image)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = stem + "-tree"
        tree.lifetime = .keepAlways
        add(tree)
    }

    @discardableResult func tap(_ label: String, prefix: Bool = false) -> Bool {
        let query = app.buttons.matching(NSPredicate(format: prefix ? "label BEGINSWITH %@" : "label == %@", label))
        for element in query.allElementsBoundByIndex where element.isHittable {
            element.tap()
            return true
        }
        return false
    }

    func requireTap(_ label: String, prefix: Bool = false) {
        XCTAssertTrue(tap(label, prefix: prefix), "Missing tappable button: \(label)\n\(app.debugDescription)")
    }

    func scrollPanel() {
        // Coordinates are relative to the visible right-side panel, after it
        // has been opened by its observed accessibility label.
        let panel = app.scrollViews.allElementsBoundByIndex.filter {
            $0.frame.midX > app.frame.width * 0.55 && $0.frame.height > 180
        }.last
        if let panel = panel { panel.swipeUp() }
        else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.81, dy: 0.72))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.81, dy: 0.27)))
        }
    }

    func panel(_ title: String, name: String, bottom: Bool = true) {
        requireTap(title, prefix: true)
        shot(name + "-top")
        if bottom { scrollPanel(); shot(name + "-bottom") }
        requireTap("完成")
    }

    func openMode(_ name: String) {
        if !tap(name, prefix: true) { app.swipeUp(); requireTap(name, prefix: true) }
        Thread.sleep(forTimeInterval: 4)
    }

    func home() {
        let back = app.navigationBars.buttons.allElementsBoundByIndex.first { $0.isHittable && ($0.label == "Back" || $0.label == "返回") }
        if let back = back { back.tap() }
        else { app.terminate(); app.launch() }
        Thread.sleep(forTimeInterval: 1)
    }

    func library(_ prefix: String, common: Bool = false) {
        requireTap(prefix == "pdf" ? "更换 PDF" : "选择文件")
        shot(prefix + "-library")
        if common {
            if tap("修改 ", prefix: true) { shot("shared-rename"); requireTap("取消") }
            if tap("删除 ", prefix: true) {
                shot("shared-delete-confirmation")
                if !tap("取消") {
                    // iPad confirmation popovers dismiss by tapping outside;
                    // do not activate the destructive confirmation button.
                    let title = app.navigationBars["GP"].staticTexts["GP"]
                    XCTAssertTrue(title.isHittable)
                    title.tap()
                }
            }
            if tap("导入") {
                shot("shared-system-file-picker")
                if !tap("取消") { _ = tap("Cancel") }
            }
        }
        requireTap("关闭")
    }

    func keypad(_ prefix: String) {
        requireTap("输入节拍速度")
        shot(prefix + "-bpm-keypad")
        if tap("清空") {
            requireTap("3"); requireTap("0"); requireTap("1")
            shot(prefix + "-bpm-invalid-301")
            XCTAssertFalse(app.buttons["应用"].isEnabled)
        }
        requireTap("取消")
    }

    func test01HomeAndGP() {
        shot("home-top")
        app.swipeUp(); shot("home-bottom")
        if tap("查看全部") { shot("recent-projects"); home() }
        app.swipeDown()
        if tap("查看续签方法") { shot("signing-help"); requireTap("关闭") }

        openMode("Guitar Pro 乐谱")
        shot("gp-main")
        panel("循环", name: "gp-loop")
        panel("节拍器", name: "gp-metronome")
        panel("声音", name: "gp-sound")
        panel("轨道", name: "gp-tracks")
        library("gp", common: true)
        home()
    }

    func test02Video() {
        openMode("视频练习")
        shot("video-main")
        panel("循环", name: "video-loop")
        requireTap("节拍器", prefix: true)
        shot("video-metronome-off")
        let enabled = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "开启节拍器")).firstMatch
        if enabled.exists && enabled.value as? String == "0" { enabled.tap() }
        shot("video-metronome-on-top")
        keypad("video")
        scrollPanel(); shot("video-metronome-bottom")
        requireTap("完成")
        panel("声音", name: "video-sound")
        library("video")
        home()
    }

    func test03PDF() {
        openMode("PDF 谱面")
        shot("pdf-main")
        requireTap("节拍器", prefix: true)
        shot("pdf-metronome-top")
        keypad("pdf")
        scrollPanel(); shot("pdf-metronome-bottom")
        requireTap("完成")
        requireTap("伴奏", prefix: true)
        shot("pdf-accompaniment-empty")
        requireTap("选择伴奏")
        shot("pdf-audio-library")
        if tap("节拍伴奏示例.wav", prefix: true) {
            shot("pdf-accompaniment-selected")
        } else { requireTap("关闭") }
        if app.buttons["完成"].isHittable { requireTap("完成") }
        panel("节拍器", name: "pdf-metronome-with-audio")
        requireTap("跟谱", prefix: true)
        shot("pdf-follow-empty")
        // Only this disposable simulator's synthetic PDF is recorded.
        if tap("开始记录") {
            Thread.sleep(forTimeInterval: 2)
            shot("pdf-follow-recording")
            if tap("结束并保存记录") { shot("pdf-follow-recorded") }
        }
        scrollPanel(); shot("pdf-follow-bottom")
        requireTap("完成")
        library("pdf")
        home()
        shot("home-after-practice")
    }
}
