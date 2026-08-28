import SwiftUI
import WebKit

/// A separate, silent first-system render: never seeks or scrolls the practice player.
struct GpCoverPreview: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.96, green: 0.95, blue: 0.91, alpha: 1)
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = context.coordinator
        if let root = Bundle.main.resourceURL?.appendingPathComponent("GpWeb") {
            webView.loadFileURL(root.appendingPathComponent("preview.html"), allowingReadAccessTo: root)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        context.coordinator.render(in: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var url: URL
        private var ready = false

        init(url: URL) { self.url = url }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            render(in: webView)
        }

        func render(in webView: WKWebView) {
            guard ready, let data = try? Data(contentsOf: url),
                  let arguments = try? JSONSerialization.data(withJSONObject: [
                    data.base64EncodedString(), url.deletingPathExtension().lastPathComponent
                  ]),
                  let json = String(data: arguments, encoding: .utf8)
            else { return }
            webView.evaluateJavaScript("window.renderPreview.apply(null, \(json))", completionHandler: nil)
        }
    }
}
