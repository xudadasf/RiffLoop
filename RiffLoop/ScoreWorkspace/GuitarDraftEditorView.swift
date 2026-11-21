import SwiftUI
import WebKit
import AVFAudio
import Combine

struct GuitarDraftDocument: Identifiable, Sendable {
    let id: UUID
    let draft: GuitarDraft
    var gpURL: URL? = nil
    var publishedHash: String? = nil
    var didSaveGP: (@MainActor @Sendable () -> Void)? = nil
}

enum GuitarEditorPage {
    static let url = Bundle.main.url(forResource: "editor", withExtension: "html", subdirectory: "ScoreEditor")
    static func matches(_ candidate: URL?) -> Bool {
        guard let candidate, candidate.isFileURL, let url else { return false }
        return candidate.standardizedFileURL.resolvingSymlinksInPath().path == url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

struct GuitarDraftEditorView: View {
    let document: GuitarDraftDocument
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var externalOpen: ScoreExternalOpenCoordinator
    @State private var confirmDiscard = false

    var body: some View {
        GuitarDraftWebEditor(document: document, close: { dismiss() }, closeDirty: { confirmDiscard = true })
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .interactiveDismissDisabled()
            .onAppear { externalOpen.beginRegionEditing() }
            .onDisappear { externalOpen.endRegionEditing() }
            .confirmationDialog("尚有未保存的编辑，确定离开？", isPresented: $confirmDiscard) {
                Button("放弃未保存的编辑", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) { }
            }
    }
}

private struct GuitarDraftWebEditor: UIViewRepresentable {
    let document: GuitarDraftDocument
    let close: () -> Void
    let closeDirty: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(document: document, close: close, closeDirty: closeDirty) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(context.coordinator, name: "guitarEditor")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .systemBackground
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        if let page = GuitarEditorPage.url, let root = Bundle.main.resourceURL {
            web.loadFileURL(page, allowingReadAccessTo: root)
        }
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) { }
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.cancelSource()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "guitarEditor")
        web.evaluateJavaScript("window.disposeGuitarEditor?.()", completionHandler: nil)
        web.stopLoading()
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var web: WKWebView?
        let document: GuitarDraftDocument
        var saved: GuitarDraft
        let close: () -> Void
        let closeDirty: () -> Void
        private var originalGP: Data?
        private var publishedHash: String?
        private var working = false
        private let sourceReader = ScoreReferenceReader()
        private var sourceTask: Task<Void, Never>?
        private let interruption = AudioInterruptionRecovery()
        private var observers = Set<AnyCancellable>()

        init(document: GuitarDraftDocument, close: @escaping () -> Void, closeDirty: @escaping () -> Void) {
            self.document = document
            self.saved = document.draft
            self.publishedHash = document.publishedHash
            self.close = close
            self.closeDirty = closeDirty
            super.init()
            interruption.onBegan = { [weak self] in self?.pause(); return nil }
            interruption.onDisconnect = { [weak self] in self?.pause() }
            NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
                .receive(on: RunLoop.main).sink { [weak self] _ in self?.pause() }.store(in: &observers)
            NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
                .receive(on: RunLoop.main).sink { [weak self] _ in self?.pause() }.store(in: &observers)
        }

        private func pause() { web?.evaluateJavaScript("window.pauseGuitarEditor?.()", completionHandler: nil) }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let web, message.webView === web, message.frameInfo.isMainFrame,
                  GuitarEditorPage.matches(message.frameInfo.request.url),
                  let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
            if action == "ready" {
                do {
                    guard let root = Bundle.main.resourceURL else { return }
                    let draft = try JSONEncoder().encode(document.draft).base64EncodedString()
                    let schema = try Data(contentsOf: root.appendingPathComponent("ScoreEditor/techniques.json")).base64EncodedString()
                    let load: String
                    if let url = document.gpURL {
                        let data = try GuitarExistingFile.read(url)
                        originalGP = data
                        load = "loadExistingGuitarGP('\(data.base64EncodedString())',JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(schema)'),c=>c.charCodeAt(0)))))"
                    } else {
                        load = "loadGuitarDraft(JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(draft)'),c=>c.charCodeAt(0)))),JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(schema)'),c=>c.charCodeAt(0)))))"
                    }
                    web.evaluateJavaScript(load) { [weak self] _, error in
                        if let error { self?.reply(["message": "编辑页加载失败：\(error.localizedDescription)"]); return }
                        do {
                            let audio = AVAudioSession.sharedInstance()
                            try audio.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                            try audio.setActive(true)
                            let soundFont = try Data(contentsOf: root.appendingPathComponent("GpWeb/soundfont/sonivox.sf3")).base64EncodedString()
                            self?.web?.evaluateJavaScript("loadEditorSoundFont('\(soundFont)')", completionHandler: nil)
                        } catch { self?.reply(["message": "曲谱已打开，音色加载失败：\(error.localizedDescription)"]) }
                    }
                } catch { reply(["message": error.localizedDescription]) }
                return
            }
            if action == "activateAudio" {
                do { try AVAudioSession.sharedInstance().setActive(true) }
                catch { pause(); reply(["message": "暂时无法播放：\(error.localizedDescription)"]) }
                return
            }
            if action == "cancelSource" { cancelSource(); return }
            if action == "source", document.gpURL == nil, let token = body["token"] as? Int {
                cancelSource()
                sourceTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        guard let value = body["source"] else { throw ScoreRegionsError.invalidPage }
                        let data = try JSONSerialization.data(withJSONObject: value)
                        let source = try JSONDecoder().decode(GuitarSource.self, from: data)
                        guard source.isValid else { throw ScoreRegionsError.invalidPage }
                        try await Task.sleep(for: .milliseconds(65))
                        let result = try await sourceReader.image(for: source)
                        try Task.checkCancellation()
                        sendSource(["token": token, "image": result.image, "label": result.label])
                    } catch {
                        if !Task.isCancelled { sendSource(["token": token, "label": "原图无法显示：\(error.localizedDescription)"]) }
                    }
                }
                return
            }
            guard !working else { return }
            if action == "close" { close(); return }
            if action == "closeDirty" { closeDirty(); return }
            working = true
            Task {
                defer { working = false }
                do {
                    if action == "saveGP", let url = document.gpURL, let originalGP,
                       let encoded = body["file"] as? String, encoded.utf8.count <= 90 * 1024 * 1024,
                       let data = Data(base64Encoded: encoded) {
                        try await GuitarExistingFile.shared.replace(url, original: originalGP, edited: data)
                        self.originalGP = data
                        document.didSaveGP?()
                        reply(["saved": true, "message": "整份 GP 已保存。"])
                        return
                    }
                    guard action == "save", document.gpURL == nil, let value = body["draft"] else { throw GuitarDraftStoreError.invalidDraft }
                    let data = try JSONSerialization.data(withJSONObject: value)
                    guard data.count <= 8 * 1024 * 1024 else { throw GuitarDraftStoreError.tooLarge }
                    let draft = try JSONDecoder().decode(GuitarDraft.self, from: data)
                    guard draft.isValidForStorage else { throw GuitarDraftStoreError.invalidDraft }
                    let result = try await GuitarResultSaver.shared.save(draft, id: document.id, replacing: saved, publishedHash: publishedHash)
                    if let hash = result.publishedHash {
                        if publishedHash != nil { publishedHash = hash }
                        document.didSaveGP?()
                    }
                    saved = draft
                    let savedForThisEditor = document.publishedHash == nil || result.publishedHash != nil
                    reply(["saved": savedForThisEditor, "message": result.message])
                } catch { reply(["message": "操作未完成：\(error.localizedDescription)"]) }
            }
        }
        func cancelSource() { sourceTask?.cancel(); sourceTask = nil }

        private func sendSource(_ values: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: values, options: .withoutEscapingSlashes) else { return }
            let json = String(decoding: data, as: UTF8.self)
            web?.evaluateJavaScript("window.guitarSourceReply(\(json))", completionHandler: nil)
        }

        private func reply(_ values: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: values) else { return }
            web?.evaluateJavaScript("guitarReply(JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(data.base64EncodedString())'),c=>c.charCodeAt(0)))))", completionHandler: nil)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // The editor has no remote pages or script sources.
            decisionHandler(navigationAction.targetFrame?.isMainFrame == true && GuitarEditorPage.matches(navigationAction.request.url) ? .allow : .cancel)
        }
    }
}

struct GuitarDraftLibraryView: View {
    @State private var documents: [GuitarDraftDocument] = []
    @State private var selected: GuitarDraftDocument?
    @State private var deleting: GuitarDraftDocument?
    @State private var message: String?
    private let store = GuitarDraftStore()
    var body: some View {
        List {
            Section {
                Button("新建电吉他曲谱") {
                    Task {
                        do { let draft = GuitarDraft(); let id = try await store.create(draft); selected = .init(id: id, draft: draft) }
                        catch { message = error.localizedDescription }
                    }
                }
                Text("点谱面选音，编辑后试听；保存更新同一份曲谱，原素材保留。")
            }
            ForEach(documents) { document in
                HStack {
                Button { selected = document } label: {
                    VStack(alignment: .leading) {
                        Text(document.draft.title)
                        Text("\(document.draft.bars.count) 小节 · \(document.draft.tempo) BPM · \(document.draft.numerator)/\(document.draft.denominator)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("清理草稿", role: .destructive) { deleting = document }.buttonStyle(.borderless)
                }
            }
            if let message { Text(message).foregroundStyle(.orange) }
        }
        .navigationTitle("电吉他曲谱")
        .task { await refresh() }
        .fullScreenCover(item: $selected, onDismiss: { Task { await refresh() } }) { GuitarDraftEditorView(document: $0) }
        .confirmationDialog("仅删除这份编辑草稿，已生成的 GP 和原素材会保留。请确认修正结果已另存。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除这份草稿", role: .destructive) {
                guard let document = deleting else { return }
                Task {
                    do { try await store.remove(document.id, matching: document.draft); await refresh() }
                    catch { message = error.localizedDescription }
                    deleting = nil
                }
            }
            Button("保留", role: .cancel) { deleting = nil }
        }
    }
    private func refresh() async {
        do {
            var result: [GuitarDraftDocument] = []
            for id in try await store.listIDs() {
                do { result.append(.init(id: id, draft: try await store.load(id))) }
                catch { message = "部分草稿暂时无法读取：\(error.localizedDescription)" }
            }
            documents = result
        } catch { message = error.localizedDescription }
    }
}
