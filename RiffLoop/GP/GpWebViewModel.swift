import Combine
import Foundation
import WebKit

@MainActor
final class GpWebViewModel: ObservableObject {
    @Published private(set) var rendererReady = false
    @Published private(set) var playerReady = false
    @Published private(set) var score: GpScoreMetadata?
    @Published private(set) var renderMetrics: GpRenderMetrics?
    @Published private(set) var position = GpPlaybackPosition(
        currentTime: 0,
        totalTime: 0,
        currentTick: 0,
        endTick: 0
    )
    @Published private(set) var isPlaying = false
    @Published private(set) var selectedBar: GpBarHit?
    @Published private(set) var errorMessage: String?

    private weak var webView: WKWebView?
    private var pendingScoreData: Data?

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    func loadScore(data: Data) {
        score = nil
        playerReady = false
        position = GpPlaybackPosition(currentTime: 0, totalTime: 0, currentTick: 0, endTick: 0)
        selectedBar = nil
        errorMessage = nil

        guard rendererReady else {
            pendingScoreData = data
            return
        }
        sendScore(data)
    }

    func togglePlayback() {
        call("playPause")
    }

    func pause() {
        call("pause")
    }

    func stop() {
        call("stop")
    }

    func seek(to tick: Double) {
        call("seekTick", arguments: [tick])
    }

    func setPlaybackSpeed(_ speed: Double) {
        call("setPlaybackSpeed", arguments: [speed])
    }

    func setSceneActive(_ isActive: Bool) {
        call("lifecycle", arguments: [isActive])
    }

    func dismissError() {
        errorMessage = nil
    }

    func reportImportError(_ error: Error) {
        errorMessage = "GP 导入失败：\(error.localizedDescription)"
    }

    func receive(_ event: GpBridgeEvent) {
        switch event {
        case .ready:
            rendererReady = true
            if let pendingScoreData {
                self.pendingScoreData = nil
                sendScore(pendingScoreData)
            }
        case let .scoreLoaded(metadata):
            score = metadata
        case let .renderFinished(metrics):
            renderMetrics = metrics
        case .playerReady:
            playerReady = true
        case let .positionChanged(position):
            self.position = position
        case let .playerStateChanged(state):
            isPlaying = state.state == 1
        case let .barHit(bar):
            selectedBar = bar
        case let .error(message):
            errorMessage = message
        }
    }

    func receiveBridgeFailure(_ error: Error) {
        errorMessage = "GP 消息解析失败：\(error.localizedDescription)"
    }

    private func sendScore(_ data: Data) {
        call("loadScore", arguments: [data.base64EncodedString()])
    }

    private func call(_ function: String, arguments: [Any] = []) {
        guard let webView else { return }

        do {
            let data = try JSONSerialization.data(withJSONObject: arguments)
            guard let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.riffloop.\(function).apply(null, \(json))") {
                [weak self] _, error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    self?.errorMessage = "GP 命令执行失败：\(error.localizedDescription)"
                }
            }
        } catch {
            errorMessage = "GP 命令编码失败：\(error.localizedDescription)"
        }
    }
}
