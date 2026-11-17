import PDFKit
import SwiftUI
import UIKit
import ImageIO

/// A preview is passed back to the main actor only after background rendering finishes.
struct ScorePagePreview: @unchecked Sendable {
    let image: UIImage?
    let pageCount: Int
    let orientation: Int
    let error: String?
}

enum ScorePageRenderer {
    static func render(source: URL, index: Int, maximumPixelSize: Int = 2048) -> ScorePagePreview {
        autoreleasepool {
            let pixelLimit = min(4096, max(256, maximumPixelSize))
            if source.pathExtension.lowercased() == "pdf" {
                guard let document = PDFDocument(url: source), document.pageCount > 0 else {
                    return failure("无法打开 PDF，请检查文件是否损坏或需要密码。")
                }
                let count = document.pageCount
                guard let page = document.page(at: index) else {
                    return failure("无法读取此 PDF 页面。", pageCount: count)
                }
                let rotation = ((page.rotation % 360) + 360) % 360
                let bounds = page.bounds(for: .cropBox)
                guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
                    return failure("此 PDF 页面的尺寸无效。", pageCount: count)
                }
                // PDF coordinates are points, not source pixels. Render the vector
                // page at a useful preview resolution even when it is small in points.
                // A scale of 1 caps the actual bitmap to 2048 pixels on every device.
                let factor = CGFloat(pixelLimit) / max(bounds.width, bounds.height)
                guard factor.isFinite, factor > 0 else { return failure("此 PDF 页面的尺寸无效。", pageCount: count) }
                let size = CGSize(width: max(1, floor(bounds.width * factor)),
                                  height: max(1, floor(bounds.height * factor)))
                if rotation != 0 {
                    // PDFKit thumbnails apply the page rotation and crop box together.
                    // Keep the same normalized, displayed coordinates for drawing and OCR.
                    let image = page.thumbnail(of: size, for: .cropBox)
                    return ScorePagePreview(image: image, pageCount: count, orientation: rotation, error: nil)
                }
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                format.preferredRange = .standard
                let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                    let cg = context.cgContext
                    cg.setFillColor(UIColor.white.cgColor)
                    cg.fill(CGRect(origin: .zero, size: size))
                    cg.translateBy(x: 0, y: size.height)
                    cg.scaleBy(x: size.width / bounds.width, y: -size.height / bounds.height)
                    // PDFKit positions the crop box itself; translating its origin
                    // again would shift nonzero crop boxes and their saved regions.
                    page.draw(with: .cropBox, to: cg)
                }
                return ScorePagePreview(image: image, pageCount: count,
                                        orientation: rotation, error: nil)
            }

            guard index == 0,
                  let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
                return failure("无法打开此图片。")
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any]
            let exifOrientation = (properties?[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
            // Preserve the previously stored UIImage orientation values for existing regions.
            let orientation: UIImage.Orientation
            switch exifOrientation {
            case 1: orientation = .up
            case 2: orientation = .upMirrored
            case 3: orientation = .down
            case 4: orientation = .downMirrored
            case 5: orientation = .leftMirrored
            case 6: orientation = .right
            case 7: orientation = .rightMirrored
            case 8: orientation = .left
            default: return failure("此图片的方向暂不支持，无法安全框选。", pageCount: 1)
            }
            let options: [String: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                kCGImageSourceCreateThumbnailWithTransform as String: true,
                kCGImageSourceThumbnailMaxPixelSize as String: pixelLimit,
                kCGImageSourceShouldCacheImmediately as String: true,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
                return failure("无法打开此图片。", pageCount: 1)
            }
            // ImageIO has already applied the orientation; the saved value remains
            // the original orientation solely for region compatibility checks.
            return ScorePagePreview(image: UIImage(cgImage: thumbnail), pageCount: 1,
                                    orientation: orientation.rawValue, error: nil)
        }
    }

    private static func failure(_ message: String, pageCount: Int = 0) -> ScorePagePreview {
        ScorePagePreview(image: nil, pageCount: pageCount, orientation: 0, error: message)
    }
}

@MainActor
final class ScoreRegionEditorModel: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var regions: [ScoreRegion] = []
    @Published private(set) var pageIndex = 0
    @Published private(set) var pageCount = 0
    @Published private(set) var busy = false
    @Published private(set) var hasPendingChange = false
    @Published private(set) var selectedID: UUID?
    @Published private(set) var snapshot: ScoreRegionsSnapshot?
    @Published var numberInput = ""
    @Published var gapInput = ""
    @Published var message: String?

    let source: URL
    private let store: ScoreRegionsStore
    private let renderer: @Sendable (URL, Int) -> ScorePagePreview
    private var orientation = 0
    private enum Change {
        case add(ScoreRegion), remove(ScoreRegion)
        case layout(ScoreRegionLocation, number: Int, gapAfter: Int)
    }
    private var pendingChange: Change?

    init(source: URL, store: ScoreRegionsStore? = nil,
         renderer: @escaping @Sendable (URL, Int) -> ScorePagePreview = { ScorePageRenderer.render(source: $0, index: $1) }) {
        self.source = source
        self.store = store ?? ScoreRegionsStore(source: source)
        self.renderer = renderer
    }

    var pendingAddedRegion: ScoreRegion? {
        if case let .add(region) = pendingChange { return region }
        return nil
    }

    var totalRegions: Int { snapshot?.layout.count ?? 0 }
    var hasUnappliedInputs: Bool {
        guard let selectedID else { return false }
        return numberInput != String(number(for: selectedID) ?? 0) || gapInput != String(gap(for: selectedID))
    }
    private func location(_ id: UUID) -> ScoreRegionLocation {
        ScoreRegionLocation(pageIndex: pageIndex, rotation: orientation, regionID: id)
    }
    func number(for id: UUID) -> Int? { snapshot?.number(for: location(id)) }
    func gap(for id: UUID) -> Int { snapshot?.layout.first { $0.location == location(id) }?.gapAfter ?? 1 }

    func select(_ id: UUID) {
        guard !busy, !hasPendingChange, regions.contains(where: { $0.id == id }) else { return }
        guard !hasUnappliedInputs else { message = "请先应用或恢复当前框的编号和间隔。"; return }
        selectedID = id
        resetInputs()
    }

    func resetInputs() {
        numberInput = selectedID.flatMap { number(for: $0) }.map(String.init) ?? ""
        gapInput = selectedID.map { String(gap(for: $0)) } ?? ""
    }

    func applyInputs() async {
        guard !busy, !hasPendingChange, let selectedID, let snapshot else { return }
        guard let number = Int(numberInput.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...max(1, totalRegions)).contains(number),
              let gap = Int(gapInput.trimmingCharacters(in: .whitespacesAndNewlines)), (0...99).contains(gap) else {
            message = "编号请输入 1 到 \(totalRegions)；后接空白小节请输入 0 到 99，0 表示连续。"
            return
        }
        await save(.layout(location(selectedID), number: number, gapAfter: gap), basedOn: snapshot)
    }

    func makePlan() async -> ScoreSequencePlan? {
        guard !busy, !hasPendingChange, !hasUnappliedInputs else { return nil }
        busy = true
        defer { busy = false }
        do {
            let latest = try await store.snapshot()
            refresh(from: latest)
            return try ScoreSequenceFactory.makePlan(from: [(source, latest)])
        } catch {
            message = "无法继续识别：\(error.localizedDescription)"
            return nil
        }
    }

    func open() async {
        guard !busy, !hasPendingChange, !hasUnappliedInputs else { return }
        busy = true
        defer { busy = false }
        await showPage(0)
    }

    func changePage(_ index: Int) async {
        guard !busy, !hasPendingChange, !hasUnappliedInputs, index >= 0, index < pageCount else { return }
        busy = true
        defer { busy = false }
        await showPage(index)
    }

    private func showPage(_ index: Int) async {
        // Clear first so a failed page never keeps another page's editable image.
        image = nil
        regions = []
        selectedID = nil
        snapshot = nil
        resetInputs()
        pageIndex = index
        do {
            try await store.bindSource()
        } catch {
            message = "无法打开素材：\(error.localizedDescription)"
            return
        }
        let source = self.source
        let renderer = self.renderer
        let preview = await Task.detached(priority: .userInitiated) {
            renderer(source, index)
        }.value
        guard !Task.isCancelled else { return }
        pageCount = preview.pageCount
        guard let renderedImage = preview.image else {
            message = preview.error ?? "无法读取此页面。"
            return
        }
        orientation = preview.orientation
        do {
            refresh(from: try await store.snapshot())
            image = renderedImage
        } catch {
            image = nil
            message = "读取已保存区域失败：\(error.localizedDescription)"
        }
    }

    func addRegion(_ region: ScoreRegion, onPage index: Int) async {
        guard !busy, !hasPendingChange, !hasUnappliedInputs else { message = "请先处理尚未保存的区域或输入。"; return }
        guard pageIndex == index, image != nil, region.isValid, let snapshot else {
            message = "页面已变化或区域无效，请重新画框。"
            return
        }
        await save(.add(region), basedOn: snapshot)
    }

    func removeRegion(_ id: UUID) async {
        guard !busy, !hasPendingChange, !hasUnappliedInputs, image != nil, let snapshot,
              let region = regions.first(where: { $0.id == id }) else { return }
        await save(.remove(region), basedOn: snapshot)
    }

    private func refresh(from snapshot: ScoreRegionsSnapshot) {
        self.snapshot = snapshot
        regions = snapshot.pages.first { $0.index == pageIndex && $0.rotation == orientation }?.regions ?? []
        if let selectedID, !regions.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        resetInputs()
    }

    private func save(_ change: Change, basedOn base: ScoreRegionsSnapshot) async {
        busy = true
        defer { busy = false }
        do {
            let current = base.pages.first { $0.index == pageIndex && $0.rotation == orientation }?.regions ?? []
            let saved: ScoreRegionsSnapshot
            switch change {
            case let .add(region):
                guard !current.contains(where: { $0.id == region.id }) else { throw ScoreRegionsError.conflict }
                saved = try await store.savePage(index: pageIndex, rotation: orientation,
                                                regions: current + [region], replacing: current)
                selectedID = region.id
            case let .remove(region):
                guard let existing = current.first(where: { $0.id == region.id }) else {
                    throw ScoreRegionsError.conflict
                }
                guard existing == region else { throw ScoreRegionsError.conflict }
                saved = try await store.savePage(index: pageIndex, rotation: orientation,
                                                regions: current.filter { $0.id != region.id }, replacing: current)
            case let .layout(location, number, gap):
                let updated = try base.changing(location, number: number, gapAfter: gap)
                saved = try await store.saveLayout(updated, replacing: base)
            }
            refresh(from: saved)
            pendingChange = nil
            hasPendingChange = false
        } catch {
            pendingChange = change
            hasPendingChange = true
            message = "区域尚未保存：\(error.localizedDescription)\n已保留本次操作，可重试保存或放弃。"
        }
    }

    func retryPendingChange() async {
        guard !busy, let change = pendingChange else { return }
        busy = true
        do {
            let latest = try await store.snapshot()
            busy = false
            await save(change, basedOn: latest)
        } catch {
            busy = false
            message = "无法读取最新区域：\(error.localizedDescription)\n本次操作仍保留。"
        }
    }

    func discardPendingChange() async {
        guard !busy, hasPendingChange else { return }
        busy = true
        defer { busy = false }
        do {
            refresh(from: try await store.snapshot())
            pendingChange = nil
            hasPendingChange = false
        } catch {
            message = "无法读取最新区域：\(error.localizedDescription)\n本次操作仍保留。"
        }
    }

}

/// Select and configure saved regions before handing them to the recognition plan.
struct ScoreRegionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var externalOpen: ScoreExternalOpenCoordinator
    @StateObject private var model: ScoreRegionEditorModel
    @State private var zoom = 1.0
    @State private var drawing = false
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    private enum Dialog { case delete(UUID), discard, message(String) }
    @State private var dialog: Dialog?
    @State private var showDialog = false
    @State private var nextPlan: ScoreSequencePlan?
    @State private var nextPlanID = UUID()
    private enum InputField: Hashable { case number, gap }
    @FocusState private var editingInput: InputField?

    private var locked: Bool { model.busy || model.hasPendingChange || model.hasUnappliedInputs }

    init(source: URL, store: ScoreRegionsStore? = nil) {
        _model = StateObject(wrappedValue: ScoreRegionEditorModel(source: source, store: store))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button("上一页") { Task { await model.changePage(model.pageIndex - 1) } }
                    .disabled(locked || model.pageIndex <= 0)
                Text("\(model.pageCount == 0 ? 0 : model.pageIndex + 1) / \(model.pageCount)")
                Button("下一页") { Task { await model.changePage(model.pageIndex + 1) } }
                    .disabled(locked || model.pageIndex + 1 >= model.pageCount)
                Spacer()
                Button("缩小") { zoom = max(1, zoom / 1.25) }.disabled(zoom <= 1)
                Text("\(Int(zoom * 100))%")
                Button("放大") { zoom = min(4, zoom * 1.25) }.disabled(zoom >= 4)
                Toggle("画框", isOn: $drawing).fixedSize().disabled(model.image == nil || locked)
                    .accessibilityIdentifier("region.drawing")
            }
            .padding(.horizontal)
            Text("点击方框选中；打开画框后拖动新增，关闭后可滚动。按编号连接，改号后其他框自动顺延。")
                .font(.caption).foregroundStyle(.secondary)
            if !externalOpen.pending.isEmpty {
                HStack {
                    Text("有 \(externalOpen.pending.count) 个外部文件待打开")
                    Button("打开待处理文件") {
                        externalOpen.endRegionEditing()
                        externalOpen.openNext()
                    }
                    .disabled(locked || dragStart != nil)
                }
            }
            if model.hasPendingChange {
                HStack {
                    Text("操作尚未保存")
                    Button("重试保存") { Task { await model.retryPendingChange() } }
                    Button("放弃操作", role: .destructive) { Task { await model.discardPendingChange() } }
                }.disabled(model.busy)
            }
            if let image = model.image {
                GeometryReader { geometry in
                    let fit = min(geometry.size.width / image.size.width, geometry.size.height / image.size.height)
                    let size = CGSize(width: image.size.width * fit * zoom, height: image.size.height * fit * zoom)
                    ScrollView([.horizontal, .vertical]) {
                        ZStack(alignment: .topLeading) {
                            Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                            ForEach(model.regions) { region in
                                regionButton(region, size: size)
                            }
                            if let region = model.pendingAddedRegion {
                                Rectangle().stroke(.orange, lineWidth: 3)
                                    .frame(width: size.width * region.width, height: size.height * region.height)
                                    .offset(x: size.width * region.x, y: size.height * region.y)
                                    .allowsHitTesting(false)
                            }
                            if let rect = dragRectangle(size: size) {
                                Rectangle().stroke(.orange, lineWidth: 2)
                                    .frame(width: rect.width, height: rect.height)
                                    .offset(x: rect.minX, y: rect.minY)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("region.canvas")
                        .simultaneousGesture(drawing && !locked ? drawGesture(size: size) : nil)
                    }
                    .scrollDisabled(drawing && !model.hasPendingChange)
                }
                selectedRegionControls
            } else {
                Spacer()
                Text("此页面暂无可框选的预览。")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .navigationTitle("手动框选")
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("返回") {
                    if model.hasPendingChange || model.hasUnappliedInputs { present(.discard) } else { leaveEditor() }
                }.disabled(model.busy)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("下一步：识别设置") {
                    editingInput = nil
                    Task {
                        if let plan = await model.makePlan() { nextPlanID = UUID(); nextPlan = plan }
                    }
                }
                .accessibilityIdentifier("region.next")
                .disabled(locked || model.totalRegions == 0 || dragStart != nil)
            }
        }
        .onAppear { externalOpen.beginRegionEditing() }
        .onDisappear { externalOpen.endRegionEditing() }
        .task { if model.image == nil { await model.open() } }
        .onChange(of: model.busy) { _, busy in
            if busy { dragStart = nil; dragEnd = nil }
        }
        .onChange(of: model.message) { _, value in
            if let value { present(.message(value)); model.message = nil }
        }
        .alert(dialogTitle, isPresented: $showDialog, presenting: dialog) { target in
            switch target {
            case let .delete(id):
                Button("删除区域", role: .destructive) {
                    Task { await model.removeRegion(id) }
                }
                .accessibilityIdentifier("region.confirmDelete")
                Button("取消", role: .cancel) { }
            case .discard:
                Button("放弃并返回", role: .destructive) { leaveEditor() }
                Button("继续处理", role: .cancel) { }
            case .message:
                Button("好", role: .cancel) { }
            }
        } message: { target in
            switch target {
            case .delete: Text("仅删除选中的框，其余框自动重新编号；素材图片不变。")
            case .discard: Text("尚未应用或保存的修改将被放弃。")
            case let .message(text): Text(text)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { nextPlan != nil }, set: { if !$0 { nextPlan = nil } }
        )) {
            if let plan = nextPlan {
                // Give the plan its own navigation controls. Reusing this stack
                // hides the destination's custom Back button on iPad.
                NavigationStack {
                    ScoreSequenceEditorView(plan: plan, isSaved: false,
                        pageNumbers: Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.reference, $0.number) }),
                        materialURLs: [model.source.lastPathComponent: model.source]) { updated in
                            try await ScoreSequenceStore(id: nextPlanID).save(updated)
                        }
                }
            }
        }
    }

    private var dialogTitle: String {
        switch dialog {
        case let .delete(id): "删除方框 \(model.number(for: id) ?? 0)？"
        case .discard: "放弃未保存的修改？"
        default: "手动框选"
        }
    }

    private func present(_ value: Dialog) { editingInput = nil; dialog = value; showDialog = true }

    private func regionButton(_ region: ScoreRegion, size: CGSize) -> some View {
        let selected = model.selectedID == region.id
        let number = model.number(for: region.id) ?? 0
        return Button { editingInput = nil; model.select(region.id) } label: {
            Rectangle().fill(selected ? Color.orange.opacity(0.16) : Color.blue.opacity(0.04))
                .overlay { Rectangle().stroke(selected ? Color.orange : Color.blue, lineWidth: selected ? 3 : 2) }
                .overlay(alignment: .topLeading) {
                    Text("\(number)").font(.body.bold()).padding(4)
                        .foregroundStyle(.white).background(selected ? Color.orange : Color.blue)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: size.width * region.width, height: size.height * region.height)
        .offset(x: size.width * region.x, y: size.height * region.y)
        .disabled(model.busy || model.hasPendingChange)
        .accessibilityLabel("方框 \(number)")
        .accessibilityValue(selected ? "已选中，后接 \(model.gap(for: region.id)) 个空白小节" : "未选中")
        .accessibilityIdentifier("region-\(region.id.uuidString)")
    }

    private var selectedRegionControls: some View {
        VStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    Text(model.selectedID == nil ? "请先点击一个框" : "编号")
                    TextField("编号", text: $model.numberInput)
                        .frame(width: 58, height: 44).focused($editingInput, equals: .number).accessibilityIdentifier("region.number")
                    Text("后接空白小节")
                    TextField("间隔", text: $model.gapInput)
                        .frame(width: 58, height: 44).focused($editingInput, equals: .gap).accessibilityIdentifier("region.gap")
                    Button("应用") { editingInput = nil; Task { await model.applyInputs() } }
                        .accessibilityIdentifier("region.apply")
                        .disabled(!model.hasUnappliedInputs)
                    Button("恢复") { editingInput = nil; model.resetInputs() }
                        .disabled(!model.hasUnappliedInputs)
                    Button("删除选中框", role: .destructive) {
                        if let id = model.selectedID { present(.delete(id)) }
                    }
                    .accessibilityIdentifier("region.delete")
                    .disabled(model.hasUnappliedInputs)
                }
                .textFieldStyle(.roundedBorder).keyboardType(.numberPad)
                .buttonStyle(.bordered).controlSize(.large)
                .disabled(model.selectedID == nil || model.busy || model.hasPendingChange)
                .padding(.horizontal)
            }
            .frame(height: 60)
            Text("共 \(model.totalRegions) 个框 · 间隔 0 表示连续；最后一个框不追加空白小节。修改后点“应用”。")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("region.help")
        }
        .padding(.bottom, 8)
    }

    private func leaveEditor() {
        externalOpen.endRegionEditing()
        dismiss()
    }

    private func drawGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in dragStart = value.startLocation; dragEnd = value.location }
            .onEnded { _ in
                defer { dragStart = nil; dragEnd = nil }
                guard let rect = dragRectangle(size: size), size.width > 0, size.height > 0,
                      rect.width / size.width >= 0.005, rect.height / size.height >= 0.005 else { return }
                let region = ScoreRegion(x: rect.minX / size.width, y: rect.minY / size.height,
                                         width: rect.width / size.width, height: rect.height / size.height)
                let pageIndex = model.pageIndex
                Task { await model.addRegion(region, onPage: pageIndex) }
            }
    }

    private func dragRectangle(size: CGSize) -> CGRect? {
        guard let start = dragStart, let end = dragEnd else { return nil }
        let x1 = min(max(start.x, 0), size.width), x2 = min(max(end.x, 0), size.width)
        let y1 = min(max(start.y, 0), size.height), y2 = min(max(end.y, 0), size.height)
        return CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
    }
}
