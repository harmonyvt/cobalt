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
