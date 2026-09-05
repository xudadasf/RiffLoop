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
    private var buffer: [(event: ReproductionEvent, bytes: Int)] = []
    private var bufferBytes = 0
    private var lastCheckpoint = 0.0
    private var recordingUntil = 0.0
    private var incidentMaterialNames = Set<String>()
    private var lastArchivedSequence = 0
    private var part = 0
    private var partBytes = 0
    private let partLimit: Int
    private let materialLimit: Int64
    private var reservedBytes: Int64 = 0
    private var captures: [String: String] = [:]
    private var loadedSnapshots: [String: (relative: String, bytes: Int64)] = [:] // material queue only

    init(root: URL? = nil, partLimit: Int = 500_000, materialLimit: Int64 = 128_000_000) {
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
                if let previous, previous.phase == "active" || previous.phase == "starting" {
                    let checkpoint = self.directory(previous.id).appendingPathComponent("checkpoint.jsonl")
                    if let data = try? Data(contentsOf: checkpoint), !data.isEmpty {
                        try data.write(to: self.directory(previous.id).appendingPathComponent("events-recovered.jsonl"), options: .atomic)
                    }
                    var recovered = previous
                    recovered.incidents += 1
                    recovered.phase = "unfinished_unknown"
                    try JSONEncoder().encode(recovered).write(to: self.directory(previous.id).appendingPathComponent("manifest.json"), options: .atomic)
                }
                // Completed normal sessions contain only a tiny rolling checkpoint and need no history.
                for old in self.readSessions() where old.incidents == 0 {
                    try? FileManager.default.removeItem(at: self.directory(old.id))
                }
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

    /// Register a selected GP before synchronous file reading, so a read that hangs or fails
    /// leaves an explicit missing prerequisite, even if no bytes reach the player.
    func expectLoadedInput(_ url: URL, role: String) {
        io.async {
            guard self.session != nil else { return }
            var material = ReproductionMaterial(id: UUID().uuidString, name: url.lastPathComponent, role: role, originalPath: url.path)
            material.status = "waiting_for_loaded_bytes"
            self.session?.materials.append(material)
            self.writeEvent("material", "material.expected", ["materialID": material.id, "role": role, "file": material.name])
        }
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
            let expected = loadedData == nil ? nil : self.session?.materials.last(where: {
                $0.role == role && $0.name == url.lastPathComponent && $0.status == "waiting_for_loaded_bytes"
            })
            let id = expected?.id ?? UUID().uuidString
            self.captures[key] = id
            if expected == nil { self.session?.materials.append(ReproductionMaterial(id: id, name: url.lastPathComponent, role: role, originalPath: url.path)) }
            if let index = self.session?.materials.firstIndex(where: { $0.id == id }) { self.session?.materials[index].status = "pending" }
            self.writeEvent("material", "material.requested", ["materialID": id, "role": role, "file": url.lastPathComponent])
            self.materials.async {
                var material = ReproductionMaterial(id: id, name: url.lastPathComponent, role: role, originalPath: url.path)
                do {
                    material.bytes = Int64(loadedData?.count ?? attributes?.fileSize ?? 0)
                    material.sha256 = try loadedData.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? Self.hash(url)
                    material.status = "referenced: snapshot only on anomaly"
                } catch { material.status = "reference_failed: \(error.localizedDescription)" }
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
            if material.snapshot == nil && material.status.hasPrefix("referenced:") && self.incidentMaterialNames.contains(material.name) {
                self.snapshotMaterial(material, sessionID: sessionID)
            }
        }
    }

    private func snapshotMaterial(_ reference: ReproductionMaterial, sessionID: String) {
        guard let index = session?.materials.firstIndex(where: { $0.id == reference.id }),
              session?.materials[index].status.hasPrefix("referenced:") == true else { return }
        session?.materials[index].status = "snapshot_pending"
        materials.async {
            var material = reference
            do {
                if let hash = reference.sha256, let existing = self.loadedSnapshots[hash] {
                    material.snapshot = existing.relative; material.status = "captured"
                } else if material.bytes > self.materialLimit - self.reservedBytes {
                    material.status = "omitted: anomaly material budget exceeded; original file required"
                } else {
                    let relative = "materials/\(material.id)/\(material.name)"
                    let target = self.directory(sessionID).appendingPathComponent(relative)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: material.originalPath), to: target)
                    let copiedHash = try Self.hash(target)
                    self.reservedBytes += material.bytes
                    material.snapshot = relative
                    material.status = copiedHash == reference.sha256 ? "captured" : "source_changed: loaded hash differs from snapshot"
                    if material.status == "captured" { self.loadedSnapshots[copiedHash] = (relative, material.bytes) }
                }
            } catch { material.status = "snapshot_failed: \(error.localizedDescription)" }
            self.finishCapture(material, sessionID: sessionID)
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
        guard var current = session else { return }
        current.lastSequence += 1
        current.lastState = context
        if kind == "incident" { current.incidents += 1 }
        var event = ReproductionEvent(sequence: current.lastSequence, date: date, elapsed: max(0, uptime - origin),
            kind: kind, name: name, details: details, state: context)
        var bytes = (try? JSONEncoder().encode(event).count) ?? 0
        if bytes > 256_000 {
            current.recordingErrors += 1
            event = ReproductionEvent(sequence: event.sequence, date: event.date, elapsed: event.elapsed,
                kind: event.kind, name: "recording.oversized_event", details: ["originalName": name, "bytes": String(bytes)], state: [:])
            bytes = (try? JSONEncoder().encode(event).count) ?? 0
        }
        buffer.append((event, bytes)); bufferBytes += bytes
        while buffer.count > 1 && (bufferBytes > 512_000 || event.elapsed - buffer[0].event.elapsed > 60) {
            bufferBytes -= buffer.removeFirst().bytes
        }
        session = current
        if kind == "incident" {
            recordingUntil = uptime + 15
            // Flush the prelude once, then append only the 15-second aftermath.
            for item in buffer where item.event.sequence > lastArchivedSequence { persistEvent(item.event) }
            let relevantNames = Set(buffer.flatMap { item in
                Array(item.event.details.filter { $0.key == "file" || $0.key == "fileName" }.values)
                + item.event.state.filter { $0.key.hasSuffix("FileName") }.values.map {
                    (try? JSONDecoder().decode(String.self, from: Data($0.utf8))) ?? $0
                }
            })
            incidentMaterialNames.formUnion(relevantNames)
            for material in session?.materials ?? [] where relevantNames.contains(material.name) {
                snapshotMaterial(material, sessionID: current.id)
            }
        } else if uptime < recordingUntil {
            persistEvent(event)
        }
        // Tiny crash-recovery checkpoint, overwritten every three seconds; normal history is not accumulated.
        if kind == "incident" || kind == "lifecycle" || uptime - lastCheckpoint >= 3 {
            do {
                var data = Data()
                for item in buffer where item.event.sequence > lastArchivedSequence {
                    data.append(try JSONEncoder().encode(item.event)); data.append(10)
                }
                try data.write(to: directory(current.id).appendingPathComponent("checkpoint.jsonl"), options: .atomic)
                try JSONEncoder().encode(session).write(to: directory(current.id).appendingPathComponent("manifest.json"), options: .atomic)
                lastCheckpoint = uptime
            } catch { session?.recordingErrors += 1 }
        }
    }

    private func persistEvent(_ event: ReproductionEvent) {
        guard var current = session else { return }
        do {
            var data = try JSONEncoder().encode(event)
            if data.count > partLimit {
                current.droppedEvents += 1
                data = try JSONEncoder().encode(ReproductionEvent(sequence: event.sequence, date: event.date, elapsed: event.elapsed,
                    kind: "incident", name: "recording.oversized_event", details: ["originalName": event.name, "bytes": String(data.count)], state: [:]))
            }
            data.append(10)
            if partBytes + data.count > partLimit {
                part += 1; partBytes = 0
                if part >= 4 {
                    let old = directory(current.id).appendingPathComponent("events-\(part - 4).jsonl")
                    if let bytes = try? Data(contentsOf: old) { current.droppedEvents += bytes.filter { $0 == 10 }.count }
                    try? FileManager.default.removeItem(at: old)
                }
            }
            let file = directory(current.id).appendingPathComponent("events-\(part).jsonl")
            if !FileManager.default.fileExists(atPath: file.path) { try Data().write(to: file) }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
            if event.kind != "sample" { try handle.synchronize() }
            partBytes += data.count
            lastArchivedSequence = event.sequence
            try JSONEncoder().encode(current).write(to: directory(current.id).appendingPathComponent("manifest.json"), options: .atomic)
        } catch { current.recordingErrors += 1 }
        session = current
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
            io.async {
                var list = self.readSessions().filter { $0.id != self.session?.id }
                if let current = self.session { list.insert(current, at: 0) }
                continuation.resume(returning: list)
            }
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
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            io.async {
                if self.session?.id == id { self.writeEvent("incident", "user.export_requested", [:]) }
                c.resume()
            }
        }
        // Drain capture requests first, then copies, then manifest updates, without blocking UI.
        for _ in 0..<2 {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in io.async { c.resume() } }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in materials.async { c.resume() } }
        }
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
        var events: [ReproductionEvent] = []
        for file in try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix("events-") && file.pathExtension == "jsonl" {
            for line in try Data(contentsOf: file).split(separator: 0x0a) {
                do { events.append(try JSONDecoder().decode(ReproductionEvent.self, from: Data(line))) }
                catch { manifest.recordingErrors += 1 }
            }
        }
        events.sort { $0.sequence < $1.sequence }
        // A killed process may leave a partial line or a journal/manifest mismatch.
        // Preserve the original files, but never silently label this export complete.
        if events.isEmpty {
            manifest.recordingErrors += 1
        }
        let relevantNames = Set(events.flatMap { event in
            Array(event.details.filter { $0.key == "file" || $0.key == "fileName" }.values)
            + event.state.filter { $0.key.hasSuffix("FileName") }.values.map {
                (try? JSONDecoder().decode(String.self, from: Data($0.utf8))) ?? $0
            }
        })
        manifest.materials = manifest.materials.filter { relevantNames.contains($0.name) || $0.snapshot != nil }
        var exportBytes: Int64 = 0
        var exportedHashes: [String: String] = [:]
        for index in manifest.materials.indices {
            var material = manifest.materials[index]
            if let hash = material.sha256, let shared = exportedHashes[hash] {
                material.snapshot = shared; material.status = "captured"
            } else if material.bytes > materialLimit - exportBytes {
                material.snapshot = nil; material.status = "omitted: anomaly material budget exceeded"
            } else if let hash = material.sha256 {
                let relative = material.snapshot ?? "materials/\(material.id)/\(material.name)"
                let target = staging.appendingPathComponent(relative)
                let source = material.snapshot.map { directory(id).appendingPathComponent($0) } ?? URL(fileURLWithPath: material.originalPath)
                do {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: source, to: target) }
                    material.snapshot = relative
                    exportBytes += material.bytes
                    material.status = try Self.hash(target) == hash ? "captured" : "source_changed: loaded hash differs from snapshot"
                    if material.status == "captured" { exportedHashes[hash] = relative }
                } catch { material.status = "snapshot_failed: \(error.localizedDescription)" }
            }
            manifest.materials[index] = material
        }
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        let incomplete = manifest.materials.filter { $0.status != "captured" }
        var text = "# RiffLoop 异常复现包\n\n会话：\(id)\n版本：\(manifest.environment["version"] ?? "unknown")\n"
        text += "\n素材检查：\(incomplete.isEmpty ? "已收集素材校验通过" : "不完整，见 manifest.json 的 materials.status")"
        text += "\n轮转丢弃事件：\(manifest.droppedEvents)；记录错误：\(manifest.recordingErrors)\n"
        text += "\n## 重放方法\n\n只保留异常前最多 60 秒（最多 512 KB）及异常后 15 秒；sequence 的间隔可能是正常片段被省略。\n\n1. 使用 environment 中同版本的 App 和尽量相同的系统、屏幕及音频路由。\n2. 把 materials 中素材导入对应文件库，按 SHA256 核对，恢复首次动作的 state/profile 设置。\n3. 按下表顺序操作，elapsed 秒保留相对间隔；对照 result/event 确认结果。\n4. 在 incident 或有 begin 没有 result 的位置重点重复，系统报告按内部时间戳关联。\n\n这是可核对的人工重放步骤，不是自动执行脚本。系统调度、后台中断和线程竞争可能无法每次重现。音频硬件、未完成的操作、素材缺失、日志轮转或输入采样会降低复现完整度。\n\n## 操作与结果\n\n"
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
