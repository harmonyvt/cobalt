import CobaltKit
import SwiftUI

extension Capabilities {
    /// The file circle / toolbar button: only where the server can take an upload.
    var showsFileButton: Bool {
        switch kind {
        case .plainCobalt, .legacyFork: return false
        case .fork: return upload
        default: return true
        }
    }
}

/// Paste and file as plain toolbar icons (the library's header, and the Mac's window toolbar). The
/// two white circles on home are the only custom-styled buttons; everywhere else these are the
/// system's own toolbar buttons.
struct PasteFileButtons: View {
    let showsFile: Bool
    @Environment(\.shell) private var shell

    var body: some View {
        Button { shell.paste() } label: {
            Label(Copy.pasteA11y, systemImage: Symbol.paste).labelStyle(.iconOnly)
        }
        .help(Copy.pasteA11y)
        if showsFile {
            FileSourceMenu {
                Label(Copy.fileA11y, systemImage: Symbol.file).labelStyle(.iconOnly)
            }
            .help(Copy.fileA11y)
        }
    }
}

/// What the file button opens: where the file comes from. Photos (the system picker, no library permission
/// asked) or files (the Files importer). Icon first, lowercase, as the system's own menus.
struct FileSourceMenu<Label: View>: View {
    @ViewBuilder var label: () -> Label
    @Environment(\.shell) private var shell

    var body: some View {
        Menu {
            Button(Copy.sourcePhotos, systemImage: Symbol.sourcePhotos) { shell.choosePhotos() }
            Button(Copy.sourceFiles, systemImage: Symbol.sourceFiles) { shell.chooseFile() }
        } label: {
            label()
        }
        .menuIndicator(.hidden)
    }
}

#if os(iOS)
// MARK: the iPhone's header (apple 04-PHASE4 4.1)
//
// Every root screen of the four tabs ends its bar the same way: the activity pill, then the settings gear, rightmost.
// A screen that wants one more control there (the library's `⋯` menu) hands it to `PhoneRootToolbar`, which puts it first, so
// the bar never has more than three items: that control, the pill, the gear.

/// The settings gear. Opens `SettingsScreen` in a sheet (with `done`) over whichever tab is up; where there is no phone shell
/// around it (a preview), it asks the shell to open settings instead.
struct PhoneGearButton: View {
    @Environment(PhoneNavState.self) private var nav: PhoneNavState?
    @Environment(\.shell) private var shell

    var body: some View {
        Button {
            if let nav { nav.settingsShown = true } else { shell.openSettings() }
        } label: {
            Label(Copy.PhoneNav.settings, systemImage: Symbol.PhoneNav.settings).labelStyle(.iconOnly)
        }
        .accessibilityIdentifier("phone.settings")
        .accessibilityHint(Copy.PhoneNav.settingsHint)
    }
}

/// Set (true) by the phone shell around a root screen whose bar the shell fills with `PhoneRootToolbar`: `QueueToolbarItem`
/// inside that screen then draws nothing. SwiftUI puts an outer `.toolbar`'s items before the screen's own, so without this the
/// gear would land left of the pill.
private struct PhoneHeaderOwnsActivityKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var phoneHeaderOwnsActivity: Bool {
        get { self[PhoneHeaderOwnsActivityKey.self] }
        set { self[PhoneHeaderOwnsActivityKey.self] = newValue }
    }
}

/// The gear alone, trailing.
struct PhoneGearItem: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { PhoneGearButton() }
    }
}

/// A root screen's trailing bar items on the iPhone: its own `leading` control (optional), the activity pill, the settings gear.
/// Use it in place of `QueueToolbarItem(model:)` on a screen that is a root of one of the four tabs and brings its own
/// navigation stack (the library, iPhone only: `UIDevice.current.userInterfaceIdiom == .phone`); the other three tabs get theirs
/// from the shell, which sets `phoneHeaderOwnsActivity` so the screen's own `QueueToolbarItem` is silent.
///
///     .toolbar {
///         PhoneRootToolbar(model: model) { Menu { ... } label: { Label("more", systemImage: "ellipsis").labelStyle(.iconOnly) } }
///     }
///
/// With no control: `PhoneRootToolbar(model: model)`.
struct PhoneRootToolbar: ToolbarContent {
    let model: AppModel
    private let leading: AnyView?

    init(model: AppModel) {
        self.model = model
        leading = nil
    }

    init<Leading: View>(model: AppModel, @ViewBuilder leading: () -> Leading) {
        self.model = model
        self.leading = AnyView(leading())
    }

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        if let leading {
            ToolbarItem(placement: .topBarTrailing) { leading }
        }
        ToolbarItem(placement: .topBarTrailing) { ActivityPill(model: model) }
        PhoneGearItem()
    }
}
#endif
