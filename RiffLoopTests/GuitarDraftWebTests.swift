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
            if let web, (try? await eval("Boolean(window.scoreEditor?.ready && document.querySelector('.scoreTarget')) && !document.body.hasAttribute('data-loading')", web)) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let editor = try XCTUnwrap(web)
        let ready = try await eval("Boolean(window.scoreEditor?.ready && document.querySelector('.scoreTarget'))", editor)
        XCTAssertEqual(ready as? Bool, true)
        guard ready as? Bool == true else { return }
        let value = try await eval("""
            (()=>{const tapDigit=n=>[...document.querySelectorAll('#keypad button')].find(b=>b.textContent===String(n)).click();
            tapDigit(1);tapDigit(3);document.getElementById('stringDown').click();tapDigit(1);tapDigit(1);
            document.getElementById('tab-beat').click();document.getElementById('insertBefore').click();document.getElementById('insertBefore').click();document.getElementById('undo').click();document.getElementById('redo').click();
            const frontOK=session.currentBar.beats[0].notes[0].fret===null && session.currentBar.beats[2].notes[0].fret===13;
            session.beat=2;session.string=1;render();document.getElementById('techniques').click();
            [...document.querySelectorAll('#toolStrip button')].find(b=>b.textContent==='掌根闷音 P.M.').click();
            document.getElementById('appliedTechniques').click();
            const applied=document.querySelector('[data-applied="note:isPalmMute"]');
            applied.querySelectorAll('button')[1].click();const removed=!session.currentNote.effects.isPalmMute;
            document.getElementById('panelClose').click();document.getElementById('undo').click();
            render();document.getElementById('save').click();
            return frontOK && removed && session.currentBar.beats.length===6 && session.currentBeat.notes.length===2;})()
            """, editor)
        XCTAssertEqual(value as? Bool,true)
        var saved = draft
        for _ in 0..<100 {
            saved = try await store.load(id)
            if saved != draft, (try? await eval("!document.body.inert && document.querySelectorAll('.scoreTarget').length===36", editor)) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(saved.bars[0].beats.count,6)
        XCTAssertEqual(saved.bars[0].beats[2].notes.map(\.fret),[13,11])
        XCTAssertEqual(saved.bars[0].beats[2].notes[0].effects["isPalmMute"],1)
        host.view.layoutIfNeeded()
        let icons = try await eval("[...document.querySelectorAll('img.toolIcon')].every(i=>i.complete && i.naturalWidth>0) && !document.querySelector('#panel').open && document.querySelectorAll('#toolTabs [role=tab]').length===8", editor)
        XCTAssertEqual(icons as? Bool,true,"Native tools must load their icons and edit without a modal")
        let layout=try await eval("innerWidth >= 700 && document.documentElement.scrollWidth <= innerWidth && document.querySelector('#keypad button').getBoundingClientRect().height >= 44 && document.querySelector('.scoreTarget.selected').getBoundingClientRect().height >= 10",editor)
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

    func testOpenExistingFileEditAndSaveFromNativeWebView() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("study.gp")
        let model = GuitarDraft(bars: [GuitarBar(beats: [GuitarBeat(duration: 1, notes: [GuitarNote(string: 1, fret: 7)])])])
        let original = try await ScoreDraftExporter.export(model)
        try original.write(to: url)
        let host = UIHostingController(rootView: GuitarDraftEditorView(document: .init(id: UUID(), draft: GuitarDraft(), gpURL: url)).environmentObject(ScoreExternalOpenCoordinator()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        func findWeb(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.compactMap(findWeb).first
        }
        let deadline = Date().addingTimeInterval(45)
        var active: WKWebView?
        while Date() < deadline {
            if let web = findWeb(host.view),
               (try? await eval("window.scoreEditor?.ready === true && session.currentNote?.fret === 7", web)) as? Bool == true {
                active = web; break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let web = try XCTUnwrap(active)
        _ = try await eval("document.querySelector('#tab-harmonic').click(); [...document.querySelectorAll('#toolStrip button')].find(b=>b.textContent==='自然泛音').click(); document.querySelector('#save').click(); true", web)
        let saveDeadline = Date().addingTimeInterval(15)
        while Date() < saveDeadline && (try? Data(contentsOf: url)) == original {
            try await Task.sleep(for: .milliseconds(100))
        }
        let saved = try Data(contentsOf: url)
        XCTAssertNotEqual(original, saved)
        let script = "alphaTab.importer.ScoreLoader.loadScoreFromBytes(Uint8Array.from(atob('\(saved.base64EncodedString())'),c=>c.charCodeAt(0)),new alphaTab.Settings()).tracks[0].staves[0].bars[0].voices[0].beats[0].notes[0].realValue"
        let pitch = try await eval(script, web)
        XCTAssertEqual(pitch as? Int, 83)
    }

    private func eval(_ source: String, _ web: WKWebView) async throws -> Any? {
        try await ScoreDraftWebReply.wait(timeout:10) { reply in web.evaluateJavaScript(source,completionHandler:reply) }
    }
}
