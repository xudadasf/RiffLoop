import SwiftUI

struct ReproductionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [ReproductionSession] = []
    @State private var exporting = false
    @State private var exportedURL: URL?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("自动保存操作顺序、时间间隔、设置、素材快照和异常线索，用于按相同步骤重放。")
                    Text("保留最近 3 次启动；每次最多 8 MB 操作记录和 256 MB 素材。超过限制、未捕获素材或异常退出时来不及落盘的步骤，会降低复现完整度。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("刚才出现异常，标记现场") {
                        ReproductionStore.shared.record("incident", "user.marked_problem")
                        Task { await reload() }
                    }
                    .accessibilityIdentifier("diagnostics.mark")
                }
                if let exportedURL {
                    Section("复现包已保存") {
                        ShareLink(item: exportedURL) { Label("导出复现包（含已捕获素材）", systemImage: "square.and.arrow.up") }
                        Text("文件 App → RiffLoop → 异常复现包。包内有重放步骤、JSONL 操作记录、素材校验值和系统诊断报告（如系统已提供）。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("启动会话") {
                    ForEach(sessions) { session in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(session.started.formatted(date: .abbreviated, time: .standard)).font(.headline)
                            Text("\(session.environment["version"] ?? "") · \(session.lastSequence) 条记录 · \(session.incidents) 条异常线索")
                                .font(.subheadline)
                            let pending = session.materials.filter { $0.status != "captured" }.count
                            Text("素材 \(session.materials.count - pending)/\(session.materials.count) · 丢弃步骤 \(session.droppedEvents) · 写入错误 \(session.recordingErrors)")
                                .font(.caption).foregroundStyle(pending > 0 || session.droppedEvents > 0 || session.recordingErrors > 0 ? Color.orange : Color.secondary)
                            Button("生成这一会话的复现包") {
                                exporting = true; exportedURL = nil
                                Task {
                                    do { exportedURL = try await ReproductionStore.shared.export(session.id) }
                                    catch { self.error = error.localizedDescription }
                                    exporting = false
                                    await reload()
                                }
                            }.disabled(exporting)
                        }.padding(.vertical, 6)
                    }
                }
                Section {
                    Text("系统报告可能延迟到达。“上次未正常结束”不等于已确认闪退；强制退出、断电和系统回收也可能留下同样标记。当前提供人工重放步骤，不会自动操作或改写你的练习文件。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("异常复现记录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("刷新") { Task { await reload() } } }
            }
            .overlay { if exporting { ProgressView("正在整理素材和操作记录…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .task { await reload() }
            .alert("生成失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func reload() async { sessions = await ReproductionStore.shared.sessions() }
}
