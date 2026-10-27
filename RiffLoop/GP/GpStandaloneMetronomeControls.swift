import SwiftUI

struct GpStandaloneMetronomeControls: View {
    @ObservedObject var viewModel: GpWebViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Button(action: viewModel.toggleStandaloneMetronome) {
                    Label(viewModel.isStandaloneMetronomePlaying ? "暂停" : "开始",
                          systemImage: viewModel.isStandaloneMetronomePlaying ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.playerReady)
                .accessibilityIdentifier("gp.standalone.play")

                TempoInputControl(bpm: Binding(
                    get: { viewModel.standaloneBpm }, set: { viewModel.setStandaloneBpm($0) }
                ), onChange: {})
                Stepper("每小节 \(viewModel.standaloneBeatsPerMeasure) 拍", value: Binding(
                    get: { viewModel.standaloneBeatsPerMeasure }, set: { viewModel.setStandaloneBeats($0) }
                ), in: 1...16)
                Picker("细分", selection: Binding(
                    get: { viewModel.standaloneSubdivisionFactor }, set: { viewModel.setStandaloneSubdivision($0) }
                )) {
                    Text("1 拍").tag(1)
                    Text("½ 拍").tag(2)
                    Text("¼ 拍").tag(4)
                    Text("⅛ 拍").tag(8)
                }
                .pickerStyle(.segmented)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: min(8, viewModel.standaloneBeatsPerMeasure)), spacing: 4) {
                    ForEach(viewModel.standaloneBeatAccents.indices, id: \.self) { index in
                        Button { viewModel.cycleStandaloneAccent(at: index) } label: {
                            VStack(spacing: 2) {
                                Text("\(index + 1)").font(.caption.monospacedDigit())
                                Text(viewModel.standaloneBeatAccents[index].label).font(.caption2)
                            }
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("独立节拍器第 \(index + 1) 拍，\(viewModel.standaloneBeatAccents[index].label)，点按切换强度")
                    }
                }
                HStack {
                    Image(systemName: "speaker.wave.2")
                    Slider(value: Binding(
                        get: { viewModel.standaloneVolume }, set: { viewModel.setStandaloneVolume($0) }
                    ), in: PracticeAudioVolume.range)
                    .accessibilityLabel("独立节拍音量")
                    Text("\(Int((viewModel.standaloneVolume * 100).rounded()))%")
                        .font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
                }
            }
            .padding(16)
        }
    }
}
