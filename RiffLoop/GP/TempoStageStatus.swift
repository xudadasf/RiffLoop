import SwiftUI

/// Choosing a stage prepares a new start; the transport's Play button still owns playback.
struct TempoStageStartMenu: View {
    @ObservedObject var viewModel: GpWebViewModel
    let transport: TempoStageTransport
    let identifier: String

    private var plan: TempoStagePlan {
        transport == .gp ? viewModel.gpStages : viewModel.standaloneStages
    }

    var body: some View {
        Menu {
            ForEach(Array(plan.stages.enumerated()), id: \.element.id) { index, stage in
                Button {
                    viewModel.selectStage(index, for: transport)
                } label: {
                    let length = stage.unit == .loops ? "\(stage.length) 轮" : "\(stage.length) 秒"
                    let title = "阶段 \(index + 1) · \(stage.bpm) BPM · \(length)"
                    if viewModel.stageReadout(for: transport).index == index {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
                .accessibilityIdentifier("stages.select.\(transport == .gp ? "gp" : "standalone").\(index + 1)")
            }
        } label: {
            HStack(spacing: 4) {
                Text("选阶段")
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(minWidth: 76, minHeight: 44)
            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(!viewModel.canSelectStage(for: transport))
        .accessibilityLabel("选择起始阶段")
        .accessibilityValue("阶段 \(viewModel.stageReadout(for: transport).index + 1)")
        .accessibilityHint("暂停后选择，下次播放从该阶段重新开始")
        .accessibilityIdentifier(identifier)
    }
}

struct TempoStageStatus: View {
    @ObservedObject var viewModel: GpWebViewModel
    let transport: TempoStageTransport
    var identifyStandalone = false

    private var needsTicks: Bool {
        switch transport {
        case .gp: return viewModel.gpProgress.clockRunning && viewModel.gpStages.stages[viewModel.gpProgress.index].unit == .seconds
        case .standalone: return viewModel.isStandaloneMetronomePlaying
        }
    }

    private var label: some View {
        let prefix = identifyStandalone && transport == .standalone ? "节拍器 · " : ""
        return Text(prefix + viewModel.stageReadout(for: transport).summary(for: transport))
            .monospacedDigit()
            .lineLimit(2)
    }

    var body: some View {
        if needsTicks {
            // Refresh just the text; the playback clock and the audio scheduler own all timing.
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in label }
        } else {
            label
        }
    }
}
