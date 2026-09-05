import SwiftUI

struct PracticeVolumeControl: View {
    let title: String
    @Binding var value: Double
    var maximum: Double = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...maximum) { Text(title) }
            HStack {
                Text("上限 \(Int(maximum * 100))%")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("恢复 100%") { value = 1 }
                    .accessibilityLabel("\(title)恢复 100%")
            }
            .font(.caption)
        }
    }
}

extension View {
    func practiceSettingsGroup() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
