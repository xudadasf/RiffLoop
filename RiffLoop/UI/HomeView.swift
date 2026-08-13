import SwiftUI

struct HomeView: View {
    var body: some View {
        NavigationStack {
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
                    subtitle: "离线 alphaTab 1.8.4 技术验证",
                    systemImage: "music.note.list"
                ) {
                    GpPracticeView()
                }

                practiceCard(
                    title: "PDF 谱面",
                    subtitle: "后续纵切迁移",
                    systemImage: "doc.richtext.fill"
                ) {
                    ContentUnavailableView("PDF 迁移中", systemImage: "hammer.fill")
                }
            }
            .padding(28)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("RiffLoop")
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
