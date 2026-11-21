import Foundation
import WebKit

enum GpLoadPhase: Equatable {
    case reading, waitingForRenderer, sending(Int, Int), parsing, drawing, backing(Int, Int), preparingPlayer

    var title: String {
        switch self {
        case .reading: return "正在读取 GP 文件"
        case .waitingForRenderer: return "正在启动谱面引擎"
        case .sending: return "正在传入曲谱"
        case .parsing: return "正在解析曲谱"
        case .drawing: return "正在绘制谱面"
        case .backing: return "正在准备内嵌伴奏"
        case .preparingPlayer: return "正在准备播放器"
        }
    }

    var bytes: (done: Int, total: Int)? {
        switch self {
        case let .sending(done, total), let .backing(done, total): return (done, total)
        default: return nil
        }
    }
}

struct GpBackingStream: Codable, Equatable, Sendable {
    let mimeType: String
    let byteLength: Int
    let revision: Int
    let syncPoints: [GpBackingSyncPoint]
}

// Each WebKit call acknowledges one bounded block before the next is created.
@MainActor
enum GpScoreTransfer {
    static let blockSize = 768 * 1024

    // Use WebKit's original callback entry point on every supported iPadOS version.
    private static func evaluate(_ script: String, in web: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    static func send(_ data: Data, id: String, web: WKWebView, progress: (Int) -> Void) async throws {
        let quotedID = String(decoding: try JSONEncoder().encode(id), as: UTF8.self)
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            let end = min(offset + blockSize, data.count)
            let start = offset
            let script = await Task.detached(priority: .userInitiated) {
                let encoded = data[data.startIndex + start ..< data.startIndex + end].base64EncodedString()
                return "window.riffloop.appendScoreChunk(\(quotedID),\(data.count),\(start),'\(encoded)')"
            }.value
            try Task.checkCancellation()
            let ack = try await evaluate(script, in: web)
            try Task.checkCancellation()
            guard (ack as? NSNumber)?.intValue == end else { throw CocoaError(.fileReadCorruptFile) }
            offset = end
            progress(end)
        }
        let result = try await evaluate("window.riffloop.finishScoreTransfer(\(quotedID))", in: web)
        guard (result as? NSNumber)?.boolValue == true else { throw CocoaError(.fileReadCorruptFile) }
    }

    // The caller takes ownership of the complete file. Partial and cancelled writes are removed here.
    static func receive(_ stream: GpBackingStream, id: String, web: WKWebView,
                        progress: (Int) -> Void) async throws -> URL {
        guard stream.byteLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let quotedID = String(decoding: try JSONEncoder().encode(id), as: UTF8.self)
        let url = GpNativeBackingPlayer.temporaryFile(for: stream.mimeType)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let output = try BackingWriter(url: url)
            var offset = 0
            while offset < stream.byteLength {
                try Task.checkCancellation()
                let count = min(blockSize, stream.byteLength - offset)
                let script = "window.riffloop.readBackingChunk(\(quotedID),\(stream.revision),\(offset),\(count))"
                let result = try await evaluate(script, in: web)
                guard let encoded = result as? String else { throw CocoaError(.fileReadCorruptFile) }
                try Task.checkCancellation()
                try await output.append(encoded, count: count)
                try Task.checkCancellation()
                offset += count
                progress(offset)
            }
            try await output.close()
            try Task.checkCancellation()
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

private actor BackingWriter {
    let handle: FileHandle
    init(url: URL) throws { handle = try FileHandle(forWritingTo: url) }
    func append(_ encoded: String, count: Int) throws {
        guard let data = Data(base64Encoded: encoded), data.count == count else { throw CocoaError(.fileReadCorruptFile) }
        try handle.write(contentsOf: data)
    }
    func close() throws { try handle.close() }
}
