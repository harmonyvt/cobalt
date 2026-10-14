import SwiftUI

/// Letters for a 7TV search. They go into the pill, never into the app behind the keyboard.
struct KeyboardKeys: View {
    let type: (String) -> Void
    let backspace: () -> Void

    private static let rows = ["1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm"]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(Self.rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 4) {
                    ForEach(Array(row), id: \.self) { letter in
                        key(String(letter)) { type(String(letter)) }
                    }
                    if index == Self.rows.count - 1 {
                        key("delete") { backspace() }
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    private func key(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title == "delete" ? "⌫" : title)
                .font(Font.cobalt(title == "delete" ? 16 : 15))
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(CobaltColor.elevated))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
