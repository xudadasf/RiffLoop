import SwiftUI
import WebKit

struct GpWebView: UIViewRepresentable {
    @ObservedObject var viewModel: GpWebViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "riffloop")

        let webView = GpViewportWebView(frame: .zero, configuration: configuration)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        viewModel.attach(webView: webView)

        guard
            let rootURL = Bundle.main.resourceURL?.appendingPathComponent("GpWeb", isDirectory: true),
            let indexURL = Bundle.main.url(
                forResource: "index",
                withExtension: "html",
                subdirectory: "GpWeb"
            )
        else {
            viewModel.receive(.error("离线 GP 渲染资源缺失。"))
            return webView
        }

        webView.loadFileURL(indexURL, allowingReadAccessTo: rootURL)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "riffloop")
        webView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let viewModel: GpWebViewModel
        private var lastPositionRecord = 0.0

        init(viewModel: GpWebViewModel) {
            self.viewModel = viewModel
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if var body = message.body as? [String: Any], let name = body["event"] as? String {
                let now = ProcessInfo.processInfo.systemUptime
                let sampled = name == "positionChanged"
                if !sampled || now - lastPositionRecord >= 1 {
                    if sampled { lastPositionRecord = now }
                    if name == "backingAudioLoaded", var payload = body["payload"] as? [String: Any] {
                        let binary = payload.removeValue(forKey: "data") as? String
                        payload["base64Characters"] = binary?.count ?? 0
                        body["payload"] = payload
                    }
                    if let json = try? JSONSerialization.data(withJSONObject: body) {
                        ReproductionStore.shared.record(sampled ? "sample" : (name == "error" || name == "reproductionError" ? "incident" : "event"), "gp.bridge." + name,
                            ["body": String(decoding: json, as: UTF8.self)])
                    }
                }
                if name.hasPrefix("reproduction") { return }
            }
            do {
                let event = try GpBridgeEvent.decode(messageBody: message.body)
                Task { @MainActor [viewModel] in
                    viewModel.receive(event)
                }
            } catch {
                Task { @MainActor [viewModel] in
                    viewModel.receiveBridgeFailure(error)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            (webView as? GpViewportWebView)?.syncViewport(force: true)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ReproductionStore.shared.record("incident", "web_content.process_terminated")
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            Task { @MainActor [viewModel] in
                viewModel.receive(.error("GP 页面加载失败：\(error.localizedDescription)"))
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            Task { @MainActor [viewModel] in
                viewModel.receive(.error("GP 页面加载失败：\(error.localizedDescription)"))
            }
        }
    }
}

/// The HTML scroller must use the area above SwiftUI's transport deck, not the full
/// WKWebView bounds. Automatic UIScrollView insets do not shrink a nested HTML scroller.
@MainActor
final class GpViewportWebView: WKWebView {
    private var lastViewport = ""
    override func layoutSubviews() {
        super.layoutSubviews()
        syncViewport()
    }
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        syncViewport()
    }
    func syncViewport(force: Bool = false) {
        let top = max(0, safeAreaInsets.top)
        let bottom = max(0, safeAreaInsets.bottom)
        let identity = "\(bounds.size):\(top):\(bottom)"
        guard force || identity != lastViewport else { return }
        lastViewport = identity
        evaluateJavaScript("window.riffloop?.setViewportInsets(\(top), \(bottom))", completionHandler: nil)
    }
}
