import CobaltKit
import SwiftUI

/// The small pieces every settings section is built from (header, footer, a value row), shared by the sections that
/// used to be private to `SettingsScreen` and by the group pages that now hold them.
enum SettingsRows {
    static func header(_ text: String) -> some View {
        Text(text).font(CobaltType.caption).textCase(nil)
    }

    static func footer(_ text: String) -> some View {
        Text(text).font(CobaltType.captionSmall).lineSpacing(2)
    }

    static func problem(_ text: String) -> some View {
        Text(text).font(Font.cobalt(12.5)).foregroundStyle(CobaltColor.errorText)
    }

    static func value(_ text: String) -> some View {
        Text(text)
            .font(Font.cobalt(12.5))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
    }

    /// A settings row: icon first, the title, and the value on the trailing edge.
    static func row<V: View>(_ title: String, _ symbol: String, @ViewBuilder value: () -> V) -> some View {
        LabeledContent {
            value()
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

/// Icon first in a fixed-width column, so every row's title lines up (system Settings style).
struct SettingsRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.frame(width: 24)
            configuration.title
        }
    }
}
