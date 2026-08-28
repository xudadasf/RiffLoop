import AVFoundation
import PDFKit
import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var recentProjects: RecentProjectsStore
    @EnvironmentObject private var displayNames: DocumentDisplayNameStore
    @StateObject private var practiceHistory = PracticeHistoryStore.shared
    @State private var signingStatus = SigningStatusSnapshot.current()
    @State private var isSigningHelpPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    welcomeHeader
                    continuePracticeCard

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            startPracticeCard
                                .frame(minWidth: 520, maxWidth: .infinity, minHeight: 216, maxHeight: 216)
                            practiceSummaryCard
                                .frame(width: 340, height: 216)
                        }

                        VStack(spacing: 16) {
                            startPracticeCard
                                .frame(minHeight: 216, maxHeight: 216)
                            practiceSummaryCard
                                .frame(minHeight: 216, maxHeight: 216)
                        }
                    }

                    if !recentProjects.projects.isEmpty { recentProjectsSection }
                }
                .frame(maxWidth: 1_180, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isSigningHelpPresented = true
                    } label: {
                        Label(signingCompactTitle, systemImage: signingStatusIcon)
                    }
                    .tint(signingStatusColor)
                }
            }
            .onAppear(perform: refreshSigningStatus)
            .sheet(isPresented: $isSigningHelpPresented) {
                signingHelp
            }
        }
    }

    private var welcomeHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text(greeting)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("继续今天的练习")
                    .font(.largeTitle.bold())
            }

            Spacer()

            Text("本周已练习 \(formatPracticeDuration(practiceHistory.secondsThisWeek()))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var continuePracticeCard: some View {
        if let project = mostRecentProject {
            ZStack(alignment: .trailing) {
                PracticeCardBackground()

                HStack(alignment: .bottom, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("最近练习 · \(project.kind.title)")
                            .font(.caption.bold())
                            .textCase(.uppercase)
                            .foregroundStyle(.white.opacity(0.7))
                        Text(displayName(for: project))
                            .font(.title.bold())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("上次打开：\(project.lastOpenedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))

                        HStack(spacing: 10) {
                            NavigationLink {
                                destination(for: project)
                            } label: {
                                Label("继续练习", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.white)
                            .foregroundStyle(Color(red: 0.10, green: 0.16, blue: 0.22))

                            NavigationLink {
                                recentProjectsPage
                            } label: {
                                Text("打开其他文件")
                            }
                            .buttonStyle(.bordered)
                            .tint(.white)
                        }
                    }

                    Spacer(minLength: 80)

                    ProjectPreviewThumbnail(url: url(for: project), kind: project.kind)
                }
                .padding(26)
            }
            .frame(minHeight: 210)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .shadow(color: .black.opacity(0.14), radius: 16, y: 8)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("选择一个练习模式开始", systemImage: "music.note")
                    .font(.title2.bold())
                Text("打开过文件后，这里会显示“继续练习”入口。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
            .padding(24)
            .cardSurface()
        }
    }

    private var startPracticeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("开始新的练习")
                    .font(.headline)
                Spacer()
                Text("自动打开上次有效文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                modeButton(for: .video)
                modeButton(for: .guitarPro)
                modeButton(for: .pdf)
            }
        }
        .padding(18)
        .cardSurface()
    }

    private var practiceSummaryCard: some View {
        let days = practiceHistory.calendarDays(weeks: 4)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("练习概览")
                    .font(.headline)
                Spacer()
                Text("最近一个月")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 24) {
                practiceMetric("今天", seconds: practiceHistory.seconds(on: Date()))
                practiceMetric("本周", seconds: practiceHistory.secondsThisWeek())
                practiceMetric("累计", seconds: practiceHistory.totalSeconds)
            }

            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(days) { day in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(practiceColor(for: day))
                        .frame(height: 12)
                        .overlay {
                            if Calendar.current.isDateInToday(day.date) {
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(.orange, lineWidth: 1.5)
                            }
                        }
                        .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue(formatPracticeDuration(day.seconds))
                }
            }
        }
        .padding(18)
        .cardSurface()
    }

    private var recentProjectsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近项目")
                    .font(.headline)
                Spacer()
                NavigationLink {
                    recentProjectsPage
                } label: {
                    Label("查看全部", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
            }

            ForEach(recentProjects.projects) { project in
                NavigationLink {
                    destination(for: project)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: iconName(for: project.kind))
                            .font(.title3)
                            .foregroundStyle(modeColor(for: project.kind))
                            .frame(width: 38, height: 38)
                            .background(
                                modeColor(for: project.kind).opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(displayName(for: project))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("\(project.kind.folderName) · \(project.lastOpenedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }

    private func modeButton(for kind: PracticeKind) -> some View {
        NavigationLink {
            modeDestination(for: kind)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: iconName(for: kind))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(modeColor(for: kind))
                    .frame(width: 42, height: 42)
                    .background(modeColor(for: kind).opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                Text(kind.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(modeDetail(for: kind))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
            .padding(12)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(.separator), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var recentProjectsPage: some View {
        List {
            ForEach(recentProjects.projects) { project in
                NavigationLink {
                    destination(for: project)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(displayName(for: project))
                            Text("\(project.kind.folderName) · \(project.lastOpenedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: iconName(for: project.kind))
                            .foregroundStyle(modeColor(for: project.kind))
                    }
                }
                .swipeActions {
                    Button("移除", role: .destructive) {
                        recentProjects.remove(kind: project.kind, fileName: project.fileName)
                    }
                }
            }
        }
        .navigationTitle("最近项目")
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
        guard !day.isFuture else { return Color(.quaternarySystemFill) }
        let minutes = day.seconds / 60
        if minutes == 0 { return Color(.quaternarySystemFill) }
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

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5 ..< 12: "上午好"
        case 12 ..< 18: "下午好"
        default: "晚上好"
        }
    }

    private var mostRecentProject: RecentProject? {
        recentProjects.projects.first { project in
            let url = url(for: project)
            return project.kind.supportedExtensions.contains(url.pathExtension.lowercased())
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private func url(for project: RecentProject) -> URL {
        RiffLoopDocumentStore()
            .folderURL(for: project.kind)
            .appendingPathComponent(project.fileName)
    }

    private func displayName(for project: RecentProject) -> String {
        displayNames.displayName(for: project.kind, fileName: project.fileName)
    }

    @ViewBuilder
    private func destination(for project: RecentProject) -> some View {
        let projectURL = url(for: project)
        switch project.kind {
        case .video:
            PracticeView(initialURL: projectURL)
        case .guitarPro:
            GpPracticeView(initialURL: projectURL)
        case .pdf:
            PdfPracticeView(initialURL: projectURL)
        }
    }

    @ViewBuilder
    private func modeDestination(for kind: PracticeKind) -> some View {
        switch kind {
        case .video:
            PracticeView(initialURL: nil)
        case .guitarPro:
            GpPracticeView(initialURL: nil)
        case .pdf:
            PdfPracticeView(initialURL: nil)
        }
    }

    private func iconName(for kind: PracticeKind) -> String {
        switch kind {
        case .video: "play.rectangle.fill"
        case .guitarPro: "music.note.list"
        case .pdf: "doc.richtext.fill"
        }
    }

    private func modeColor(for kind: PracticeKind) -> Color {
        switch kind {
        case .video: .blue
        case .guitarPro: .orange
        case .pdf: .red
        }
    }

    private func modeDetail(for kind: PracticeKind) -> String {
        switch kind {
        case .video: "节拍器 · A/B 循环"
        case .guitarPro: "音符跟谱 · 循环"
        case .pdf: "节拍器 · 自动跟谱"
        }
    }

    private var signingCompactTitle: String {
        guard let expirationDate = signingStatus.expirationDate else { return signingStatusTitle }
        let days = max(0, Int(ceil(expirationDate.timeIntervalSinceNow / (24 * 60 * 60))))
        switch signingStatus.kind {
        case .valid: return "签名有效 · \(days) 天"
        case .expiringSoon: return "签名剩 \(days) 天"
        case .expired: return "签名已过期"
        case .unavailable: return signingStatusTitle
        }
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
}

private extension View {
    func cardSurface() -> some View {
        background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color(.separator), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.05), radius: 12, y: 5)
    }
}

private struct PracticeCardBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.08, green: 0.14, blue: 0.20), Color(red: 0.17, green: 0.29, blue: 0.34)],
            startPoint: .leading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Canvas { context, size in
                // Quiet string-like arcs stay on the right, away from the title and actions.
                for index in 0..<6 {
                    var path = Path()
                    let offset = CGFloat(index) * 22
                    path.move(to: CGPoint(x: size.width * 0.45 + offset, y: size.height + 20))
                    path.addCurve(
                        to: CGPoint(x: size.width + 20, y: 20 + offset),
                        control1: CGPoint(x: size.width * 0.65, y: size.height * 0.25 + offset),
                        control2: CGPoint(x: size.width * 0.8, y: size.height * 0.85 - offset)
                    )
                    context.stroke(path, with: .color(.white.opacity(0.09)), lineWidth: 1)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ProjectPreviewThumbnail: View {
    let url: URL
    let kind: PracticeKind

    @State private var image: UIImage?

    var body: some View {
        Group {
            if kind == .guitarPro {
                GpCoverPreview(url: url)
                    .allowsHitTesting(false)
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: kind == .video ? .fit : .fill)
            } else {
                Image(systemName: fallbackIcon)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.12))
            }
        }
        .frame(width: 192, height: 128, alignment: .top)
        .background(.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .task(id: url) {
            image = nil
            guard kind != .guitarPro else { return }
            image = await projectOpeningPreview(at: url, kind: kind)
        }
        .accessibilityLabel("\(kind.title)预览")
    }

    private var fallbackIcon: String {
        switch kind {
        case .video: "play.rectangle.fill"
        case .guitarPro: "music.note.list"
        case .pdf: "doc.richtext.fill"
        }
    }
}

func projectOpeningPreview(at url: URL, kind: PracticeKind) async -> UIImage? {
    if kind == .video {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 768, height: 512)
        guard let result = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: result.image)
    }
    guard kind == .pdf, let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
    let bounds = page.bounds(for: .cropBox)
    guard bounds.width > 0, bounds.height > 0 else { return nil }
    // Keep the first page's title instead of centre-cropping a whole-page thumbnail.
    let size = CGSize(width: 768, height: 512)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: size))
        let scale = size.width / bounds.width
        context.cgContext.translateBy(x: 0, y: bounds.height * scale)
        context.cgContext.scaleBy(x: scale, y: -scale)
        context.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .cropBox, to: context.cgContext)
    }
}
