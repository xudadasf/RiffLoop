import XCTest
@testable import RiffLoop

final class ScoreSequenceFactoryTests: XCTestCase {
    func testSelectedFilesAndTheirRegionsBecomeAPlanInOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a.pdf")
        let second = root.appendingPathComponent("b.png")
        let folder = root.appendingPathComponent("regions")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let region1 = ScoreRegion(x: 0, y: 0, width: 0.5, height: 0.5)
        let region2 = ScoreRegion(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        try await ScoreRegionsStore(source: first, folder: folder).savePage(index: 1, rotation: 0, regions: [region2])
        try await ScoreRegionsStore(source: first, folder: folder).savePage(index: 0, rotation: 0, regions: [region1])
        let region3 = ScoreRegion(x: 0, y: 0, width: 1, height: 1)
        try await ScoreRegionsStore(source: second, folder: folder).savePage(index: 0, rotation: 0, regions: [region3])

        let plan = try await ScoreSequenceFactory.makePlan(from: [first, second], regionsFolder: folder)
        XCTAssertEqual(plan.materials.map(\.name), ["a.pdf", "b.png"])
        XCTAssertEqual(plan.entries.map(\.reference.regionID), [region1.id, region2.id, region3.id])
        XCTAssertEqual(plan.entries.map(\.number), [1, 2, 3])
        XCTAssertEqual(plan.entries.map(\.gapAfter), [1, 1, 1])

        let newFirst = ScoreRegion(x: 0, y: 0, width: 0.25, height: 0.25)
        let newSecond = ScoreRegion(x: 0.25, y: 0.25, width: 0.25, height: 0.25)
        try await ScoreRegionsStore(source: first, folder: folder)
            .savePage(index: 1, rotation: 0, regions: [region2, newFirst])
        try await ScoreRegionsStore(source: second, folder: folder)
            .savePage(index: 0, rotation: 0, regions: [region3, newSecond])
        var available: [ScoreSequenceRegionReference] = []
        for (material, source) in zip(plan.materials, [first, second]) {
            let snapshot = try await ScoreRegionsStore(source: source, folder: folder).snapshot()
            for page in snapshot.pages {
                for region in page.regions {
                    available.append(ScoreSequenceRegionReference(material: material, pageIndex: page.index,
                                                                  rotation: page.rotation, regionID: region.id))
                }
            }
        }
        let additions = ScoreSequenceFactory.newRegions(in: available, plan: plan)
        XCTAssertEqual(additions.map(\.regionID), [newFirst.id, newSecond.id])
        XCTAssertEqual(plan.entries.map(\.reference.regionID), [region1.id, region2.id, region3.id])
    }

    func testFileWithoutRegionsRejectsEntirePlan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("marked.png")
        let second = root.appendingPathComponent("empty.png")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let region = ScoreRegion(x: 0, y: 0, width: 1, height: 1)
        let folder = root.appendingPathComponent("regions")
        let store = ScoreRegionsStore(source: first, folder: folder)
        try await store.savePage(index: 0, rotation: 0, regions: [region])
        do {
            _ = try await ScoreSequenceFactory.makePlan(from: [first, second], regionsFolder: folder)
            XCTFail("An unmarked selected file must not be skipped")
        } catch ScoreSequenceCreationError.withoutRegions(let names) {
            XCTAssertEqual(names, ["empty.png"])
        }
    }

    func testMissingSelectedFileDoesNotProduceAPartialPlan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = root.appendingPathComponent("marked.png")
        let absent = root.appendingPathComponent("missing.pdf")
        let folder = root.appendingPathComponent("regions")
        try Data("present".utf8).write(to: valid)
        let region = ScoreRegion(x: 0, y: 0, width: 1, height: 1)
        try await ScoreRegionsStore(source: valid, folder: folder)
            .savePage(index: 0, rotation: 0, regions: [region])
        do {
            _ = try await ScoreSequenceFactory.makePlan(from: [valid, absent], regionsFolder: folder)
            XCTFail("A missing selected file must not be skipped")
        } catch ScoreSequenceCreationError.unreadableMaterial(let name, _) {
            XCTAssertEqual(name, "missing.pdf")
        }
    }
}
