import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var recentProjects: RecentProjectsStore
    @StateObject private var practiceHistory = PracticeHistoryStore.shared
    @State private var signingStatus = SigningStatusSnapshot.current()
    @State private var isSigningHelpPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 20) {
                        practiceCard(
                            title: "视频练习",
                            subtitle: "播放、节拍器与 A/B 循环",
                            systemImage: "play.rectangle.fill"
                        ) {
                            PracticeView(initialURL: mostRecentURL(for: .video))
                        }

                        practiceCard(
                            title: "Guitar Pro 乐谱",
                            subtitle: "音符级循环与内嵌伴奏",
                            systemImage: "music.note.list"
                        ) {
                            GpPracticeView(initialURL: mostRecentURL(for: .guitarPro))
                        }

                        practiceCard(
                            title: "PDF 谱面",
                            subtitle: "伴奏、轨迹与自动跟谱",
                            systemImage: "doc.richtext.fill"
                        ) {
                            PdfPracticeView(initialURL: mostRecentURL(for: .pdf))
                        }
                    }

                    practiceCalendarCard
                    signingStatusCard

                    if !recentProjects.projects.isEmpty {
                        Text("最近项目")
                            .font(.title3.bold())
                        LazyVStack(spacing: 8) {
                            ForEach(recentProjects.projects) { project in
                                HStack(spacing: 12) {
                                    NavigationLink {
                                        destination(for: project)
                                    } label: {
                                        Label(project.fileName, systemImage: iconName(for: project.kind))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    Button(role: .destructive) {
                                        recentProjects.remove(
                                            kind: project.kind,
                                            fileName: project.fileName
                                        )
                                    } label: {
                                        Label("移除记录", systemImage: "trash")
                                            .labelStyle(.iconOnly)
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .padding(14)
                                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }
                .padding(28)
            }
            .background {
                LinearGradient(
                    colors: [Color(red: 0.08, green: 0.09, blue: 0.13), .black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            }
            .navigationTitle("RiffLoop")
            .onAppear(perform: refreshSigningStatus)
            .sheet(isPresented: $isSigningHelpPresented) {
                signingHelp
            }
        }
    }

    private var practiceCalendarCard: some View {
        let days = practiceHistory.calendarDays()
        let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)

        return HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                Label("练习日历", systemImage: "calendar.badge.clock")
                    .font(.title3.bold())
                    .foregroundStyle(.orange)
                Text("颜色越深，练习时间越长")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 24) {
                    practiceMetric("今天", seconds: practiceHistory.seconds(on: Date()))
                    practiceMetric("本周", seconds: practiceHistory.secondsThisWeek())
                    practiceMetric("累计", seconds: practiceHistory.totalSeconds)
                }

                Text("按天统计从此版本开始，原有各文件累计时长保持不变。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(Array(practiceHistory.weekdaySymbols().enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(days) { day in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(practiceColor(for: day))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            if Calendar.current.isDateInToday(day.date) {
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(.orange, lineWidth: 2)
                            }
                        }
                        .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue(formatPracticeDuration(day.seconds))
                }
            }
            .frame(width: 240)
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color.orange.opacity(0.13), Color.white.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.orange.opacity(0.22), lineWidth: 1)
        }
    }

    private func practiceMetric(_ title: String, seconds: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(formatPracticeDuration(seconds))
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func practiceColor(for day: PracticeDay) -> Color {
        guard !day.isFuture else { return Color.white.opacity(0.08) }
        let minutes = day.seconds / 60
        if minutes == 0 { return .white }
        if minutes < 5 { return Color.orange.opacity(0.3) }
        if minutes < 15 { return Color.orange.opacity(0.5) }
        if minutes < 30 { return Color.orange.opacity(0.7) }
        return .orange
    }

    private func formatPracticeDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(max(0, seconds) / 60)
        if totalMinutes < 60 { return "\(totalMinutes) 分钟" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours) 小时" : "\(hours)小时 \(minutes)分"
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
            Button("无线续签步骤") { isSigningHelpPresented = true }
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

                Text("1. 首次设置需用 USB：在 iTunes 的设备摘要中开启“通过 Wi-Fi 与此 iPad 同步”，点击“同步/完成”，并让 Sideloadly 成功安装过一次。")
                Text("2. 日常无线续签时，电脑与 iPad 连接同一个局域网，保持 iPad 屏幕点亮，并关闭电脑和 iPad 上的 VPN/代理。")
                Text("3. 在 Windows 打开 Sideloadly，确认 Device 中出现这台 iPad；把最新 RiffLoop IPA 拖入，并继续使用原来的 Apple 账号。")
                Text("4. 不要修改 Bundle ID；IPA 内应为 com.riffloop.prototype。保持 Automatic Refresh 开启，然后点击 Start。")
                Text("5. 若 Apple 要求验证，只在 Sideloadly 中完成密码或双重认证，不要把账号信息填入 RiffLoop。")
                Text("6. 等待 Sideloadly 显示完成。不要卸载旧 App，直接覆盖安装才能保留文件和设置。无线设备未出现时，再接 USB 覆盖安装。")
                Text("7. 重新打开 RiffLoop 并点“重新检测”，确认到期时间已经延后。")

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
            .navigationTitle("无线/手动续签")
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

    private func mostRecentURL(for kind: PracticeKind) -> URL? {
        let folder = RiffLoopDocumentStore().folderURL(for: kind)
        return recentProjects.projects
            .lazy
            .filter { $0.kind == kind }
            .map { folder.appendingPathComponent($0.fileName) }
            .first { url in
                kind.supportedExtensions.contains(url.pathExtension.lowercased())
                    && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
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
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.12), Color.white.opacity(0.06)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 18)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
    }
}
