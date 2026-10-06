import CobaltKit
import SwiftUI

// The library's menus: the context menu of a tile, row or table line, the sort and show menu, and the view
// switcher.

/// The context menu (long press; right click on the Mac), in this order: open, copy webp link, copy video
/// link, share, save to photos, the offline items (CONTRACT-OFFLINE decision 11), make public / make private…,
/// rename, then `delete everything…` last and destructive. What the media cannot
/// do is not shown (plain cobalt has no links; a media with nothing on the server cannot be deleted
/// there). `delete everything…` asks the CONTRACT-MEDIA 1.12 confirm, and is off while this device runs
/// something for the media.
struct LibraryMenuItems: View {
    let row: LibraryRow
    let controller: LibraryController
    /// Asks the confirm of "remove offline copy": the tile, the list and the table hold the dialog (a menu cannot).
    /// Without it (a preview) the copy goes at once, unless it is the only one.
    var askRemove: ((MediaItem) -> Void)?

    init(row: LibraryRow, controller: LibraryController, askRemove: ((MediaItem) -> Void)? = nil) {
        self.row = row
        self.controller = controller
        self.askRemove = askRemove
    }

    var body: some View {
        let item = row.item
        Button(Copy.Library2.open, systemImage: Symbol.Library.open) { controller.open(row) }
        if let url = controller.webpLink(item) {
            Button(Copy.Library2.copyWebpLink, systemImage: Symbol.Library.copyLink) { controller.copy(url) }
        }
        if let url = controller.videoLink(item) {
            Button(Copy.Library2.copyVideoLink, systemImage: Symbol.Library.copyLink) { controller.copy(url) }
        }
        if let url = controller.shareURL(item) {
            ShareLink(item: url) {
                Label(Copy.Library2.share, systemImage: Symbol.Library.share)
            }
        }
        if controller.canSave(item) {
            #if os(macOS)
            Button(Copy.saveAs, systemImage: Symbol.Library.savePhotos) { controller.save(item) }
            #else
            Button(Copy.Library2.saveToPhotos, systemImage: Symbol.Library.savePhotos) { controller.save(item) }
            #endif
        }
        OfflineMenuItems(item: item, controller: controller, askRemove: askRemove)
        ShowInFilesButton(model: controller.model, item: item)
        if controller.canSwitchVisibility(item) {
            if row.isPublic {
                Button(Copy.Library2.makePrivate, systemImage: Symbol.Library.makePrivate) { controller.makingPrivate = item }
            } else {
                Button(Copy.Library2.makePublic, systemImage: Symbol.Library.makePublic) { controller.setVisibility(item, public: true) }
            }
        }
        Button(Copy.Library2.rename, systemImage: Symbol.Library.rename) { controller.renaming = item }
        ShowInFinderButton(model: controller.model, videos: item.local?.renditions ?? [])
        if controller.canDelete(item) {
            Divider()
            Button(Copy.Library2.deleteEverything, systemImage: Symbol.Library.deleteEverything, role: .destructive) {
                controller.deleting = item
            }
            .disabled(controller.isBusy(item))
        }
    }
}

/// What the media's offline state lets the owner do, one rendition at a time (CONTRACT-OFFLINE decision 11).
/// A cached file only flips to kept; `unavailable` (nothing to fetch it from) offers nothing.
@MainActor
struct OfflinePlan {
    /// Something downloads or waits for the network: the one thing to offer is "stop downloading".
    var active = false
    /// A rendition can be fetched, or flipped from the cache to kept (a retry after a failure counts).
    var canKeep = false
    /// A rendition is kept here: its file can go.
    var hasKept = false
    /// A kept rendition is the only copy: the confirm says it cannot come back.
    var onlyCopy = false

    init(item: MediaItem, model: AppModel) {
        for rendition in item.renditions {
            switch model.offlineState(of: rendition) {
            case .downloading, .waiting:
                active = true
            case .offline:
                hasKept = true
                if model.isOnlyCopy(rendition) { onlyCopy = true }
            case .cached, .failed, .none:
                canKeep = true
            case .unavailable:
                break
            }
        }
    }
}

/// Exactly one of "keep offline", "stop downloading" and "remove offline copy" (both of the first and the last when
/// only some of the media is kept).
struct OfflineMenuItems: View {
    let item: MediaItem
    let controller: LibraryController
    var askRemove: ((MediaItem) -> Void)?

    var body: some View {
        let model = controller.model
        let plan = OfflinePlan(item: item, model: model)
        if !model.store.canKeep {
            EmptyView()
        } else if plan.active {
            Button(Copy.Offline.stop, systemImage: Symbol.stopDownloading) { model.stopDownloading(item) }
        } else {
            if plan.canKeep {
                Button(Copy.Offline.keep, systemImage: Symbol.keepOffline) { model.keepOffline(item) }
            }
            if plan.hasKept, askRemove != nil || !plan.onlyCopy {
                Button(Copy.Offline.removeCopy, systemImage: Symbol.removeOffline) {
                    if let askRemove { askRemove(item) } else { Task { await model.removeOfflineCopy(item) } }
                }
                .disabled(controller.isBusy(item))
            }
        }
    }
}

/// "show in files" (iPhone and iPad): the media's folder in the files app. Drawn only while a kept file is in the
/// visible root and the model has a link that opens it; empty elsewhere (the Mac has `ShowInFinderButton`), so a
/// menu can list it unconditionally.
struct ShowInFilesButton: View {
    let model: AppModel
    let item: MediaItem
    #if os(iOS)
    @Environment(\.openURL) private var openURL
    #endif

    var body: some View {
        #if os(iOS)
        if model.store.canKeep, item.renditions.contains(where: { $0.local?.place == .offline }), let url = model.showInFilesURL(item) {
            Button(Copy.Offline.showInFiles, systemImage: Symbol.showInFiles) { openURL(url) }
        }
        #else
        EmptyView()
        #endif
    }
}

/// What the context menu shows above its items: the face at its aspect with the title and its meta under it.
struct LibraryPreviewCard: View {
    let row: LibraryRow
    private let width: CGFloat = 236

    var body: some View {
        let aspect = MasonryPlan.clampAspect(row.faceAspect)
        VStack(alignment: .leading, spacing: 0) {
            FacePicture(item: row.item, maxPixel: 480, gradient: 1)
                .frame(width: width, height: (width * aspect).rounded())
            VStack(alignment: .leading, spacing: 3) {
                LibraryTitleText(row: row, size: 12)
                Text(LibraryRowCopy.meta(row, now: Date()))
                    .font(CobaltType.badge)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(width: width, alignment: .leading)
        }
        .frame(width: width)
        .background(CobaltColor.surface)
    }
}

/// One half of the iPhone and iPad's view switcher: a plain toolbar button for a view, the current one filled and
/// in the primary ink. Two of them in a `ToolbarItemGroup` share one glass capsule.
struct LibraryViewButton: View {
    @Bindable var library: LibraryModel
    let mode: LibraryViewMode

    var body: some View {
        let selected = library.viewMode == mode
        Button {
            library.viewMode = mode
        } label: {
            Image(systemName: mode == .mosaic ? Symbol.Library.mosaic : Symbol.Library.table)
                .symbolVariant(selected ? .fill : .none)
                .foregroundStyle(selected ? .primary : .secondary)
        }
        .accessibilityLabel(Copy.Library2.name(mode))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(Copy.Library2.name(mode))
    }
}

/// The Mac's two-segment view switcher: `square.grid.2x2` / `list.bullet`, remembered per device by the model.
struct LibraryViewSwitcher: View {
    @Bindable var library: LibraryModel

    var body: some View {
        Picker(Copy.Library2.view, selection: $library.viewMode) {
            ForEach(LibraryViewMode.allCases, id: \.self) { mode in
                Image(systemName: mode == .mosaic ? Symbol.Library.mosaic : Symbol.Library.table)
                    .accessibilityLabel(Copy.Library2.name(mode))
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 96)
        .accessibilityLabel(Copy.Library2.view)
        .help(Copy.Library2.view)
    }
}

/// The `arrow.up.arrow.down` menu: a `sort` list (picking the current key again reverses it; the current key
/// carries `chevron.down` / `chevron.up`) and a `show` list. The table's header mirrors the same sort.
struct LibrarySortMenu: View {
    @Bindable var library: LibraryModel
    /// False where nothing can be kept offline: the `offline` sort key and `show` case are not offered.
    var offersOffline = true

    /// Dates and sizes first-largest; a title reads a to z.
    static func pick(_ key: LibrarySortKey, current: LibrarySort) -> LibrarySort {
        if current.key == key { return LibrarySort(key: key, ascending: !current.ascending) }
        return LibrarySort(key: key, ascending: key == .title)
    }

    var body: some View {
        Menu {
            Section(Copy.Library2.sort) {
                ForEach(LibrarySortKey.allCases.filter { offersOffline || $0 != .offline }, id: \.self) { key in
                    Button {
                        library.sort = Self.pick(key, current: library.sort)
                    } label: {
                        if library.sort.key == key {
                            Label(Copy.Library2.name(key), systemImage: library.sort.ascending ? Symbol.Library.ascending : Symbol.Library.descending)
                        } else {
                            Text(Copy.Library2.name(key))
                        }
                    }
                    .accessibilityValue(library.sort.key == key ? Copy.Library2.direction(library.sort) : "")
                }
            }
            Section(Copy.Library2.show) {
                Picker(Copy.Library2.show, selection: $library.show) {
                    ForEach(LibraryShow.allCases.filter { offersOffline || $0 != .offline }, id: \.self) { show in
                        Text(Copy.Library2.name(show)).tag(show)
                    }
                }
                .pickerStyle(.inline)
            }
        } label: {
            Label(Copy.Library2.sort, systemImage: Symbol.Library.sortMenu).labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .help(Copy.Library2.sort)
        .accessibilityLabel(Copy.Library2.sort)
        .accessibilityValue("\(Copy.Library2.name(library.sort.key)), \(Copy.Library2.direction(library.sort))")
    }
}
