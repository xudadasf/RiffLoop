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
            .flatMap { try Data(contentsOf: $0).split(separator: 10).map { try JSONDecoder().decode(ReproductionEvent.self, from: Data($0)) } }
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
        store.record("begin", "load", ["file": "b.gp", "operationID": "load-2"])
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
        try Data("new disk version".utf8).write(to: source)
        store.capture(source, role: "gp", loadedData: Data("loaded".utf8))
        store.capture(source, role: "video") // over budget; must not claim reproducibility
        let list = await store.sessions()
        let id = try XCTUnwrap(list.first?.id)
        let export = try await store.export(id)
        addTeardownBlock { try? FileManager.default.removeItem(at: export) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.path))
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
        for number in 0..<50 { store.record("action", "seek", ["tick": String(number)]) }
        let sessions = await store.sessions()
        let session = try XCTUnwrap(sessions.first)
        XCTAssertGreaterThan(session.droppedEvents, 0)
        let retained = try events(root, session.id)
        XCTAssertEqual(retained.last?.details["tick"], "49")
        XCTAssertEqual(session.lastSequence, session.droppedEvents + retained.count)
        let parts = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(session.id), includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
        XCTAssertLessThanOrEqual(parts.count, 4)
    }
}
