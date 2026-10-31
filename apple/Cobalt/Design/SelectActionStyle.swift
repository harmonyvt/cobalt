import SwiftUI

/// The select panel's action row (library, bottom): one icon button per action, all the same capsule and height,
/// each tinted for what it does. `link` is the main one (solid, the same ink as the `select` pill), `collection` is
/// the collection amber, `edit` the editor violet, `share` the shared blue, `status` (`status…` and `unhide`,
/// APP-API-CONTRACT 37.7) the plain ink on the elevated grey, `addLink` (`add to link`, APP-API-CONTRACT 41.4) the focus
/// blue. A plain style on purpose: the glass styles drew some of
/// them as light slabs, some dark, and a `Menu` label not at all.
struct SelectActionStyle: ButtonStyle {
    enum Tone { case link, collection, edit, share, status, addLink }

    let tone: Tone
    @Environment(\.isEnabled) private var isEnabled

    static let height: CGFloat = 48

    private var ink: Color {
        switch tone {
        case .link: CobaltColor.onText
        case .collection: CobaltColor.collection
        case .edit: CobaltColor.collectionSet
        case .share: CobaltColor.linkBlue
        case .status: CobaltColor.text
        case .addLink: CobaltColor.focus
        }
    }

    private var fill: Color {
        switch tone {
        case .link: CobaltColor.text
        case .collection: CobaltColor.collectionBack
        case .edit: CobaltColor.collectionSetBack
        case .share: CobaltColor.linkBlue.opacity(0.16)
        case .status: CobaltColor.elevated
        case .addLink: CobaltColor.focus.opacity(0.14)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // on the label: a Label inside keeps its title for VoiceOver and shows only its icon
            .labelStyle(.iconOnly)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, minHeight: Self.height)
            .background(fill, in: Capsule())
            .overlay(Capsule().strokeBorder(ink.opacity(tone == .link ? 0 : 0.22), lineWidth: 1))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.38)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .haptic(.impact(weight: .light, intensity: 0.7), trigger: configuration.isPressed, when: { $0 })
    }
}

extension ButtonStyle where Self == SelectActionStyle {
    static func selectAction(_ tone: SelectActionStyle.Tone) -> SelectActionStyle { SelectActionStyle(tone: tone) }
}
