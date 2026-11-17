import SwiftUI
import WebKit
import AVFAudio
import Combine

struct GuitarDraftDocument: Identifiable {
    let id: UUID
    let draft: GuitarDraft
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
        if let root = Bundle.main.resourceURL {
            web.loadFileURL(root.appendingPathComponent("ScoreEditor/editor.html"), allowingReadAccessTo: root)
        }
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) { }
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
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
        private var working = false
        private let interruption = AudioInterruptionRecovery()
        private var observers = Set<AnyCancellable>()

        init(document: GuitarDraftDocument, close: @escaping () -> Void, closeDirty: @escaping () -> Void) {
            self.document = document
            self.saved = document.draft
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
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
            if action == "ready" {
                do {
                    guard let root = Bundle.main.resourceURL else { return }
                    let draft = try JSONEncoder().encode(document.draft).base64EncodedString()
                    let schema = try Data(contentsOf: root.appendingPathComponent("ScoreEditor/techniques.json")).base64EncodedString()
                    web?.evaluateJavaScript("loadGuitarDraft(JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(draft)'),c=>c.charCodeAt(0)))),JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(schema)'),c=>c.charCodeAt(0)))))") { [weak self] _, error in
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
            guard !working else { return }
            if action == "close" { close(); return }
            if action == "closeDirty" { closeDirty(); return }
            working = true
            Task {
                defer { working = false }
                do {
                    if action == "source", let value = body["source"] {
                        let data = try JSONSerialization.data(withJSONObject: value)
                        let source = try JSONDecoder().decode(GuitarSource.self, from: data)
                        let files = try await ScoreWorkspaceStore().files()
                        guard let url = files.first(where: { $0.lastPathComponent == source.name }),
                              try await ScoreRegionsStore(source: url).snapshot().sourceDigest == source.digest else {
                            throw ScoreRegionsError.sourceChanged
                        }
                        let preview = await Task.detached { ScorePageRenderer.render(source: url, index: source.page) }.value
                        guard let image = preview.image?.cgImage else { throw ScoreRegionsError.unreadableSource }
                        let r = source.region
                        guard r.isValid, let cropped = image.cropping(to: CGRect(x: r.x * Double(image.width), y: r.y * Double(image.height), width: r.width * Double(image.width), height: r.height * Double(image.height))),
                              let jpeg = UIImage(cgImage: cropped).jpegData(compressionQuality: 0.85) else { throw ScoreRegionsError.invalidPage }
                        reply(["source": jpeg.base64EncodedString(), "message": "原图仅供对照，编辑不会改变素材。"])
                        return
                    }
                    guard let value = body["draft"] else { throw GuitarDraftStoreError.invalidDraft }
                    let data = try JSONSerialization.data(withJSONObject: value)
                    guard data.count <= 8 * 1024 * 1024 else { throw GuitarDraftStoreError.tooLarge }
                    let draft = try JSONDecoder().decode(GuitarDraft.self, from: data)
                    guard draft.isValidForStorage else { throw GuitarDraftStoreError.invalidDraft }
                    let message = try await GuitarResultSaver.shared.save(draft, id: document.id, replacing: saved)
                    saved = draft
                    reply(["saved": true, "message": message])
                } catch { reply(["message": "操作未完成：\(error.localizedDescription)"]) }
            }
        }
        private func reply(_ values: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: values) else { return }
            web?.evaluateJavaScript("guitarReply(JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(data.base64EncodedString())'),c=>c.charCodeAt(0)))))", completionHandler: nil)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // The editor has no remote pages or script sources.
            decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
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
