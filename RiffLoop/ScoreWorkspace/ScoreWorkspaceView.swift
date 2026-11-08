import SwiftUI
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

    func removeCopy(_ url: URL) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.removeCopy(url)
            do {
                try await ScoreRegionsStore(source: url).removeSavedData()
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
    @State private var filePendingDeletion: URL?

    var body: some View {
        List {
            Section {
                Text("在这里准备 PDF、照片或截图。素材会复制到制谱工作区，原文件不会被修改。")
                    .foregroundStyle(.secondary)
                Text("可预览和手动画框。自动分区、识别和编辑正在开发。")
                    .foregroundStyle(.secondary)
            }
            Section("素材（按名称排列）") {
                if model.files.isEmpty {
                    Text("还没有素材，请先从文件中导入。")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.files, id: \.path) { url in
                    HStack {
                        NavigationLink {
                            ScoreRegionEditorView(source: url)
                        } label: {
                            Label(url.lastPathComponent, systemImage: url.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "photo")
                        }
                        Button("删除副本", role: .destructive) { filePendingDeletion = url }
                            .disabled(model.isWorking)
                    }
                }
            }
        }
        .navigationTitle("识别与编辑")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("导入素材", systemImage: "plus") { isImporterPresented = true }
                    .disabled(model.isWorking)
            }
        }
        .overlay {
            if model.isWorking { ProgressView("正在处理素材…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
        }
        .task { await model.refresh() }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.pdf, .image],
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
            Text("只删除工作区中的副本，不会删除原文件。")
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
