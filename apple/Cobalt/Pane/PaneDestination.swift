import CobaltKit
import SwiftUI

/// Which page each `PaneItem` opens (apple/CONTRACT-PANE.md section 3). The switch is here; the pages are in
/// `Destinations/`, one file per area lane, so the lanes never edit a shared file:
///
///   PaneDestination+LibraryHome.swift            post, peek, selection, save
///   PaneDestination+LinksChat.swift              link, collection (chat opens what it made as `post`)
///   PaneDestination+SevenTvStudioBooru.swift     emote, emoteAddToSet, reward, poolVideo, booruPost, booruFilters
///   PaneDestination+TwitchSwarmsNamesQueue.swift stream, swarm, name, job
///
/// Every page function has the same shape: `@MainActor @ViewBuilder static func <case>(<payload>, model: AppModel,
/// pane: Pane) -> some View`. It is drawn inside the pane's `NavigationStack` with `\.paneShape` (and `\.paneHinge`
/// when split) set, under the pane's header. Anything else a page needs it reads from the environment or from
/// `pane.provided(_:)`.
struct PaneDestination: View {
    let item: PaneItem
    let model: AppModel
    @Environment(Pane.self) private var pane

    var body: some View {
        switch item {
        // library and home
        case .post(let id): Self.post(id, model: model, pane: pane)
        case .peek(let id): Self.peek(id, model: model, pane: pane)
        case .selection: Self.selection(model: model, pane: pane)
        case .save(let id): Self.save(id, model: model, pane: pane)
        // links and chat
        case .link(let id): Self.link(id, model: model, pane: pane)
        case .collection(let id): Self.collection(id, model: model, pane: pane)
        // 7tv, studio and booru
        case .emote(let id): Self.emote(id, model: model, pane: pane)
        case .emoteAddToSet(let id): Self.emoteAddToSet(id, model: model, pane: pane)
        case .reward(let id): Self.reward(id, model: model, pane: pane)
        case .poolVideo(let id): Self.poolVideo(id, model: model, pane: pane)
        case .booruPost(let id): Self.booruPost(id, model: model, pane: pane)
        case .booruFilters: Self.booruFilters(model: model, pane: pane)
        // twitch, swarms, names and the queue
        case .stream(let login): Self.stream(login, model: model, pane: pane)
        case .dualStream(let primary, let secondary): Self.dualStream(primary: primary, secondary: secondary, model: model, pane: pane)
        case .swarm(let id): Self.swarm(id, model: model, pane: pane)
        case .name(let id): Self.name(id, model: model, pane: pane)
        case .job(let id): Self.job(id, model: model, pane: pane)
        }
    }
}

/// The page of an area that has not moved into the pane yet: a `PanePage` titled with the item's kind.
struct PanePlaceholderPage: View {
    let item: PaneItem

    var body: some View {
        PanePage(title: item.kind, subtitle: Copy.Pane.notYet) {
            ZStack {
                Rectangle().fill(CobaltColor.surface)
                Image(systemName: Symbol.Pane.placeholder)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(CobaltColor.caption)
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
        } controls: {
            EmptyView()
        }
    }
}
