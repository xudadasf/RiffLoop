import AVKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct PracticeView: View {
    @StateObject private var viewModel = PracticeViewModel()
    @State private var isImporterPresented = false
    @State private var scrubTime: TimeInterval = 0
    @State private var isScrubbing = false

    private let rates: [Float] = [0.25, 0.5, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5]

    var body: some View {
        VStack(spacing: 14) {
            videoArea
            timeline
            transportControls
            loopControls
            metronomeControls
        }
        .padding(18)
        .background(Color.black.ignoresSafeArea())
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.mpeg4Movie],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                viewModel.importMedia(from: url)
            }
        }
        .alert(
            "RiffLoop",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.dismissError() } }
            )
        ) {
            Button("好", role: .cancel) { viewModel.dismissError() }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onChange(of: viewModel.currentTime) { _, newValue in
            if !isScrubbing {
                scrubTime = newValue
            }
        }
    }

    private var videoArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.08))

            if viewModel.hasMedia {
                VideoPlayer(player: viewModel.player)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 48))
                    Text("导入一个 MP4 开始技术验证")
                        .font(.title2.weight(.semibold))
                    Button("从 Files 导入 MP4") {
                        isImporterPresented = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
    }

    private var timeline: some View {
        HStack(spacing: 12) {
            Text(formatTime(isScrubbing ? scrubTime : viewModel.currentTime))
                .monospacedDigit()
                .frame(width: 82, alignment: .leading)

            Slider(
                value: $scrubTime,
                in: 0...max(viewModel.duration, 0.01),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        viewModel.seek(to: scrubTime)
                    }
                }
            )
            .disabled(!viewModel.hasMedia)

            Text(formatTime(viewModel.duration))
                .monospacedDigit()
                .frame(width: 82, alignment: .trailing)
        }
        .font(.headline)
    }

    private var transportControls: some View {
        HStack(spacing: 16) {
            Button("导入") { isImporterPresented = true }
                .buttonStyle(.bordered)

            Button { viewModel.skip(by: -10) } label: {
                Label("后退 10 秒", systemImage: "gobackward.10")
                    .labelStyle(.iconOnly)
            }

            Button { viewModel.skip(by: -5) } label: {
                Label("后退 5 秒", systemImage: "gobackward.5")
                    .labelStyle(.iconOnly)
            }

            Button(action: viewModel.togglePlayback) {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 58, height: 34)
            }
            .buttonStyle(.borderedProminent)

            Button { viewModel.skip(by: 5) } label: {
                Label("前进 5 秒", systemImage: "goforward.5")
                    .labelStyle(.iconOnly)
            }

            Button { viewModel.skip(by: 10) } label: {
                Label("前进 10 秒", systemImage: "goforward.10")
                    .labelStyle(.iconOnly)
            }

            Picker("速度", selection: Binding(
                get: { viewModel.playbackRate },
                set: { viewModel.setPlaybackRate($0) }
            )) {
                ForEach(rates, id: \.self) { rate in
                    Text(rateLabel(rate)).tag(rate)
                }
            }
            .pickerStyle(.menu)
        }
        .font(.title3.weight(.semibold))
        .disabled(!viewModel.hasMedia)
    }

    private var loopControls: some View {
        HStack(spacing: 14) {
            valueCard(title: "A", value: viewModel.pointA)
            Button("Set A") { viewModel.setPointA() }
                .buttonStyle(.bordered)

            valueCard(title: "B", value: viewModel.pointB)
            Button("Set B") { viewModel.setPointB() }
                .buttonStyle(.bordered)

            Toggle("Loop", isOn: Binding(
                get: { viewModel.loopEnabled },
                set: { viewModel.setLoopEnabled($0) }
            ))
            .toggleStyle(.button)
            .tint(.orange)
        }
        .controlSize(.large)
        .disabled(!viewModel.hasMedia)
    }

    private var metronomeControls: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Text("BPM")
                TextField("120", value: $viewModel.bpm, format: .number.precision(.fractionLength(0)))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit { viewModel.applyTimingSettings() }

                Stepper("", value: $viewModel.bpm, in: 30...300, step: 1)
                    .labelsHidden()
                    .onChange(of: viewModel.bpm) { _, _ in
                        viewModel.applyTimingSettings()
                    }
            }

            Picker("细分", selection: $viewModel.subdivision) {
                ForEach(Subdivision.allCases) { subdivision in
                    Text(subdivision.rawValue).tag(subdivision)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: viewModel.subdivision) { _, _ in
                viewModel.applyTimingSettings()
            }

            Toggle("Metronome", isOn: $viewModel.metronomeEnabled)
                .toggleStyle(.button)
                .tint(.green)
                .onChange(of: viewModel.metronomeEnabled) { _, _ in
                    viewModel.applyTimingSettings()
                }

            Button("Set Beat 1") { viewModel.setBeatOne() }
                .buttonStyle(.borderedProminent)

            VStack(alignment: .leading, spacing: 2) {
                Text("Beat 1")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(viewModel.beatOffset.map(formatTime) ?? "未设置")
                    .monospacedDigit()
            }
            .frame(minWidth: 100, alignment: .leading)
        }
        .font(.headline)
        .controlSize(.large)
        .disabled(!viewModel.hasMedia)
    }

    private func valueCard(title: String, value: TimeInterval?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.map(formatTime) ?? "--:--.---")
                .monospacedDigit()
        }
        .frame(minWidth: 108, alignment: .leading)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00.000" }
        let totalMilliseconds = Int((seconds * 1_000).rounded())
        let minutes = totalMilliseconds / 60_000
        let wholeSeconds = (totalMilliseconds / 1_000) % 60
        let milliseconds = totalMilliseconds % 1_000
        return String(format: "%02d:%02d.%03d", minutes, wholeSeconds, milliseconds)
    }

    private func rateLabel(_ rate: Float) -> String {
        String(format: "%.2g×", rate)
    }
}

#Preview("iPad Landscape") {
    PracticeView()
        .frame(width: 1_180, height: 820)
}
