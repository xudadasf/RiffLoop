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

    @discardableResult
    func importExternalFile(_ sourceURL: URL) -> URL? {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        do {
            let importedURL = try store.importFile(from: sourceURL, for: kind)
            refresh()
            return importedURL
        } catch {
            errorMessage = "导入失败：\(error.localizedDescription)"
            return nil
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
    @EnvironmentObject private var displayNames: DocumentDisplayNameStore
    @StateObject private var model: DocumentLibraryModel
    @State private var isImporterPresented = false
    @State private var filePendingDeletion: URL?
    @State private var filePendingRename: URL?
    let onSelect: (URL) -> Void
    let onDelete: (URL) -> Void

    init(
        kind: PracticeKind,
        onSelect: @escaping (URL) -> Void,
        onDelete: @escaping (URL) -> Void = { _ in }
    ) {
        _model = StateObject(wrappedValue: DocumentLibraryModel(kind: kind))
        self.onSelect = onSelect
        self.onDelete = onDelete
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
                                        Text(displayName(for: fileURL))
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

                            Menu {
                                Button("修改显示名称", systemImage: "pencil") { filePendingRename = fileURL }
                                Button("删除文件", systemImage: "trash", role: .destructive) { filePendingDeletion = fileURL }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title3).frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("更多：\(displayName(for: fileURL))")
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
                    Button { isImporterPresented = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                            Text("导入文件")
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                filePendingRename = model.importExternalFile(url)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { filePendingRename != nil },
                set: { if !$0 { filePendingRename = nil } }
            )
        ) {
            if let fileURL = filePendingRename {
                DocumentDisplayNameEditor(
                    kind: model.kind,
                    fileName: fileURL.lastPathComponent
                )
            }
        }
        .confirmationDialog(
            "删除文件？",
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
                        displayNames.removeName(
                            for: model.kind,
                            fileName: fileURL.lastPathComponent
                        )
                        onDelete(fileURL)
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

    private func displayName(for url: URL) -> String {
        displayNames.displayName(for: model.kind, fileName: url.lastPathComponent)
    }
}

private struct DocumentDisplayNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var displayNames: DocumentDisplayNameStore
    @State private var name: String

    let kind: PracticeKind
    let fileName: String

    init(kind: PracticeKind, fileName: String) {
        self.kind = kind
        self.fileName = fileName
        _name = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("显示名称") {
                    TextField(fileName, text: $name)
                    Text("留空时显示原文件名。这里只改变界面名称，不会重命名或移动真实文件。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("原文件") {
                    Text(fileName)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if displayNames.customName(for: kind, fileName: fileName) != nil {
                    Section {
                        Button("恢复原文件名", role: .destructive) {
                            displayNames.removeName(for: kind, fileName: fileName)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("修改显示名称")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        displayNames.setDisplayName(name, for: kind, fileName: fileName)
                        dismiss()
                    } label: {
                        Text("保存")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .onAppear {
                name = displayNames.customName(for: kind, fileName: fileName) ?? ""
            }
        }
        .presentationDetents([.height(420), .large])
        .presentationDragIndicator(.visible)
    }
}
