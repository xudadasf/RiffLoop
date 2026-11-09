import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

@MainActor
final class ScoreWorkspaceModel: ObservableObject {
    @Published private(set) var files: [URL] = []
    @Published private(set) var isWorking = false
    @Published var message: String?

    private let store: ScoreWorkspaceStore

    init(store: ScoreWorkspaceStore = ScoreWorkspaceStore()) {
        self.store = store
    }

    func refresh() async {
        do {
            files = try await store.files()
        } catch {
            message = "读取制谱素材失败：\(error.localizedDescription)"
        }
    }

    func importFiles(_ urls: [URL]) async {
        guard !isWorking, !urls.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        var failures: [String] = []
        for url in urls {
            do {
                _ = try await store.importCopy(from: url)
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        await refresh()
        if !failures.isEmpty {
            message = "部分素材未能导入：\n" + failures.joined(separator: "\n")
        }
    }

    func importPhotos(_ items: [PhotosPickerItem]) async {
        guard !isWorking, !items.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        var failures: [String] = []
        // Process one photo at a time via files, without loading the batch into memory.
        for (index, item) in items.enumerated() {
            do {
                guard let photo = try await item.loadTransferable(type: ScorePhotoImport.self) else {
                    throw ScorePhotoImportError.unavailable
                }
                defer { try? FileManager.default.removeItem(at: photo.temporaryURL) }
                _ = try await store.importCopy(from: photo.temporaryURL)
            } catch {
                failures.append("第 \(index + 1) 张：\(error.localizedDescription)")
            }
        }
        await refresh()
        if !failures.isEmpty {
            message = "部分照片未能导入：\n" + failures.joined(separator: "\n")
        }
    }

    func removeCopy(_ url: URL) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let regions = ScoreRegionsStore(source: url)
            let digest = try await regions.prepareRemoval()
            try await store.removeCopy(url)
            do {
                try await regions.removeSavedData(for: digest)
            } catch {
                message = "素材副本已删除，但区域记录清理失败：\(error.localizedDescription)"
            }
            await refresh()
        } catch {
            message = "删除素材副本失败：\(error.localizedDescription)"
        }
    }
}

/// A separate workspace; it never changes an imported source or a practice project.
struct ScoreWorkspaceView: View {
    @StateObject private var model = ScoreWorkspaceModel()
    @State private var isImporterPresented = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var filePendingDeletion: URL?

    var body: some View {
        List {
            Section {
                Text("在这里准备 PDF、照片或截图。素材会复制到制谱工作区，原文件不会被修改。")
                    .foregroundStyle(.secondary)
                Text("可预览和手动画框。自动分区、识别和编辑正在开发。")
                    .foregroundStyle(.secondary)
            }
            Section {
                NavigationLink("区域顺序与间隔") {
                    ScoreSequenceLibraryView()
                }
            }
            Section("素材（按名称排列）") {
                if model.files.isEmpty {
                    Text("还没有素材，请先从文件或照片中导入。")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.files, id: \.path) { url in
                    HStack {
                        NavigationLink {
                            ScoreRegionEditorView(source: url)
                        } label: {
                            HStack(spacing: 10) {
                                ScoreMaterialThumbnailView(url: url)
                                Text(url.lastPathComponent)
                            }
                        }
                        Button("删除副本", role: .destructive) { filePendingDeletion = url }
                            .disabled(model.isWorking)
                    }
                }
            }
        }
        .navigationTitle("识别与编辑")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: nil,
                             matching: .images, preferredItemEncoding: .current) {
                    Label("从照片导入", systemImage: "photo.on.rectangle")
                }
                .disabled(model.isWorking)
                Button("从文件导入", systemImage: "folder") { isImporterPresented = true }
                    .disabled(model.isWorking)
            }
        }
        .overlay {
            if model.isWorking { ProgressView("正在处理素材…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
        }
        .task { await model.refresh() }
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            selectedPhotos = []
            Task { await model.importPhotos(items) }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: ["pdf", "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff"]
                .compactMap { UTType(filenameExtension: $0) },
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                Task { await model.importFiles(urls) }
            case let .failure(error):
                let nsError = error as NSError
                if nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError {
                    model.message = "选择素材失败：\(error.localizedDescription)"
                }
            }
        }
        .confirmationDialog("删除素材副本？", isPresented: Binding(
            get: { filePendingDeletion != nil },
            set: { if !$0 { filePendingDeletion = nil } }
        ), titleVisibility: .visible) {
            if let url = filePendingDeletion {
                Button("删除 \(url.lastPathComponent)", role: .destructive) {
                    Task { await model.removeCopy(url) }
                    filePendingDeletion = nil
                }
            }
            Button("取消", role: .cancel) { filePendingDeletion = nil }
        } message: {
            Text("将删除工作区中的素材副本及其已保存的区域，不会删除原文件。")
        }
        .alert("识别与编辑", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )) {
            Button("好") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }
}
