import CobaltKit
import SwiftUI

/// Compact `select` pill pinned at the trailing end of the library's top filter row while not selecting.
/// Replaces the old floating bottom button so the masonry grid stays completely unobstructed while browsing.
struct LibrarySelectButton: View {
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: Symbol.Library.select)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(Copy.Library2.select)
                    .font(Font.cobalt(11.5, .semibold, relativeTo: .caption))
            }
            .foregroundStyle(CobaltColor.text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 11)
            .frame(minHeight: 30)
            .background(Capsule().fill(CobaltColor.elevated))
            .overlay(Capsule().strokeBorder(CobaltColor.hairline, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.38 : 1)
        .disabled(disabled)
        .accessibilityLabel(Copy.Library2.select)
        .accessibilityIdentifier("library.select")
        #if os(macOS)
        .keyboardShortcut("s", modifiers: [.command, .shift])
        #endif
    }
}

/// Slim top selection header (`safeAreaInset(edge: .top)` while selecting).
///
/// Holds `done` (exits select mode), the live picked count (`library.select.count`), and `all` / `none` so the
/// masonry grid stays wide open while all selection actions and picked thumbnails live together in `LibraryPickedSheet`
/// at the bottom.
struct LibrarySelectTopBar: View {
    let controller: LibraryController
    /// The posts on screen (the chips, the search and the show filter decide which).
    let rows: [LibraryRow]
    let toggle: () -> Void

    var body: some View {
        let count = controller.pickedRows(rows).count
        let shareable = rows.filter(\.shareable)
        let allPicked = !shareable.isEmpty && shareable.allSatisfy { controller.picked.contains($0.id) }

        HStack(spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 4) {
                    Image(systemName: Symbol.close)
                        .font(.system(size: 10.5, weight: .bold))
                    Text(Copy.Library2.doneSelecting)
                        .font(Font.cobalt(12, .semibold, relativeTo: .caption))
                }
                .foregroundStyle(CobaltColor.text)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(CobaltColor.elevated))
                .overlay(Capsule().strokeBorder(CobaltColor.hairline, lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .keyboardShortcut(.cancelAction)
            #endif
            .accessibilityLabel(Copy.Library2.stopSelecting)
            .accessibilityIdentifier("library.select.stop")

            Text(Copy.Library2.pickedCount(count))
                .font(Font.cobalt(13, .semibold, relativeTo: .subheadline))
                .foregroundStyle(count == 0 ? CobaltColor.caption : CobaltColor.text)
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                // layout checks (apple/CobaltUITests) read the count here: "2 picked"
                .accessibilityIdentifier("library.select.count")

            Spacer(minLength: 8)

            Button {
                withAnimation(Motion.rows) { controller.toggleAll(rows) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: allPicked ? Symbol.Library.selectNone : Symbol.Library.selectAll)
                        .font(.system(size: 11, weight: .semibold))
                    Text(allPicked ? Copy.Library2.noneShort : Copy.Library2.all)
                        .font(Font.cobalt(12, .semibold, relativeTo: .caption))
                }
                .foregroundStyle(CobaltColor.text)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(CobaltColor.elevated))
                .overlay(Capsule().strokeBorder(CobaltColor.hairline, lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(shareable.isEmpty ? 0.38 : 1)
            .disabled(shareable.isEmpty)
            .accessibilityLabel(allPicked ? Copy.Library2.selectNone : Copy.Library2.selectAll)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

// MARK: - bottom selection sheet (picked items + action grid)

/// Docked bottom Liquid Glass sheet (`safeAreaInset(edge: .bottom)` while selecting) holding the picked items in tap
/// order together with the compact labeled action grid directly below at thumb height.
///
/// The picked-items tray is collapsed by default to a slim horizontal rail of numbered thumbnails. Dragging up or
/// tapping its header expands the tray in-place into a compact scrollable grid so the masonry behind stays visible and
/// tappable. Tap a thumbnail to unpick; hold to peek.
struct LibraryPickedSheet: View {
    let model: AppModel
    let controller: LibraryController
    /// The posts on screen (the chips, the search and the show filter decide which).
    let rows: [LibraryRow]
    let tier: Tier
    let makeLink: () -> Void
    let file: (LibraryController.CollectionTarget) -> Void
    let share: () -> Void

    private enum PublicLinkPrompt: Equatable {
        case makeLink(count: Int)
        case collection(count: Int)

        var count: Int {
            switch self {
            case .makeLink(let n), .collection(let n): n
            }
        }
    }

    private enum PublicWorkTarget { case makeLink, collection }

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var expanded = false
    @State private var pickingCollection = false
    @State private var deleting = false
    @State private var creatingEdit = false
    @State private var editNote: String?
    @State private var publicPrompt: PublicLinkPrompt?
    @State private var makingPublicTarget: PublicWorkTarget?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var store: ShareSetStore { model.shareSets }
    private var makesLinks: Bool { model.capabilities.shareSets }
    private var files: Bool { makesLinks && model.capabilities.shareCollections }
    private var inAlbum: Bool { model.library.showingHidden }
    private var offersStatus: Bool { model.capabilities.hidden }
    private var offersPrivate: Bool { makesLinks && model.capabilities.privateLinks }
    private var addsToLinks: Bool { controller.addsToLinks }
    private var offersEdit: Bool { model.editor.isAvailable }
    private var busy: Bool { controller.changingStatus || model.library.statusInFlight }

    private var canDeleteAnyRow: Bool { rows.contains { controller.canDelete($0.item) } }
    private func deletes(_ picks: [LibraryRow]) -> Bool { picks.contains { controller.canDelete($0.item) } }

    /// How many action tiles the grid currently draws (kept stable across picks so the grid never reflows).
    private var actionCount: Int {
        if inAlbum {
            return 1 + (offersStatus ? 1 : 0) + (canDeleteAnyRow ? 1 : 0)
        }
        var count = 1 // share
        if makesLinks { count += 1 }
        if offersPrivate { count += 1 }
        if files { count += 1 }
        if addsToLinks { count += 1 }
        if offersEdit { count += 1 }
        if offersStatus { count += 1 }
        if canDeleteAnyRow { count += 1 }
        return count
    }

    private var columns: [GridItem] {
        let maxCols = tier == .wide ? 8 : 4
        let raw = max(1, min(actionCount, maxCols))
        let isRegular = sizeClass == .regular || Platform.isMac
        let count = isRegular && raw > 1 ? DuoGrid.snapEven(raw) : raw
        return Array(repeating: GridItem(.flexible(), spacing: 6), count: count)
    }

    var body: some View {
        let picks = controller.pickedRows(rows)
        let canExpand = !picks.isEmpty
        let verdict = controller.shareLinkVerdict(rows)
        let ready = verdict == .ready && !controller.makingShareLink && !busy
        let canPromptPublic = controller.canMakePicksPublicForLink(rows) && !controller.makingShareLink && !busy

        VStack(spacing: 0) {
            // grabber + compact header for the picked items tray (tap or vertical drag expands/collapses)
            VStack(spacing: 6) {
                Capsule()
                    .fill(CobaltColor.caption.opacity(0.35))
                    .frame(width: 34, height: 4)
                    .padding(.top, 7)
                    .accessibilityHidden(true)

                HStack(spacing: 6) {
                    if picks.isEmpty {
                        Text(Copy.SelectPane.nothingPicked)
                            .font(CobaltType.captionSmall)
                            .foregroundStyle(CobaltColor.caption)
                            .lineLimit(1)
                    } else {
                        Text(Copy.Library2.selected(picks.count))
                            .font(Font.cobalt(12.5, .semibold, relativeTo: .caption))
                            .foregroundStyle(CobaltColor.text)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        let kinds = Copy.SelectPane.kinds(picks)
                        if !kinds.isEmpty {
                            Text("· \(kinds)")
                                .font(CobaltType.captionSmall)
                                .foregroundStyle(CobaltColor.caption)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }

                    Spacer(minLength: 6)

                    if canExpand {
                        Button {
                            withAnimation(Motion.rows) { controller.clearPicks() }
                        } label: {
                            Text(Copy.Library2.clearPicks)
                                .font(Font.cobalt(11.5, .medium, relativeTo: .caption))
                                .foregroundStyle(CobaltColor.caption)
                                .padding(.horizontal, 8)
                                .frame(height: 24)
                                .background(Capsule().fill(CobaltColor.elevated.opacity(0.85)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button {
                            withAnimation(Motion.card) { expanded.toggle() }
                        } label: {
                            Image(systemName: expanded ? "chevron.down" : "chevron.up")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(CobaltColor.text)
                                .frame(width: 26, height: 24)
                                .background(Capsule().fill(CobaltColor.elevated.opacity(0.85)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(expanded ? Copy.Library2.shelfFold : Copy.Library2.shelfUnfold)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, picks.isEmpty ? 8 : 5)
            }
            .contentShape(.rect)
            .onTapGesture {
                guard canExpand else { return }
                withAnimation(Motion.card) { expanded.toggle() }
            }

            if !picks.isEmpty {
                if expanded {
                    expandedGrid(picks)
                        .transition(.opacity)
                } else {
                    collapsedStrip(picks)
                        .transition(.opacity)
                }
            }

            Rectangle()
                .fill(CobaltColor.hairline)
                .frame(height: 0.5)
                .allowsHitTesting(false)

            // compact labeled action grid + live status note at thumb height
            VStack(alignment: .leading, spacing: 7) {
                LazyVGrid(columns: columns, spacing: 6) {
                    if inAlbum {
                        unhideTile(picks)
                        if offersStatus { statusTile(picks) }
                        if canDeleteAnyRow { deleteTile(picks) }
                    } else {
                        if makesLinks { makeLinkTile(ready: ready, canPromptPublic: canPromptPublic) }
                        if offersPrivate { privacyTile }
                        if files { collectionTile(ready: ready, canPromptPublic: canPromptPublic) }
                        if addsToLinks { addToLinkTile(picks) }
                        shareTile(picks)
                        if offersEdit { editTile(picks) }
                        if offersStatus { statusTile(picks) }
                        if canDeleteAnyRow { deleteTile(picks) }
                    }
                }
                if let note = footerNote(picks: picks, verdict: verdict, canPromptPublic: canPromptPublic) {
                    Text(note.text)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(note.emphasized ? CobaltColor.text : CobaltColor.caption)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .padding(.horizontal, 2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: tier == .wide ? 680 : 560)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(CobaltColor.hairline, lineWidth: 0.5)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .simultaneousGesture(
            DragGesture(minimumDistance: 14)
                .onEnded { drag in
                    guard canExpand else { return }
                    let vertical = abs(drag.translation.height) > abs(drag.translation.width)
                    guard vertical else { return }
                    if drag.translation.height < -24, !expanded {
                        withAnimation(Motion.card) { expanded = true }
                    } else if drag.translation.height > 24, expanded {
                        withAnimation(Motion.card) { expanded = false }
                    }
                }
        )
        .onChange(of: picks.isEmpty) { _, empty in
            if empty, expanded { expanded = false }
        }
        .onChange(of: picks.map(\.id)) { _, _ in editNote = nil }
        .motion(reduceMotion ? .default : Motion.rows, value: picks.map(\.id))
        .motion(Motion.rows, value: verdict)
        .motion(Motion.card, value: expanded)
        .haptic(.impact(weight: .light), trigger: expanded)
        .task {
            // load default public/private preference from settings › sharing once per select session
            if makesLinks, model.capabilities.privateLinks, !store.privateLoaded {
                try? await store.refreshPrivate()
            }
        }
        .alert(
            publicPrompt.map { Copy.Links.makePublicAlertTitle($0.count) } ?? "",
            isPresented: Binding(get: { publicPrompt != nil }, set: { if !$0 { publicPrompt = nil } }),
            presenting: publicPrompt
        ) { prompt in
            switch prompt {
            case .makeLink:
                Button(Copy.Links.makePublicAndLink) {
                    makingPublicTarget = .makeLink
                    Task {
                        defer { makingPublicTarget = nil }
                        await controller.makePublicThenLinkAndEnd(rows)
                    }
                }
                if offersPrivate {
                    Button(Copy.Links.usePrivateLinkInstead) {
                        controller.shareLinkPrivate = true
                        makeLink()
                    }
                }
            case .collection:
                Button(Copy.Links.makePublicAndCollection) {
                    makingPublicTarget = .collection
                    Task {
                        defer { makingPublicTarget = nil }
                        if await controller.makeNonPublicPicksPublic(rows) {
                            pickingCollection = true
                        }
                    }
                }
                if offersPrivate {
                    Button(Copy.Links.usePrivateCollectionInstead) {
                        controller.shareLinkPrivate = true
                        pickingCollection = true
                    }
                }
            }
            Button(Copy.Links.cancel, role: .cancel) {}
        } message: { prompt in
            switch prompt {
            case .makeLink(let count): Text(Copy.Links.makePublicForLinkMessage(count))
            case .collection(let count): Text(Copy.Links.makePublicForCollectionMessage(count))
            }
        }
        .modifier(SelectSheets(
            pickingCollection: $pickingCollection,
            deleting: $deleting,
            model: model,
            controller: controller,
            rows: rows,
            file: file
        ))
    }

    // MARK: picked thumbnails

    /// Collapsed small-sheet state: one auto-scrolling horizontal row of numbered picks.
    private func collapsedStrip(_ picks: [LibraryRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(picks.enumerated()), id: \.element.id) { index, row in
                        PickThumb(row: row, number: index + 1, controller: controller, side: 46)
                            .id(row.id)
                            .transition(.scale(scale: 0.72).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 10)
            }
            .scrollClipDisabled()
            .onChange(of: picks.last?.id) { _, last in
                guard let last else { return }
                withAnimation(Motion.rows) { proxy.scrollTo(last, anchor: .trailing) }
            }
        }
    }

    /// Expanded small-sheet state: compact scrollable wrap grid of every picked item.
    private func expandedGrid(_ picks: [LibraryRow]) -> some View {
        ScrollView {
            DuoAdaptiveGrid(minItemWidth: 60, spacing: 8) {
                ForEach(Array(picks.enumerated()), id: \.element.id) { index, row in
                    PickThumb(row: row, number: index + 1, controller: controller, side: nil)
                        .id(row.id)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
        .frame(maxHeight: 164)
    }

    // MARK: action grid tiles

    private func makeLinkTile(ready: Bool, canPromptPublic: Bool) -> some View {
        let enabled = ready || canPromptPublic
        let working = controller.makingShareLink || makingPublicTarget == .makeLink
        return Button {
            if ready {
                makeLink()
            } else if canPromptPublic {
                publicPrompt = .makeLink(count: controller.nonPublicSharePicks(rows).count)
            }
        } label: {
            SelectGridTile(
                title: Copy.Links.make,
                symbol: Symbol.link,
                tone: .primary,
                working: working
            )
        }
        .buttonStyle(.selectGridPress)
        .disabled(!enabled)
        .accessibilityValue(Text(working ? Copy.Links.making : ""))
        .accessibilityHint(Copy.Links.makeA11yHint)
    }

    /// 1-tap `public` / `private` link mode toggle directly in the grid.
    private var privacyTile: some View {
        let isPrivate = controller.makesPrivateLink
        return Button {
            withAnimation(Motion.chip) { controller.shareLinkPrivate = !isPrivate }
        } label: {
            SelectGridTile(
                title: isPrivate ? Copy.PrivateLinks.choicePrivate : Copy.PrivateLinks.choicePublic,
                symbol: isPrivate ? Symbol.PrivateLinks.makePrivate : Symbol.PrivateLinks.publicLink,
                tone: isPrivate ? .privacyActive : .neutral
            )
        }
        .buttonStyle(.selectGridPress)
        .disabled(controller.makingShareLink || busy)
        .haptic(.selection, trigger: isPrivate)
        .accessibilityLabel(Copy.PrivateLinks.choice)
        .accessibilityValue(isPrivate ? Copy.PrivateLinks.choicePrivate : Copy.PrivateLinks.choicePublic)
    }

    private func collectionTile(ready: Bool, canPromptPublic: Bool) -> some View {
        let enabled = ready || canPromptPublic
        let working = makingPublicTarget == .collection
        return Button {
            if ready {
                pickingCollection = true
            } else if canPromptPublic {
                publicPrompt = .collection(count: controller.nonPublicSharePicks(rows).count)
            }
        } label: {
            SelectGridTile(
                title: Copy.Library2.collection,
                symbol: Symbol.Library.collectionFile,
                tone: .collection,
                working: working
            )
        }
        .buttonStyle(.selectGridPress)
        .disabled(!enabled)
    }

    private func addToLinkTile(_ picks: [LibraryRow]) -> some View {
        Button { controller.addPicksToLink(picks) } label: {
            SelectGridTile(
                title: Copy.LinkEdit.addToLink,
                symbol: Symbol.LinkEdit.addToLink,
                tone: .addLink,
                working: controller.appendingToLink
            )
        }
        .buttonStyle(.selectGridPress)
        .disabled(picks.isEmpty || controller.appendingToLink)
        .accessibilityHint(Copy.LinkEdit.addToLinkHint)
    }

    private func shareTile(_ picks: [LibraryRow]) -> some View {
        Button(action: share) {
            SelectGridTile(
                title: Copy.Library2.share,
                symbol: Symbol.Library.share,
                tone: .share,
                working: controller.preparingShare
            )
        }
        .buttonStyle(.selectGridPress)
        .disabled(controller.preparingShare || picks.isEmpty)
    }

    private func editTile(_ picks: [LibraryRow]) -> some View {
        let enabled = picks.contains(where: EditPicksButton.canEdit) && !creatingEdit
        return Button { createEdit(picks) } label: {
            SelectGridTile(
                title: Copy.Editor.edit,
                symbol: Symbol.Editor.edit,
                tone: .edit,
                working: creatingEdit
            )
        }
        .buttonStyle(.selectGridPress)
        .disabled(!enabled)
        .accessibilityLabel(creatingEdit ? Copy.Editor.creating : Copy.Editor.edit)
        .accessibilityHint(enabled ? Copy.Editor.editLine : Copy.Editor.editNoVideo)
    }

    private func unhideTile(_ picks: [LibraryRow]) -> some View {
        Button {
            controller.chooseStatus(.off, posts: controller.pickedPosts(rows))
        } label: {
            SelectGridTile(
                title: Copy.HiddenAlbum.unhide,
                symbol: Symbol.HiddenAlbum.unhide,
                tone: .primary,
                working: busy
            )
        }
        .buttonStyle(.selectGridPress)
        .disabled(picks.isEmpty || busy)
        .accessibilityHint(Copy.HiddenAlbum.unhideHint)
    }

    private func statusTile(_ picks: [LibraryRow]) -> some View {
        let disabled = picks.isEmpty || busy
        return Menu {
            StatusMenuItems(model: model) { controller.chooseStatus($0, posts: controller.pickedPosts(rows)) }
        } label: {
            SelectGridTile(
                title: Copy.HiddenAlbum.status,
                symbol: Symbol.HiddenAlbum.status,
                tone: .neutral,
                working: busy && makingPublicTarget == nil
            )
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        .menuStyle(.button)
        #endif
        .buttonStyle(.plain)
        .opacity(disabled ? 0.36 : 1)
        .disabled(disabled)
        .help(Copy.HiddenAlbum.status)
        .accessibilityLabel(Copy.HiddenAlbum.status)
        .accessibilityHint(Copy.HiddenAlbum.statusHint)
    }

    private func deleteTile(_ picks: [LibraryRow]) -> some View {
        let enabled = deletes(picks) && !busy
        return Button { deleting = true } label: {
            SelectGridTile(
                title: Copy.DeletePicks.delete,
                symbol: Symbol.Library.deleteEverything,
                tone: .destructive
            )
        }
        .buttonStyle(.selectGridPress)
        .disabled(!enabled)
        .accessibilityHint(Copy.DeletePicks.deleteHint)
        #if os(macOS)
        .keyboardShortcut(.delete, modifiers: [.command])
        #endif
    }

    // MARK: helpers

    private func footerNote(picks: [LibraryRow], verdict: ShareSetVerdict, canPromptPublic: Bool) -> (text: String, emphasized: Bool)? {
        guard !inAlbum, !picks.isEmpty else { return nil }
        if let editNote { return (editNote, true) }
        guard makesLinks else { return nil }
        if canPromptPublic, case .notPublic(let count) = verdict {
            return (Copy.Links.notPublicPromptHint(count), true)
        }
        return (Copy.PrivateLinks.line(for: verdict, count: picks.count, isPrivate: controller.makesPrivateLink),
                verdict != .ready)
    }

    private func createEdit(_ picks: [LibraryRow]) {
        editNote = nil
        creatingEdit = true
        Task {
            defer { creatingEdit = false }
            let items = picks.filter(EditPicksButton.canEdit).map(\.item)
            do {
                let left = try await model.editor.create(from: items)
                EditorLauncher.shared.firstToast = EditPicksButton.firstToast(left)
            } catch {
                switch EditError.from(error) {
                case .invalid(.empty): editNote = Copy.Editor.editNoVideo
                case .tooMany: editNote = Copy.Editor.tooManyProjects
                case .invalid(let problem): editNote = Copy.Editor.problem(problem)
                default: editNote = Copy.Editor.couldntCreate
                }
            }
        }
    }
}

/// One compact tile in `LibraryPickedSheet`'s action grid: crisp SF symbol over a single lowercase label.
private struct SelectGridTile: View {
    enum Tone { case primary, neutral, privacyActive, collection, addLink, share, edit, destructive }

    let title: String
    let symbol: String
    let tone: Tone
    var working: Bool = false

    private var ink: Color {
        switch tone {
        case .primary: CobaltColor.onText
        case .neutral: CobaltColor.text
        case .privacyActive: CobaltColor.collectionSet
        case .collection: CobaltColor.collection
        case .addLink: CobaltColor.focus
        case .share: CobaltColor.linkBlue
        case .edit: CobaltColor.collectionSet
        case .destructive: CobaltColor.errorText
        }
    }

    private var fill: Color {
        switch tone {
        case .primary: CobaltColor.text
        case .neutral: CobaltColor.elevated
        case .privacyActive: CobaltColor.collectionSetBack
        case .collection: CobaltColor.collectionBack
        case .addLink: CobaltColor.focus.opacity(0.14)
        case .share: CobaltColor.linkBlue.opacity(0.14)
        case .edit: CobaltColor.collectionSetBack
        case .destructive: CobaltColor.errorText.opacity(0.12)
        }
    }

    private var border: Color {
        switch tone {
        case .primary: .clear
        case .neutral: CobaltColor.hairline
        default: ink.opacity(0.22)
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                if working {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(ink)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 14.5, weight: .semibold))
                }
            }
            .frame(height: 17)
            Text(title)
                .font(Font.cobalt(10.5, .semibold, relativeTo: .caption2))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .padding(.horizontal, 4)
        .background(fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(border, lineWidth: 0.75)
        )
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

/// Press feedback & disabled dimming for `SelectGridTile` buttons.
private struct SelectGridPressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.36)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
            .haptic(.impact(weight: .light, intensity: 0.65), trigger: configuration.isPressed, when: { $0 })
    }
}

private extension ButtonStyle where Self == SelectGridPressStyle {
    static var selectGridPress: SelectGridPressStyle { SelectGridPressStyle() }
}

/// One pick in `LibraryPickedSheet`: its picture with its order number and a subtle remove mark.
/// Tap unpicks it; hold previews it full-size.
private struct PickThumb: View {
    let row: LibraryRow
    let number: Int
    let controller: LibraryController
    /// Nil fills the adaptive grid cell squarely.
    var side: CGFloat? = 46

    var body: some View {
        Button {
            if controller.takeSwallowedTap() { return }
            withAnimation(Motion.rows) { controller.unpick(row.id) }
        } label: {
            FacePicture(item: row.item, maxPixel: 192, showsGlyph: false)
                .frame(width: side, height: side)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(CobaltColor.hairline, lineWidth: 0.5)
                )
                .overlay(alignment: .topLeading) {
                    Text("\(number)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(CobaltColor.onText)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(CobaltColor.text, in: Circle())
                        .offset(x: -4, y: -4)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: Symbol.close)
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(.black.opacity(0.62), in: Circle())
                        .padding(3)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .peekOnHold(row, controller: controller)
        .accessibilityLabel(LibraryRowCopy.a11yLabel(row))
        .accessibilityHint(Copy.Library2.unpickHint)
    }
}

/// Collection & delete sheets owned by `LibraryPickedSheet`.
private struct SelectSheets: ViewModifier {
    @Binding var pickingCollection: Bool
    @Binding var deleting: Bool
    let model: AppModel
    let controller: LibraryController
    let rows: [LibraryRow]
    let file: (LibraryController.CollectionTarget) -> Void

    private var store: ShareSetStore { model.shareSets }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $pickingCollection) {
                CollectionPickerSheet(store: store, picks: controller.pickedRows(controller.freshRows(from: rows)), file: file)
            }
            .sheet(isPresented: $deleting) {
                let picks = controller.pickedRows(rows).map(\.item).filter { controller.canDelete($0) }
                LibraryDeleteSheet(picks: picks, impact: DeleteImpact(picks: picks, model: model), delete: controller.deletePicks)
            }
    }
}
