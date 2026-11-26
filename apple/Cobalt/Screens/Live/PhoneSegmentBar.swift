#if os(iOS)
import SwiftUI

/// The segmented picker under the bar of a hub screen (live, chat & swarms): one row, the system's own segmented control, a hair
/// line under it. The hub's content sits beneath it.
struct PhoneSegmentBar<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [Option]
    var identifier = "phone.segments"

    struct Option: Identifiable {
        let value: Value
        let title: String
        var a11y: String?
        var id: String { title }
    }

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(options) { option in
                Text(option.title).tag(option.value)
                    .accessibilityLabel(option.a11y ?? option.title)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier(identifier)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}
#endif
