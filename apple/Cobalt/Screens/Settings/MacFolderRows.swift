import CobaltKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The folder rows of "on this mac" (CONTRACT-OFFLINE.md 13.10): the Finder folder that holds the offline files
/// (`~/Movies/cobalt` unless the owner chose another), its three buttons, the problem line, the move progress and the
/// "move the N offline files to <path>?" question. Rows only: `StorageSettingsSection` puts them in its one section, in the
/// contract's order. Driven by `model.macFolder.status`; this view only draws it and forwards the owner's choices. Nothing is
/// drawn where `isAvailable` is false (iPhone, iPad).
struct MacFolderRows: View {
    let model: AppModel

    /// "move the N offline files to <path>?": N while the dialog is open, and the folder it is about.
    @State private var moveCount: Int?
    @State private var movePath = ""
    @State private var notice: String?

    private var folder: MacFolder { model.macFolder }
    private var status: MacFolder.Status { folder.status }

    var body: some View {
        if folder.isAvailable {
            folderRow
                .confirmationDialog(
                    moveCount.map { Copy.Folder.moveTitle(count: $0, path: movePath) } ?? "",
                    isPresented: Binding(get: { moveCount != nil }, set: { if !$0 { answer(nil) } }),
                    titleVisibility: .visible
                ) {
                    Button(Copy.Folder.move) { answer(true) }
                    // not `.cancel`: from iOS 26 / macOS 26 a dialog anchored to its row drops its cancel button, and this is a real answer
                    Button(Copy.Folder.leaveThem) { answer(false) }
                } message: {
                    Text(Copy.Folder.moveMessage)
                }
            actionsRow
            if let moving = status.moving {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Copy.Folder.moving(done: moving.done, of: moving.total))
                        .font(Font.cobalt(12.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    ProgressView(value: Double(min(moving.done, moving.total)), total: Double(max(moving.total, 1)))
                        .progressViewStyle(.linear)
                        .tint(CobaltColor.text)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
            }
            if let line = Self.problemLine(status.problem) {
                problem(line)
            }
            if let notice { problem(notice) }
        }
    }

    /// The problem line of a folder state; nil when there is none.
    static func problemLine(_ problem: MacFolder.Problem?) -> String? {
        switch problem {
        case .unreachable: return Copy.Folder.unreachable
        case .notAllowed: return Copy.Folder.notAllowed
        case .wrongFolder: return Copy.Folder.wrongFolder
        case .diskFull: return Copy.Folder.diskFull
        case nil: return nil
        }
    }

    private func problem(_ text: String) -> some View {
        Text(text).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.errorText)
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
            Button(Copy.Folder.showInFinder, systemImage: Symbol.showInFinder) {
                Task { await folder.reveal() }
            }
            .disabled(status.problem == .unreachable)
            .help(status.problem == .unreachable ? Copy.Folder.notConnected(path: status.path) : "")
            if !status.isDefault {
                Button(Copy.Folder.useDefault, systemImage: Symbol.Folder.reset, action: resetToDefault)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .labelStyle(.titleOnly)
        .disabled(status.moving != nil)
    }

    // MARK: actions

    private func handle(_ outcome: MacFolder.ChooseOutcome, path: String) {
        switch outcome {
        case .chosen, .unchanged: break
        case .askMove(let count):
            movePath = path
            moveCount = count
        case .refusedICloud: notice = Copy.Folder.refusedICloud
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
        Task { handle(await folder.resetToDefault(), path: "~/Movies/cobalt") }
    }

    #if os(macOS)
    private func picked(_ url: URL) async {
        notice = nil
        handle(await folder.chooseFolder(url), path: (url.path as NSString).abbreviatingWithTildeInPath)
    }
    #endif

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
        panel.message = Copy.Folder.chooseMessage
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
