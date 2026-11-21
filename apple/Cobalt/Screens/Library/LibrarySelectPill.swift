import CobaltKit
import SwiftUI

/// Select, by the thumb (the S3 board on the library canvas): a white `select` pill floats over the bottom of the
/// library. Tapped, it grows into one panel that holds all of select: how many are picked, the picks as a row of
/// thumbnails in the order they were tapped (tap one to take it out, hold one to see it), then icon circles (icon-first
/// controls; hold one to name it) for `make link`,
/// `collection` (make the link and file it, picked in `CollectionPickerSheet`), `edit` and `share` (the files). While the panel is up, taps on tiles pick them;
/// otherwise they open, as always. It sits in the library's bottom safe area, so on the iPhone it is above the tab bar,
/// and the same panel is the Mac's and the iPad's.
///
/// With `features.hidden` the row ends with `status…` (a menu: hidden, off, public link, private link; one request for
/// every pick, APP-API-CONTRACT 37.7). In the hidden album the row is `unhide` and `status…` only: nothing hidden can be
/// shared, filed or edited. Last comes the trash circle (`LibraryDeleteSheet`): what goes, with a post's files to choose.
struct LibrarySelectPill: View {
    let model: AppModel
    let controller: LibraryController
    /// The posts on screen (the chips, the search and the show filter decide which).
    let rows: [LibraryRow]
    let toggle: () -> Void
    let makeLink: () -> Void
    let file: (LibraryController.CollectionTarget) -> Void
    let share: () -> Void
    /// Drawn on the other screen of a spread (Duo building blocks): the whole panel there, the picks on the left.
    var inPane = false
    /// The inline copy's sheet flags, for the pane's copy.
    var collectionShown: Binding<Bool>? = nil
    var deleteShown: Binding<Bool>? = nil

    @State private var pickingCollection = false
    @Environment(\.spreadPane) private var host
    @Environment(\.isSpread) private var spread
    @State private var editNote: String?
    /// The trash circle's sheet is up.
    @State private var deleting = false

    private var store: ShareSetStore { model.shareSets }
    private var makesLinks: Bool { model.capabilities.shareSets }
    private var files: Bool { makesLinks && model.capabilities.shareCollections }
    private var inAlbum: Bool { model.library.showingHidden }
    private var offersStatus: Bool { model.capabilities.hidden }
    private var addsToLinks: Bool { controller.addsToLinks }

    /// The panel belongs on the other screen: a spread, while selecting.
    private var wantsPane: Bool { !inPane && spread && host != nil && controller.selecting }

    private static let paneID = "library-select"

    var body: some View {
        if inPane {
            ScrollView { panel.padding(16) }
                .scrollBounceBehavior(.basedOnSize)
        } else {
            inline
                .onChange(of: wantsPane, initial: true) { _, on in
                    if on { showPane() } else { host?.close(id: Self.paneID) }
                }
                // a sheet of the panel (collection, delete) took the pane: the panel comes back when it closes
                .onChange(of: host?.pane == nil) { _, empty in
                    if empty, wantsPane { showPane() }
                }
        }
    }

    private func showPane() {
        guard let host, !host.isShowing(Self.paneID) else { return }
        // the pane's copy asks this copy's sheets: this one stays on screen, so its sheets outlive the pane they replace
        let pane = LibrarySelectPill(
            model: model, controller: controller, rows: rows, toggle: toggle, makeLink: makeLink, file: file, share: share,
            inPane: true, collectionShown: $pickingCollection, deleteShown: $deleting)
        // closing the panel is its own close button (it ends selecting); a sheet replacing it changes nothing here
        host.show(id: Self.paneID, content: AnyView(pane)) {}
    }

    private var inline: some View {
        Group {
            if controller.selecting, wantsPane {
                Color.clear.frame(height: 0)
            } else if controller.selecting {
                panel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                startButton
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        #if os(iOS)
        .padding(.bottom, 12)       // clear of the floating tab bar
        #else
        .padding(.bottom, 6)
        #endif
        .frame(maxWidth: .infinity)
        .modifier(sheets)
    }

    private var sheets: SelectSheets {
        SelectSheets(
            pickingCollection: $pickingCollection, deleting: $deleting, model: model, controller: controller, rows: rows, file: file)
    }

    // MARK: the pill

    /// `select` as one solid circle (icon-first controls): its name shows on a hold, and VoiceOver reads it.
    private var startButton: some View {
        Button(action: toggle) {
            Label(Copy.Library2.select, systemImage: Symbol.Library.select)
        }
        .buttonStyle(.cobaltIcon(prominent: true))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .disabled(!rows.contains(where: \.shareable))
        .accessibilityIdentifier("library.select")
        #if os(macOS)
        .keyboardShortcut("s", modifiers: [.command, .shift])
        #endif
    }

    // MARK: the panel

    private var panel: some View {
        let picks = controller.pickedRows(rows)
        let verdict = controller.shareLinkVerdict(rows)
        let ready = verdict == .ready && !controller.makingShareLink
        return VStack(alignment: .leading, spacing: 10) {
            header(count: picks.count)
            if !picks.isEmpty { thumbs(picks) }
            if !inAlbum, makesLinks, model.capabilities.privateLinks {
                privacyChoice
            }
            if !inAlbum, makesLinks, !picks.isEmpty {
                Text(Copy.PrivateLinks.line(for: verdict, count: picks.count, isPrivate: controller.makesPrivateLink))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(verdict == .ready ? CobaltColor.caption : CobaltColor.text)
                    .contentTransition(.opacity)
                    .padding(.horizontal, 4)
            }
            if let editNote, !picks.isEmpty, !inAlbum {
                Text(editNote)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .padding(.horizontal, 4)
            }
            // icon-first controls: one circle per action, each in its select-panel colour (the colours of
            // SelectActionStyle), `make link` the one solid circle; holding one names it
            IconRow(spacing: 6) {
                if inAlbum {
                    unhideButton(picks)
                } else {
                    shareActions(picks, ready: ready)
                }
                if offersStatus { statusMenu(picks) }
                if deletes(picks) { trashButton(picks) }
            }
        }
        .padding(12)
        .frame(maxWidth: inPane ? .infinity : 520)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .motion(Motion.rows, value: picks.map(\.id))
        .motion(Motion.rows, value: verdict)
    }

    /// `unhide` (the album's main action): the picks go back to the library as `off`, with no link.
    private func unhideButton(_ picks: [LibraryRow]) -> some View {
        Button {
            controller.chooseStatus(.off, posts: controller.pickedPosts(rows))
        } label: {
            Label(Copy.HiddenAlbum.unhide, systemImage: Symbol.HiddenAlbum.unhide)
        }
        .buttonStyle(.cobaltIcon(prominent: true))
        .disabled(picks.isEmpty || busy)
        .accessibilityHint(Copy.HiddenAlbum.unhideHint)
    }

    /// `status…`: hidden, off, public link, private link for every pick at once.
    private func statusMenu(_ picks: [LibraryRow]) -> some View {
        Menu {
            StatusMenuItems(model: model) { controller.chooseStatus($0, posts: controller.pickedPosts(rows)) }
        } label: {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Label(Copy.HiddenAlbum.status, systemImage: Symbol.HiddenAlbum.status)
            }
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        .menuStyle(.button)
        #endif
        .buttonStyle(.selectAction(.status))
        // a menu, not a `.cobaltIcon()` button: the select style drawn as a circle beside the icon buttons
        .frame(width: Self.slot, height: Self.slot)
        .disabled(picks.isEmpty || busy)
        .help(Copy.HiddenAlbum.status)
        .accessibilityLabel(Copy.HiddenAlbum.status)
        .accessibilityHint(Copy.HiddenAlbum.statusHint)
    }

    /// The trash circle (last, in the error red): the sheet that says what goes, and lets a post's files be chosen.
    private func trashButton(_ picks: [LibraryRow]) -> some View {
        Button { if let deleteShown { deleteShown.wrappedValue = true } else { deleting = true } } label: {
            Label(Copy.DeletePicks.delete, systemImage: Symbol.Library.deleteEverything)
        }
        .buttonStyle(.cobaltIcon(tint: CobaltColor.errorText))
        .disabled(picks.isEmpty || busy)
        .accessibilityHint(Copy.DeletePicks.deleteHint)
        #if os(macOS)
        .keyboardShortcut(.delete, modifiers: [.command])
        #endif
    }

    /// The trash is offered when a pick has something the server can delete.
    private func deletes(_ picks: [LibraryRow]) -> Bool {
        picks.contains { controller.canDelete($0.item) }
    }

    /// One circle of the action row: the `.cobaltIcon()` diameter, for the controls that are not icon buttons.
    private static let slot: CGFloat = 50

    /// A status change is on its way: the buttons wait.
    private var busy: Bool { controller.changingStatus || model.library.statusInFlight }

    /// The row of a normal library: make link, collection, edit, share.
    @ViewBuilder
    private func shareActions(_ picks: [LibraryRow], ready: Bool) -> some View {
        if makesLinks {
            Button(action: makeLink) {
                Label(Copy.Links.make, systemImage: Symbol.link)
            }
            .buttonStyle(.cobaltIcon(prominent: true, state: controller.makingShareLink ? .working : .idle))
            .disabled(!ready)
            .accessibilityValue(Text(controller.makingShareLink ? Copy.Links.making : ""))
            .accessibilityHint(Copy.Links.makeA11yHint)
        }
        if files {
            Button { if let collectionShown { collectionShown.wrappedValue = true } else { pickingCollection = true } } label: {
                Label(Copy.Library2.collection, systemImage: Symbol.Library.collectionFile)
            }
            .buttonStyle(.cobaltIcon(tint: CobaltColor.collection))
            .disabled(!ready)
        }
        if addsToLinks {
            // the picker loads the links itself, so this works before the links tab was ever opened
            Button { controller.addPicksToLink(picks) } label: {
                Label(Copy.LinkEdit.addToLink, systemImage: Symbol.LinkEdit.addToLink)
            }
            .buttonStyle(.cobaltIcon(tint: CobaltColor.focus, state: controller.appendingToLink ? .working : .idle))
            .disabled(picks.isEmpty || controller.appendingToLink)
            .accessibilityHint(Copy.LinkEdit.addToLinkHint)
        }
        if model.editor.isAvailable {
            // the editor's own button (Screens/Editor), held to one circle of the row
            EditPicksButton(model: model, picks: picks, note: $editNote)
                .frame(width: Self.slot, height: Self.slot)
        }
        Button(action: share) { Label(Copy.Library2.share, systemImage: Symbol.Library.share) }
            .buttonStyle(.cobaltIcon(tint: CobaltColor.linkBlue, state: controller.preparingShare ? .working : .idle))
            .disabled(controller.preparingShare || picks.isEmpty)
    }

    /// `public` / `private` for the link the panel makes (APP-API-CONTRACT 36.6), starting at settings › sharing's
    /// `new links start`. Private takes files that are not public too.
    private var privacyChoice: some View {
        Picker(Copy.PrivateLinks.choice, selection: Binding(
            get: { controller.makesPrivateLink },
            set: { controller.shareLinkPrivate = $0 }
        )) {
            Label(Copy.PrivateLinks.choicePublic, systemImage: Symbol.PrivateLinks.publicLink).tag(false)
            Label(Copy.PrivateLinks.choicePrivate, systemImage: Symbol.PrivateLinks.makePrivate).tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .disabled(controller.makingShareLink)
        .task {
            // what new links start as, once per panel
            if !store.privateLoaded { try? await store.refreshPrivate() }
        }
    }

    private func header(count: Int) -> some View {
        let shareable = rows.filter(\.shareable)
        let allPicked = !shareable.isEmpty && shareable.allSatisfy { controller.picked.contains($0.id) }
        return HStack(spacing: 8) {
            Button(action: toggle) {
                Label(Copy.Library2.stopSelecting, systemImage: Symbol.close)
            }
            .buttonStyle(.cobaltIcon(.small))
            #if os(macOS)
            .keyboardShortcut(.cancelAction)
            #endif
            .accessibilityIdentifier("library.select.stop")
            Text(Copy.Library2.pickedCount(count))
                .font(CobaltType.bodySemibold)
                .foregroundStyle(CobaltColor.text)
                .contentTransition(.numericText())
                // the layout checks (apple/CobaltUITests) read the count here: "2 picked"
                .accessibilityIdentifier("library.select.count")
            Spacer(minLength: 8)
            Button {
                withAnimation(Motion.rows) { controller.toggleAll(rows) }
            } label: {
                Label(
                    allPicked ? Copy.Library2.selectNone : Copy.Library2.selectAll,
                    systemImage: allPicked ? Symbol.Library.selectNone : Symbol.Library.selectAll
                )
            }
            .buttonStyle(.cobaltIcon(.small))
            .disabled(shareable.isEmpty)
        }
    }

    /// The picks in tap order. The newest scrolls into view as it lands.
    private func thumbs(_ picks: [LibraryRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(picks.enumerated()), id: \.element.id) { index, row in
                        PickThumb(row: row, number: index + 1, controller: controller)
                            .id(row.id)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            }
            .scrollClipDisabled()
            .onChange(of: picks.last?.id) { _, last in
                guard let last else { return }
                withAnimation(Motion.rows) { proxy.scrollTo(last, anchor: .trailing) }
            }
        }
    }
}

/// One pick in the pill: its picture with its number. A tap takes it out of the picks; a hold shows it.
private struct PickThumb: View {
    let row: LibraryRow
    let number: Int
    let controller: LibraryController

    var body: some View {
        Button {
            if controller.takeSwallowedTap() { return }
            withAnimation(Motion.rows) { controller.unpick(row.id) }
        } label: {
            FacePicture(item: row.item, maxPixel: 192, showsGlyph: false)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Text("\(number)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(CobaltColor.onText)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(CobaltColor.text, in: Circle())
                        .offset(x: -5, y: -5)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .peekOnHold(row, controller: controller)
        .accessibilityLabel(LibraryRowCopy.a11yLabel(row))
        .accessibilityHint(Copy.Library2.unpickHint)
    }
}

/// The panel's two sheets (collection, delete), on whichever copy of the panel is drawn.
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
        .spreadSheet(isPresented: $pickingCollection, id: "library-collection") {
            CollectionPickerSheet(store: store, picks: controller.pickedRows(rows), file: file)
        }
        .spreadSheet(isPresented: $deleting, id: "library-delete") {
            let picks = controller.pickedRows(rows).map(\.item).filter { controller.canDelete($0) }
            LibraryDeleteSheet(picks: picks, impact: DeleteImpact(picks: picks, model: model), delete: controller.deletePicks)
        }
    }
}
