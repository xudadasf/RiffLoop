import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var recentProjects: RecentProjectsStore
    @State private var signingStatus = SigningStatusSnapshot.current()
    @State private var isSigningHelpPresented = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 20) {
                    practiceCard(
                        title: "视频练习",
                        subtitle: "播放、节拍器与 A/B 循环",
                        systemImage: "play.rectangle.fill"
                    ) {
                        PracticeView()
                    }

                    practiceCard(
                        title: "Guitar Pro 乐谱",
                        subtitle: "离线 alphaTab 1.8.4",
                        systemImage: "music.note.list"
                    ) {
                        GpPracticeView()
                    }

                    practiceCard(
                        title: "PDF 谱面",
                        subtitle: "伴奏、轨迹与自动跟谱",
                        systemImage: "doc.richtext.fill"
                    ) {
                        PdfPracticeView()
                    }
                }

                signingStatusCard

                if !recentProjects.projects.isEmpty {
                    Text("最近项目")
                        .font(.title3.bold())
                    List {
                        ForEach(recentProjects.projects) { project in
                            NavigationLink {
                                destination(for: project)
                            } label: {
                                Label(project.fileName, systemImage: iconName(for: project.kind))
                            }
                            .swipeActions {
                                Button("移除记录", role: .destructive) {
                                    recentProjects.remove(
                                        kind: project.kind,
                                        fileName: project.fileName
                                    )
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .padding(28)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("RiffLoop")
            .onAppear(perform: refreshSigningStatus)
            .sheet(isPresented: $isSigningHelpPresented) {
                signingHelp
            }
        }
    }

    private var signingStatusCard: some View {
        HStack(spacing: 16) {
            Image(systemName: signingStatusIcon)
                .font(.title2)
                .foregroundStyle(signingStatusColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(signingStatusTitle)
                    .font(.headline)
                Text(signingStatusDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("重新检测", action: refreshSigningStatus)
                .buttonStyle(.bordered)
            Button("手动续签") { isSigningHelpPresented = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    private var signingHelp: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label("续签需要在 Windows 的 Sideloadly 中完成", systemImage: "desktopcomputer")
                    .font(.title2.bold())

                Text("1. 在 Windows 打开 Sideloadly。让电脑与 iPad 处于同一局域网；若设备未出现，请改用 USB 连接。")
                Text("2. 把最新的 RiffLoop IPA 拖入 Sideloadly，在 Device 中选择这台 iPad，并选择原来用于安装的 Apple 账号。")
                Text("3. 不要使用修改 Bundle ID 功能；IPA 内的 Bundle ID 应为 com.riffloop.prototype。保持 Automatic Refresh 开启，然后点击 Start。")
                Text("4. 若 Apple 要求验证，请在 Sideloadly 中完成密码或双重认证；不要把账号信息填入 RiffLoop。")
                Text("5. 等待 Sideloadly 显示安装完成。不要先删除 iPad 上的 RiffLoop，直接覆盖安装才能保留文件和设置。")
                Text("6. 重新打开 RiffLoop 并点“重新检测”，确认到期时间已经延后。")

                Text("iPad App 无法给自身重新签名。此入口用于查看续签步骤和重新检测状态。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("重新检测") {
                    refreshSigningStatus()
                    isSigningHelpPresented = false
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(28)
            .navigationTitle("手动续签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { isSigningHelpPresented = false }
                }
            }
        }
    }

    private var signingStatusTitle: String {
        switch signingStatus.kind {
        case .valid: "签名有效"
        case .expiringSoon: "签名即将到期"
        case .expired: "签名已过期"
        case .unavailable: "无法读取签名状态"
        }
    }

    private var signingStatusDetail: String {
        guard let expirationDate = signingStatus.expirationDate else {
            return "模拟器、未签名构建或描述文件格式无法识别"
        }
        let remainingDays = max(
            0,
            Int(ceil(expirationDate.timeIntervalSinceNow / (24 * 60 * 60)))
        )
        let date = expirationDate.formatted(date: .abbreviated, time: .shortened)
        if signingStatus.kind == .expired {
            return "到期时间：\(date) · 请使用 Sideloadly 覆盖续签"
        }
        return "到期时间：\(date) · 约剩 \(remainingDays) 天 · 仅作提醒，以系统校验为准"
    }

    private var signingStatusIcon: String {
        switch signingStatus.kind {
        case .valid: "checkmark.shield.fill"
        case .expiringSoon: "exclamationmark.shield.fill"
        case .expired: "xmark.shield.fill"
        case .unavailable: "questionmark.diamond.fill"
        }
    }

    private var signingStatusColor: Color {
        switch signingStatus.kind {
        case .valid: .green
        case .expiringSoon: .orange
        case .expired: .red
        case .unavailable: .secondary
        }
    }

    private func refreshSigningStatus() {
        signingStatus = .current()
    }

    @ViewBuilder
    private func destination(for project: RecentProject) -> some View {
        let url = RiffLoopDocumentStore()
            .folderURL(for: project.kind)
            .appendingPathComponent(project.fileName)

        switch project.kind {
        case .video:
            PracticeView(initialURL: url)
        case .guitarPro:
            GpPracticeView(initialURL: url)
        case .pdf:
            PdfPracticeView(initialURL: url)
        }
    }

    private func iconName(for kind: PracticeKind) -> String {
        switch kind {
        case .video: "film"
        case .guitarPro: "music.note.list"
        case .pdf: "doc.richtext"
        }
    }

    private func practiceCard<Destination: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Text(title)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: 220, alignment: .leading)
            .padding(22)
            .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}
