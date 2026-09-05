import CryptoKit
import Foundation

struct ReproductionEvent: Codable {
    let sequence: Int
    let date: Date
    let elapsed: Double
    let kind: String
    let name: String
    let details: [String: String]
    let state: [String: String]
}

struct ReproductionMaterial: Codable {
    let id: String
    let name: String
    let role: String
    let originalPath: String
    var bytes: Int64 = 0
    var sha256: String?
    var snapshot: String?
    var status = "pending"
}

struct ReproductionSession: Codable, Identifiable {
    let id: String
    let started: Date
    var environment: [String: String]
    var materials: [ReproductionMaterial] = []
    var incidents = 0
    var droppedEvents = 0
    var recordingErrors = 0
    var lastSequence = 0
    var phase = "starting"
    var lastState: [String: String] = [:]
}

/// Disk and hashing work never runs on the caller's (usually UI) thread.
/// A separate material queue prevents a large video copy from blocking the journal.
final class ReproductionStore: @unchecked Sendable {
    static let shared = ReproductionStore()
    let root: URL
    private let io = DispatchQueue(label: "riffloop.reproduction.journal", qos: .utility)
    private let materials = DispatchQueue(label: "riffloop.reproduction.materials", qos: .utility)
    private let exporter = DispatchQueue(label: "riffloop.reproduction.export", qos: .utility)
    private var session: ReproductionSession?
    private var context: [String: String] = [:]
    private var origin = ProcessInfo.processInfo.systemUptime
    private var part = 0
    private var partBytes = 0
    private let partLimit: Int
    private let materialLimit: Int64
    private var reservedBytes: Int64 = 0
    private var captures: [String: String] = [:]

    init(root: URL? = nil, partLimit: Int = 2_000_000, materialLimit: Int64 = 256_000_000) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reproduction", isDirectory: true)
        self.partLimit = partLimit
        self.materialLimit = materialLimit
    }

    func start(environment: [String: String]) {
        io.async {
            guard self.session == nil else { return }
            do {
                try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
                var excluded = URLResourceValues()
                excluded.isExcludedFromBackup = true
                var root = self.root
                try root.setResourceValues(excluded)
                let previous = self.readSessions().first
                self.origin = ProcessInfo.processInfo.systemUptime
                let session = ReproductionSession(id: UUID().uuidString, started: Date(), environment: environment)
                self.session = session
                try FileManager.default.createDirectory(at: self.directory(session.id), withIntermediateDirectories: true)
                self.writeEvent("lifecycle", "session.start", [:])
                if let previous, previous.phase == "active" || previous.phase == "starting" {
                    self.writeEvent("incident", "previous_session_unfinished", [
                        "previousSession": previous.id,
                        "classification": "unknown: crash, force quit, termination or power loss; not proof of crash"
                    ])
                }
                // Keep three sessions; complete retained journals carry their own material copies.
                for old in self.readSessions().dropFirst(3) {
                    try? FileManager.default.removeItem(at: self.directory(old.id))
                }
            } catch { self.session?.recordingErrors += 1 }
        }
    }

    func update(_ state: [String: String]) {
        io.async { self.context.merge(state) { _, new in new } }
    }

    func record(_ kind: String = "action", _ name: String, _ details: [String: String] = [:]) {
        let date = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        io.async { self.writeEvent(kind, name, details, date: date, uptime: uptime) }
    }

    func phase(_ phase: String) {
        io.async {
            self.session?.phase = phase
            self.writeEvent("lifecycle", "scene.\(phase)", [:])
        }
    }

    func encoded<Value: Encodable>(_ value: Value) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "<encoding failed>" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Capture a separate copy, so later deletion/renaming does not silently change a replay.
    /// Over-budget, changed, or unreadable inputs are explicitly incomplete in the manifest.
    func capture(_ url: URL, role: String, loadedData: Data? = nil) {
        io.async {
            guard let sessionID = self.session?.id else { return }
            let attributes = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            // Exact loaded GP bytes are hashed on the material queue; other inputs reuse only the same file revision.
            let revision = loadedData == nil ? "\(attributes?.fileSize ?? -1):\(attributes?.contentModificationDate?.timeIntervalSince1970 ?? -1)" : UUID().uuidString
            let key = "\(role):\(url.path):\(revision)"
            if let id = self.captures[key] {
                self.writeEvent("material", "material.reused", ["materialID": id, "role": role])
                return
            }
            let id = UUID().uuidString
            self.captures[key] = id
            self.session?.materials.append(ReproductionMaterial(id: id, name: url.lastPathComponent, role: role, originalPath: url.path))
            self.writeEvent("material", "material.requested", ["materialID": id, "role": role, "file": url.lastPathComponent])
            self.materials.async {
                var material = ReproductionMaterial(id: id, name: url.lastPathComponent, role: role, originalPath: url.path)
                do {
                    let before = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    material.bytes = Int64(loadedData?.count ?? before?.fileSize ?? 0)
                    guard material.bytes <= self.materialLimit - self.reservedBytes else {
                        material.status = "omitted: material budget exceeded; original file required"
                        self.finishCapture(material, sessionID: sessionID)
                        return
                    }
                    self.reservedBytes += material.bytes
                    let relative = "materials/\(id)/\(url.lastPathComponent)"
                    let target = self.directory(sessionID).appendingPathComponent(relative)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if let loadedData { try loadedData.write(to: target, options: .atomic) }
                    else { try FileManager.default.copyItem(at: url, to: target) }
                    material.sha256 = try Self.hash(target)
                    material.snapshot = relative
                    let after = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    material.status = loadedData != nil || (before != nil && before?.fileSize == after?.fileSize && before?.contentModificationDate == after?.contentModificationDate)
                        ? "captured" : "changed_during_capture: cannot verify loaded bytes"
                } catch { material.status = "capture_failed: \(error.localizedDescription)" }
                self.finishCapture(material, sessionID: sessionID)
            }
        }
    }

    private func finishCapture(_ material: ReproductionMaterial, sessionID: String) {
        io.async {
            guard self.session?.id == sessionID,
                  let index = self.session?.materials.firstIndex(where: { $0.id == material.id }) else { return }
            self.session?.materials[index] = material
            self.writeEvent("material", "material.finished", ["materialID": material.id, "status": material.status])
        }
    }

    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty { hash.update(data: block) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func directory(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    private func writeEvent(_ kind: String, _ name: String, _ details: [String: String], date: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard var session else { return }
        session.lastSequence += 1
        if kind == "incident" { session.incidents += 1 }
        session.lastState = context
        let event = ReproductionEvent(sequence: session.lastSequence, date: date,
            elapsed: max(0, uptime - origin), kind: kind, name: name, details: details, state: context)
        do {
            var data = try JSONEncoder().encode(event)
            data.append(0x0a)
            if partBytes + data.count > partLimit {
                part += 1
                partBytes = 0
                if part >= 4 {
                    let old = directory(session.id).appendingPathComponent("events-\(part - 4).jsonl")
                    if let bytes = try? Data(contentsOf: old) { session.droppedEvents += bytes.filter { $0 == 0x0a }.count }
                    try? FileManager.default.removeItem(at: old)
                }
            }
            let file = directory(session.id).appendingPathComponent("events-\(part).jsonl")
            if !FileManager.default.fileExists(atPath: file.path) { try Data().write(to: file) }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            // Persist action/incident breadcrumbs before their corresponding async result.
            if kind != "sample" { try handle.synchronize() }
            partBytes += data.count
            try JSONEncoder().encode(session).write(to: directory(session.id).appendingPathComponent("manifest.json"), options: .atomic)
        } catch { session.recordingErrors += 1 }
        self.session = session
    }

    func saveSystemReport(_ data: Data) {
        io.async {
            guard let id = self.session?.id else { return }
            do {
                let name = "metrickit-\(UUID().uuidString).json"
                try data.write(to: self.directory(id).appendingPathComponent(name), options: .atomic)
                self.writeEvent("incident", "system.diagnostic_received", ["file": name,
                    "note": "System delivery may describe an earlier session; correlate payload timestamps."])
            } catch { self.writeEvent("incident", "system.diagnostic_write_failed", ["error": error.localizedDescription]) }
        }
    }

    func sessions() async -> [ReproductionSession] {
        await withCheckedContinuation { continuation in
            io.async { continuation.resume(returning: self.readSessions()) }
        }
    }

    private func readSessions() -> [ReproductionSession] {
        let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return children.compactMap { url in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")) else { return nil }
            return try? JSONDecoder().decode(ReproductionSession.self, from: data)
        }.sorted { $0.started > $1.started }
    }

    func export(_ id: String) async throws -> URL {
        // Drain capture requests first, then copies, then manifest updates, without blocking UI.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in io.async { c.resume() } }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in materials.async { c.resume() } }
        return try await withCheckedThrowingContinuation { continuation in
            io.async {
                let staging = FileManager.default.temporaryDirectory.appendingPathComponent("repro-\(UUID().uuidString)", isDirectory: true)
                do {
                    guard self.readSessions().contains(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                    // Only freeze small journal/manifest files under the journal queue. Material copies and ZIP compression run independently.
                    for file in try FileManager.default.contentsOfDirectory(at: self.directory(id), includingPropertiesForKeys: nil) where file.lastPathComponent != "materials" {
                        try FileManager.default.copyItem(at: file, to: staging.appendingPathComponent(file.lastPathComponent))
                    }
                    self.exporter.async {
                        do { continuation.resume(returning: try self.makeExport(id, staging: staging)) }
                        catch { continuation.resume(throwing: error) }
                    }
                } catch {
                    try? FileManager.default.removeItem(at: staging)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func makeExport(_ id: String, staging: URL) throws -> URL {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: staging) }
        var manifest = try JSONDecoder().decode(ReproductionSession.self, from: Data(contentsOf: staging.appendingPathComponent("manifest.json")))
        for index in manifest.materials.indices {
            guard let relative = manifest.materials[index].snapshot else { continue }
            let file = staging.appendingPathComponent(relative)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: directory(id).appendingPathComponent(relative), to: file)
            if (try? Self.hash(file)) != manifest.materials[index].sha256 {
                manifest.materials[index].status = "snapshot_checksum_failed"
            }
            // Original local sandbox paths are not useful on another installation.
        }
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        let events = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl" }
            .flatMap { url in
                try Data(contentsOf: url).split(separator: 0x0a).compactMap { try? JSONDecoder().decode(ReproductionEvent.self, from: Data($0)) }
            }.sorted { $0.sequence < $1.sequence }
        let incomplete = manifest.materials.filter { $0.status != "captured" }
        var text = "# RiffLoop 异常复现包\n\n会话：\(id)\n版本：\(manifest.environment["version"] ?? "unknown")\n"
        text += "\n素材检查：\(incomplete.isEmpty ? "已收集素材校验通过" : "不完整，见 manifest.json 的 materials.status")"
        text += "\n轮转丢弃事件：\(manifest.droppedEvents)；记录错误：\(manifest.recordingErrors)\n"
        text += "\n## 重放方法\n\n1. 使用 environment 中同版本的 App 和尽量相同的系统、屏幕及音频路由。\n2. 把 materials 中素材导入对应文件库，按 SHA256 核对，恢复首次动作的 state/profile 设置。\n3. 按下表顺序操作，elapsed 秒保留相对间隔；对照 result/event 确认结果。\n4. 在 incident 或有 begin 没有 result 的位置重点重复，系统报告按内部时间戳关联。\n\n这是可核对的人工重放步骤，不是自动执行脚本。系统调度、后台中断和线程竞争可能无法每次重现。音频硬件、未完成的操作、素材缺失、日志轮转或输入采样会降低复现完整度。\n\n## 操作与结果\n\n"
        for event in events {
            text += String(format: "[%06d +%.3fs] %@ %@\n", event.sequence, event.elapsed, event.kind, event.name)
            text += "参数：\(encoded(event.details))\n状态：\(encoded(event.state))\n\n"
        }
        try text.write(to: staging.appendingPathComponent("重放步骤.txt"), atomically: true, encoding: .utf8)
        let exports = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("异常复现包", isDirectory: true)
        try fm.createDirectory(at: exports, withIntermediateDirectories: true)
        let output = exports.appendingPathComponent("RiffLoop-\(id).zip")
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading, error: &coordinationError) { archive in
            do {
                if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
                try fm.copyItem(at: archive, to: output)
            } catch { copyError = error }
        }
        if let error = coordinationError { throw error }
        if let error = copyError { throw error }
        guard fm.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteUnknown) }
        return output
    }
}
