#if os(iOS)
import CobaltKit
import SwiftUI

/// The iPhone library's one "…" menu (APP-spec 04, section 4.3 item 1): everything the bar used to spread over six
/// icons (the two view buttons, the sky map, sort, paste and files) plus the album and select, so the bar keeps
/// only this menu, the activity pill and the shell's settings gear.
///
/// Every capability stays reachable: view (mosaic or list), select, sort and filter (the same lists as the iPad's sort
/// menu, as a submenu), the hidden album, the sky map (only where the search has embedded the posts), and adding a
/// link, photos or a file. The kind chips under the bar stay as they were.
struct LibraryPhoneMenu: View {
    let model: AppModel
    @Bindable var controller: LibraryController
    let toggleSelecting: () -> Void
    @Environment(\.shell) private var shell

    private var library: LibraryModel { model.library }

    var body: some View {
        @Bindable var library = model.library
        Menu {
            Section {
                Button(action: toggleSelecting) {
                    Label(
                        controller.selecting ? Copy.Library2.doneSelecting : Copy.Library2.select,
                        systemImage: Symbol.Library.select)
                }
                .accessibilityIdentifier("library.more.select")
                if model.capabilities.hidden {
                    Toggle(isOn: $library.showingHidden) {
                        Label(Copy.HiddenAlbum.chipName, systemImage: Symbol.HiddenRules.hidden)
                    }
                    .accessibilityIdentifier("library.more.hidden")
                }
                if model.capabilities.search, !controller.selecting {
                    Button { controller.showingSkyMap = true } label: {
                        Label(Copy.SkyMap.title, systemImage: Symbol.SkyMap.button)
                    }
                }
            }
            Section(Copy.Library2.view) {
                Picker(Copy.Library2.view, selection: $library.viewMode) {
                    ForEach(LibraryViewMode.allCases, id: \.self) { mode in
                        Label(
                            Copy.Library2.name(mode),
                            systemImage: mode == .mosaic ? Symbol.Library.mosaic : Symbol.Library.table
                        ).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            }
            Menu {
                LibrarySortItems(
                    library: library, offersOffline: model.store.canKeep, offersKinds: model.capabilities.gallery)
            } label: {
                Label(Copy.Library2.sort, systemImage: Symbol.Library.sortMenu)
            }
            .accessibilityIdentifier("library.sort")
            Section {
                Button(Copy.pasteA11y, systemImage: Symbol.paste) { shell.paste() }
                if model.capabilities.showsFileButton {
                    Button(Copy.sourcePhotos, systemImage: Symbol.sourcePhotos) { shell.choosePhotos() }
                    Button(Copy.sourceFiles, systemImage: Symbol.sourceFiles) { shell.chooseFile() }
                }
            }
        } label: {
            Label(Copy.Media.more, systemImage: Symbol.Library.more).labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(Copy.Media.more)
        .accessibilityValue("\(Copy.Library2.name(library.sort.key)), \(Copy.Library2.name(library.viewMode))")
        // the layout checks (apple/CobaltUITests) find the bar's menu by this
        .accessibilityIdentifier("library.more")
    }
}
#endif
