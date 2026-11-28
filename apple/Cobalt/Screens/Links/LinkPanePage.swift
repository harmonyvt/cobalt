import CobaltKit
import SwiftUI

// A gallery link in the screen pane (apple/CONTRACT-PANE.md section 5, `PaneItem.link`). Opened from a card in the links
// tab, a collection's page or the library's "added to" toast. The hero is the link's files as tiles (2x2 beside the tab;
// spanned over two screens, every file fills the media screen), the big buttons copy, edit (pushes the editor, `LinkScreen`),
// make private / public and revoke, the body is the numbered files (a tap opens the post in the pane), and the shelf holds
// "how discord shows it" and the link's collections. Share is the address row's own `ShareLink` (the system share sheet).
// Nothing here keeps running: closing hides the pane.

struct LinkPanePage: View {
    let model: AppModel
    let id: String

    @Environment(Pane.self) private var pane
    @Environment(\.shell) private var shell
    @State private var controller: LinksController
    /// The editor is pushed on the pane's own stack.
    @State private var editing = false
    /// Whether `?audio=normal` is selected for copying/sharing (strictly gated by `AudioShareGate.status == .unlocked`).
    @State private var useNormalAudio = false
    /// Set when the owner starts leveling from this pane so `?audio=normal` switches on automatically once unlocked.
    @State private var autoUnlockPending = false

    init(model: AppModel, id: String) {
        self.model = model
        self.id = id
        _controller = State(initialValue: LinksController(model: model))
    }

    private var store: ShareSetStore { model.shareSets }
    private var link: ShareSet? { store.set(id) }
    private var audioEnabled: Bool { model.capabilities.audioLeveling }

    var body: some View {
        let gate = link.map { controller.audioGate(for: $0) }
        Group {
            if let link, let gate {
                page(link, gate: gate)
            } else if case .failed = store.state {
                PaneGonePage(message: Copy.LinksPane.cantLoad)
            } else if store.state == .loaded {
                PaneGonePage()
            } else {
                PaneLoadingPage()
            }
        }
        .task {
            if store.sets.isEmpty { await store.refresh() }
            if audioEnabled, !model.audioLeveling.loaded {
                await model.audioLeveling.load()
            }
        }
        .onChange(of: id) { _, _ in
            useNormalAudio = false
            autoUnlockPending = false
        }
        .onChange(of: gate?.status) { _, status in
            if status != .unlocked {
                useNormalAudio = false
            } else if autoUnlockPending {
                autoUnlockPending = false
                withAnimation(Motion.chip) { useNormalAudio = true }
                shell.showStatus(Copy.AudioBulk.unlockedAuto)
                controller.doneToken += 1
            }
        }
        // revoked here or elsewhere: nothing left to show, so the pane hides
        .onChange(of: link == nil) { _, gone in
            if gone, store.state == .loaded { pane.close() }
        }
        .navigationDestination(isPresented: $editing) {
            LinkScreen(model: model, setID: id, startsEditing: true)
        }
        .linkPresentations(controller)
    }

    // MARK: the page

    private func page(_ link: ShareSet, gate: AudioShareGate) -> some View {
        let audioStore = model.audioLeveling
        let entries = LinkFileEntry.entries(
            link.items.map(\.id),
            link: link,
            lookup: LinkFileLookup(model: model),
            audioFor: { id, fallback in audioStore.optimisticAudio(for: id, fallback: fallback) }
        )
        let activeURL = audioEnabled ? gate.resolveURL(base: link.url, useNormal: useNormalAudio) : link.url
        return PanePage(
            title: link.displayTitle, subtitle: subtitle(link), more: moreActions(link)
        ) {
            LinkPaneHero(entries: entries, model: model)
                .draggable(activeURL)
        } controls: {
            LinkPaneControls(
                link: link,
                gate: gate,
                audioEnabled: audioEnabled,
                target: model.audioLeveling.settings.target,
                useNormalAudio: $useNormalAudio,
                activeURL: activeURL,
                isSubmitting: controller.levelingBulk,
                isCopied: controller.copiedID == link.id,
                onCopy: {
                    if audioEnabled {
                        controller.copy(link, gate: gate, useNormal: useNormalAudio, shell: shell)
                    } else {
                        controller.copy(link, shell: shell)
                    }
                },
                onLevelRemaining: {
                    autoUnlockPending = true
                    controller.levelBulk(link: link, shell: shell)
                },
                onBlockedTap: {
                    controller.blockedAudioTap(gate: gate, shell: shell)
                },
                actions: stripActions(link)
            )
        } body: {
            LinkPaneBody(
                link: link,
                entries: entries,
                model: model,
                controller: controller,
                onLevelSingle: { fileID in
                    autoUnlockPending = true
                    controller.levelSingle(fileID: fileID, linkID: link.id, shell: shell)
                }
            )
        } shelf: {
            PaneCard(Copy.LinkEdit.discordSection) {
                LinkDiscordPreview(heading: heading(link), entries: entries.filter(\.shows), model: model)
            }
            if controller.collectionsEnabled {
                PaneCard(Copy.LinksPane.collectionsCard) { LinkPaneCollections(link: link, controller: controller) }
            }
        }
    }

    private func subtitle(_ link: ShareSet) -> String {
        let privacy = controller.privateLinksEnabled
            ? (link.isPrivate ? Copy.PrivateLinks.badgePrivate : Copy.PrivateLinks.badgePublic) : nil
        return Copy.LinksPane.subtitle(
            files: link.items.count, privacy: privacy, when: Format.when(link.createdAt, now: Date()))
    }

    /// The discord preview's heading: the link's title, else "the ai caption".
    private func heading(_ link: ShareSet) -> String {
        if let title = link.title, !title.isEmpty { return title }
        return Copy.LinkEdit.captionTitle
    }

    private func stripActions(_ link: ShareSet) -> [PaneAction] {
        var actions: [PaneAction] = []
        if model.capabilities.shareSetEdit {
            actions.append(PaneAction(Copy.LinkEdit.edit, systemImage: "pencil", needsServer: true) { editing = true })
        }
        if controller.privateLinksEnabled {
            if link.isPrivate {
                actions.append(PaneAction(
                    Copy.PrivateLinks.makePublic, systemImage: Symbol.PrivateLinks.makePublic, needsServer: true
                ) { controller.makingPublic = link })
                actions.append(PaneAction(
                    Copy.PrivateLinks.rotateKey, systemImage: Symbol.PrivateLinks.rotate, needsServer: true
                ) { controller.rotatingKey = link })
            } else {
                actions.append(PaneAction(
                    Copy.PrivateLinks.makePrivate, systemImage: Symbol.PrivateLinks.makePrivate, needsServer: true
                ) { controller.makePrivate(link, shell: shell) })
            }
        }
        actions.append(PaneAction(
            Copy.Links.revoke, systemImage: Symbol.revokeLink, role: .destructive, needsServer: true
        ) { controller.revoking = link })
        return actions
    }

    private func moreActions(_ link: ShareSet) -> [PaneAction] {
        var actions: [PaneAction] = []
        if controller.privateLinksEnabled, link.isPrivate {
            actions.append(PaneAction(
                Copy.PrivateLinks.rotateKey, systemImage: Symbol.PrivateLinks.rotate, needsServer: true
            ) { controller.rotatingKey = link })
        }
        if controller.collectionsEnabled {
            actions.append(PaneAction(
                Copy.Collections.newEllipsis, systemImage: Symbol.collectionNew, needsServer: true
            ) { controller.newCollection(including: link) })
        }
        return actions
    }
}

// MARK: - the controls (Unified Liquid Glass Share Deck + Compact Glassy Action Strip)

/// Unified Liquid Glass Share Deck (copy, `?audio=normal` hard gate, 1-tap bulk level, live URL + share)
/// paired with a compact 1-row glassy action strip (`edit`, `private`, `rotate`, `revoke`).
/// Hidden in the bar (a link never runs, so the bar never shows it).
private struct LinkPaneControls: View {
    let link: ShareSet
    let gate: AudioShareGate
    let audioEnabled: Bool
    let target: AudioTargetLufs
    @Binding var useNormalAudio: Bool
    let activeURL: URL
    let isSubmitting: Bool
    let isCopied: Bool
    let onCopy: () -> Void
    let onLevelRemaining: () -> Void
    let onBlockedTap: () -> Void
    let actions: [PaneAction]

    @Environment(\.paneShape) private var shape

    var body: some View {
        if shape != .bar {
            VStack(alignment: .leading, spacing: 10) {
                if audioEnabled {
                    LinkAudioDock(
                        link: link,
                        gate: gate,
                        target: target,
                        useNormalAudio: $useNormalAudio,
                        activeURL: activeURL,
                        isSubmitting: isSubmitting,
                        isCopied: isCopied,
                        primaryCopyMode: true,
                        onCopy: onCopy,
                        onLevelRemaining: onLevelRemaining,
                        onBlockedTap: onBlockedTap
                    )
                } else {
                    LinkPlainShareDeck(link: link, isCopied: isCopied, onCopy: onCopy)
                }

                if !actions.isEmpty {
                    LinkActionStrip(actions: actions)
                }
            }
        }
    }
}

/// Compact 1-row Liquid Glass action strip beneath the Share Deck (stacks into full-width rows at accessibility
/// text sizes), honoring the pane's offline honesty contract (notes, caption, toast on paused tap).
private struct LinkActionStrip: View {
    let actions: [PaneAction]

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.paneOffline) private var offline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassEffectContainer(spacing: 8) {
                if typeSize.isAccessibilitySize {
                    VStack(spacing: 8) {
                        ForEach(actions) { action in
                            stripButton(action, compactRow: true)
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        ForEach(actions) { action in
                            stripButton(action, compactRow: false)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            if offline {
                ForEach(PaneActionGrid.notes(for: actions, offline: offline), id: \.self) { note in
                    Text(note)
                        .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                        .foregroundStyle(CobaltColor.captionOnElevated)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
            }

            if let toast {
                Text(toast)
                    .font(Font.cobalt(12, .medium, relativeTo: .caption))
                    .foregroundStyle(CobaltColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(CobaltColor.elevated.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(.opacity)
                    .accessibilityIdentifier("pane.actions.toast")
            }
        }
        .onChange(of: offline) { _, now in
            if !now { toastTask?.cancel(); toast = nil }
        }
    }

    @ViewBuilder
    private func stripButton(_ action: PaneAction, compactRow: Bool) -> some View {
        let paused = action.pausedOffline(offline) && !action.isDisabled && !action.isWorking
        let locked = action.isDisabled || action.isWorking
        let destructive = action.role == .destructive
        let caption = PaneActionGrid.caption(for: action, offline: offline)
        let tint: Color = destructive ? CobaltColor.error.opacity(0.14) : CobaltColor.surface.opacity(0.6)

        Group {
            if paused {
                Button { say(Copy.Pane.pausedReason(action.title)) } label: {
                    buttonLabel(action, caption: caption, compactRow: compactRow)
                }
                .accessibilityValue(Copy.Pane.needsNetwork)
                .accessibilityHint(Copy.Pane.needsServer)
            } else {
                Button(role: action.role) {
                    action.perform()
                } label: {
                    buttonLabel(action, caption: caption, compactRow: compactRow)
                }
            }
        }
        .buttonStyle(LinkStripButtonStyle(destructive: destructive, tint: tint))
        .disabled(locked)
        .opacity(action.isWorking ? 0.82 : (action.isDisabled ? 0.45 : (paused ? 0.6 : 1)))
    }

    @ViewBuilder
    private func buttonLabel(_ action: PaneAction, caption: String?, compactRow: Bool) -> some View {
        if compactRow {
            HStack(spacing: 10) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title)
                        .font(Font.cobalt(13.5, .semibold, relativeTo: .body))
                    if let caption {
                        Text(caption)
                            .font(Font.cobalt(11, .regular, relativeTo: .caption2))
                            .foregroundStyle(CobaltColor.caption)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        } else {
            VStack(spacing: 4) {
                Image(systemName: action.systemImage)
                    .font(.system(size: Platform.isMac ? 14 : 15, weight: .semibold))
                Text(action.title)
                    .font(Font.cobalt(Platform.isMac ? 11 : 11.5, .semibold, relativeTo: .caption))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if let caption {
                    Text(caption)
                        .font(Font.cobalt(9.5, .regular, relativeTo: .caption2))
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Platform.isMac ? 48 : 52, maxHeight: .infinity)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
        }
    }

    private func say(_ text: String) {
        toastTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { toast = text }
        AccessibilityNotification.Announcement(text).post()
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.18)) { toast = nil }
        }
    }
}

private struct LinkStripButtonStyle: ButtonStyle {
    let destructive: Bool
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(destructive ? CobaltColor.errorText : CobaltColor.text)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .glassEffect(.regular.tint(tint).interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(destructive ? CobaltColor.error.opacity(0.28) : CobaltColor.hairline, lineWidth: 0.65)
                    .allowsHitTesting(false)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.press, value: configuration.isPressed)
            .haptic(.impact(weight: .light), trigger: configuration.isPressed) { $0 }
    }
}

// MARK: - the hero

/// The link's files as tiles under the header: up to four (2x2) beside the tab; spanned over two screens, every file
/// fills the media screen. A tile opens its post and shows a Clear Liquid Glass loudness pip for videos when audio
/// leveling is enabled.
private struct LinkPaneHero: View {
    let entries: [LinkFileEntry]
    let model: AppModel

    @Environment(\.paneShape) private var shape
    @Environment(Pane.self) private var pane: Pane?

    var body: some View {
        switch shape {
        case .bar:
            LinkCover(items: entries.map(\.item), side: 40, totalCount: entries.count)
        case .tall:
            grid(Array(entries.prefix(4)))
                .aspectRatio(1, contentMode: .fit)
        case .wide:
            grid(Array(entries.prefix(4)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .split:
            grid(entries)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func grid(_ shown: [LinkFileEntry]) -> some View {
        let showAudioPips = model.capabilities.audioLeveling
        return LinkTileGrid(count: shown.count) { index, side in
            let entry = shown[index]
            Button {
                if let post = entry.post { pane?.open(.post(post.id)) }
            } label: {
                LinkFileThumb(entry: entry, side: side, radius: 14, maxPixel: 640, model: model)
                    .opacity(entry.shows ? 1 : 0.45)
                    .overlay(alignment: .bottomTrailing) {
                        if showAudioPips, entry.shows, entry.kind == .video, side >= 100 {
                            HeroAudioPip(audio: entry.audio)
                                .padding(7)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6)
                            .allowsHitTesting(false)
                    )
            }
            .buttonStyle(.plain)
            .disabled(entry.post == nil)
            .accessibilityLabel(Copy.LinkEdit.fileA11y(
                number: entry.number, name: entry.post.map { model.mediaItem(for: $0).titleText } ?? entry.kindWord,
                meta: entry.meta, warning: entry.warningText))
            .accessibilityHint(entry.post == nil ? "" : Copy.LinkEdit.openPostHint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Tiny Clear Liquid Glass loudness indicator placed in the bottom-trailing corner of hero video tiles.
private struct HeroAudioPip: View {
    let audio: AudioLoudnessInfo?

    var body: some View {
        HStack(spacing: 4) {
            if audio?.isRendering == true {
                ProgressView()
                    .controlSize(.mini)
                    .tint(AudioDockTone.amber)
            } else if audio?.isLeveled == true {
                Image(systemName: Symbol.AudioBulk.leveled)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AudioDockTone.emerald)
            } else if audio?.isSilent == true {
                Image(systemName: Symbol.AudioBulk.silent)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
            } else {
                Circle()
                    .fill(audio?.statusTint ?? AudioDockTone.neutral)
                    .frame(width: 6, height: 6)
            }
            if let text = shortText {
                Text(text)
                    .font(Font.cobalt(10, .semibold, relativeTo: .caption2))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .mediaGlassCapsule(interactive: false)
        .accessibilityHidden(true)
    }

    private var shortText: String? {
        guard let audio else { return nil }
        if audio.isLeveled {
            if let out = audio.outputLufs, out.isFinite { return String(format: "%.1f", out) }
            return Copy.AudioBulk.badgeLeveledFallback
        }
        if audio.isRendering { return Copy.AudioBulk.badgeLeveling }
        if audio.isSilent { return Copy.AudioBulk.badgeSilent }
        if let lufs = audio.integratedLufs, lufs.isFinite { return String(format: "%.1f", lufs) }
        return nil
    }
}

/// Square tiles in the most room they can have: the grid picks the column count that makes each tile biggest in the
/// space it is given (1 file one big tile, 2 side by side or stacked, 3-4 a square, 5-10 three or four across).
struct LinkTileGrid<Tile: View>: View {
    let count: Int
    var gap: CGFloat = 5
    @ViewBuilder let tile: (Int, CGFloat) -> Tile

    var body: some View {
        GeometryReader { geo in
            let shape = Self.shape(count: count, in: geo.size, gap: gap)
            VStack(spacing: gap) {
                ForEach(0..<shape.rows, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(row * shape.columns..<min((row + 1) * shape.columns, count), id: \.self) { index in
                            tile(index, shape.side)
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// The columns, rows and tile side that fill `size` best.
    static func shape(count: Int, in size: CGSize, gap: CGFloat) -> (columns: Int, rows: Int, side: CGFloat) {
        guard count > 0, size.width > 0, size.height > 0 else { return (1, 0, 0) }
        var best = (columns: 1, rows: count, side: CGFloat(0))
        for columns in 1...count {
            let rows = (count + columns - 1) / columns
            let across = (size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let down = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            let side = max(min(across, down), 0).rounded(.down)
            if side > best.side { best = (columns, rows, side) }
        }
        return best
    }
}

// MARK: - the body

/// Privacy & collection tags, then the numbered files with per-row loudness telemetry.
private struct LinkPaneBody: View {
    let link: ShareSet
    let entries: [LinkFileEntry]
    let model: AppModel
    let controller: LinksController
    let onLevelSingle: (String) -> Void

    @Environment(Pane.self) private var pane: Pane?

    private var audioEnabled: Bool { model.capabilities.audioLeveling }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LinkHeaderTags(link: link, controller: controller)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(text: Copy.LinkEdit.filesSection)
                    Spacer(minLength: 8)
                    SectionLabel(text: Copy.LinkEdit.countOf(entries.count, max: model.capabilities.limits.shareSetMax))
                }
                ForEach(entries) { entry in
                    row(entry)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func row(_ entry: LinkFileEntry) -> some View {
        let canLevelRow = audioEnabled && entry.shows && entry.kind == .video && {
            guard let audio = entry.audio else { return true }
            return !audio.isLeveled && !audio.isRendering && !audio.isSilent
        }()
        LinkFileRow(
            entry: entry,
            model: model,
            onOpen: {
                if let post = entry.post { pane?.open(.post(post.id)) }
            },
            showAudioBadge: audioEnabled,
            onLevelAudio: canLevelRow ? { onLevelSingle(entry.id) } : nil
        )
        .contextMenu {
            if canLevelRow {
                Button(
                    entry.audio?.state == .failed ? Copy.AudioBulk.retryLeveling : Copy.AudioBulk.levelAudio,
                    systemImage: entry.audio?.state == .failed ? Symbol.AudioBulk.retry : Symbol.AudioBulk.waveform
                ) {
                    onLevelSingle(entry.id)
                }
            }
        }
    }
}

// MARK: - the collections card

/// A chip per collection: lit while the link is in it, a tap puts it in or takes it out, a long press opens the
/// collection in the pane. Then "new collection…".
private struct LinkPaneCollections: View {
    let link: ShareSet
    let controller: LinksController

    @Environment(\.shell) private var shell
    @Environment(Pane.self) private var pane: Pane?

    var body: some View {
        let collections = controller.store.collections
        VStack(alignment: .leading, spacing: 10) {
            if collections.isEmpty {
                Text(Copy.LinksPane.noCollectionsYet)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
            } else {
                Text(Copy.LinksPane.collectionsHint)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                DuoAdaptiveGrid(minItemWidth: 130, spacing: 8, alignment: .leading) {
                    ForEach(collections) { collection in
                        chip(collection)
                    }
                }
            }
            Button { controller.newCollection(including: link) } label: {
                Label(Copy.Collections.newEllipsis, systemImage: Symbol.collectionNew)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .overlay(Capsule().strokeBorder(CobaltColor.border, style: StrokeStyle(lineWidth: 1.1, dash: [4, 3])))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func chip(_ collection: ShareCollection) -> some View {
        let on = collection.contains(link.id)
        return Button { controller.toggle(link, in: collection, shell: shell) } label: {
            Label(collection.name, systemImage: on ? Symbol.linkPicked : Symbol.collection)
                .labelStyle(CollectionLineLabel())
                .font(Font.cobalt(12, on ? .semibold : .medium, relativeTo: .caption))
                .foregroundStyle(on ? CobaltColor.collection : CobaltColor.text)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(on ? CobaltColor.collection.opacity(0.16) : CobaltColor.elevated.opacity(0.55)).interactive(),
            in: .capsule
        )
        .overlay(
            Capsule()
                .strokeBorder(on ? CobaltColor.collection.opacity(0.55) : CobaltColor.hairline, lineWidth: on ? 1 : 0.6)
                .allowsHitTesting(false)
        )
        .accessibilityAddTraits(on ? .isSelected : [])
        .contextMenu {
            Button(Copy.LinksPane.openCollection, systemImage: Symbol.collection) { pane?.open(.collection(collection.id)) }
        }
    }
}

#if DEBUG
// MARK: - previews

private struct LoadedLinks<Content: View>: View {
    let model: AppModel
    @ViewBuilder let content: () -> Content
    @State private var ready = false

    var body: some View {
        Group {
            if ready { content() } else { Color.clear }
        }
        .task {
            await model.shareSets.refresh()
            ready = true
        }
    }
}

private struct LinkPaneShape<Content: View>: View {
    let shape: PaneShape
    var hinge: PaneHinge?
    @ViewBuilder let content: Content
    @State private var pane = Pane(route: PaneRoute(item: .link(LinkPanePreview.harbour), state: .screen))

    var body: some View {
        NavigationStack { content }
            .environment(\.paneShape, shape)
            .environment(\.paneHinge, hinge)
            .environment(\.paneHeaderHeight, PaneChrome.headerHeight)
            .background(CobaltColor.bg)
            .environment(pane)
    }
}

enum LinkPanePreview {
    static let harbour = "9000000000000000001"
    static let kitchen = "9000000000000000003"
}

#Preview("link pane · tall", traits: .fixedLayout(width: 440, height: 900)) {
    PreviewHost(.happy, tab: .links) { model in
        LoadedLinks(model: model) {
            LinkPaneShape(shape: .tall) { LinkPanePage(model: model, id: LinkPanePreview.harbour) }
        }
    }
}
#Preview("link pane · a file gone private, dark", traits: .fixedLayout(width: 440, height: 900)) {
    PreviewHost(.happy, tab: .links) { model in
        LoadedLinks(model: model) {
            LinkPaneShape(shape: .tall) { LinkPanePage(model: model, id: LinkPanePreview.kitchen) }
        }
    }
    .preferredColorScheme(.dark)
}
#Preview("link pane · AX3", traits: .fixedLayout(width: 440, height: 900)) {
    PreviewHost(.happy, tab: .links) { model in
        LoadedLinks(model: model) {
            LinkPaneShape(shape: .tall) { LinkPanePage(model: model, id: LinkPanePreview.harbour) }
        }
    }
    .dynamicTypeSize(.accessibility3)
}
#Preview("link pane · wide", traits: .fixedLayout(width: 1000, height: 560)) {
    PreviewHost(.happy, tab: .links) { model in
        LoadedLinks(model: model) {
            LinkPaneShape(shape: .wide) { LinkPanePage(model: model, id: LinkPanePreview.harbour) }
        }
    }
}
#Preview("link pane · spanned, wide duo", traits: .fixedLayout(width: 1080, height: 800)) {
    PreviewHost(.happy, tab: .links) { model in
        LoadedLinks(model: model) {
            LinkPaneShape(shape: .split(.media), hinge: PaneHinge(axis: .vertical, position: 540)) {
                LinkPanePage(model: model, id: LinkPanePreview.harbour)
            }
        }
    }
}
#Preview("link pane · gone", traits: .fixedLayout(width: 440, height: 600)) {
    PreviewHost(.happy, tab: .links) { model in
        LoadedLinks(model: model) {
            LinkPaneShape(shape: .tall) { LinkPanePage(model: model, id: "nope") }
        }
    }
}
#endif
