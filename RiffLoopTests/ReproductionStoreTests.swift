import XCTest
@testable import RiffLoop

final class ReproductionStoreTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func events(_ root: URL, _ id: String) throws -> [ReproductionEvent] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(id), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .flatMap { ReproductionCheckpoint.decode(try Data(contentsOf: $0)).events }
            .sorted { $0.sequence < $1.sequence }
    }

    func testReplayKeepsOrderedParametersAndBeforeAfterStateAcrossRelaunch() async throws {
        let root = try root()
        let store = ReproductionStore(root: root)
        store.start(environment: ["version": "test"])
        store.phase("active")
        store.update(["file": "a.gp", "playing": "true"])
        store.record("action", "panel", ["target": "sound"])
        store.update(["panel": "sound"])
        store.record("incident", "load", ["file": "b.gp", "operationID": "load-2"])
        let sessions = await store.sessions()
        let id = try XCTUnwrap(sessions.first?.id)
        let journal = try events(root, id)
        XCTAssertEqual(journal.map(\.sequence), Array(1...journal.count))
        XCTAssertEqual(journal.suffix(2).first?.state["playing"], "true")
        XCTAssertEqual(journal.last?.state["panel"], "sound")
        XCTAssertEqual(journal.last?.details["operationID"], "load-2")
        XCTAssertEqual(journal.last?.details["file"], "b.gp")
        let next = ReproductionStore(root: root)
        next.start(environment: [:])
        let nextSessions = await next.sessions()
        let newID = try XCTUnwrap(nextSessions.first?.id)
        let unfinished = try XCTUnwrap(events(root, newID).first { $0.name == "previous_session_unfinished" })
        XCTAssertEqual(unfinished.details["previousSession"], id)
        XCTAssertTrue(unfinished.details["classification"]?.contains("not proof of crash") == true)
        XCTAssertEqual(try events(root, id).last?.details["file"], "b.gp")
    }

    func testBackgroundIsNotAStallAndForegroundStallReportsOnceThenRecovers() {
        var probe = ResponsivenessProbe()
        probe.setActive(false, now: 1)
        XCTAssertNil(probe.check(now: 100))
        probe.setActive(true, now: 100)
        XCTAssertNil(probe.check(now: 100.5))
        XCTAssertNotNil(probe.check(now: 101))
        XCTAssertNil(probe.check(now: 103))
        XCTAssertEqual(probe.beat(now: 104), 4)
        XCTAssertNil(probe.check(now: 104.1))
        probe.setActive(false, now: 105)
        probe.setActive(true, now: 500)
        XCTAssertNil(probe.check(now: 500.1))
    }

    func testExportPreservesActualLoadedBytesAndReportsMissingMaterial() async throws {
        let root = try root()
        let store = ReproductionStore(root: root, materialLimit: 8)
        store.start(environment: [:])
        let source = root.appendingPathComponent("score.gp")
        try Data("loaded".utf8).write(to: source)
        store.capture(source, role: "gp", loadedData: Data("loaded".utf8))
        let video = root.appendingPathComponent("video.mp4")
        try Data("oversized video".utf8).write(to: video)
        store.capture(video, role: "video") // over budget; must not claim reproducibility
        let list = await store.sessions()
        let id = try XCTUnwrap(list.first?.id)
        let export = try await store.export(id)
        addTeardownBlock { try? FileManager.default.removeItem(at: export) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.path))
        XCTAssertEqual(try Data(contentsOf: export).prefix(4), Data([0x50, 0x4b, 0x03, 0x04]))
        let refreshed = await store.sessions()
        let session = try XCTUnwrap(refreshed.first)
        let material = try XCTUnwrap(session.materials.first)
        XCTAssertEqual(material.status, "captured")
        let relative = try XCTUnwrap(material.snapshot)
        let captured = root.appendingPathComponent(id).appendingPathComponent(relative)
        XCTAssertEqual(try Data(contentsOf: captured), Data("loaded".utf8))
        XCTAssertEqual(material.sha256, try ReproductionStore.hash(captured))
        XCTAssertTrue(session.materials.last?.status.hasPrefix("omitted:") == true)
    }

    func testRotationCountsMissingStepsAndBoundsJournalFiles() async throws {
        let root = try root()
        let store = ReproductionStore(root: root, partLimit: 512)
        store.start(environment: [:])
        for number in 0..<50 { store.record(number == 49 ? "incident" : "action", "seek", ["tick": String(number)]) }
        let sessions = await store.sessions()
        let session = try XCTUnwrap(sessions.first)
        XCTAssertGreaterThan(session.droppedEvents, 0)
        let retained = try events(root, session.id)
        XCTAssertEqual(retained.last?.details["tick"], "49")
        XCTAssertEqual(session.lastSequence, session.droppedEvents + retained.count)
        let parts = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(session.id), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl" }
        XCTAssertLessThanOrEqual(parts.count, 4)
    }

    func testUnreadInputRemainsMissingAndIdenticalLoadedScoresShareBudget() async throws {
        let root = try root()
        let store = ReproductionStore(root: root, materialLimit: 6)
        store.start(environment: [:])
        let selected = root.appendingPathComponent("never-readable.gp")
        store.expectLoadedInput(selected, role: "gp")
        let score = root.appendingPathComponent("loaded.gp")
        try Data("loaded".utf8).write(to: score)
        for _ in 0..<3 {
            store.expectLoadedInput(score, role: "gp")
            store.capture(score, role: "gp", loadedData: Data("loaded".utf8))
        }
        let list = await store.sessions()
        let id = try XCTUnwrap(list.first?.id)
        let export = try await store.export(id)
        addTeardownBlock { try? FileManager.default.removeItem(at: export) }
        let updated = await store.sessions()
        let materials = try XCTUnwrap(updated.first?.materials)
        XCTAssertEqual(materials.count, 4)
        XCTAssertEqual(materials.first?.status, "waiting_for_loaded_bytes")
        XCTAssertTrue(materials.dropFirst().allSatisfy { $0.status == "captured" })
        XCTAssertEqual(Set(materials.dropFirst().compactMap(\.snapshot)).count, 1)
    }

    func testNormalActivityDoesNotCreateArchivedLogsOrMaterialCopies() async throws {
        let root = try root()
        let store = ReproductionStore(root: root)
        store.start(environment: [:])
        let source = root.appendingPathComponent("normal.gp")
        try Data("score".utf8).write(to: source)
        store.capture(source, role: "gp", loadedData: Data("score".utf8))
        for number in 0..<100 { store.record("action", "seek", ["tick": String(number)]) }
        store.record("lifecycle", "checkpoint")
        let list = await store.sessions()
        let session = try XCTUnwrap(list.first)
        XCTAssertEqual(session.incidents, 0)
        let directory = root.appendingPathComponent(session.id)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.contains { $0.lastPathComponent.hasPrefix("events-") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("materials").path))
        XCTAssertLessThanOrEqual(try Data(contentsOf: directory.appendingPathComponent("checkpoint.jsonl")).count, 512_000)
    }
    func testRedeliveredSystemReportDoesNotCreateFreshIncidentsOnNormalLaunch() async throws {
        let root = try root()
        let store = ReproductionStore(root: root)
        store.start(environment: [:])
        let report = Data("synthetic system report".utf8)
        store.saveSystemReport(report)
        store.saveSystemReport(report)
        store.phase("inactive")
        let first = await store.sessions()
        XCTAssertEqual(first.first?.incidents, 1)
        let next = ReproductionStore(root: root)
        next.start(environment: [:])
        next.saveSystemReport(report)
        let second = await next.sessions()
        XCTAssertEqual(second.first?.incidents, 0)
    }

    func testCheckpointAppendsEachStepOnceAndIncidentIndexSurvivesRotation() async throws {
        let root = try root()
        let store = ReproductionStore(root: root, partLimit: 512)
        store.start(environment: [:])
        for number in 0..<20 { store.record("lifecycle", "checkpoint", ["step": String(number)]) }
        let first = await store.sessions()
        let id = try XCTUnwrap(first.first?.id)
        let folder = root.appendingPathComponent(id)
        let checkpoint = try Data(contentsOf: folder.appendingPathComponent("checkpoint.jsonl"))
            .split(separator: 10).map { try JSONDecoder().decode(ReproductionEvent.self, from: Data($0)) }
        XCTAssertEqual(checkpoint.filter { $0.name == "checkpoint" }.count, 20)
        XCTAssertEqual(Set(checkpoint.map(\.sequence)).count, checkpoint.count)
        store.record("incident", "first_failure")
        for number in 0..<80 { store.record("incident", "repeated_failure", ["step": String(number)]) }
        _ = await store.sessions()
        let indexData = try Data(contentsOf: folder.appendingPathComponent("incident-index.json"))
        let index = try JSONDecoder().decode([ReproductionEvent].self, from: indexData)
        XCTAssertEqual(index.count, 64)
        XCTAssertEqual(index.last?.details["step"], "79")
        XCTAssertLessThanOrEqual(indexData.count, 128_000)
    }

    func testCompactCheckpointRecoversExactStateAcrossBlocksAndLegacyLines() throws {
        let first = ReproductionEvent(sequence: 1, date: Date(), elapsed: 0, kind: "action", name: "open",
            details: ["file": "synthetic.gp"], state: ["tempo": "100", "position": "1", "removed": "yes"])
        let second = ReproductionEvent(sequence: 2, date: first.date, elapsed: 1, kind: "sample", name: "position",
            details: [:], state: ["tempo": "100", "position": "2"])
        let third = ReproductionEvent(sequence: 3, date: first.date, elapsed: 2, kind: "action", name: "pause",
            details: [:], state: ["tempo": "80", "position": "2", "playing": "false"])
        var bytes = try JSONEncoder().encode(first); bytes.append(10) // pre-upgrade format
        bytes.append(try ReproductionCheckpoint.encode([second, third]))
        let decoded = ReproductionCheckpoint.decode(bytes)
        XCTAssertEqual(decoded.errors, 0)
        XCTAssertEqual(decoded.events.map(\.state), [first.state, second.state, third.state])
        XCTAssertEqual(decoded.events.map(\.sequence), [1, 2, 3])
    }

    func testDamagedCheckpointDoesNotInventStateAndNextAppendCanRecover() throws {
        let original = ReproductionEvent(sequence: 1, date: Date(), elapsed: 0, kind: "action", name: "open", details: [:], state: ["tempo": "100"])
        let next = ReproductionEvent(sequence: 2, date: original.date, elapsed: 1, kind: "action", name: "seek", details: ["tick": "4"], state: ["tempo": "100", "tick": "4"])
        let encoded = try ReproductionCheckpoint.encode([original, next])
        let lines = encoded.split(separator: 10)
        var damaged = Data("torn-line\n".utf8); damaged.append(contentsOf: lines[1]); damaged.append(10)
        damaged.append(try ReproductionCheckpoint.encode([next]))
        let recovered = ReproductionCheckpoint.decode(damaged)
        XCTAssertEqual(recovered.errors, 2)
        XCTAssertEqual(recovered.events.count, 1)
        XCTAssertEqual(recovered.events.first?.state, next.state)
        XCTAssertEqual(recovered.events.first?.details, next.details)
    }

    func testRelaunchExpandsDeltaCheckpointIntoFullReplayState() async throws {
        let root = try root()
        let store = ReproductionStore(root: root)
        store.start(environment: [:]); store.phase("active")
        store.update(["tempo": "100", "file": "synthetic.gp"])
        store.record("action", "play")
        store.update(["tempo": "80", "position": "123"])
        store.record("action", "seek", ["tick": "123"])
        store.phase("active") // immediate flush despite normal batching
        let before = await store.sessions()
        let id = try XCTUnwrap(before.first?.id)
        let next = ReproductionStore(root: root); next.start(environment: [:])
        _ = await next.sessions()
        let data = try Data(contentsOf: root.appendingPathComponent(id).appendingPathComponent("events-recovered.jsonl"))
        let recovered = try data.split(separator: 10).map { try JSONDecoder().decode(ReproductionEvent.self, from: Data($0)) }
        let seek = try XCTUnwrap(recovered.first { $0.name == "seek" })
        XCTAssertEqual(seek.state, ["tempo": "80", "file": "synthetic.gp", "position": "123"])
        XCTAssertEqual(seek.details["tick"], "123")
    }

}
