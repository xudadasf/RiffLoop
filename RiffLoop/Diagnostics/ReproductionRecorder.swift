import AVFoundation
import MetricKit
import UIKit
import Darwin

/// Pure state machine so background suspension and stall deduplication can be tested.
struct ResponsivenessProbe {
    var active = false
    var lastBeat = 0.0
    var reported = false
    mutating func setActive(_ value: Bool, now: Double) {
        active = value; lastBeat = now; reported = false
    }
    mutating func beat(now: Double) -> Double? {
        let duration = reported ? now - lastBeat : nil
        lastBeat = now; reported = false
        return duration
    }
    mutating func check(now: Double) -> Double? {
        guard active, !reported, now - lastBeat >= 0.75 else { return nil }
        reported = true
        return now - lastBeat
    }
}

final class ReproductionRecorder: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = ReproductionRecorder()
    private let queue = DispatchQueue(label: "riffloop.reproduction.watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var probe = ResponsivenessProbe()
    private var heartbeatPending = false
    private var operations: [String: (name: String, started: Double, reported: Bool)] = [:]
    private var observers: [NSObjectProtocol] = []
    private var started = false

    @MainActor func start() {
        guard !started else { return }
        started = true
        let info = Bundle.main.infoDictionary ?? [:]
        var hardware = utsname()
        uname(&hardware)
        let model = withUnsafeBytes(of: &hardware.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        ReproductionStore.shared.start(environment: [
            "version": "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))",
            "system": UIDevice.current.systemVersion,
            "device": model,
            "systemBuild": ProcessInfo.processInfo.operatingSystemVersionString,
            "memoryBytes": String(ProcessInfo.processInfo.physicalMemory),
            "screen": "\(UIScreen.main.bounds.width)x\(UIScreen.main.bounds.height)@\(UIScreen.main.scale)",
            "locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier,
            "recordingSchema": "1",
            "limitations": "semantic operations and sampled state; no guaranteed deterministic OS scheduling; 4 journal parts, 256 MB materials, last 3 sessions"
        ])
        MXMetricManager.shared.add(self)
        for payload in MXMetricManager.shared.pastDiagnosticPayloads { didReceive([payload]) }
        let center = NotificationCenter.default
        for (notification, name) in [
            (UIApplication.didReceiveMemoryWarningNotification, "memory.warning"),
            (AVAudioSession.interruptionNotification, "audio.interruption"),
            (AVAudioSession.routeChangeNotification, "audio.route_changed"),
            (AVAudioSession.mediaServicesWereResetNotification, "audio.services_reset"),
            (ProcessInfo.thermalStateDidChangeNotification, "thermal.changed"),
            (UIDevice.orientationDidChangeNotification, "orientation.changed")
        ] {
            observers.append(center.addObserver(forName: notification, object: nil, queue: .main) { note in
                let details = (note.userInfo ?? [:]).reduce(into: [String: String]()) { $0[String(describing: $1.key)] = String(describing: $1.value) }
                ReproductionStore.shared.record(name == "memory.warning" ? "incident" : "environment", name, details)
                Task { @MainActor in Self.environmentSnapshot() }
            })
        }
        observers.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            ReproductionStore.shared.phase("termination_notified")
        })
        Self.environmentSnapshot()
        queue.async {
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
        setActive(UIApplication.shared.applicationState == .active)
    }

    @MainActor private static func environmentSnapshot() {
        let session = AVAudioSession.sharedInstance()
        ReproductionStore.shared.update([
            "audioRoute": session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ","),
            "audioSampleRate": String(session.sampleRate),
            "audioIOBuffer": String(session.ioBufferDuration),
            "audioCategory": session.category.rawValue,
            "thermal": String(ProcessInfo.processInfo.thermalState.rawValue),
            "orientation": String(UIDevice.current.orientation.rawValue)
        ])
    }

    func setActive(_ active: Bool) {
        ReproductionStore.shared.phase(active ? "active" : "inactive")
        queue.async {
            self.probe.setActive(active, now: ProcessInfo.processInfo.systemUptime)
            // Requests suspended by the system must not be classified as UI hangs.
            for (id, operation) in self.operations {
                if !active {
                    ReproductionStore.shared.record("event", "operation.suspended", ["operationID": id, "operation": operation.name])
                }
                self.operations[id]?.started = ProcessInfo.processInfo.systemUptime
            }
        }
    }

    @discardableResult func begin(_ name: String, details: [String: String] = [:]) -> String {
        let id = UUID().uuidString
        var details = details
        details["operationID"] = id
        ReproductionStore.shared.record("begin", name, details)
        let now = ProcessInfo.processInfo.systemUptime
        queue.async {
            if self.operations.count >= 512, let oldest = self.operations.min(by: { $0.value.started < $1.value.started }) {
                self.operations.removeValue(forKey: oldest.key)
                ReproductionStore.shared.record("incident", "operation.tracking_limit", ["operationID": oldest.key, "operation": oldest.value.name])
            }
            self.operations[id] = (name, now, false)
        }
        return id
    }

    func end(_ id: String, result: String) {
        // Enqueue the result at the call site, beside its state snapshot. Routing it through
        // the watchdog first could incorrectly attach a later action's state and timestamp.
        ReproductionStore.shared.record("result", "operation.completed", ["operationID": id, "result": result])
        queue.async { self.operations.removeValue(forKey: id) }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        guard probe.active else { return }
        if let delay = probe.check(now: now) {
            ReproductionStore.shared.record("incident", "main_thread.stall", ["seconds": String(delay),
                "pendingOperations": operations.values.map(\.name).joined(separator: ",")])
        }
        for (id, operation) in operations where !operation.reported && now - operation.started >= 10 {
            operations[id]?.reported = true
            ReproductionStore.shared.record("incident", "operation.timeout", ["operationID": id,
                "operation": operation.name, "seconds": String(now - operation.started)])
        }
        guard !heartbeatPending else { return }
        heartbeatPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.queue.async {
                if let delay = self.probe.beat(now: now) {
                    ReproductionStore.shared.record("result", "main_thread.recovered", ["seconds": String(delay)])
                }
                self.heartbeatPending = false
            }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { ReproductionStore.shared.saveSystemReport(payload.jsonRepresentation()) }
    }
}
