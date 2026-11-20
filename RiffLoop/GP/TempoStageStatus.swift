import SwiftUI

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
