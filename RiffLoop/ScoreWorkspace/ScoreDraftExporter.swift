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
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft))
        let web = WKWebView(frame: .zero)
        defer { web.stopLoading() }
        web.loadFileURL(page, allowingReadAccessTo: root)
        let deadline = Date().addingTimeInterval(60)
        var ready = false
        while Date() < deadline {
            try Task.checkCancellation()
            if let result = try? await web.evaluateJavaScript("typeof alphaTab !== 'undefined' && typeof RiffLoopDraftEditor !== 'undefined'"),
               result as? Bool == true {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard ready else { throw ScoreDraftExportError.unavailable }
        let result = try await web.callAsyncJavaScript("""
            const bytes = RiffLoopDraftEditor.exportStoredDraft(alphaTab, draft);
            if (!(bytes instanceof Uint8Array) || !bytes.length || bytes.length > 8 * 1024 * 1024) {
                throw new Error('Invalid GP output');
            }
            const pieces = [];
            for (let i = 0; i < bytes.length; i += 8192) {
                pieces.push(String.fromCharCode(...bytes.subarray(i, i + 8192)));
            }
            return btoa(pieces.join(''));
            """, arguments: ["draft": payload], in: nil, contentWorld: .page)
        try Task.checkCancellation()
        guard let encoded = result as? String, let data = Data(base64Encoded: encoded),
              data.count <= 8 * 1024 * 1024, data.starts(with: [0x50, 0x4b, 0x03, 0x04]) else {
            throw ScoreDraftExportError.invalidOutput
        }
        return data
    }
}
