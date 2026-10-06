import CobaltKit
import SwiftUI

// The library's menus: the context menu of a tile, row or table line, the sort and show menu, and the view
// switcher.

/// The context menu (long press; right click on the Mac), in this order: open, copy webp link, copy video
/// link, share, save to photos, make public / make private…, rename, then `delete everything…` last and destructive. What the media cannot
/// do is not shown (plain cobalt has no links; a media with nothing on the server cannot be deleted
/// there). `delete everything…` asks the CONTRACT-MEDIA 1.12 confirm, and is off while this device runs
/// something for the media.
struct LibraryMenuItems: View {
    let row: LibraryRow
    let controller: LibraryController

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

/// The two-segment view switcher: `square.grid.2x2` / `list.bullet`, remembered per device by the model.
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

    /// Dates and sizes first-largest; a title reads a to z.
    static func pick(_ key: LibrarySortKey, current: LibrarySort) -> LibrarySort {
        if current.key == key { return LibrarySort(key: key, ascending: !current.ascending) }
        return LibrarySort(key: key, ascending: key == .title)
    }

    var body: some View {
        Menu {
            Section(Copy.Library2.sort) {
                ForEach(LibrarySortKey.allCases, id: \.self) { key in
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
                    ForEach(LibraryShow.allCases, id: \.self) { show in
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
