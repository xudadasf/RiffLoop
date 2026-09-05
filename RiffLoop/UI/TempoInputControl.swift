import SwiftUI

/// Editing is a draft: only a complete, in-range integer reaches the audio engine.
struct TempoDraft: Equatable {
    var text: String
    var replacesOnNextDigit = true
    var pasteRejected = false

    init(value: Double) {
        text = String(Int(value.isFinite ? min(max(value.rounded(), 30), 300) : 120))
    }

    var value: Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(text), (30...300).contains(number) else { return nil }
        return number
    }

    mutating func digit(_ digit: Int) {
        guard (0...9).contains(digit) else { return }
        if replacesOnNextDigit { text = ""; replacesOnNextDigit = false }
        guard text.count < 3 else { return }
        text += String(digit)
        pasteRejected = false
    }

    mutating func delete() {
        if !text.isEmpty { text.removeLast() }
        replacesOnNextDigit = false
        pasteRejected = false
    }

    mutating func clear() {
        text = ""
        replacesOnNextDigit = false
        pasteRejected = false
    }

    mutating func paste(_ string: String) {
        let candidate = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.count <= 3,
              candidate.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(candidate), (30...300).contains(number) else {
            pasteRejected = true
            return
        }
        text = String(number)
        replacesOnNextDigit = true
        pasteRejected = false
    }
}

struct TempoInputControl: View {
    @Binding var bpm: Double
    var onChange: () -> Void
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 8) {
            Text("BPM")
            Button { isEditing = true } label: {
                Text(TempoDraft(value: bpm).text)
                    .font(.body.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 64, minHeight: 44)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("输入节拍速度")
            .accessibilityValue("\(TempoDraft(value: bpm).text) BPM")
            .popover(isPresented: $isEditing) {
                TempoKeypad(value: bpm) { number in
                    bpm = Double(number)
                    onChange()
                    isEditing = false
                } cancel: { isEditing = false }
                .presentationCompactAdaptation(.popover)
            }
            Stepper("调整 BPM", value: Binding(
                get: { bpm },
                set: { bpm = $0; onChange() }
            ), in: 30...300, step: 1)
            .labelsHidden()
        }
    }
}

struct TempoKeypad: View {
    @State private var draft: TempoDraft
    @FocusState private var hasKeyboardFocus: Bool
    let apply: (Int) -> Void
    let cancel: () -> Void

    init(value: Double, apply: @escaping (Int) -> Void, cancel: @escaping () -> Void) {
        _draft = State(initialValue: TempoDraft(value: value))
        self.apply = apply
        self.cancel = cancel
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("节拍速度").font(.headline)
                Spacer()
                Button("取消", action: cancel)
            }
            Text(draft.text.isEmpty ? "—" : draft.text)
                .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                .frame(maxWidth: .infinity, minHeight: 48)
                .accessibilityLabel("待输入速度")
            Text(draft.pasteRejected ? "请输入 30–300 的整数" : "30–300 BPM · 输入后点应用")
                .font(.caption)
                .foregroundStyle(draft.pasteRejected ? Color.orange : .secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(1...9, id: \.self) { number in digitButton(number) }
                Button { draft.clear() } label: {
                    Text("清空").frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                }
                digitButton(0)
                Button { draft.delete() } label: {
                    Image(systemName: "delete.left").frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                }.accessibilityLabel("删除一位")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            HStack {
                PasteButton(payloadType: String.self) { values in
                    if let text = values.first { draft.paste(text) }
                }
                Spacer()
                Button("应用") { if let value = draft.value { apply(value) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.value == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 300)
        .background(Color(.secondarySystemGroupedBackground))
        .focusable()
        .focused($hasKeyboardFocus)
        .focusEffectDisabled()
        .onAppear { hasKeyboardFocus = true }
        .onKeyPress(characters: .decimalDigits) { press in
            guard press.characters.utf8.count == 1, let digit = Int(press.characters) else { return .ignored }
            draft.digit(digit)
            return .handled
        }
        .onKeyPress(.delete) { draft.delete(); return .handled }
    }

    private func digitButton(_ number: Int) -> some View {
        Button { draft.digit(number) } label: {
            Text("\(number)")
                .font(.title2.monospacedDigit())
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
