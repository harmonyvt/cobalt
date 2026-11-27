import CobaltKit
import SwiftUI

// A gallery link's own screen (APP-API-CONTRACT 41.4, mockup share-link-edit): the title, the link with "copy share",
// the public/private badge and its collections; a "how discord shows it" preview of the files that show; then the files
// numbered 1..N in the order Discord shows them, each with its kind and length and "not shown: …" when it no longer
// shows. A tap on a file opens its post. `edit` (toolbar, ⌘E on the Mac) turns the list into the editor: drag to move
// (iPhone and iPad: the handle; Mac: the row), the minus to take out (off at 2), "add files" (off at the maximum), the
// title as a field, and a bar with the changes, cancel and save (⌘S). Cancel with changes asks first; while editing
// the back button is hidden, so leaving always goes through cancel. Save sends the whole list once with `expect`; a
// link changed on another device is reloaded and says so. The toast after a save offers undo. Opened from a link card
// (links tab, a collection) while the server has `features.share_set_edit`, or from the library's "added to" toast.
//
// In the screen pane (apple/CONTRACT-PANE.md section 5) this is the pushed editor of a link's pane page (`edit`): a
// file's tap there opens the post in the pane (`pane.open(.post(id))`) instead of pushing its detail. In the library's
// sheet it still pushes (the sheet is in front of the pane).

/// A link opened from a card (a button and `navigationDestination(item:)`, as collections are).
struct LinkRoute: Hashable, Identifiable {
    let id: String
}

struct LinkScreen: View {
    let model: AppModel
    let setID: String
    /// Shown in a sheet (the library's "open"): a `done` button closes it.
    var inSheet = false
    /// Opens straight into the editor (the pane page's `edit`).
    var startsEditing = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.shell) private var shell
    @Environment(Pane.self) private var pane: Pane?
    @State private var controller: LinksController
    /// The editor's draft; nil reads.
    @State private var draft: ShareSetEdit?
    @State private var saving = false
    @State private var askingDiscard = false
    /// The discard confirm was asked by the pane's close (Escape, the xmark), not by this editor's cancel: discarding closes
    /// the pane too.
    @State private var closingPane = false
    @State private var pickingFiles = false
    @State private var openedPost: OpenedMedia?
    @State private var savedToken = 0
    @State private var failedToken = 0

    init(model: AppModel, setID: String, inSheet: Bool = false, startsEditing: Bool = false) {
        self.model = model
        self.setID = setID
        self.inSheet = inSheet
        self.startsEditing = startsEditing
        _controller = State(initialValue: LinksController(model: model))
    }

    private var store: ShareSetStore { model.shareSets }
    private var link: ShareSet? { store.set(setID) }
    private var editing: Bool { draft != nil }
    private var canEdit: Bool { model.capabilities.shareSetEdit }

    private var screenTitle: String {
        if editing { return Copy.LinkEdit.editTitle }
        return link?.displayTitle ?? Copy.LinkEdit.screenTitle
    }

    var body: some View {
        Group {
            if let link {
                LinkScreenList(
                    model: model, link: link, controller: controller, draft: $draft,
                    openPost: { openPost($0) }, addFiles: { pickingFiles = true })
            } else {
                Color.clear      // revoked (here or elsewhere): the pop below is on its way
            }
        }
        .background(CobaltColor.bg)
        .navigationTitle(screenTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationBarBackButtonHidden(editing)
        .interactiveDismissDisabled(editing)
        // the editor pushed on the pane's stack with unsaved changes: the pane's close (Escape, the xmark, VoiceOver's
        // escape, swiping the sheet down) asks first instead of throwing the draft away
        .paneHoldsClose(!inSheet && (draft?.hasChanges ?? false)) {
            closingPane = true
            askingDiscard = true
        }
        .toolbar { toolbarItems }
        // in a sheet: close and edit sit in its top-right corner (a Mac sheet would draw toolbar items at the bottom)
        .sheetCorner { if canEdit { editButton.labelStyle(.iconOnly) } }
        .environment(\.sheetClose, inSheet && !editing ? SheetCloseAction { dismiss() } : nil)
        .safeAreaInset(edge: .bottom, spacing: 0) { saveBar }
        .modifier(LinkScreenPresentations(
            model: model, link: link, draft: $draft, askingDiscard: $askingDiscard, closingPane: $closingPane,
            pickingFiles: $pickingFiles, openedPost: $openedPost, savedToken: savedToken, failedToken: failedToken))
        .onChange(of: link == nil) { _, gone in
            if gone { draft = nil; dismiss() }
        }
        .task {
            if startsEditing, draft == nil, link != nil { startEdit() }
        }
        .linkPresentations(controller)
    }

    /// A file's tap: its post opens in the pane; in the library's sheet (or with no pane) its detail is pushed.
    private func openPost(_ opened: OpenedMedia) {
        if !inSheet, let pane, let post = opened.item.post {
            pane.open(.post(post.id))
        } else {
            openedPost = opened
        }
    }

    // MARK: the toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        if editing {
            ToolbarItem(placement: .cancellationAction) {
                DuoToolbarButton(title: Copy.LinkEdit.cancel, systemImage: "xmark", role: .cancel) { cancelEdit() }
            }
            .duoVisibilityPriority(.high)
        } else {
            if canEdit, !inSheet {
                ToolbarItem(placement: .primaryAction) { editButton }
                    .duoVisibilityPriority(.high)
            }
        }
    }

    private var editButton: some View {
        Button(Copy.LinkEdit.edit, systemImage: "pencil") { startEdit() }
            .disabled(link == nil)
            #if os(macOS)
            .keyboardShortcut("e", modifiers: .command)
            .help(Copy.LinkEdit.edit)
            #endif
    }

    @ViewBuilder
    private var saveBar: some View {
        if let draft {
            LinkSaveBar(draft: draft, saving: saving, cancel: cancelEdit, save: save)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: edit

    private func startEdit() {
        guard let link, canEdit else { return }
        withAnimation(Motion.rows) {
            draft = ShareSetEdit(set: link, maximum: model.capabilities.limits.shareSetMax)
        }
    }

    /// Cancel: straight out with no changes, else "discard changes?" first.
    private func cancelEdit() {
        guard let draft, !saving else { return }
        if draft.hasChanges {
            closingPane = false
            askingDiscard = true
        } else {
            withAnimation(Motion.rows) { self.draft = nil }
        }
    }

    private func save() {
        guard let draft, draft.canSave, !saving else { return }
        saving = true
        let store = self.store
        let shell = self.shell
        let id = setID
        Task {
            defer { saving = false }
            do {
                let updated = try await store.update(
                    id, items: draft.itemsToSend, title: draft.titleChange, expect: draft.original)
                withAnimation(Motion.rows) { self.draft = nil }
                savedToken += 1
                shell.showNote(LinkEditUndo.note(store: store, shell: shell, before: draft, after: updated))
            } catch ShareSetError.changed {
                // the store holds the server's link now: the draft was made from another list
                withAnimation(Motion.rows) { self.draft = nil }
                failedToken += 1
                shell.showStatus(Copy.LinkEdit.changedElsewhere)
            } catch {
                failedToken += 1
                shell.showStatus(Copy.LinkEdit.message(for: error))
            }
        }
    }
}

// MARK: - the list

/// The screen's list: the header, the discord preview, the numbered files; in edit mode the rows move and take out,
/// and "add files" closes the section.
private struct LinkScreenList: View {
    let model: AppModel
    let link: ShareSet
    let controller: LinksController
    @Binding var draft: ShareSetEdit?
    let openPost: (OpenedMedia) -> Void
    let addFiles: () -> Void

    @Environment(\.shell) private var shell
    @State private var useNormalAudio = false
    @State private var autoUnlockPending = false

    private var maximum: Int { model.capabilities.limits.shareSetMax }
    private var audioEnabled: Bool { model.capabilities.audioLeveling }

    var body: some View {
        let lookup = LinkFileLookup(model: model)
        let ids = draft?.items ?? link.items.map(\.id)
        let audioStore = model.audioLeveling
        let entries = LinkFileEntry.entries(
            ids,
            link: link,
            lookup: lookup,
            audioFor: { id, fallback in audioStore.optimisticAudio(for: id, fallback: fallback) }
        )
        let gate = controller.audioGate(for: link)
        let activeURL = audioEnabled ? gate.resolveURL(base: link.url, useNormal: useNormalAudio) : link.url

        List {
            Section {
                LinkHeader(
                    link: link,
                    controller: controller,
                    title: titleBinding,
                    showsAddressRow: !audioEnabled
                )
                .modifier(LinkListRow())
                if draft == nil, audioEnabled {
                    LinkAudioDock(
                        link: link,
                        gate: gate,
                        target: model.audioLeveling.settings.target,
                        useNormalAudio: $useNormalAudio,
                        activeURL: activeURL,
                        isSubmitting: controller.levelingBulk,
                        isCopied: controller.copiedID == link.id,
                        onCopy: {
                            controller.copy(link, gate: gate, useNormal: useNormalAudio, shell: shell)
                        },
                        onLevelRemaining: {
                            autoUnlockPending = true
                            controller.levelBulk(link: link, shell: shell)
                        },
                        onBlockedTap: {
                            controller.blockedAudioTap(gate: gate, shell: shell)
                        }
                    )
                    .modifier(LinkListRow())
                }
            }
            Section {
                LinkDiscordPreview(heading: heading, entries: entries.filter(\.shows), model: model)
                    .modifier(LinkListRow())
            } header: {
                SectionLabel(text: Copy.LinkEdit.discordSection)
            }
            Section {
                LinkFileList(
                    model: model,
                    linkID: link.id,
                    entries: entries,
                    draft: $draft,
                    openPost: openPost,
                    onLevelSingle: audioEnabled ? { fileID in
                        autoUnlockPending = true
                        controller.levelSingle(fileID: fileID, linkID: link.id, shell: shell)
                    } : nil
                )
                if let draft {
                    LinkAddFilesRow(draft: draft, add: addFiles)
                        .modifier(LinkListRow())
                } else {
                    Text(Copy.LinkEdit.readHint)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .modifier(LinkListRow())
                }
            } header: {
                HStack {
                    SectionLabel(text: Copy.LinkEdit.filesSection)
                    Spacer(minLength: 8)
                    SectionLabel(text: Copy.LinkEdit.countOf(ids.count, max: maximum))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        #if os(iOS)
        .environment(\.editMode, .constant(draft == nil ? .inactive : .active))
        #endif
        .motion(Motion.rows, value: ids)
        .onChange(of: gate.status) { _, status in
            if status != .unlocked {
                useNormalAudio = false
            } else if autoUnlockPending {
                autoUnlockPending = false
                withAnimation(Motion.chip) { useNormalAudio = true }
                shell.showStatus(Copy.AudioBulk.unlockedAuto)
                controller.doneToken += 1
            }
        }
        .refreshable { if draft == nil { await model.shareSets.refresh() } }
    }

    /// The preview's heading: the draft's title, else the link's, else "the ai caption".
    private var heading: String {
        if let draft { return draft.cleanedTitle ?? Copy.LinkEdit.captionTitle }
        if let title = link.title, !title.isEmpty { return title }
        return Copy.LinkEdit.captionTitle
    }

    private var titleBinding: Binding<String>? {
        guard draft != nil else { return nil }
        return Binding(
            get: { draft?.title ?? "" },
            set: { text in draft?.title = LinkEditUndo.cut(text) })
    }
}

/// A row of the link screen's list: no background, no separator, the screen's insets.
private struct LinkListRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}

/// The numbered files: buttons that open the post while reading; rows that move (`onMove`) and take out (the minus)
/// while editing.
private struct LinkFileList: View {
    let model: AppModel
    let linkID: String
    let entries: [LinkFileEntry]
    @Binding var draft: ShareSetEdit?
    let openPost: (OpenedMedia) -> Void
    var onLevelSingle: ((String) -> Void)? = nil

    var body: some View {
        if let current = draft {
            ForEach(entries) { entry in
                LinkFileRow(entry: entry, model: model, remove: { remove(entry.id) }, canRemove: current.canRemove)
                    .modifier(LinkListRow())
            }
            .onMove { from, to in draft?.move(fromOffsets: from, toOffset: to) }
        } else {
            ForEach(entries) { entry in
                LinkFileReadRow(
                    entry: entry,
                    model: model,
                    openPost: openPost,
                    onLevelAudio: onLevelSingle.map { level in { level(entry.id) } }
                )
                .modifier(LinkListRow())
            }
        }
    }

    private func remove(_ id: String) {
        withAnimation(Motion.rows) { draft?.remove(id) }
    }
}

/// A file's row while reading: a tap opens its post (when the library has it), and the trailing loudness pill can
/// level or retry an un-leveled video without nesting buttons.
private struct LinkFileReadRow: View {
    let entry: LinkFileEntry
    let model: AppModel
    let openPost: (OpenedMedia) -> Void
    var onLevelAudio: (() -> Void)? = nil

    private var canLevelRow: Bool {
        guard onLevelAudio != nil, entry.shows, entry.kind == .video else { return false }
        guard let audio = entry.audio else { return true }
        return !audio.isLeveled && !audio.isRendering && !audio.isSilent
    }

    var body: some View {
        LinkFileRow(
            entry: entry,
            model: model,
            onOpen: {
                guard let opened = LinkEditUndo.opened(entry, model: model) else { return }
                openPost(opened)
            },
            showAudioBadge: model.capabilities.audioLeveling,
            onLevelAudio: onLevelAudio
        )
        .contextMenu {
            if canLevelRow, let onLevelAudio {
                Button(
                    entry.audio?.state == .failed ? Copy.AudioBulk.retryLeveling : Copy.AudioBulk.levelAudio,
                    systemImage: entry.audio?.state == .failed ? Symbol.AudioBulk.retry : Symbol.AudioBulk.waveform,
                    action: onLevelAudio
                )
            }
        }
    }
}

/// "add files" with the room left, or "full"; and the 2-file note under it.
private struct LinkAddFilesRow: View {
    let draft: ShareSetEdit
    let add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: add) {
                HStack(spacing: 10) {
                    Label(Copy.LinkEdit.addFiles, systemImage: Symbol.LinkEdit.add)
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(draft.isFull ? CobaltColor.disabledInk : CobaltColor.text)
                    Spacer(minLength: 8)
                    Text(draft.isFull ? Copy.LinkEdit.full(draft.maximum) : Copy.LinkEdit.room(draft.room))
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: Metrics.hit)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(CobaltColor.border, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(draft.isFull)
            if !draft.canRemove {
                Text(Copy.LinkEdit.removeOff)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
            }
        }
    }
}

// MARK: - presentations

/// The discard confirm, the add-files sheet, the post a file opens, and the save haptics.
private struct LinkScreenPresentations: ViewModifier {
    @Environment(Pane.self) private var pane: Pane?
    let model: AppModel
    let link: ShareSet?
    @Binding var draft: ShareSetEdit?
    @Binding var askingDiscard: Bool
    @Binding var closingPane: Bool
    @Binding var pickingFiles: Bool
    @Binding var openedPost: OpenedMedia?
    let savedToken: Int
    let failedToken: Int

    func body(content: Content) -> some View {
        content
            .confirmationDialog(Copy.LinkEdit.discardTitle, isPresented: $askingDiscard, titleVisibility: .visible) {
                Button(Copy.LinkEdit.discard, role: .destructive) {
                    let leaving = closingPane
                    closingPane = false
                    withAnimation(Motion.rows) { draft = nil }
                    // asked by the pane's close: the owner meant to leave, so the pane closes (never held again)
                    if leaving { pane?.close(force: true) }
                }
                Button(Copy.LinkEdit.keepEditing, role: .cancel) { closingPane = false }
            }
            .sheet(isPresented: $pickingFiles) { picker }
            .navigationDestination(item: $openedPost) { target in
                MediaDetail(model: model, item: target.item, initial: target.initial)
            }
            .haptic(.success, trigger: savedToken)
            .haptic(.error, trigger: failedToken)
    }

    @ViewBuilder
    private var picker: some View {
        if let link, let current = draft {
            LinkFilePicker(
                model: model, isPrivate: link.isPrivate, inLink: current.items, room: current.room
            ) { ids in
                withAnimation(Motion.rows) { _ = draft?.append(ids) }
            }
        }
    }
}

// MARK: - helpers

/// The undo after a save, and the small rules the screen shares.
@MainActor
enum LinkEditUndo {
    /// The toast after a save: "link updated", the discord line, and undo (a second PATCH with the old list and title).
    static func note(store: ShareSetStore, shell: ShellActions, before: ShareSetEdit, after: ShareSet) -> StatusNote {
        StatusNote(text: Copy.LinkEdit.updated, detail: Copy.LinkEdit.discordKeeps, actionTitle: Copy.LinkEdit.undo) {
            undo(store: store, shell: shell, before: before, after: after)
        }
    }

    static func undo(store: ShareSetStore, shell: ShellActions, before: ShareSetEdit, after: ShareSet) {
        let now = after.items.map(\.id)
        let items: [String]? = now == before.original ? nil : before.original
        let title: ShareSetTitleChange
        if before.titleChanged {
            if let old = before.originalTitle, !old.isEmpty { title = .set(old) } else { title = .clear }
        } else {
            title = .keep
        }
        guard items != nil || title != .keep else { return }
        Task {
            do {
                try await store.update(after.id, items: items, title: title, expect: now)
                shell.showStatus(Copy.LinkEdit.putBack)
            } catch {
                shell.showStatus(Copy.LinkEdit.message(for: error))
            }
        }
    }

    /// The title field takes at most `ShareSetRule.titleLimit` characters.
    nonisolated static func cut(_ text: String) -> String {
        guard text.unicodeScalars.count > ShareSetRule.titleLimit else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.prefix(ShareSetRule.titleLimit))
        return String(scalars)
    }

    /// The post a file's tap opens, at the rendition that holds the file.
    static func opened(_ entry: LinkFileEntry, model: AppModel) -> OpenedMedia? {
        guard let post = entry.post else { return nil }
        let item = model.mediaItem(for: post)
        let rendition = item.renditions.first { $0.file?.id == entry.id || $0.hosted?.id == entry.id }
        return OpenedMedia(item: item, initial: rendition?.id ?? item.face.id)
    }
}
