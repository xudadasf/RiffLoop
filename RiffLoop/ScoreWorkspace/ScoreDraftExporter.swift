import Foundation
import WebKit

enum ScoreDraftExportError: LocalizedError {
    case incomplete
    case missingResources
    case unavailable
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .incomplete: "草稿包含无效内容或尚未填满每个小节，不能导出。"
        case .missingResources: "离线草稿导出资源缺失。"
        case .unavailable: "离线草稿导出暂不可用，请重试。"
        case .invalidOutput: "生成的 GP 数据无效。"
        }
    }
}

/// Isolated new-draft export only. It never reads existing GP files or writes
/// to the practice library. The JS exporter reads the resulting GP back and
/// rejects it if the supported notes, rests or playback timing changed.
enum ScoreDraftExporter {
    @MainActor
    static func export(_ draft: ScoreDraft) async throws -> Data {
        guard draft.isComplete else { throw ScoreDraftExportError.incomplete }
        guard let root = Bundle.main.resourceURL,
              let page = Bundle.main.url(forResource: "ScoreDraft", withExtension: "html"),
              Bundle.main.url(forResource: "draft-core", withExtension: "js") != nil,
              FileManager.default.fileExists(atPath: root.appendingPathComponent("GpWeb/alphaTab.min.js").path) else {
            throw ScoreDraftExportError.missingResources
        }
        // Base64 contains only ASCII alphabet characters, so the user's title
        // and other draft data cannot become executable JavaScript.
        let payload = try JSONEncoder().encode(draft).base64EncodedString()
        let web = WKWebView(frame: .zero)
        defer { web.stopLoading() }
        web.loadFileURL(page, allowingReadAccessTo: root)
        let deadline = Date().addingTimeInterval(60)
        var ready = false
        while Date() < deadline {
            try Task.checkCancellation()
            if let result = try? await evaluate("typeof alphaTab !== 'undefined' && typeof RiffLoopDraftEditor !== 'undefined'", in: web),
               result as? Bool == true {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard ready else { throw ScoreDraftExportError.unavailable }
        let result = try await evaluate("""
            (() => {
            const jsonBytes = Uint8Array.from(atob('\(payload)'), c => c.charCodeAt(0));
            const draft = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(jsonBytes));
            const bytes = RiffLoopDraftEditor.exportStoredDraft(alphaTab, draft);
            if (!(bytes instanceof Uint8Array) || !bytes.length || bytes.length > 8 * 1024 * 1024) {
                throw new Error('Invalid GP output');
            }
            const pieces = [];
            for (let i = 0; i < bytes.length; i += 8192) {
                pieces.push(String.fromCharCode(...bytes.subarray(i, i + 8192)));
            }
            return btoa(pieces.join(''));
            })()
            """, in: web)
        try Task.checkCancellation()
        guard let encoded = result as? String, let data = Data(base64Encoded: encoded),
              data.count <= 8 * 1024 * 1024, data.starts(with: [0x50, 0x4b, 0x03, 0x04]) else {
            throw ScoreDraftExportError.invalidOutput
        }
        return data
    }

    // Use the completion-handler API: the WebKit native async overlay is not
    // available in every iPadOS runtime supported by this application.
    @MainActor
    private static func evaluate(_ script: String, in web: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            web.evaluateJavaScript(script, completionHandler: { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            })
        }
    }
}
