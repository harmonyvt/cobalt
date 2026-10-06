import CobaltKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// "folder" (macOS): the Mac's counterpart of the photos album. Every video and webp cobalt keeps is
/// copied once into a folder in Finder: `~/Movies/cobalt` unless the owner chose another. Driven by
/// `model.folderSync.status`; this view only draws it and forwards the owner's choices. Nothing is drawn
/// where `isAvailable` is false (iPhone, iPad).
struct FolderSettingsSection: View {
    let model: AppModel

    /// The toggle reads on while turning it on is under way.
    @State private var enabling = false
    /// "also save the N videos already in cobalt?": N while the dialog is open.
    @State private var backfillCount: Int?
    @State private var notice: String?

    private var sync: FolderSync { model.folderSync }
    private var status: FolderSync.Status { sync.status }

    var body: some View {
        if sync.isAvailable {
            Section {
                folderToggle
                if status.enabled {
                    folderRow
                    actionsRow
                    statusRow
                    if status.existing > 0 {
                        Button(Copy.Folder.existingRow(status.existing), systemImage: Symbol.Folder.existing) {
                            Task { await sync.includeExisting(true) }
                        }
                    }
                    if let notice {
                        Text(notice).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.errorText)
                    }
                }
            } header: {
                Text(Copy.Folder.group).font(CobaltType.caption).textCase(nil)
            } footer: {
                Text(status.enabled ? Copy.Folder.footer : Copy.Folder.footerOff).font(CobaltType.captionSmall).lineSpacing(2)
            }
        }
    }

    // MARK: rows

    private var folderToggle: some View {
        Toggle(isOn: Binding(
            get: { status.enabled || enabling },
            set: { on in
                if on { turnOn() } else { sync.disable() }
            })) {
            Label(Copy.Folder.toggle, systemImage: Symbol.Folder.toggle)
        }
        .confirmationDialog(
            backfillCount.map { Copy.Folder.backfillTitle($0) } ?? "",
            isPresented: Binding(
                get: { backfillCount != nil },
                set: { if !$0 { answerBackfill(false) } }),
            titleVisibility: .visible
        ) {
            Button(backfillCount.map { Copy.Folder.backfillAdd($0) } ?? "") { answerBackfill(true) }
            // not `.cancel`: from iOS 26 / macOS 26 a dialog anchored to its row drops its cancel button, and this is a real answer
            Button(Copy.Folder.backfillSkip) { answerBackfill(false) }
        }
    }

    private var folderRow: some View {
        LabeledContent {
            Text(status.path)
                .font(Font.cobalt(12.5))
                .foregroundStyle(status.problem == .folderMissing || status.problem == .notAllowed ? CobaltColor.errorText : Color.secondary)
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
                Task { await sync.revealInFinder() }
            }
            if !status.isDefault {
                Button(Copy.Folder.resetToDefault, systemImage: Symbol.Folder.reset, action: resetToDefault)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .labelStyle(.titleOnly)
    }

    private var statusRow: some View {
        let line = FolderStatusLine(status)
        return VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(line.text)
                        .foregroundStyle(line.textIsProblem ? CobaltColor.errorText : Color.secondary)
                        .monospacedDigit()
                    if let extra = line.extra {
                        Text(extra).foregroundStyle(CobaltColor.errorText)
                    }
                }
                .font(Font.cobalt(12.5))
                .multilineTextAlignment(.trailing)
            } label: {
                Label(Copy.Folder.statusRow, systemImage: line.showsProblemIcon ? Symbol.Folder.problem : Symbol.Folder.status)
            }
            if let progress = status.progress, progress.total > 0 {
                ProgressView(value: Double(min(progress.done, progress.total)), total: Double(progress.total))
                    .progressViewStyle(.linear)
                    .tint(CobaltColor.text)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: actions

    private func turnOn() {
        guard !enabling else { return }
        enabling = true
        Task {
            let existing = await sync.enable()
            enabling = false
            if existing > 0 { backfillCount = existing }
        }
    }

    /// The once-only question. Idempotent: a button and the dialog's own dismissal can both land here.
    private func answerBackfill(_ include: Bool) {
        guard backfillCount != nil else { return }
        backfillCount = nil
        Task { await sync.includeExisting(include) }
    }

    private func resetToDefault() {
        notice = nil
        Task {
            if case .chosen(let existing) = await sync.resetToDefault(), existing > 0 { backfillCount = existing }
        }
    }

    private func picked(_ url: URL) async {
        notice = nil
        switch await sync.chooseFolder(url) {
        case .chosen(let existing): if existing > 0 { backfillCount = existing }
        case .unchanged: break
        case .failed: notice = Copy.Folder.chooseFailed
        }
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

/// What the status row says: a problem first (folder gone, no permission, disk full), else what is being
/// saved, else the count with what waits.
struct FolderStatusLine {
    let text: String
    /// A second line: what could not be saved, when the first line is about something else.
    let extra: String?
    let textIsProblem: Bool
    var showsProblemIcon: Bool { textIsProblem || extra != nil }

    init(_ s: FolderSync.Status) {
        let gaveUp = s.gaveUp > 0 ? Copy.Folder.gaveUp(s.gaveUp) : nil
        switch s.problem {
        case .folderMissing: self.init(Copy.Folder.folderMissing, gaveUp, true)
        case .notAllowed: self.init(Copy.Folder.notAllowed, gaveUp, true)
        case .diskFull: self.init(Copy.Folder.diskFull(s.waiting), gaveUp, true)
        case nil:
            if let progress = s.progress {
                self.init(Copy.Folder.saving(progress.done, of: progress.total), gaveUp, false)
            } else if s.saved == 0, s.waiting == 0, let gaveUp {
                self.init(gaveUp, nil, true)
            } else {
                let count = Copy.Folder.saved(s.saved) + (s.waiting > 0 ? " · " + Copy.Folder.waiting(s.waiting) : "")
                self.init(count, gaveUp, false)
            }
        }
    }

    private init(_ text: String, _ extra: String?, _ textIsProblem: Bool) {
        self.text = text
        self.extra = extra
        self.textIsProblem = textIsProblem
    }
}
