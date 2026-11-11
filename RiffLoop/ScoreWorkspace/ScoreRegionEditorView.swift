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
    static func render(source: URL, index: Int) -> ScorePagePreview {
        autoreleasepool {
            if source.pathExtension.lowercased() == "pdf" {
                guard let document = PDFDocument(url: source), document.pageCount > 0 else {
                    return failure("无法打开 PDF，请检查文件是否损坏或需要密码。")
                }
                let count = document.pageCount
                guard let page = document.page(at: index) else {
                    return failure("无法读取此 PDF 页面。", pageCount: count)
                }
                let rotation = ((page.rotation % 360) + 360) % 360
                guard rotation == 0 else {
                    return failure("此 PDF 页面带有旋转，当前暂不支持框选，以免保存错误位置。请先将页面旋转后另存，或使用截图。", pageCount: count)
                }
                let bounds = page.bounds(for: .cropBox)
                guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
                    return failure("此 PDF 页面的尺寸无效。", pageCount: count)
                }
                // PDF coordinates are points, not source pixels. Render the vector
                // page at a useful preview resolution even when it is small in points.
                // A scale of 1 caps the actual bitmap to 2048 pixels on every device.
                let factor = 2048 / max(bounds.width, bounds.height)
                guard factor.isFinite, factor > 0 else { return failure("此 PDF 页面的尺寸无效。", pageCount: count) }
                let size = CGSize(width: max(1, floor(bounds.width * factor)),
                                  height: max(1, floor(bounds.height * factor)))
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
                kCGImageSourceThumbnailMaxPixelSize as String: 2048,
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
    @Published var message: String?

    private let source: URL
    private let store: ScoreRegionsStore
    private let renderer: @Sendable (URL, Int) -> ScorePagePreview
    private var orientation = 0
    private enum Change { case add(ScoreRegion), remove(ScoreRegion) }
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

    func open() async {
        guard !busy, !hasPendingChange else { return }
        busy = true
        defer { busy = false }
        await showPage(0)
    }

    func changePage(_ index: Int) async {
        guard !busy, !hasPendingChange, index >= 0, index < pageCount else { return }
        busy = true
        defer { busy = false }
        await showPage(index)
    }

    private func showPage(_ index: Int) async {
        // Clear first so a failed page never keeps another page's editable image.
        image = nil
        regions = []
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
            regions = try await store.loadPage(index: index, rotation: orientation)
            image = renderedImage
        } catch {
            image = nil
            message = "读取已保存区域失败：\(error.localizedDescription)"
        }
    }

    func addRegion(_ region: ScoreRegion, onPage index: Int) async {
        guard !busy, !hasPendingChange else { message = "请先处理尚未保存的区域。"; return }
        guard pageIndex == index, image != nil, region.isValid else {
            message = "页面已变化或区域无效，请重新画框。"
            return
        }
        await save(.add(region), basedOn: regions)
    }

    func removeRegion(_ id: UUID) async {
        guard !busy, !hasPendingChange, image != nil,
              let region = regions.first(where: { $0.id == id }) else { return }
        await save(.remove(region), basedOn: regions)
    }

    private func save(_ change: Change, basedOn current: [ScoreRegion]) async {
        busy = true
        defer { busy = false }
        do {
            let updated: [ScoreRegion]
            switch change {
            case let .add(region):
                guard !current.contains(where: { $0.id == region.id }) else { throw ScoreRegionsError.conflict }
                updated = current + [region]
            case let .remove(region):
                guard let existing = current.first(where: { $0.id == region.id }) else {
                    throw ScoreRegionsError.conflict
                }
                guard existing == region else { throw ScoreRegionsError.conflict }
                updated = current.filter { $0.id != region.id }
            }
            try await store.savePage(index: pageIndex, rotation: orientation, regions: updated, replacing: current)
            regions = updated
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
            let latest = try await store.loadPage(index: pageIndex, rotation: orientation)
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
            regions = try await store.loadPage(index: pageIndex, rotation: orientation)
            pendingChange = nil
            hasPendingChange = false
        } catch {
            message = "无法读取最新区域：\(error.localizedDescription)\n本次操作仍保留。"
        }
    }

}

/// Manual region selection only. Recognition and ordering are not implemented here.
struct ScoreRegionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var externalOpen: ScoreExternalOpenCoordinator
    @StateObject private var model: ScoreRegionEditorModel
    @State private var zoom = 1.0
    @State private var drawing = false
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    @State private var regionPendingDeletion: UUID?
    @State private var confirmDiscard = false

    init(source: URL) {
        _model = StateObject(wrappedValue: ScoreRegionEditorModel(source: source))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button("上一页") { Task { await model.changePage(model.pageIndex - 1) } }
                    .disabled(model.busy || model.hasPendingChange || model.pageIndex <= 0)
                Text("\(model.pageCount == 0 ? 0 : model.pageIndex + 1) / \(model.pageCount)")
                Button("下一页") { Task { await model.changePage(model.pageIndex + 1) } }
                    .disabled(model.busy || model.hasPendingChange || model.pageIndex + 1 >= model.pageCount)
                Spacer()
                Button("缩小") { zoom = max(1, zoom / 1.25) }.disabled(zoom <= 1)
                Text("\(Int(zoom * 100))%")
                Button("放大") { zoom = min(4, zoom * 1.25) }.disabled(zoom >= 4)
                Toggle("画框", isOn: $drawing).fixedSize().disabled(model.image == nil || model.busy || model.hasPendingChange)
            }
            .padding(.horizontal)
            Text("打开画框后拖动画出区域；关闭画框可滚动。区域仅用于保存，自动识别尚未完成。")
                .font(.caption).foregroundStyle(.secondary)
            if !externalOpen.pending.isEmpty {
                HStack {
                    Text("有 \(externalOpen.pending.count) 个外部文件待打开")
                    Button("打开待处理文件") {
                        externalOpen.endRegionEditing()
                        externalOpen.openNext()
                    }
                    .disabled(model.busy || model.hasPendingChange || dragStart != nil)
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
                            ForEach(Array(model.regions.enumerated()), id: \.element.id) { index, region in
                                Rectangle().stroke(.blue, lineWidth: 2)
                                    .frame(width: size.width * region.width, height: size.height * region.height)
                                    .overlay(alignment: .topLeading) {
                                        Text("\(index + 1)")
                                            .font(.caption.bold())
                                            .padding(3)
                                            .foregroundStyle(.white)
                                            .background(.blue)
                                    }
                                    .offset(x: size.width * region.x, y: size.height * region.y)
                            }
                            if let region = model.pendingAddedRegion {
                                Rectangle().stroke(.orange, lineWidth: 3)
                                    .frame(width: size.width * region.width, height: size.height * region.height)
                                    .offset(x: size.width * region.x, y: size.height * region.y)
                            }
                            if let rect = dragRectangle(size: size) {
                                Rectangle().stroke(.orange, lineWidth: 2)
                                    .frame(width: rect.width, height: rect.height)
                                    .offset(x: rect.minX, y: rect.minY)
                            }
                        }
                        .frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .gesture(drawing && !model.busy && !model.hasPendingChange ? drawGesture(size: size) : nil)
                    }
                    .scrollDisabled(drawing && !model.hasPendingChange)
                }
                if !model.regions.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(Array(model.regions.enumerated()), id: \.element.id) { index, region in
                                Button("删除区域 \(index + 1)", role: .destructive) {
                                    regionPendingDeletion = region.id
                                }.disabled(model.busy || model.hasPendingChange)
                            }
                        }.padding(.horizontal)
                    }
                }
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
                    if model.hasPendingChange { confirmDiscard = true } else { leaveEditor() }
                }.disabled(model.busy)
            }
        }
        .onAppear { externalOpen.beginRegionEditing() }
        .onDisappear { externalOpen.endRegionEditing() }
        .task { await model.open() }
        .onChange(of: model.busy) { _, busy in
            if busy { dragStart = nil; dragEnd = nil }
        }
        .confirmationDialog("删除这个区域？", isPresented: Binding(
            get: { regionPendingDeletion != nil },
            set: { if !$0 { regionPendingDeletion = nil } }
        ), titleVisibility: .visible) {
            if let id = regionPendingDeletion {
                Button("删除区域", role: .destructive) {
                    Task { await model.removeRegion(id) }
                    regionPendingDeletion = nil
                }
            }
            Button("取消", role: .cancel) { regionPendingDeletion = nil }
        } message: {
            Text("删除后需要重新画框。")
        }
        .confirmationDialog("放弃未保存的区域操作？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("放弃并返回", role: .destructive) { leaveEditor() }
            Button("继续处理", role: .cancel) { }
        }
        .alert("手动框选", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )) { Button("好") { model.message = nil } } message: { Text(model.message ?? "") }
    }

    private func leaveEditor() {
        externalOpen.endRegionEditing()
        dismiss()
    }

    private func drawGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
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
