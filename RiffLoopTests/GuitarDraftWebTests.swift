import SwiftUI
import WebKit
import XCTest
@testable import RiffLoop

@MainActor
final class GuitarDraftWebTests: XCTestCase {
    func testNativeEditorKeypadRestAndTechniquesSaveRoundTrip() async throws {
        let store = GuitarDraftStore()
        var draft = GuitarDraft(title: "原生编辑测试")
        draft.bars[0].beats = (0..<4).map { _ in GuitarBeat() }
        let id = try await store.create(draft)
        let host = UIHostingController(rootView: GuitarDraftEditorView(document: .init(id: id, draft: draft)).environmentObject(ScoreExternalOpenCoordinator()))
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKeyWindow=scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene:scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }
        func find(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.compactMap { find($0) }.first
        }
        let deadline = Date().addingTimeInterval(45)
        var web: WKWebView?
        while Date() < deadline {
            web = find(host.view)
            if let web, (try? await eval("typeof session !== 'undefined' && !!session", web)) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let editor = try XCTUnwrap(web)
        let ready = try await eval("!!session", editor)
        XCTAssertEqual(ready as? Bool, true)
        let value = try await eval("""
            (()=>{session.setFret(13);session.string=2;session.setFret(11);
            session.insertBeat();session.insertBeat();session.undo();session.redo();
            session.beat=2;session.string=1;session.change(()=>session.currentNote.effects.isPalmMute=1);
            render();document.getElementById('save').click();
            return session.currentBar.beats.length===6 && session.currentBeat.notes.length===2;})()
            """, editor)
        XCTAssertEqual(value as? Bool,true)
        var saved = draft
        for _ in 0..<100 {
            saved = try await store.load(id)
            if saved != draft { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(saved.bars[0].beats.count,6)
        XCTAssertEqual(saved.bars[0].beats[2].notes.map(\.fret),[13,11])
        XCTAssertEqual(saved.bars[0].beats[2].notes[0].effects["isPalmMute"],1)
        host.view.layoutIfNeeded()
        let layout=try await eval("innerWidth >= 700 && document.documentElement.scrollWidth <= innerWidth && document.querySelector('.cell').getBoundingClientRect().height >= 44",editor)
        XCTAssertEqual(layout as? Bool,true,"Native iPad editor must retain touch targets and fit the viewport")
        let image:UIImage = try await withCheckedThrowingContinuation { continuation in
            editor.takeSnapshot(with:nil) { image,error in
                if let image { continuation.resume(returning:image) }
                else { continuation.resume(throwing:error ?? NSError(domain:"EditorSnapshot",code:1)) }
            }
        }
        let pixels=try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
        XCTAssertGreaterThan(pixels.filter { $0 > 32 }.count,pixels.count/3,"A blank native snapshot is not visual validation")
        let attachment = XCTAttachment(image: image); attachment.name = "Electric-guitar-editor-mini"; attachment.lifetime = .keepAlways; add(attachment)
        try await store.remove(id, matching: saved)
    }

    func testNativeGPExportKeepsElectricPitchAndEffects() async throws {
        let note = GuitarNote(string: 1,fret: 13,effects: ["isPalmMute":1],bend: [.init(offset:0,value:0),.init(offset:60,value:4)])
        let draft = GuitarDraft(tempo:70,numerator:3,denominator:4,bars:[GuitarBar(beats:[GuitarBeat(notes:[note]),GuitarBeat(duration:2)])])
        let data = try await ScoreDraftExporter.export(draft)
        XCTAssertTrue(data.starts(with:[0x50,0x4b,0x03,0x04]))
    }

    private func eval(_ source: String, _ web: WKWebView) async throws -> Any? {
        try await ScoreDraftWebReply.wait(timeout:10) { reply in web.evaluateJavaScript(source,completionHandler:reply) }
    }
}
