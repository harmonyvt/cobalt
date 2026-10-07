import CobaltKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// "folder" (macOS): the Finder folder that holds the offline files (CONTRACT-OFFLINE.md section 13): `~/Movies/cobalt`
/// unless the owner chose another. Driven by `model.macFolder.status`; this view only draws it and forwards the owner's
/// choices. Nothing is drawn where `isAvailable` is false (iPhone, iPad).
///
/// Wave M1 compile shim for the old "save to a folder" section (the copier is gone): the folder row, its three buttons,
/// the problem line and the "move the offline files?" question, copy as 13.10 pins it. The Mac surfaces lane (M2) folds it
/// into the "on this mac" section.
struct FolderSettingsSection: View {
    let model: AppModel

    /// "move the N offline files to <path>?": N while the dialog is open.
    @State private var moveCount: Int?
    @State private var notice: String?

    private var folder: MacFolder { model.macFolder }
    private var status: MacFolder.Status { folder.status }

    var body: some View {
        if folder.isAvailable {
            Section {
                folderRow
                    .confirmationDialog(
                        moveCount.map { "move the \($0) offline files to \(status.path)?" } ?? "",
                        isPresented: Binding(get: { moveCount != nil }, set: { if !$0 { answer(nil) } }),
                        titleVisibility: .visible
                    ) {
                        Button("move") { answer(true) }
                        // not `.cancel`: from iOS 26 / macOS 26 a dialog anchored to its row drops its cancel button, and this is a real answer
                        Button("leave them") { answer(false) }
                    } message: {
                        Text("left behind, they stay in the old folder and aren't offline here any more.")
                    }
                actionsRow
                if let line = problemLine {
                    Text(line).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.errorText)
                }
                if let notice {
                    Text(notice).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.errorText)
                }
            } header: {
                Text(Copy.Folder.group).font(CobaltType.caption).textCase(nil)
            } footer: {
                Text("offline files stay in this folder until you remove them, here or in finder.").font(CobaltType.captionSmall).lineSpacing(2)
            }
        }
    }

    private var problemLine: String? {
        switch status.problem {
        case .unreachable: return "this folder isn't connected. new saves wait on this mac until it's back."
        case .notAllowed: return "cobalt can't write to this folder."
        case .wrongFolder: return "this isn't the folder cobalt was using. choose it again."
        case .diskFull: return "the disk is full."
        case nil: return nil
        }
    }

    private var folderRow: some View {
        LabeledContent {
            Text(status.path)
                .font(Font.cobalt(12.5))
                .foregroundStyle(status.problem != nil ? CobaltColor.errorText : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(status.path)
        } label: {
            Label(Copy.Folder.row, systemImage: Symbol.Folder.row)
        }
    }

    private var actionsRow: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button(Copy.Folder.choose, systemImage: Symbol.Folder.choose, action: chooseFolder)
            Button(Copy.Folder.showInFinder, systemImage: Symbol.Folder.showInFinder) {
                Task { await folder.reveal() }
            }
            .disabled(status.problem == .unreachable)
            if !status.isDefault {
                Button("use ~/Movies/cobalt", systemImage: Symbol.Folder.reset, action: resetToDefault)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .labelStyle(.titleOnly)
    }

    // MARK: actions

    private func handle(_ outcome: MacFolder.ChooseOutcome) {
        switch outcome {
        case .chosen, .unchanged: break
        case .askMove(let count): moveCount = count
        case .refusedICloud: notice = "pick a folder on this mac or an external disk. icloud drive folders can't hold offline files."
        case .failed: notice = Copy.Folder.chooseFailed
        }
    }

    /// Idempotent: a button and the dialog's own dismissal can both land here.
    private func answer(_ move: Bool?) {
        guard moveCount != nil else { return }
        moveCount = nil
        Task { await folder.answerMove(move) }
    }

    private func resetToDefault() {
        notice = nil
        Task { handle(await folder.resetToDefault()) }
    }

    private func picked(_ url: URL) async {
        notice = nil
        handle(await folder.chooseFolder(url))
    }

    /// The folder picker. AppKit calls the completion on a thread of its choosing: it is `@Sendable` and
    /// hops to the main actor explicitly.
    private func chooseFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = Copy.Folder.choosePrompt
        panel.message = "offline files are kept in this folder."
        panel.directoryURL = URL(fileURLWithPath: (status.path as NSString).expandingTildeInPath, isDirectory: true)
        let chosen: @Sendable (NSApplication.ModalResponse) -> Void = { response in
            Task { @MainActor in
                guard response == .OK, let url = panel.url else { return }
                await picked(url)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: chosen)
        } else {
            panel.begin(completionHandler: chosen)
        }
        #endif
    }
}
