import CobaltKit
import SwiftUI

/// The tabs above the hero (CONTRACT-MEDIA 1.9): `video`, then `webp 1`, `webp 2`... Shown only when the media has
/// two or more files. A native segmented `Picker` while the tabs fit (`maxSegments`: 4 on iPhone, 6 on iPad and
/// the Mac), else a horizontally scrolling chip row that keeps the selected chip in view. Accessibility sizes
/// take the chips too: a segmented control cannot hold words that large.
struct RenditionTabs: View {
    let item: MediaItem
    @Binding var selection: Rendition.ID
    var maxSegments = 4

    @Environment(\.dynamicTypeSize) private var typeSize

    private var names: [(rendition: Rendition, name: String)] {
        item.renditions.map { ($0, $0.tabName(of: item)) }
    }

    /// Whether this many tabs sit in a segmented control.
    static func isSegmented(count: Int, maxSegments: Int, accessibilitySize: Bool) -> Bool {
        count <= maxSegments && !accessibilitySize
    }

    var body: some View {
        let list = names
        if list.count >= 2 {
            Group {
                if Self.isSegmented(count: list.count, maxSegments: maxSegments, accessibilitySize: typeSize.isAccessibilitySize) {
                    segmented(list)
                } else {
                    chips(list)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Copy.Media.tabsA11y)
        }
    }

    private func segmented(_ list: [(rendition: Rendition, name: String)]) -> some View {
        Picker(Copy.Media.tabsA11y, selection: $selection) {
            ForEach(Array(list.enumerated()), id: \.element.rendition.id) { index, entry in
                Text(entry.name)
                    .tag(entry.rendition.id)
                    .accessibilityLabel(Copy.Media.tabA11y(entry.name, index + 1, of: list.count))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func chips(_ list: [(rendition: Rendition, name: String)]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(list.enumerated()), id: \.element.rendition.id) { index, entry in
                        chip(entry.rendition, name: entry.name, index: index, of: list.count)
                            .id(entry.rendition.id)
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollClipDisabled()
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, id in
                withAnimation(Motion.chip) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func chip(_ r: Rendition, name: String, index: Int, of count: Int) -> some View {
        let on = r.id == selection
        return Button {
            selection = r.id
        } label: {
            Label(name, systemImage: r.tabSymbol)
                .font(Font.cobalt(12, .medium, relativeTo: .footnote))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(on ? CobaltColor.onText : CobaltColor.text)
                .padding(.horizontal, 13)
                .frame(minHeight: 34)
                .background(on ? CobaltColor.text : CobaltColor.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? Color.clear : CobaltColor.hairline, lineWidth: 1))
                .padding(.vertical, 5)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.Media.tabA11y(name, index + 1, of: count))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
