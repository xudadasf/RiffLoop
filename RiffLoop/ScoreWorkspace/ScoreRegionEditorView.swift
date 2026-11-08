import PDFKit
import SwiftUI
import UIKit

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
    private var pdf: PDFDocument?
    private var sourceImage: UIImage?
    private var orientation = 0

    init(source: URL) {
        self.source = source
        self.store = ScoreRegionsStore(source: source)
    }

    func open() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if source.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: source), document.pageCount > 0 else {
                message = "无法打开 PDF，请检查文件是否损坏或需要密码。"
                return
            }
            pdf = document
            pageCount = document.pageCount
        } else {
            guard let value = UIImage(contentsOfFile: source.path), value.cgImage != nil else {
                message = "无法打开此图片。"
                return
            }
            sourceImage = value
            pageCount = 1
        }
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
        if let pdf {
            guard let page = pdf.page(at: index) else {
                message = "无法读取此 PDF 页面。"
                return
            }
            let rotation = ((page.rotation % 360) + 360) % 360
            guard rotation == 0 else {
                message = "此 PDF 页面带有旋转，当前暂不支持框选，以免保存错误位置。请先将页面旋转后另存，或使用截图。"
                return
            }
            let bounds = page.bounds(for: .cropBox)
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
                message = "此 PDF 页面的尺寸无效。"
                return
            }
            let size = previewSize(width: bounds.width, height: bounds.height)
            image = page.thumbnail(of: size, for: .cropBox)
            orientation = rotation
        } else if let sourceImage, let cgImage = sourceImage.cgImage {
            let swapsDimensions: Bool
            switch sourceImage.imageOrientation {
            case .left, .right, .leftMirrored, .rightMirrored: swapsDimensions = true
            case .up, .down, .upMirrored, .downMirrored: swapsDimensions = false
            @unknown default:
                message = "此图片的方向暂不支持，无法安全框选。"
                return
            }
            let width = CGFloat(swapsDimensions ? cgImage.height : cgImage.width)
            let height = CGFloat(swapsDimensions ? cgImage.width : cgImage.height)
            guard width > 0, height > 0 else { message = "图片尺寸无效。"; return }
            let size = previewSize(width: width, height: height)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            // UIImage.draw applies all eight EXIF orientations before coordinates are taken.
            image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                sourceImage.draw(in: CGRect(origin: .zero, size: size))
            }
            orientation = sourceImage.imageOrientation.rawValue
        } else {
            message = "无法读取此页面。"
            return
        }
        do {
            regions = try await store.loadPage(index: index, rotation: orientation)
        } catch {
            image = nil
            message = "读取已保存区域失败：\(error.localizedDescription)"
        }
    }

    func addRegion(_ region: ScoreRegion, onPage index: Int) async {
        guard !busy, pageIndex == index, image != nil, region.isValid else { return }
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

    private func previewSize(width: CGFloat, height: CGFloat) -> CGSize {
        let factor = min(1, 2048 / max(width, height))
        return CGSize(width: max(1, width * factor), height: max(1, height * factor))
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
                        .gesture(drawing ? drawGesture(size: size) : nil)
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
