import CobaltKit
import SwiftUI

/// Select, by the thumb (the S3 board on the library canvas): a white `select` pill floats over the bottom of the
/// library. Tapped, it grows into one panel that holds all of select: how many are picked, the picks as a row of
/// thumbnails in the order they were tapped (tap one to take it out, hold one to see it), then icon buttons for `make link`,
/// `collection` (make the link and file it, picked in `CollectionPickerSheet`), `edit` and `share` (the files). While the panel is up, taps on tiles pick them;
/// otherwise they open, as always. It sits in the library's bottom safe area, so on the iPhone it is above the tab bar,
/// and the same panel is the Mac's and the iPad's.
struct LibrarySelectPill: View {
    let model: AppModel
    let controller: LibraryController
    /// The posts on screen (the chips, the search and the show filter decide which).
    let rows: [LibraryRow]
    let toggle: () -> Void
    let makeLink: () -> Void
    let file: (LibraryController.CollectionTarget) -> Void
    let share: () -> Void

    @State private var pickingCollection = false
    @State private var editNote: String?

    private var store: ShareSetStore { model.shareSets }
    private var makesLinks: Bool { model.capabilities.shareSets }
    private var files: Bool { makesLinks && model.capabilities.shareCollections }

    var body: some View {
        Group {
            if controller.selecting {
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
        .sheet(isPresented: $pickingCollection) {
            CollectionPickerSheet(store: store, picks: controller.pickedRows(rows), file: file)
        }
    }

    // MARK: the pill

    private var startButton: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: Symbol.Gallery.unticked)
                    .font(.system(size: 15, weight: .semibold))
                Text(Copy.Library2.select)
                    .font(CobaltType.bodySemibold)
            }
            .foregroundStyle(CobaltColor.onText)
            .padding(.horizontal, 22)
            .frame(minHeight: 48)
            .background(CobaltColor.text, in: Capsule())
            .contentShape(Capsule())
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(!rows.contains(where: \.shareable))
        .accessibilityLabel(Copy.Library2.select)
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
            if makesLinks, model.capabilities.privateLinks {
                privacyChoice
            }
            if makesLinks, !picks.isEmpty {
                Text(Copy.PrivateLinks.line(for: verdict, count: picks.count, isPrivate: controller.makesPrivateLink))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(verdict == .ready ? CobaltColor.caption : CobaltColor.text)
                    .contentTransition(.opacity)
                    .padding(.horizontal, 4)
            }
            if let editNote, !picks.isEmpty {
                Text(editNote)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .padding(.horizontal, 4)
            }
            // icons only, one equal slot each, so the row always fits the panel (it pushed the panel off an iPhone's
            // edges); all one capsule, each tinted for what it does (SelectActionStyle)
            HStack(spacing: 8) {
                if makesLinks {
                    Button(action: makeLink) {
                        if controller.makingShareLink {
                            ProgressView().controlSize(.small).tint(CobaltColor.onText)
                        } else {
                            Label(Copy.Links.make, systemImage: Symbol.link)
                        }
                    }
                    .buttonStyle(.selectAction(.link))
                    .disabled(!ready)
                    .help(Copy.Links.make)
                    .accessibilityLabel(controller.makingShareLink ? Copy.Links.making : Copy.Links.make)
                    .accessibilityHint(Copy.Links.makeA11yHint)
                }
                if files {
                    Button { pickingCollection = true } label: {
                        Label(Copy.Library2.collection, systemImage: Symbol.Library.collectionFile)
                    }
                    .buttonStyle(.selectAction(.collection))
                    .disabled(!ready)
                    .help(Copy.Library2.collection)
                    .accessibilityLabel(Copy.Library2.collection)
                }
                if model.editor.isAvailable { EditPicksButton(model: model, picks: picks, note: $editNote) }
                Button(action: share) { Label(Copy.Library2.share, systemImage: Symbol.Library.share) }
                    .buttonStyle(.selectAction(.share))
                    .disabled(controller.preparingShare || picks.isEmpty)
                    .help(Copy.Library2.share)
                    .accessibilityLabel(Copy.Library2.share)
            }
        }
        .padding(12)
        .frame(maxWidth: 520)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .motion(Motion.rows, value: picks.map(\.id))
        .motion(Motion.rows, value: verdict)
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
            Text(Copy.Library2.pickedCount(count))
                .font(CobaltType.bodySemibold)
                .foregroundStyle(CobaltColor.text)
                .contentTransition(.numericText())
            Spacer(minLength: 8)
            Button(allPicked ? Copy.Library2.noneShort : Copy.Library2.all) {
                withAnimation(Motion.rows) { controller.toggleAll(rows) }
            }
            .font(CobaltType.captionSmall)
            .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
            .disabled(shareable.isEmpty)
            .accessibilityLabel(allPicked ? Copy.Library2.selectNone : Copy.Library2.selectAll)
            Button(action: toggle) {
                Image(systemName: Symbol.close)
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(CobaltColor.elevated, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Copy.Library2.stopSelecting)
            #if os(macOS)
            .keyboardShortcut(.cancelAction)
            #endif
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
