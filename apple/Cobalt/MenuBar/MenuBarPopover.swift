#if os(macOS)
import AppKit
import CobaltKit
import SwiftUI

/// The menu bar window: paste a link, watch the jobs, keep saves offline. A choice the window
/// already asks (several links, a file's name, a multi-item post) is handed to that window.
struct MenuBarPopover: View {
    let model: AppModel

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @State private var compact = false
    @State private var activityOpen = true
    @State private var offlineOpen = true
    @State private var finderOpen = true
    @State private var note: String?
    @State private var watched: Set<Job.ID> = []
    @State private var forwarded: Set<Job.ID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if !compact { account }
            paste
            if compact {
                compactSummary
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        activity
                        offline
                        finder
                    }
                }
                .frame(maxHeight: 420)
                .scrollBounceBehavior(.basedOnSize)
            }
            menu
        }
        .padding(10)
        .frame(width: 336)
        .tint(CobaltColor.text)
        .cobaltRoot(model: model)
        .onAppear {
            arm()
            model.menuBarFinder.reload()
            model.unifiedQueue.setVisible(true)
            if model.capabilities.accounts { Task { await model.account.refresh() } }
        }
        .onChange(of: model.finderSidebar) { _, _ in model.menuBarFinder.reload() }
        .onChange(of: model.finderSidebarNote) { _, _ in model.menuBarFinder.reload() }
        .onChange(of: model.library.isLoading) { _, _ in model.menuBarFinder.reload() }
        .onChange(of: model.library.loadingAll.map { "\($0.loaded)/\($0.total)" }) { _, _ in
            model.menuBarFinder.reload()
        }
        .onDisappear {
            if model.selectedTab != .queue { model.unifiedQueue.setVisible(false) }
        }
        .onChange(of: ownerJob) { _, id in forward(id) }
        .task(id: note) {
            guard note != nil else { return }
            try? await Task.sleep(for: .seconds(2.6))
            note = nil
        }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Copy.appName)
                    .font(Font.cobalt(15, .semibold, relativeTo: .headline))
                    .foregroundStyle(CobaltColor.text)
                HStack(spacing: 6) {
                    Circle().fill(connectionColor).frame(width: 7, height: 7)
                    Text(connectionText)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if connection == .offline {
                smallButton(Copy.Queue.tryAgain) { tryServer() }
            }
            chevron(open: !compact) { compact.toggle() }
        }
    }

    private var connection: Connection {
        if model.capabilities.kind == .unreachable || model.unifiedQueue.serverProblem { return .offline }
        if model.isCheckingServer { return .waking }
        if model.queue.live.contains(where: { $0.pipeline.progressStory?.waking == true }) { return .waking }
        return .connected
    }

    private var connectionText: String {
        switch connection {
        case .connected: return Copy.MenuBar.connected
        case .waking: return Copy.MenuBar.waking
        case .offline: return Copy.Queue.serverProblem
        }
    }

    private var connectionColor: Color {
        switch connection {
        case .connected: return CobaltColor.success
        case .waking: return CobaltColor.collection
        case .offline: return CobaltColor.error
        }
    }

    private func tryServer() {
        Task {
            await model.refreshServer()
            _ = await model.unifiedQueue.refresh()
        }
    }

    // MARK: account

    private var account: some View {
        Button {
            NSApp.activate()
            openSettings()
        } label: {
            HStack(spacing: 10) {
                Text(accountInitial)
                    .font(Font.cobalt(13, .semibold))
                    .foregroundStyle(CobaltColor.text)
                    .frame(width: 30, height: 30)
                    .background(CobaltColor.text.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(accountTitle)
                        .font(Font.cobalt(12.5, .medium))
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(1)
                    Text(accountSubtitle)
                        .font(CobaltType.tab)
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CobaltColor.caption)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { hairline }
        .overlay(alignment: .bottom) { hairline }
    }

    private var signedOut: Bool { model.signInPinned || !model.settings.hasAPIKey }

    private var accountTitle: String {
        if signedOut { return Copy.Account.signedOutRow }
        if let email = model.account.email { return "\(email) · \(Copy.Account.signedIn)" }
        if let name = model.serverSummary.keyName { return "\(name) · \(Copy.Account.signedIn)" }
        return Copy.Account.signedIn
    }

    private var accountSubtitle: String {
        if signedOut { return Copy.Account.signedOutHint }
        if let name = model.serverSummary.keyName, model.account.email != nil {
            return "\(name) · \(model.serverSummary.host)"
        }
        return model.serverSummary.host
    }

    private var accountInitial: String {
        let source = model.account.email ?? model.serverSummary.keyName ?? Copy.appName
        return String(source.prefix(1)).lowercased()
    }

    // MARK: paste

    private var paste: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: pasteLink) {
                HStack(spacing: 10) {
                    Text("+")
                        .font(Font.cobalt(15, .semibold))
                        .foregroundStyle(CobaltColor.text)
                        .frame(width: 26, height: 26)
                        .background(CobaltColor.onText, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Copy.MenuBar.pasteLink)
                            .font(Font.cobalt(13, .semibold))
                        Text(Copy.MenuBar.pasteHint)
                            .font(CobaltType.tab)
                            .opacity(0.7)
                    }
                    Spacer(minLength: 0)
                    Text(Copy.MenuBar.shortcutPaste)
                        .font(CobaltType.caption)
                        .opacity(0.65)
                }
                .foregroundStyle(CobaltColor.onText)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(CobaltColor.text, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("v", modifiers: .command)
            .accessibilityLabel(Copy.MenuBar.pasteLink)
            if let note {
                Text(note)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(note == Copy.Jobs.noLink || note == Copy.Jobs.duplicate ? CobaltColor.errorText : CobaltColor.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pasteLink() {
        let items = Pasteboard.contents()
        switch PasteRouter.plan(for: items, model: model) {
        case .needsAttention:
            MenuBarHandoff.shared.stage(items: items)
            reveal()
        default:
            switch PasteRouter.perform(items, via: .paste, dropped: false, model: model) {
            case .status(let text):
                note = text
            case .queued(let message, let ids):
                watched.formUnion(ids)
                note = message
                activityOpen = true
            case .review, .nameFile:
                // the plan and the perform disagreed: the window still owns the sheet
                MenuBarHandoff.shared.stage(items: items)
                reveal()
            }
        }
    }

    /// A job this popover started that now needs the owner. Nil while none do.
    private var ownerJob: Job.ID? {
        watched.first { id in
            guard let job = model.queue.job(id), !forwarded.contains(id) else { return false }
            return MenuBarPaste.jobNeedsOwner(isPicker: job.isPicker, waitsForTitle: job.pipeline.waitsForTitle)
        }
    }

    private func forward(_ id: Job.ID?) {
        guard let id, !forwarded.contains(id) else { return }
        forwarded.insert(id)
        MenuBarHandoff.shared.stage(focus: id)
        reveal()
    }

    // MARK: activity

    private var activityItems: [QueueItem] {
        model.unifiedQueue.items.filter { [.now, .waiting, .failed].contains($0.section) }
    }

    private var recentItems: [QueueItem] {
        Array(model.unifiedQueue.items.filter { $0.section == .finished }.prefix(4))
    }

    private var activityHeader: String {
        var running = 0, waiting = 0, failed = 0
        for item in activityItems {
            switch item.section {
            case .now: running += 1
            case .waiting: waiting += 1
            case .failed: failed += 1
            default: break
            }
        }
        if running == 0, waiting == 0, failed == 0 { return Copy.Queue.allDone }
        return Copy.Queue.header(running: running, waiting: waiting, failed: failed)
    }

    private var canClear: Bool {
        model.unifiedQueue.items.contains { ($0.section == .finished || $0.section == .failed) && $0.actions.contains(.dismiss) }
    }

    private var activity: some View {
        group {
            VStack(alignment: .leading, spacing: 6) {
                sectionHead(
                    Copy.MenuBar.activity, activityHeader, open: activityOpen, toggle: { activityOpen.toggle() },
                    actionTitle: activityOpen && canClear ? Copy.Jobs.clearFinished : nil, action: clearFinished)
                if activityOpen {
                    ForEach(activityItems) { item in
                        activityRow(item)
                    }
                    if !recentItems.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(Copy.Queue.finished)
                                .font(CobaltType.captionSmall)
                                .foregroundStyle(CobaltColor.caption)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                                ForEach(recentItems) { item in
                                    recentTile(item)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    private func activityRow(_ item: QueueItem) -> some View {
        let line = MenuBarRowLine(item: item, model: model)
        return HStack(alignment: .center, spacing: 9) {
            MenuBarThumb(url: line.poster, service: line.service, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(line.title)
                    .font(Font.cobalt(12, .medium))
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                Text(line.detail)
                    .font(CobaltType.tab)
                    .foregroundStyle(line.isError ? CobaltColor.errorText : CobaltColor.caption)
                    .lineLimit(2)
                if line.showsBar {
                    StoryBar(fraction: line.fraction, height: 3)
                        .padding(.top, 3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if item.actions.contains(.open) || line.needsOwner { open(item) } }
            rowAction(item, line: line)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .top) { hairline }
    }

    @ViewBuilder
    private func rowAction(_ item: QueueItem, line: MenuBarRowLine) -> some View {
        if line.needsOwner {
            smallButton(Copy.Jobs.open) { open(item) }
        } else if item.actions.contains(.retry) {
            smallButton(Copy.Queue.tryAgain) { Task { await model.perform(.retry, on: item) } }
        } else if item.actions.contains(.cancel) || item.actions.contains(.dismiss) {
            Button { cancel(item, title: line.title) } label: {
                Image(systemName: Symbol.close)
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(CobaltColor.text.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(CobaltColor.caption)
            .accessibilityLabel(Copy.Jobs.cancelA11y(line.title))
        }
    }

    private func recentTile(_ item: QueueItem) -> some View {
        let line = MenuBarRowLine(item: item, model: model)
        return Button { open(item) } label: {
            VStack(alignment: .leading, spacing: 3) {
                MenuBarThumb(url: line.poster, service: line.service, size: nil)
                    .aspectRatio(1, contentMode: .fit)
                Text(line.title)
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                Text(line.when)
                    .font(Font.cobalt(9))
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private func open(_ item: QueueItem) {
        if let job = item.job {
            model.queue.focus(job.id)
            model.selectedTab = .save
        } else {
            model.open(item)
        }
        reveal()
    }

    private func cancel(_ item: QueueItem, title: String) {
        let stop: Bool = {
            guard let job = item.job else { return false }
            return JobCardFacts.exit(for: job.pipeline, lineMode: model.queue.lineMode) == .stop
        }()
        Task {
            await model.perform(item.actions.contains(.cancel) ? .cancel : .dismiss, on: item)
        }
        note = stop ? Copy.Jobs.stoppedFollowing(title) : Copy.Jobs.cancelled(title)
    }

    private func clearFinished() {
        let clearing = model.unifiedQueue.items.filter {
            ($0.section == .finished || $0.section == .failed) && $0.actions.contains(.dismiss)
        }
        Task {
            for item in clearing { await model.perform(.dismiss, on: item) }
        }
    }

    // MARK: offline

    private var offline: some View {
        let keep = model.settings.keepVideosOnDevice
        let usage = model.store.offlineUsage.offline
        let downloads = model.offlineDownloads.summary
        let pull = model.savePull.status
        return group {
            VStack(alignment: .leading, spacing: 8) {
                sectionHead(
                    Copy.Offline.filter, offlineMeta(keep: keep, usage: usage, downloads: downloads, pull: pull),
                    open: offlineOpen, toggle: { offlineOpen.toggle() })
                if offlineOpen, model.store.canKeep {
                    toggleRow(Copy.Offline.keepNewSaves, on: keep) { model.setKeepNewSaves($0) }
                    if pull.available {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(Copy.Folder.pullRow)
                                    .font(Font.cobalt(12))
                                    .foregroundStyle(CobaltColor.text)
                                Spacer(minLength: 8)
                                TimelineView(.periodic(from: .now, by: 30)) { context in
                                    Text(StorageSettingsSection.pullLine(pull, now: context.date))
                                        .font(CobaltType.captionSmall)
                                        .foregroundStyle(pull.paused == .auth ? CobaltColor.errorText : CobaltColor.caption)
                                        .multilineTextAlignment(.trailing)
                                        .lineLimit(2)
                                }
                            }
                            if keep, pull.paused == nil, downloads.left > 0 {
                                StoryBar(fraction: pullFraction(downloads), height: 3)
                                Text(Copy.Offline.queueLine(left: downloads.left, bytes: downloads.bytes, total: downloads.total))
                                    .font(CobaltType.badge)
                                    .foregroundStyle(CobaltColor.caption)
                            }
                            if !keep {
                                Text(Copy.Folder.pullKeepOff)
                                    .font(CobaltType.badge)
                                    .foregroundStyle(CobaltColor.caption)
                            }
                        }
                    }
                }
            }
        }
    }

    private func offlineMeta(keep: Bool, usage: StorageUsage, downloads: (left: Int, bytes: Int64, total: Int64?), pull: SavePull.Status) -> String {
        if !keep { return Copy.featureOff }
        if pull.available, pull.paused == nil, downloads.left > 0 { return Copy.Folder.pullDownloading(downloads.left) }
        return Copy.Offline.filesUsage(count: usage.count, bytes: usage.bytes, limit: nil)
    }

    private func pullFraction(_ downloads: (left: Int, bytes: Int64, total: Int64?)) -> Double? {
        guard let total = downloads.total, total > 0 else { return nil }
        return Double(downloads.bytes) / Double(total)
    }

    // MARK: finder (read-only location; hidden until the live app connects the provider)

    @ViewBuilder
    private var finder: some View {
        let finder = model.menuBarFinder
        if finder.isAvailable {
            let status = finder.status
            group {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHead(Copy.MenuBar.finderTitle, finderMeta(status), open: finderOpen, toggle: { finderOpen.toggle() })
                    if finderOpen {
                        toggleRow(Copy.Folder.finderToggle, on: status.enabled) { on in
                            Task { await finder.setEnabled(on) }
                        }
                        Text(status.note ?? Copy.Folder.finderFooter)
                            .font(CobaltType.badge)
                            .foregroundStyle(CobaltColor.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        if case .updating(let fraction) = status.phase {
                            StoryBar(fraction: fraction, height: 3)
                        }
                    }
                }
            }
        }
    }

    private func finderMeta(_ status: MenuBarFinderStatus) -> String {
        switch status.phase {
        case .off: return Copy.featureOff
        case .upToDate: return Copy.MenuBar.finderUpToDate
        case .updating: return Copy.MenuBar.finderUpdating
        }
    }

    // MARK: menu

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            hairline.padding(.bottom, 4)
            menuRow(Copy.MenuBar.openApp, Copy.MenuBar.shortcutOpen, shortcut: .init("o", [.command, .shift])) { reveal() }
            if model.menuBarFinder.isAvailable {
                menuRow(
                    Copy.MenuBar.openInFinder, "",
                    enabled: model.menuBarFinder.status.enabled
                ) { model.menuBarFinder.openInFinder() }
            }
            menuRow(Copy.Queue.openQueueA11y, Copy.MenuBar.shortcutQueue, shortcut: .init("j", [.command, .shift])) {
                model.showQueue()
                reveal()
            }
            menuRow(Copy.MenuBar.settings, Copy.MenuBar.shortcutSettings) {
                NSApp.activate()
                openSettings()
            }
            hairline.padding(.vertical, 4)
            menuRow(Copy.MenuBar.quit, Copy.MenuBar.shortcutQuit) { NSApp.terminate(nil) }
        }
    }

    private func menuRow(
        _ title: String, _ keys: String, shortcut: MenuShortcut? = nil, enabled: Bool = true, action: @escaping () -> Void
    ) -> some View {
        MenuBarMenuRow(title: title, keys: keys, shortcut: shortcut, enabled: enabled, action: action)
    }

    // MARK: compact

    private var compactSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(activityItems.isEmpty ? Copy.Queue.emptyTitle : activityHeader)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(activityItems.contains { $0.section == .failed } ? CobaltColor.errorText : CobaltColor.caption)
                Spacer(minLength: 8)
                Text(Copy.Offline.filesUsage(
                    count: model.store.offlineUsage.offline.count, bytes: model.store.offlineUsage.offline.bytes, limit: nil))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
            }
            if !MenuBarPhases.live(model.queue).isEmpty {
                StoryBar(fraction: MenuBarIcon.state(phases: MenuBarPhases.live(model.queue), failed: false).ring, height: 3)
            }
        }
    }

    // MARK: pieces

    private func reveal() {
        arm()
        MacWindows.reveal(openWindow)
    }

    private func arm() {
        MenuBarHandoff.shared.reveal = { MacWindows.reveal(openWindow) }
    }

    private var hairline: some View {
        Rectangle().fill(CobaltColor.hairline).frame(height: 1)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CobaltColor.text.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CobaltColor.hairline))
    }

    private func sectionHead(
        _ title: String, _ meta: String, open: Bool, toggle: @escaping () -> Void,
        actionTitle: String? = nil, action: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 8) {
            chevron(open: open, action: toggle)
            Text(title)
                .font(Font.cobalt(12.5, .semibold))
                .foregroundStyle(CobaltColor.text)
            Text(meta)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let actionTitle, let action { smallButton(actionTitle, action: action) }
        }
    }

    private func chevron(open: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(open ? 0 : -90))
                .frame(width: 22, height: 22)
                .background(CobaltColor.text.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(CobaltColor.text)
        .accessibilityLabel(open ? Copy.MenuBar.collapse : Copy.MenuBar.expand)
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(CobaltType.captionSmall)
            .foregroundStyle(CobaltColor.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(CobaltColor.text.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func toggleRow(_ title: String, on: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text(title)
                .font(Font.cobalt(12))
                .foregroundStyle(CobaltColor.text)
            Spacer(minLength: 8)
            Toggle(title, isOn: Binding(get: { on }, set: set))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(CobaltColor.text)
        }
    }
}

private enum Connection { case connected, waking, offline }

/// A keyboard shortcut the menu row registers only while this window is key.
private struct MenuShortcut {
    var key: KeyEquivalent
    var modifiers: EventModifiers
    init(_ key: Character, _ modifiers: EventModifiers) {
        self.key = KeyEquivalent(key)
        self.modifiers = modifiers
    }
}

private struct MenuBarMenuRow: View {
    let title: String
    let keys: String
    var shortcut: MenuShortcut?
    var enabled = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                if !keys.isEmpty {
                    Text(keys)
                        .foregroundStyle(CobaltColor.caption)
                }
            }
            .font(Font.cobalt(12.5))
            .foregroundStyle(enabled ? CobaltColor.text : CobaltColor.disabledInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover && enabled ? CobaltColor.text.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .modifier(MenuShortcutModifier(shortcut: enabled ? shortcut : nil))
    }
}

private struct MenuShortcutModifier: ViewModifier {
    var shortcut: MenuShortcut?

    @ViewBuilder func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
        } else {
            content
        }
    }
}

/// What one activity or recent row says, from the queue's own facts.
private struct MenuBarRowLine {
    var title: String
    var detail: String
    var when: String
    var service: String?
    var poster: URL?
    var fraction: Double?
    var showsBar = false
    var isError = false
    var needsOwner = false

    @MainActor
    init(item: QueueItem, model: AppModel) {
        when = ""
        switch item.kind {
        case .job(let job):
            let facts = JobCardFacts(job: job, lineMax: model.capabilities.limits.lineMax, lineMode: model.queue.lineMode)
            title = facts.title
            detail = Self.line(facts.headline, facts.detail)
            fraction = facts.fraction
            showsBar = facts.showsBar && facts.kind != .failed
            isError = facts.kind == .failed
            needsOwner = MenuBarPaste.jobNeedsOwner(isPicker: job.isPicker, waitsForTitle: job.pipeline.waitsForTitle)
            service = job.pipeline.linkService
            poster = MenuBarPoster.url(mediaID: job.pipeline.stored?.mediaID, model: model)
            if let at = job.finishedAt { when = Copy.Folder.ago(seconds: Date().timeIntervalSince(at)) }
        case .finished(let work):
            title = work.title
            detail = QueueRowFacts(item: item, now: Date()).headline
            when = Copy.Folder.ago(seconds: Date().timeIntervalSince(work.finishedAt))
            poster = MenuBarPoster.url(mediaID: work.mediaID, model: model)
            if let post = work.mediaID.flatMap({ model.library.post(id: $0) }) { service = post.service }
        default:
            let facts = QueueRowFacts(item: item, now: Date())
            title = facts.title.isEmpty ? facts.headline : facts.title
            detail = facts.headline
            fraction = facts.fraction
            showsBar = facts.showsBar
            isError = facts.isError
            poster = facts.poster
            when = facts.headline
            if case .server(let work) = item.kind, let link = work.link { service = LinkInfo(link)?.service }
        }
    }

    private static func line(_ headline: String, _ detail: ProgressStory.Detail?) -> String {
        guard case .text(let text)? = detail, !text.isEmpty, text != headline else { return headline }
        return "\(headline) · \(text)"
    }
}

@MainActor
private enum MenuBarPoster {
    static func url(mediaID: String?, model: AppModel) -> URL? {
        guard let mediaID else { return nil }
        if let media = model.store.media.first(where: { $0.id == mediaID }) {
            return media.face.posterURL ?? media.original?.posterURL
        }
        if let post = model.library.post(id: mediaID) { return post.posterURL }
        return model.library.posts.first { $0.id == mediaID || $0.files.contains { $0.id == mediaID } }?.posterURL
    }
}

/// A square poster, or a flat service chip when there is no picture yet.
private struct MenuBarThumb: View {
    var url: URL?
    var service: String?
    /// Nil fills the width (the recent grid). A number is a fixed square.
    var size: CGFloat?

    // Session replay (APP-API-CONTRACT 58): media is always masked.
    var body: some View { mediaBody.mediaMask() }

    @ViewBuilder private var mediaBody: some View {
        ZStack(alignment: .bottomLeading) {
            CobaltColor.frameTop
            if let url {
                if url.isFileURL, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    RemoteStill(poster: RemotePoster(url: url, isVideo: false), maxPixel: 160)
                }
            }
            if let service, !service.isEmpty {
                Text(service)
                    .font(Font.cobalt(8))
                    .foregroundStyle(CobaltColor.badgeInk)
                    .lineLimit(1)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(CobaltColor.badgeBack, in: RoundedRectangle(cornerRadius: 3))
                    .padding(3)
            }
        }
        .frame(width: size, height: size)
        .frame(maxWidth: size == nil ? .infinity : nil)
        .aspectRatio(size == nil ? 1 : nil, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: (size ?? 36) * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("menu bar · busy") {
    MenuBarPopover(model: AppModel.previewQueue(.busy))
}
#endif
#endif
