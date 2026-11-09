import SwiftUI

enum ScoreSequenceCreationError: LocalizedError {
    case noMaterials
    case unreadableMaterial(String, String)
    case withoutRegions([String])

    var errorDescription: String? {
        switch self {
        case .noMaterials:
            "请选择需要拼接的素材。"
        case let .unreadableMaterial(name, reason):
            "无法读取素材“\(name)”的区域：\(reason)"
        case let .withoutRegions(names):
            "以下素材还没有区域，请先打开素材画框：\n" + names.joined(separator: "\n")
        }
    }
}

/// A plan is built only from the selected copies and their saved regions.
enum ScoreSequenceFactory {
    static func makePlan(from sources: [URL], regionsFolder: URL? = nil) async throws -> ScoreSequencePlan {
        guard !sources.isEmpty else { throw ScoreSequenceCreationError.noMaterials }
        var materials: [ScoreSequenceMaterial] = []
        var references: [ScoreSequenceRegionReference] = []
        var missing: [String] = []
        for source in sources {
            let snapshot: ScoreRegionsSnapshot
            do {
                snapshot = try await ScoreRegionsStore(source: source, folder: regionsFolder).snapshot()
            } catch {
                throw ScoreSequenceCreationError.unreadableMaterial(source.lastPathComponent, error.localizedDescription)
            }
            let material = ScoreSequenceMaterial(name: source.lastPathComponent, sourceDigest: snapshot.sourceDigest)
            materials.append(material)
            let boxes = snapshot.pages.flatMap { page in
                page.regions.map { region in
                    ScoreSequenceRegionReference(material: material, pageIndex: page.index,
                                                 rotation: page.rotation, regionID: region.id)
                }
            }
            if boxes.isEmpty { missing.append(material.name) }
            references.append(contentsOf: boxes)
        }
        guard missing.isEmpty else { throw ScoreSequenceCreationError.withoutRegions(missing) }
        return try ScoreSequencePlan(materials: materials, regions: references)
    }

    /// Keep the caller's material, page and within-page order; dictionary order is not stable.
    static func newRegions(in available: [ScoreSequenceRegionReference], plan: ScoreSequencePlan) -> [ScoreSequenceRegionReference] {
        let known = Set(plan.entries.map(\.reference))
        return available.filter { !known.contains($0) }
    }
}

private struct ScoreSequenceListItem: Identifiable {
    let id: UUID
    let plan: ScoreSequencePlan?
}

private struct ScoreSequenceOpenContext {
    let id: UUID
    let plan: ScoreSequencePlan
    let pageNumbers: [ScoreSequenceRegionReference: Int]
    let materialURLs: [String: URL]
    let newRegions: [ScoreSequenceRegionReference]
    let issues: [String]
}

@MainActor
private final class ScoreSequenceLibraryModel: ObservableObject {
    @Published private(set) var files: [URL] = []
    @Published private(set) var plans: [ScoreSequenceListItem] = []
    @Published private(set) var busy = false
    @Published var message: String?
    @Published var openedPlan: ScoreSequenceOpenContext?
    private let workspace = ScoreWorkspaceStore()

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            files = try await workspace.files()
            var result: [ScoreSequenceListItem] = []
            for id in try ScoreSequenceStore.listIDs() {
                // A damaged plan remains visible; it must never silently disappear.
                let plan = try? await ScoreSequenceStore(id: id).load()
                result.append(ScoreSequenceListItem(id: id, plan: plan))
            }
            plans = result
        } catch {
            message = "读取素材或计划失败：\(error.localizedDescription)"
        }
    }

    func create(selected: Set<URL>) async {
        guard !busy else { return }
        guard !selected.isEmpty else { message = ScoreSequenceCreationError.noMaterials.localizedDescription; return }
        busy = true
        defer { busy = false }
        do {
            // Re-read the workspace so an externally removed file is not skipped.
            let current = try await workspace.files()
            let sources = current.filter { selected.contains($0) }
            guard sources.count == selected.count else {
                message = "部分已选素材不存在，请刷新后重新选择。"
                return
            }
            let plan = try await ScoreSequenceFactory.makePlan(from: sources)
            let id = UUID()
            try await ScoreSequenceStore(id: id).save(plan)
            files = current
            plans.append(ScoreSequenceListItem(id: id, plan: plan))
            openedPlan = await makeOpenContext(id: id, plan: plan, availableFiles: current)
        } catch {
            message = "无法创建计划：\(error.localizedDescription)"
        }
    }

    func open(id: UUID) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            guard let plan = try await ScoreSequenceStore(id: id).load() else {
                message = "计划文件已不存在，请刷新列表。"
                return
            }
            let current = try await workspace.files()
            files = current
            openedPlan = await makeOpenContext(id: id, plan: plan, availableFiles: current)
        } catch {
            message = "无法打开计划：\(error.localizedDescription)"
        }
    }

    func delete(id: UUID) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await ScoreSequenceStore(id: id).delete()
            plans.removeAll { $0.id == id }
        } catch {
            message = "删除计划失败：\(error.localizedDescription)"
        }
    }

    private func makeOpenContext(id: UUID, plan: ScoreSequencePlan, availableFiles: [URL]) async -> ScoreSequenceOpenContext {
        var numbers: [ScoreSequenceRegionReference: Int] = [:]
        var materialURLs: [String: URL] = [:]
        var available: [ScoreSequenceRegionReference] = []
        var issues: [String] = []
        for material in plan.materials {
            guard let source = availableFiles.first(where: { $0.lastPathComponent == material.name }) else {
                issues.append("素材“\(material.name)”已缺失。")
                continue
            }
            do {
                let snapshot = try await ScoreRegionsStore(source: source).snapshot()
                guard snapshot.sourceDigest == material.sourceDigest else {
                    issues.append("素材“\(material.name)”的内容已更改。")
                    continue
                }
                materialURLs[material.name] = source
                for page in snapshot.pages {
                    for (index, region) in page.regions.enumerated() {
                        let ref = ScoreSequenceRegionReference(material: material, pageIndex: page.index,
                                                               rotation: page.rotation, regionID: region.id)
                        numbers[ref] = index + 1
                        available.append(ref)
                    }
                }
            } catch {
                issues.append("无法读取素材“\(material.name)”的区域：\(error.localizedDescription)")
            }
        }
        let missing = plan.selectedEntries.filter { numbers[$0.reference] == nil }.map(\.number)
        if !missing.isEmpty {
            issues.append("以下已采用的顺序表框未找到对应区域：" + missing.map(String.init).joined(separator: "、"))
            issues.append("可取消采用后保存并重新打开以刷新提示；同一素材中新画的区域可在此页追加，素材内容已变时需要新建计划。")
        }
        let newRegions = ScoreSequenceFactory.newRegions(in: available, plan: plan)
        return ScoreSequenceOpenContext(id: id, plan: plan, pageNumbers: numbers,
                                        materialURLs: materialURLs, newRegions: newRegions, issues: issues)
    }
}

/// Explicit selection is separate from the region editor and practice player.
struct ScoreSequenceLibraryView: View {
    @StateObject private var model = ScoreSequenceLibraryModel()
    @State private var selected: Set<URL> = []
    @State private var planPendingDeletion: UUID?

    var body: some View {
        List {
            Section {
                Text("选择要拼接的素材。每个素材需要先画好区域，计划会使用这些已保存的框。")
                    .foregroundStyle(.secondary)
                Text("初始顺序按素材名称排列，可在下一步调整；不按勾选先后排序。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("选择素材") {
                if model.files.isEmpty {
                    Text("暂无素材，请先导入并框选谱面。")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.files, id: \.self) { url in
                    Toggle(isOn: Binding(
                        get: { selected.contains(url) },
                        set: { enabled in
                            if enabled { selected.insert(url) } else { selected.remove(url) }
                        }
                    )) {
                        HStack(spacing: 10) {
                            ScoreMaterialThumbnailView(url: url)
                            Text(url.lastPathComponent)
                        }
                    }
                    .disabled(model.busy)
                }
                Button("为所选素材创建计划") {
                    Task { await model.create(selected: selected) }
                }
                .disabled(model.busy || selected.isEmpty)
            }
            Section("已保存的计划") {
                if model.plans.isEmpty {
                    Text("还没有计划。")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.plans) { item in
                    HStack {
                        if let plan = item.plan {
                            Button {
                                Task { await model.open(id: item.id) }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(plan.materials.map(\.name).joined(separator: "、"))
                                        .lineLimit(2)
                                    Text("计划 \(item.id.uuidString.prefix(8)) · \(plan.materials.count) 份素材 · \(plan.entries.count) 个区域")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.busy)
                        } else {
                            Text("计划 \(item.id.uuidString.prefix(8)) 无法读取，请检查或删除。")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("删除", role: .destructive) { planPendingDeletion = item.id }
                            .buttonStyle(.borderless)
                            .disabled(model.busy)
                    }
                }
            }
        }
        .navigationTitle("区域顺序与间隔")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.busy)
            }
        }
        .overlay {
            if model.busy { ProgressView("正在准备计划…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
        }
        .task { await model.refresh() }
        .navigationDestination(isPresented: Binding(
            get: { model.openedPlan != nil },
            set: { if !$0 { model.openedPlan = nil; Task { await model.refresh() } } }
        )) {
            if let opened = model.openedPlan {
                ScoreSequenceEditorView(plan: opened.plan, pageNumbers: opened.pageNumbers,
                                        materialURLs: opened.materialURLs,
                                        newRegions: opened.newRegions) { updated in
                    try await ScoreSequenceStore(id: opened.id).save(updated)
                }
                .safeAreaInset(edge: .top) {
                    if !opened.issues.isEmpty {
                        ScrollView {
                            Text(opened.issues.joined(separator: "\n"))
                                .font(.caption).foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        .frame(maxHeight: 120)
                        .background(.yellow.opacity(0.25))
                    }
                }
            }
        }
        .confirmationDialog("删除这个计划？", isPresented: Binding(
            get: { planPendingDeletion != nil },
            set: { if !$0 { planPendingDeletion = nil } }
        ), titleVisibility: .visible) {
            if let id = planPendingDeletion {
                Button("删除计划", role: .destructive) {
                    Task { await model.delete(id: id) }
                    planPendingDeletion = nil
                }
            }
            Button("取消", role: .cancel) { planPendingDeletion = nil }
        } message: {
            Text("仅删除此计划，不会删除素材、已画的区域或原文件。")
        }
        .alert("区域计划", isPresented: Binding(
            get: { model.message != nil }, set: { if !$0 { model.message = nil } }
        )) { Button("好") { model.message = nil } } message: { Text(model.message ?? "") }
    }
}
