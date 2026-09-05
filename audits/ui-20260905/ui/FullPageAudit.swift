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
            let more = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "更多：")).firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 5))
            // SwiftUI Menu can report isHittable=false inside a List despite
            // its visible 44-point button. Tap its observed bounds and verify
            // the resulting menu, rather than accepting a tap as success.
            more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.buttons["修改显示名称"].waitForExistence(timeout: 5))
            shot("shared-file-actions")
            requireTap("修改显示名称")
            shot("shared-rename")
            XCTAssertTrue(app.buttons["保存"].isHittable)
            requireTap("取消")
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
        Thread.sleep(forTimeInterval: 4)
        shot("home-top")
        let signing = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "查看续签方法")).firstMatch
        XCTAssertTrue(signing.isHittable)
        signing.tap()
        shot("signing-help-top")
        app.swipeUp(); shot("signing-help-bottom")
        requireTap("关闭")
        app.swipeUp(); shot("home-bottom")
        if tap("查看全部") { shot("recent-projects"); home() }
        app.swipeDown()

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
        scrollPanel()
        requireTap("重新记录")
        Thread.sleep(forTimeInterval: 1)
        shot("pdf-follow-replacement-draft")
        requireTap("取消记录")
        XCTAssertTrue(app.staticTexts["轨迹已保存 · 2 个位置点"].exists)
        shot("pdf-follow-cancel-restored")
        scrollPanel(); shot("pdf-follow-bottom")
        requireTap("删除轨迹")
        shot("pdf-delete-track-confirmation")
        // Cancel the iPad confirmation by tapping the visible page outside it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.35)).tap()
        XCTAssertTrue(app.staticTexts["轨迹已保存 · 2 个位置点"].exists)
        requireTap("完成")
        library("pdf")
        home()
        shot("home-after-practice")
    }

    func test04SupplementaryPages() {
        openMode("Guitar Pro 乐谱")
        requireTap("节拍器", prefix: true)
        let enabled = app.switches["开启节拍器"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        // SwiftUI exposes a wide row and a nested UISwitch. Tap the actual
        // switch, since the row's center does not toggle this Form control.
        let control = enabled.switches.firstMatch
        XCTAssertTrue(control.isHittable)
        control.tap()
        XCTAssertTrue(app.staticTexts["节拍音量"].firstMatch.waitForExistence(timeout: 5))
        shot("gp-metronome-enabled-top")
        scrollPanel(); shot("gp-metronome-enabled-middle")
        scrollPanel(); shot("gp-metronome-enabled-bottom")
        let countIn = app.switches["开始播放前预备拍"].switches.firstMatch
        XCTAssertTrue(countIn.isHittable)
        countIn.tap()
        scrollPanel(); shot("gp-count-in-volume")
        requireTap("完成")
    }

    func test05SystemPicker() {
        openMode("Guitar Pro 乐谱")
        requireTap("选择文件")
        Thread.sleep(forTimeInterval: 2)
        requireTap("导入文件")
        Thread.sleep(forTimeInterval: 6)
        shot("shared-system-file-picker")
        // Closing the disposable simulator app avoids any dependency on the
        // provider's localized Cancel label, and never imports a file.
        app.terminate()
    }
}
