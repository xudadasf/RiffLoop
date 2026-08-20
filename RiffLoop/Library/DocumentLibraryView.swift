import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DocumentLibraryModel: ObservableObject {
    @Published private(set) var files: [URL] = []
    @Published private(set) var errorMessage: String?

    let kind: PracticeKind
    let folderURL: URL
    private let store: RiffLoopDocumentStore

    init(kind: PracticeKind, store: RiffLoopDocumentStore = RiffLoopDocumentStore()) {
        self.kind = kind
        self.store = store
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

    func dismissError() {
        errorMessage = nil
    }
}

struct DocumentLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: DocumentLibraryModel
    @State private var isImporterPresented = false
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
