import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var recentProjects: RecentProjectsStore

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
                        ContentUnavailableView("PDF 迁移中", systemImage: "hammer.fill")
                    }
                }

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
        }
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
            ContentUnavailableView("PDF 迁移中", systemImage: "hammer.fill")
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
