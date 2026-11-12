import Foundation
import WebKit

enum ScoreDraftExportError: LocalizedError {
    case incomplete
    case missingResources
    case unavailable
    case invalidOutput
    case tooLarge
    case busy

    var errorDescription: String? {
        switch self {
        case .incomplete: "草稿包含无效内容或尚未填满每个小节，不能导出。"
        case .missingResources: "离线草稿导出资源缺失。"
        case .unavailable: "离线草稿导出暂不可用，请重试。"
        case .invalidOutput: "生成的 GP 数据无效。"
        case .tooLarge: "草稿较大，当前暂不能安全导出。"
        case .busy: "正在导出另一份草稿，请稍后重试。"
        }
    }
}

/// Completes at most once, even if WebKit replies after the timeout.
@MainActor
final class ScoreDraftWebReply {
    private var continuation: CheckedContinuation<Any?, Error>?

    init(_ continuation: CheckedContinuation<Any?, Error>) {
        self.continuation = continuation
    }

    func finish(value: Any?, error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: value) }
    }

    static func wait(timeout: TimeInterval,
                     start: (@escaping (Any?, Error?) -> Void) -> Void) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            let reply = ScoreDraftWebReply(continuation)
            start { value, error in
                DispatchQueue.main.async { reply.finish(value: value, error: error) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                reply.finish(value: nil, error: ScoreDraftExportError.unavailable)
            }
        }
    }
}

/// Isolated new-draft export only. It never reads existing GP files or writes
/// to the practice library. The JS exporter reads the resulting GP back and
/// rejects it if the supported notes, rests or playback timing changed.
enum ScoreDraftExporter {
    // Temporary conservative limit, not a measurement of iPad mini 6 capacity.
    static let maximumEvents = 512
    static let maximumBars = 64
    @MainActor private static var exporting = false

    @MainActor
    static func export(_ draft: ScoreDraft) async throws -> Data {
        guard draft.isComplete else { throw ScoreDraftExportError.incomplete }
        guard draft.bars.count <= maximumBars,
              draft.bars.reduce(0, { $0 + $1.count }) <= maximumEvents else {
            throw ScoreDraftExportError.tooLarge
        }
        return try await exportPayload(JSONEncoder().encode(draft).base64EncodedString(), version: .v1)
    }

    @MainActor
    static func export(_ draft: ScoreDraftV2) async throws -> Data {
        guard draft.isValidForStorage, draft.barTimings?.allSatisfy({ $0 == .complete }) == true else {
            throw ScoreDraftExportError.incomplete
        }
        guard draft.canExport else { throw ScoreDraftExportError.tooLarge }
        return try await exportPayload(JSONEncoder().encode(draft).base64EncodedString(), version: .v2)
    }

    private enum Version { case v1, v2 }

    @MainActor
    private static func exportPayload(_ payload: String, version: Version) async throws -> Data {
        guard !exporting else { throw ScoreDraftExportError.busy }
        exporting = true
        defer { exporting = false }
        guard let root = Bundle.main.resourceURL,
              let page = Bundle.main.url(forResource: "ScoreDraft", withExtension: "html"),
              Bundle.main.url(forResource: "draft-core", withExtension: "js") != nil,
              FileManager.default.fileExists(atPath: root.appendingPathComponent("GpWeb/alphaTab.min.js").path) else {
            throw ScoreDraftExportError.missingResources
        }
        let v2Source: String?
        switch version {
        case .v1: v2Source = nil
        case .v2:
            guard let url = Bundle.main.url(forResource: "draft-v2", withExtension: "cjs") else {
                throw ScoreDraftExportError.missingResources
            }
            v2Source = try String(contentsOf: url, encoding: .utf8)
        }
        let web = WKWebView(frame: .zero)
        defer { web.stopLoading() }
        web.loadFileURL(page, allowingReadAccessTo: root)
        let deadline = Date().addingTimeInterval(60)
        var ready = false
        while Date() < deadline {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            if let result = try? await evaluate("typeof alphaTab !== 'undefined' && typeof RiffLoopDraftEditor !== 'undefined'",
                                                in: web, timeout: min(30, remaining)),
               result as? Bool == true {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard ready else { throw ScoreDraftExportError.unavailable }
        let exportExpression: String
        if let v2Source {
            // Use the app-bundled experiment itself, scoped as CommonJS so it
            // cannot replace the v1 editor's globals. No user text is injected.
            let loaded = try await evaluate("""
                (() => {
                const module = { exports: {} };
                (function(module) {
                \(v2Source)
                })(module);
                globalThis.RiffLoopDraftV2 = module.exports;
                return typeof globalThis.RiffLoopDraftV2.exportDraft === 'function';
                })()
                """, in: web)
            guard loaded as? Bool == true else { throw ScoreDraftExportError.unavailable }
            exportExpression = "RiffLoopDraftV2.exportDraft(alphaTab, draft)"
        } else {
            exportExpression = "RiffLoopDraftEditor.exportStoredDraft(alphaTab, draft)"
        }
        // Base64 contains only ASCII alphabet characters, so the user's title
        // and other draft data cannot become executable JavaScript.
        let result = try await evaluate("""
            (() => {
            const jsonBytes = Uint8Array.from(atob('\(payload)'), c => c.charCodeAt(0));
            const draft = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(jsonBytes));
            const bytes = \(exportExpression);
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
    private static func evaluate(_ script: String, in web: WKWebView, timeout: TimeInterval = 30) async throws -> Any? {
        try await ScoreDraftWebReply.wait(timeout: timeout) { completion in
            web.evaluateJavaScript(script, completionHandler: completion)
        }
    }
}
