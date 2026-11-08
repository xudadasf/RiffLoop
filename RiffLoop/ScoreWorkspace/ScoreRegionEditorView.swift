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
                let factor = min(1, 2048 / max(bounds.width, bounds.height))
                let size = CGSize(width: max(1, bounds.width * factor), height: max(1, bounds.height * factor))
                return ScorePagePreview(image: page.thumbnail(of: size, for: .cropBox), pageCount: count,
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
    @Published var message: String?

    private let source: URL
    private let store: ScoreRegionsStore
    private var orientation = 0

    init(source: URL) {
        self.source = source
        self.store = ScoreRegionsStore(source: source)
    }

    func open() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await showPage(0)
    }

    func changePage(_ index: Int) async {
        guard !busy, index >= 0, index < pageCount else { return }
        busy = true
        defer { busy = false }
        await showPage(index)
    }

    private func showPage(_ index: Int) async {
        // Clear first so a failed page never keeps another page's editable image.
        image = nil
        regions = []
        pageIndex = index
        let source = self.source
        let preview = await Task.detached(priority: .userInitiated) {
            ScorePageRenderer.render(source: source, index: index)
        }.value
        guard !Task.isCancelled else { return }
        pageCount = preview.pageCount
        guard let renderedImage = preview.image else {
            message = preview.error ?? "无法读取此页面。"
            return
        }
        image = renderedImage
        orientation = preview.orientation
        do {
            regions = try await store.loadPage(index: index, rotation: orientation)
        } catch {
            image = nil
            message = "读取已保存区域失败：\(error.localizedDescription)"
        }
    }

    func addRegion(_ region: ScoreRegion, onPage index: Int) async {
        guard !busy else { message = "正在保存，请稍后重新画框。"; return }
        guard pageIndex == index, image != nil, region.isValid else {
            message = "页面已变化或区域无效，请重新画框。"
            return
        }
        await save(regions + [region])
    }

    func removeRegion(_ id: UUID) async {
        guard !busy, image != nil else { return }
        await save(regions.filter { $0.id != id })
    }

    private func save(_ updated: [ScoreRegion]) async {
        busy = true
        defer { busy = false }
        do {
            try await store.savePage(index: pageIndex, rotation: orientation, regions: updated)
            regions = updated
        } catch {
            message = "保存区域失败：\(error.localizedDescription)"
        }
    }

}

/// Manual region selection only. Recognition and ordering are not implemented here.
struct ScoreRegionEditorView: View {
    @StateObject private var model: ScoreRegionEditorModel
    @State private var zoom = 1.0
    @State private var drawing = false
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?

    init(source: URL) {
        _model = StateObject(wrappedValue: ScoreRegionEditorModel(source: source))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button("上一页") { Task { await model.changePage(model.pageIndex - 1) } }
                    .disabled(model.busy || model.pageIndex <= 0)
                Text("\(model.pageCount == 0 ? 0 : model.pageIndex + 1) / \(model.pageCount)")
                Button("下一页") { Task { await model.changePage(model.pageIndex + 1) } }
                    .disabled(model.busy || model.pageIndex + 1 >= model.pageCount)
                Spacer()
                Button("缩小") { zoom = max(1, zoom / 1.25) }.disabled(zoom <= 1)
                Text("\(Int(zoom * 100))%")
                Button("放大") { zoom = min(4, zoom * 1.25) }.disabled(zoom >= 4)
                Toggle("画框", isOn: $drawing).fixedSize().disabled(model.image == nil || model.busy)
            }
            .padding(.horizontal)
            Text("打开画框后拖动画出区域；关闭画框可滚动。区域仅用于保存，自动识别尚未完成。")
                .font(.caption).foregroundStyle(.secondary)
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
                            if let rect = dragRectangle(size: size) {
                                Rectangle().stroke(.orange, lineWidth: 2)
                                    .frame(width: rect.width, height: rect.height)
                                    .offset(x: rect.minX, y: rect.minY)
                            }
                        }
                        .frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .gesture(drawing && !model.busy ? drawGesture(size: size) : nil)
                    }
                    .scrollDisabled(drawing)
                }
                if !model.regions.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(Array(model.regions.enumerated()), id: \.element.id) { index, region in
                                Button("删除区域 \(index + 1)", role: .destructive) {
                                    Task { await model.removeRegion(region.id) }
                                }.disabled(model.busy)
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
        .task { await model.open() }
        .onChange(of: model.busy) { _, busy in
            if busy { dragStart = nil; dragEnd = nil }
        }
        .alert("手动框选", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )) { Button("好") { model.message = nil } } message: { Text(model.message ?? "") }
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
