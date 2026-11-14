#if os(iOS)
import CobaltKit
import SwiftUI

/// iPhone's tab bar. The system's own "More" nests each tab's navigation stack inside its own, which drew a second back
/// button and an empty title row above 7tv, chat and the others. So on an iPhone with more than five tabs the bar holds the
/// first four and our "more" tab, whose content is ONE navigation stack: a list of the remaining tabs, each row pushing
/// that tab's bare screen (no stack of its own) into this stack, so a screen's own pushes (a 7tv set, a chat thread) land in
/// the same stack and the back button reads "more".
///
/// `model.selectedTab` stays the source of truth. A tab in the bar is selected by writing it; a tab behind "more" is
/// selected by pushing it onto `path` (the list row does it, or anything that writes `model.selectedTab`, through
/// `model.tabSets`, which counts every write, so a request for the tab that was already selected still pushes it).
struct PhoneTabs<Screen: View>: View {
    let model: AppModel
    /// The visible tabs in order, without the queue (a sheet on iPhone).
    let tabs: [AppTab]
    let glowSuppressed: Bool
    /// A tab's bare screen: no navigation stack around it (the library brings its own).
    @ViewBuilder let screen: (AppTab) -> Screen

    /// What the bar selects: one of its tabs, or "more".
    enum Slot: Hashable {
        case tab(AppTab)
        case more
    }

    /// Five tabs fit; with six or more the bar keeps four and "more".
    static func split(_ tabs: [AppTab]) -> (bar: [AppTab], overflow: [AppTab]) {
        tabs.count > 5 ? (Array(tabs.prefix(4)), Array(tabs.dropFirst(4))) : (tabs, [])
    }

    @State private var selection: Slot
    @State private var path: [AppTab]

    init(model: AppModel, tabs: [AppTab], glowSuppressed: Bool, @ViewBuilder screen: @escaping (AppTab) -> Screen) {
        self.model = model
        self.tabs = tabs
        self.glowSuppressed = glowSuppressed
        self.screen = screen
        let overflow = Self.split(tabs).overflow
        let tab = model.selectedTab
        _selection = State(initialValue: overflow.contains(tab) ? .more : .tab(tab))
        _path = State(initialValue: overflow.contains(tab) ? [tab] : [])
        #if DEBUG
        // `-previewMoreList 1` (simulator evidence): opens on the "more" tab's list, nothing pushed
        if UserDefaults.standard.bool(forKey: "previewMoreList"), !overflow.isEmpty {
            _selection = State(initialValue: .more)
            _path = State(initialValue: [])
        }
        #endif
    }

    private var bar: [AppTab] { Self.split(tabs).bar }
    private var overflow: [AppTab] { Self.split(tabs).overflow }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(bar, id: \.self) { tab in
                Tab(Copy.tab(tab), systemImage: icon(for: tab), value: Slot.tab(tab)) {
                    root(tab)
                }
            }
            if !overflow.isEmpty {
                Tab(Copy.more, systemImage: Symbol.moreTab, value: Slot.more) {
                    moreStack
                }
            }
        }
        .onChange(of: selection) { _, slot in
            switch slot {
            case .tab(let tab): model.selectedTab = tab
            case .more: if let shown = path.last { model.selectedTab = shown }
            }
        }
        .onChange(of: path) { _, now in
            if let shown = now.last { model.selectedTab = shown }
        }
        .onChange(of: model.tabSets) { _, _ in follow(model.selectedTab) }
    }

    /// Something wrote `model.selectedTab` (a deep link, a paste, the studio card, a launch argument): show it.
    private func follow(_ tab: AppTab) {
        if overflow.contains(tab) {
            if path != [tab] { path = [tab] }
            selection = .more
        } else if bar.contains(tab) {
            selection = .tab(tab)
        }
    }

    @ViewBuilder
    private func root(_ tab: AppTab) -> some View {
        Group {
            if tab == .library {
                screen(tab)
            } else {
                NavigationStack { screen(tab) }
            }
        }
        .syncGlow(model.library.syncStatus, suppressed: glowSuppressed)
    }

    private var moreStack: some View {
        NavigationStack(path: $path) {
            List(overflow, id: \.self) { tab in
                NavigationLink(value: tab) {
                    Label(Copy.tab(tab), systemImage: icon(for: tab))
                        .font(CobaltType.body)
                }
                .listRowBackground(CobaltColor.row)
            }
            .scrollContentBackground(.hidden)
            .background(CobaltColor.bg)
            .navigationTitle(Copy.more)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: AppTab.self) { tab in
                screen(tab)
            }
        }
        .syncGlow(model.library.syncStatus, suppressed: glowSuppressed)
    }
}
#endif
