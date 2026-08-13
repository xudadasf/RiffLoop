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

        let webView = WKWebView(frame: .zero, configuration: configuration)
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

        init(viewModel: GpWebViewModel) {
            self.viewModel = viewModel
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
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
