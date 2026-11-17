import Foundation

// Compiled with the actual ReproductionStore on macOS; only the monotonic clock is simulated.
// No private device logs or scores are used in CI.
final class ProbeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 1_000.0
    func read() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ time: Double) { lock.lock(); value = time; lock.unlock() }
}

@main struct DiagnosticWriteBudgetProbe {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = ProbeClock()
        let store = ReproductionStore(root: root, uptimeClock: { clock.read() })
        store.start(environment: ["version": "synthetic-write-budget"])
        store.phase("active")
        var context = Dictionary(uniqueKeysWithValues: (0..<70).map { ("setting.\($0)", String(repeating: "v", count: 24)) })
        context["screen"] = "gp"
        context["gp.isPlaying"] = "true"
        store.update(context)
        let initial = await store.sessions()
        let id = initial[0].id
        let folder = root.appendingPathComponent(id)
        var seenSequences = Set<Int>()
        var bytesWritten = 0
        var manifestWrites = 0
        var previousManifest = Data()
        for tick in 1...360 {
            clock.set(1_000 + Double(tick) / 4)
            store.update(["gp.position": String(tick)])
            store.record("sample", "gp.state")
            store.record("event", "gp.bridge.reproductionAudio", ["time": String(tick)])
            if tick % 20 == 0 { store.record("action", "gp.seek", ["tick": String(tick)]) }
            _ = await store.sessions()
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                where file.lastPathComponent.hasPrefix("checkpoint") {
                for line in try Data(contentsOf: file).split(separator: 10) {
                    let json = try JSONSerialization.jsonObject(with: Data(line)) as! [String: Any]
                    let sequence = json["sequence"] as! Int
                    if seenSequences.insert(sequence).inserted { bytesWritten += line.count + 1 }
                }
            }
            let manifest = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
            if manifest != previousManifest { manifestWrites += 1; bytesWritten += manifest.count; previousManifest = manifest }
        }
        print("NORMAL_ACTIVITY seconds=90 bytesWritten=\(bytesWritten) manifestWrites=\(manifestWrites)")
        // About 800 synthetic events: full repeated 3 KB states used to exceed 2 MB.
        guard bytesWritten < 500_000, manifestWrites <= 10 else {
            fputs("FAIL: routine diagnostics exceed the write budget\n", stderr)
            exit(1)
        }
        store.record("incident", "synthetic_failure", ["trigger": "preserve-full-prelude"])
        store.phase("active")
        let sessions = await store.sessions()
        guard sessions[0].recordingErrors == 0, sessions[0].incidents == 1 else { exit(2) }
        let archived = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("events-") }
            .flatMap { try Data(contentsOf: $0).split(separator: 10).map { try JSONDecoder().decode(ReproductionEvent.self, from: Data($0)) } }
        guard let incident = archived.first(where: { $0.name == "synthetic_failure" }),
              incident.state["setting.69"] == context["setting.69"], incident.state["gp.position"] == "360",
              archived.contains(where: { $0.name == "gp.seek" && $0.details["tick"] == "360" }) else { exit(3) }
        print("PASS: bounded normal writes; incident keeps original state and exact actions")
    }
}
