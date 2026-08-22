import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DocumentLibraryModel: ObservableObject {
    @Published private(set) var files: [URL] = []
    @Published private(set) var errorMessage: String?

    let kind: PracticeKind
    let folderURL: URL
    private let store: RiffLoopDocumentStore
    private let settingsStore: FilePracticeSettingsStore

    init(
        kind: PracticeKind,
        store: RiffLoopDocumentStore = RiffLoopDocumentStore(),
        settingsStore: FilePracticeSettingsStore = FilePracticeSettingsStore()
    ) {
        self.kind = kind
        self.store = store
        self.settingsStore = settingsStore
        folderURL = store.folderURL(for: kind)
        refresh()
    }

    func refresh() {
        do {
            files = try store.files(for: kind)
            errorMessage = nil
        } catch {
            errorMessage = "文件夹读取失败：\(error.localizedDescription)"
        }
    }

    func importExternalFile(_ sourceURL: URL) {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        do {
            _ = try store.importFile(from: sourceURL, for: kind)
            refresh()
        } catch {
            errorMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func deleteFile(_ fileURL: URL) -> Bool {
        do {
            try store.deleteFile(fileURL, for: kind)
            settingsStore.remove(kind: kind, fileName: fileURL.lastPathComponent)
            refresh()
            return true
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
            return false
        }
    }

    func dismissError() {
        errorMessage = nil
    }
}

struct DocumentLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var recentProjects: RecentProjectsStore
    @StateObject private var model: DocumentLibraryModel
    @State private var isImporterPresented = false
    @State private var filePendingDeletion: URL?
    let onSelect: (URL) -> Void

    init(kind: PracticeKind, onSelect: @escaping (URL) -> Void) {
        _model = StateObject(wrappedValue: DocumentLibraryModel(kind: kind))
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.files.isEmpty {
                    ContentUnavailableView {
                        Label("“\(model.kind.folderName)”文件夹为空", systemImage: "folder")
                    } description: {
                        Text("可从 Files 或电脑放入文件，也可在这里导入。")
                    } actions: {
                        Button("从 Files 导入") { isImporterPresented = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List(model.files, id: \.path) { fileURL in
                        HStack(spacing: 12) {
                            Button {
                                onSelect(fileURL)
                                dismiss()
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: iconName)
                                        .font(.title2)
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(fileURL.deletingPathExtension().lastPathComponent)
                                            .foregroundStyle(.primary)
                                        Text(fileURL.pathExtension.uppercased())
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if model.kind == .guitarPro {
                                Button(role: .destructive) {
                                    filePendingDeletion = fileURL
                                } label: {
                                    Label("删除", systemImage: "trash")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                                .accessibilityLabel("删除 \(fileURL.lastPathComponent)")
                            }
                        }
                    }
                }
            }
            .navigationTitle(model.kind.folderName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("刷新", action: model.refresh)
                    Button("导入") { isImporterPresented = true }
                }
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                model.importExternalFile(url)
            }
        }
        .confirmationDialog(
            "删除 GP 文件？",
            isPresented: Binding(
                get: { filePendingDeletion != nil },
                set: { if !$0 { filePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let fileURL = filePendingDeletion {
                Button("删除 \(fileURL.lastPathComponent)", role: .destructive) {
                    if model.deleteFile(fileURL) {
                        recentProjects.remove(
                            kind: model.kind,
                            fileName: fileURL.lastPathComponent
                        )
                    }
                    filePendingDeletion = nil
                }
            }
            Button("取消", role: .cancel) { filePendingDeletion = nil }
        } message: {
            Text("此操作会永久删除文件及其练习设置，无法撤销。")
        }
        .alert(
            "RiffLoop",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.dismissError() } }
            )
        ) {
            Button("好", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task {
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private var iconName: String {
        switch model.kind {
        case .video: "film"
        case .guitarPro: "music.note.list"
        case .pdf: "doc.richtext"
        }
    }
}
