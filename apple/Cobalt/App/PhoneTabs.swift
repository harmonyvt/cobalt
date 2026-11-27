#if os(iOS)
import CobaltKit
import SwiftUI

/// The iPhone's tab bar (apple 04-PHASE4 4.1): four tabs, no "more". capture (the save screen), library, live (the OBS stage,
/// twitch and 7tv under one picker) and tools (a list of the rest). Every root screen has the activity pill and the settings
/// gear in its bar; settings is a sheet over whichever tab is up.
///
/// `model.selectedTab` stays the one answer to "which screen is in front" (the studio's polling, the library's hidden album,
/// the home screen's pastes read it), so it is kept true: `PhoneNavState.active` is the screen really showing (a live segment, the
/// row the tools tab has pushed, the tools list itself) and is written into `selectedTab` the moment it changes. The other
/// way round, anything that writes `selectedTab` (a deep link, a paste, a launch argument) moves the tabs there
/// (`PhoneNavState.show`), counted by `model.tabSets` so a request for the screen that is already selected still lands.
struct PhoneTabs<Screen: View>: View {
    let model: AppModel
    /// A screen's bare content: no navigation stack around it (the library brings its own). The shell's `tabScreen`.
    @ViewBuilder let screen: (AppTab) -> Screen

    @State private var nav: PhoneNavState
    @Environment(\.shell) private var shell
    @Environment(Pane.self) private var pane: Pane?

    init(model: AppModel, @ViewBuilder screen: @escaping (AppTab) -> Screen) {
        self.model = model
        self.screen = screen
        let nav = PhoneNavState()
        nav.show(model.selectedTab)
        #if DEBUG
        DebugHooks.applyPhonePreviewTab(to: nav)
        #endif
        _nav = State(initialValue: nav)
    }

    private var slots: [PhoneSlot] { PhoneNavState.slots(for: model) }

    var body: some View {
        @Bindable var nav = nav
        TabView(selection: $nav.slot) {
            ForEach(slots, id: \.self) { slot in
                Tab(slot.title, systemImage: slot.symbol, value: slot) {
                    root(slot)
                }
                .badge(slot == .tools ? model.swarms.waitingCount : 0)
            }
        }
        .environment(nav)
        // a running item in the screen pane closes to a bar over the tabs (apple/CONTRACT-PANE.md; `PaneHost` wraps this)
        .modifier(PaneBarAccessory(model: model))
        .sheet(isPresented: $nav.settingsShown) { settingsSheet }
        // the screen that shows is what `selectedTab` says: written the moment it changes (the old "more" left it stale)
        .onChange(of: nav.active, initial: true) { _, active in
            #if DEBUG
            DebugHooks.log("phone.active=\(active.rawValue) slot=\(nav.slot.rawValue)")      // `-debugHooks 1`
            #endif
            if model.selectedTab != active { model.selectedTab = active }
        }
        // something wrote `selectedTab` (a deep link, a paste, the studio card, a launch argument): show it
        .onChange(of: model.tabSets) { _, _ in follow(model.selectedTab) }
        // the server lost a screen under the tab it was on
        .onChange(of: model.capabilities) { _, _ in nav.settle(with: model) }
    }

    private func follow(_ tab: AppTab) {
        // the queue is a sheet: `QueueTabRedirect` opens it and selects capture
        guard tab != .queue, tab != nav.active || tab == .settings else { return }
        nav.show(tab)
        // settings opened as a sheet leaves the tab where it was: `selectedTab` says so again
        if model.selectedTab != nav.active { model.selectedTab = nav.active }
    }

    // MARK: the four roots

    @ViewBuilder
    private func root(_ slot: PhoneSlot) -> some View {
        switch slot {
        case .capture:
            NavigationStack {
                screen(.save)
                    // the home screen's own `QueueToolbarItem` goes quiet: the pill and the gear are the shell's, in that order
                    .environment(\.phoneHeaderOwnsActivity, true)
                    .toolbar { PhoneRootToolbar(model: model) }
            }
        case .library:
            // the library brings its own stack and ends its bar with `PhoneRootToolbar` (pill, gear)
            screen(.library)
        case .live:
            NavigationStack {
                LiveScreen(model: model) { segment in screen(segment.tab) }
            }
        case .tools:
            @Bindable var nav = nav
            NavigationStack(path: $nav.path) {
                ToolsScreen(model: model)
                    .navigationDestination(for: ToolsDestination.self) { destination in
                        toolsScreen(destination)
                    }
            }
        }
    }

    @ViewBuilder
    private func toolsScreen(_ destination: ToolsDestination) -> some View {
        switch destination {
        case .links: screen(.links)
        case .assistants: AssistantsScreen(model: model) { half in screen(half.tab) }
        case .editor: ToolsEditsScreen(model: model)
        case .booru: screen(.booru)
        case .names: screen(.names)
        }
    }

    // MARK: settings

    /// The settings sheet: the whole screen in a large sheet, closed with the unified circular `<` back button.
    private var settingsSheet: some View {
        CobaltSettingsSheet(model: model, shell: shell, pane: pane) {
            nav.settingsShown = false
        }
    }
}

/// Shared Settings modal sheet for compact iPhone (`PhoneTabs`) and iPhone Duo (`RegularFourTabs`),
/// using the unified Spotify-style circular Liquid Glass `<` back button below the Duo status circle.
struct CobaltSettingsSheet: View {
    let model: AppModel
    let shell: ShellActions
    let pane: Pane?
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            SettingsScreen(model: model)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    CobaltBackToolbarItem(
                        title: Copy.PhoneNav.done,
                        accessibilityIdentifier: "phone.settings.done",
                        cancels: true,
                        action: onClose
                    )
                }
        }
        .presentationDetents([.large])
        .cobaltRoot(model: model)
        .environment(\.shell, shell)
        .coversPane(pane)
    }
}
#endif
