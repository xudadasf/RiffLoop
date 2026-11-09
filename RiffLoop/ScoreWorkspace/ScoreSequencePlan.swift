import Foundation

/// A task explicitly selects its materials; names are unique within the workspace.
struct ScoreSequenceMaterial: Codable, Hashable {
    let name: String
    let sourceDigest: String

    var isValid: Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") &&
            sourceDigest.count == 64 && sourceDigest.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

struct ScoreSequenceRegionReference: Codable, Hashable {
    let material: ScoreSequenceMaterial
    let pageIndex: Int
    let rotation: Int
    let regionID: UUID
}

struct ScoreSequenceEntry: Codable, Equatable {
    let number: Int
    let reference: ScoreSequenceRegionReference
    var isSelected: Bool
    var gapAfter: Int
}

struct ScoreRecognitionOrder: Equatable {
    let regions: [ScoreSequenceRegionReference]
    /// One gap between each pair; the final region never adds a trailing gap.
    let gaps: [Int]
}

enum ScoreSequenceError: Error, Equatable {
    case invalidPlan
    case invalidNumber
    case invalidGap
    case duplicateReference
    case noSelectedRegions
    case unreviewedMaterials([String])
    case unresolvedRegions([Int])
    case unregisteredRegions([ScoreSequenceRegionReference])
}

/// Number identifies a box, while array order identifies its writing position.
struct ScoreSequencePlan: Codable, Equatable {
    let version: Int
    let materials: [ScoreSequenceMaterial]
    private(set) var entries: [ScoreSequenceEntry]

    init(materials: [ScoreSequenceMaterial], regions: [ScoreSequenceRegionReference]) throws {
        self.version = 1
        self.materials = materials
        self.entries = regions.enumerated().map { index, reference in
            ScoreSequenceEntry(number: index + 1, reference: reference, isSelected: true, gapAfter: 1)
        }
        try validate()
    }

    var selectedEntries: [ScoreSequenceEntry] { entries.filter(\.isSelected) }

    func validate() throws {
        guard version == 1, !materials.isEmpty, materials.allSatisfy(\.isValid),
              Set(materials).count == materials.count,
              Set(materials.map(\.name)).count == materials.count,
              Set(entries.map(\.number)).count == entries.count,
              Set(entries.map(\.reference)).count == entries.count,
              entries.allSatisfy({ entry in
                  entry.number > 0 && (0...99).contains(entry.gapAfter) &&
                      entry.reference.pageIndex >= 0 && materials.contains(entry.reference.material)
              }) else { throw ScoreSequenceError.invalidPlan }
    }

    /// Entering an existing box number at a writing position swaps the two boxes.
    mutating func assign(number: Int, toPosition position: Int) throws {
        let slots = entries.indices.filter { entries[$0].isSelected }
        guard (0..<slots.count).contains(position),
              let other = slots.firstIndex(where: { entries[$0].number == number }) else {
            throw ScoreSequenceError.invalidNumber
        }
        entries.swapAt(slots[position], slots[other])
    }

    mutating func setSelected(_ selected: Bool, number: Int) throws {
        guard let index = entries.firstIndex(where: { $0.number == number }) else {
            throw ScoreSequenceError.invalidNumber
        }
        entries[index].isSelected = selected
    }

    mutating func setGapAfter(_ gap: Int, number: Int) throws {
        guard (0...99).contains(gap) else { throw ScoreSequenceError.invalidGap }
        guard let index = entries.firstIndex(where: { $0.number == number }) else {
            throw ScoreSequenceError.invalidNumber
        }
        entries[index].gapAfter = gap
    }

    /// Newly drawn regions append without changing existing box numbers or order.
    mutating func append(_ references: [ScoreSequenceRegionReference]) throws {
        guard references.allSatisfy({ $0.pageIndex >= 0 && materials.contains($0.material) }) else {
            throw ScoreSequenceError.invalidPlan
        }
        let existing = Set(entries.map(\.reference))
        guard Set(references).count == references.count,
              references.allSatisfy({ !existing.contains($0) }) else {
            throw ScoreSequenceError.duplicateReference
        }
        let maxNumber = entries.map(\.number).max() ?? 0
        guard references.count <= Int.max - maxNumber else { throw ScoreSequenceError.invalidPlan }
        entries.append(contentsOf: references.enumerated().map { index, reference in
            ScoreSequenceEntry(number: maxNumber + index + 1, reference: reference, isSelected: true, gapAfter: 1)
        })
    }

    /// The caller supplies an up-to-date snapshot of regions in the chosen files.
    /// Missing selected regions are reported rather than silently omitted.
    func recognitionOrder(available: Set<ScoreSequenceRegionReference>) throws -> ScoreRecognitionOrder {
        try validate()
        let selected = selectedEntries
        guard !selected.isEmpty else { throw ScoreSequenceError.noSelectedRegions }
        let unreviewed = materials.filter { material in
            !entries.contains { $0.reference.material == material }
        }.map(\.name)
        guard unreviewed.isEmpty else { throw ScoreSequenceError.unreviewedMaterials(unreviewed) }
        let missing = selected.filter { !available.contains($0.reference) }.map(\.number)
        guard missing.isEmpty else { throw ScoreSequenceError.unresolvedRegions(missing) }
        // A newly drawn box in a chosen material needs an explicit place (or
        // exclusion) in the plan; otherwise a later conversion would omit it.
        let registered = Set(entries.map(\.reference))
        let newRegions = available.filter {
            materials.contains($0.material) && !registered.contains($0)
        }.sorted {
            let left = materials.firstIndex(of: $0.material) ?? materials.count
            let right = materials.firstIndex(of: $1.material) ?? materials.count
            if left != right { return left < right }
            if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
            if $0.rotation != $1.rotation { return $0.rotation < $1.rotation }
            return $0.regionID.uuidString < $1.regionID.uuidString
        }
        guard newRegions.isEmpty else { throw ScoreSequenceError.unregisteredRegions(newRegions) }
        return ScoreRecognitionOrder(regions: selected.map(\.reference), gaps: selected.dropLast().map(\.gapAfter))
    }
}

/// Plans are separate from the source material and the practice library.
actor ScoreSequenceStore {
    private let fileURL: URL

    init(id: UUID, folder: URL? = nil) {
        fileURL = Self.planFolder(folder).appendingPathComponent(id.uuidString + ".json")
    }

    /// Ignore arbitrary files and links; a corrupt plan remains visible and load reports the error.
    static func listIDs(folder: URL? = nil) throws -> [UUID] {
        let root = planFolder(folder)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ).compactMap { url -> UUID? in
            let name = url.lastPathComponent
            guard name.hasSuffix(".json"),
                  let id = UUID(uuidString: String(name.dropLast(5))),
                  name == id.uuidString + ".json",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return id
        }.sorted { $0.uuidString < $1.uuidString }
    }

    private static func planFolder(_ folder: URL?) -> URL {
        folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScoreWorkspace/Plans", isDirectory: true)
    }

    func load() throws -> ScoreSequencePlan? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let plan: ScoreSequencePlan
        do {
            plan = try JSONDecoder().decode(ScoreSequencePlan.self, from: Data(contentsOf: fileURL))
        } catch {
            throw ScoreSequenceError.invalidPlan
        }
        try plan.validate()
        return plan
    }

    func save(_ plan: ScoreSequencePlan) throws {
        try plan.validate()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(plan).write(to: fileURL, options: [.atomic])
    }

    /// Delete this task only; materials and other tasks are not touched.
    func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ScoreSequenceError.invalidPlan
        }
        try FileManager.default.removeItem(at: fileURL)
    }
}
