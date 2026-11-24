#if os(iOS)
import CobaltKit
import SwiftUI

/// The tools tab's list (apple 04-PHASE4 4.1): the secondary workspaces, grouped, each row pushing its screen onto the tab's
/// one navigation stack (`PhoneNavState.path`). A row shows only where the server has the screen. The swarms that wait for the owner
/// are counted on the "chat & swarms" row and on the tab itself.
struct ToolsScreen: View {
    let model: AppModel

    var body: some View {
        List {
            if ToolsDestination.links.isAvailable(model) {
                Section(Copy.PhoneNav.sectionShare) {
                    row(.links, title: Copy.PhoneNav.toolsLinks, note: Copy.PhoneNav.toolsLinksNote, symbol: Symbol.links)
                }
            }
            if ToolsDestination.assistants.isAvailable(model) {
                Section(Copy.PhoneNav.sectionAssistants) {
                    row(
                        .assistants, title: Copy.PhoneNav.toolsAssistants, note: Copy.PhoneNav.toolsAssistantsNote, symbol: Symbol.chat,
                        badge: model.swarms.waitingCount)
                }
            }
            if ToolsDestination.editor.isAvailable(model) {
                Section(Copy.PhoneNav.sectionMake) {
                    row(.editor, title: Copy.PhoneNav.toolsEditor, note: Copy.PhoneNav.toolsEditorNote, symbol: Symbol.PhoneNav.editor)
                }
            }
            if ToolsDestination.booru.isAvailable(model) || ToolsDestination.names.isAvailable(model) {
                Section(Copy.PhoneNav.sectionFind) {
                    if ToolsDestination.booru.isAvailable(model) {
                        row(.booru, title: Copy.PhoneNav.toolsBooru, note: Copy.PhoneNav.toolsBooruNote, symbol: Symbol.Booru.tab)
                    }
                    if ToolsDestination.names.isAvailable(model) {
                        row(.names, title: Copy.PhoneNav.toolsNames, note: Copy.PhoneNav.toolsNamesNote, symbol: Symbol.Names.menu)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CobaltColor.bg)
        .navigationTitle(Copy.PhoneNav.tools)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { PhoneRootToolbar(model: model) }
        .task { if model.editor.isAvailable { await model.editor.refresh() } }
    }

    private func row(_ destination: ToolsDestination, title: String, note: String, symbol: String, badge: Int = 0) -> some View {
        NavigationLink(value: destination) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(CobaltColor.text)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(CobaltType.body).foregroundStyle(CobaltColor.text)
                    Text(note).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
                }
            }
            .padding(.vertical, 2)
        }
        .badge(badge)
        .listRowBackground(CobaltColor.row)
        .accessibilityIdentifier("tools.row.\(destination.rawValue)")
    }
}

/// The tools row "chat & swarms": chat and the swarms under one toggle, the one last open first. With only one of the two on
/// the server it is that screen alone, no toggle. The swarms that wait are counted in the toggle's word.
struct AssistantsScreen<Content: View>: View {
    let model: AppModel
    @Environment(PhoneNavState.self) private var nav: PhoneNavState?
    /// The screen of a half (`AppShell.tabScreen`).
    @ViewBuilder let half: (AssistantSegment) -> Content

    private var halves: [AssistantSegment] {
        AssistantSegment.allCases.filter { $0.tab.isAvailable(with: model.capabilities) }
    }

    var body: some View {
        let available = halves
        let current = available.contains(nav?.assistants ?? .chat) ? (nav?.assistants ?? .chat) : (available.first ?? .chat)
        VStack(spacing: 0) {
            if available.count > 1 {
                PhoneSegmentBar(
                    label: Copy.PhoneNav.assistantSegments,
                    selection: Binding(get: { current }, set: { nav?.assistants = $0 }),
                    options: available.map { segment in
                        let waiting = model.swarms.waitingCount
                        switch segment {
                        case .chat: return .init(value: segment, title: Copy.PhoneNav.assistantChat)
                        case .swarms:
                            return .init(
                                value: segment,
                                title: waiting > 0 ? Copy.PhoneNav.swarmsWaiting(waiting) : Copy.PhoneNav.assistantSwarms,
                                a11y: waiting > 0 ? Copy.PhoneNav.swarmsWaitingA11y(waiting) : nil)
                        }
                    },
                    identifier: "tools.assistants.segments")
            }
            half(current)
                .id(current)
        }
        .background(CobaltColor.bg)
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
