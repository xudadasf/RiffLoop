import SwiftUI
import UniformTypeIdentifiers

struct PdfAudioLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var importerPresented = false
    @State private var errorMessage: String?
    private let store = RiffLoopDocumentStore()
    let onSelect: (URL) -> Void

    var body: some View {
        NavigationStack {
            List(files, id: \.path) { url in
                Button {
                    onSelect(url)
                    dismiss()
                } label: {
                    Label(url.lastPathComponent, systemImage: "waveform")
                }
            }
            .overlay {
                if files.isEmpty {
                    ContentUnavailableView(
                        "暂无伴奏",
                        systemImage: "waveform",
                        description: Text("伴奏与 PDF 放在同一个 PDF 文件夹。")
                    )
                }
            }
            .navigationTitle("PDF 伴奏")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("刷新", action: refresh)
                    Button("导入") { importerPresented = true }
                }
            }
        }
        .onAppear(perform: refresh)
        .fileImporter(
            isPresented: $importerPresented,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let source = urls.first else { return }
            let accessing = source.startAccessingSecurityScopedResource()
            defer { if accessing { source.stopAccessingSecurityScopedResource() } }
            do {
                onSelect(try store.importPdfAudio(from: source))
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert("RiffLoop", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func refresh() {
        do { files = try store.pdfAudioFiles() }
        catch { errorMessage = error.localizedDescription }
    }
}
