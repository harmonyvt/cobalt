import CobaltKit
import Observation
import SwiftUI

// The 7TV card (APP-API-CONTRACT 57.7). The studio tab now shows only a "7tv →" row (`StageSevenTvShortcut`) and the 7tv tab
// (`SevenTvScreen`) reuses the card's parts, controller and presentations; the card itself stays for its previews. Not linked: "link 7tv" opens the link sheet. Linked: the
// avatar and name, "expires in N days" under 7 days, unlink (asks first); channel chips (you first); the picked channel's sets,
// the live one marked, each with open and (with `can.make_live`) make live; new set (with `can.create_sets`). 7TV signed the
// token out: an amber line and "link again". A server without the routes hides the card. The state is `model.sevenTv`; taps
// go through a `SevenTvController`, which also says what the bookmarklet's link came to.

/// A set to open on the set screen.
struct SevenTvSetRoute: Hashable, Identifiable {
    let setID: String
    let channelID: String

    var id: String { setID }
}

@MainActor @Observable
final class SevenTvController {
    let model: AppModel

    var linkShown = false
    var confirmingUnlink = false
    /// The channel a "new set" is being named for.
    var newSetChannel: String?
    var newSetName = ""
    var openSet: SevenTvSetRoute?
    /// What is in flight: "unlink", "new", "live-<set id>".
    private(set) var busy: Set<String> = []
    private(set) var doneTick = 0
    private(set) var failTick = 0
    /// One model per open set, so the 7tv tab's live preview, its search and the pushed set screen edit the same grid.
    @ObservationIgnored private var setModels: [String: SevenTvSetModel] = [:]

    init(model: AppModel) {
        self.model = model
    }

    var store: SevenTvStore { model.sevenTv }

    /// The set's model, made once per set.
    func setModel(_ setID: String, channelID: String) -> SevenTvSetModel {
        if let made = setModels[setID], made.channelID == channelID { return made }
        let made = store.openSet(setID, channelID: channelID)
        setModels[setID] = made
        return made
    }

    func setModel(for route: SevenTvSetRoute) -> SevenTvSetModel { setModel(route.setID, channelID: route.channelID) }

    func isBusy(_ key: String) -> Bool { busy.contains(key) }

    /// Runs `work` once at a time per `key`; a refusal becomes the shell's status line and the error haptic.
    private func run(_ key: String, shell: ShellActions, success: String? = nil, work: @escaping @MainActor () async throws -> Void) {
        guard !busy.contains(key) else { return }
        busy.insert(key)
        Task {
            defer { busy.remove(key) }
            do {
                try await work()
                if let success { shell.showStatus(success) }
                doneTick += 1
            } catch {
                shell.showStatus(Copy.SevenTv.message(for: error))
                failTick += 1
            }
        }
    }

    /// Unlinks. A link made in the login sheet is capystore's own 7TV session: the server ends it (`?logout=1`) and the
    /// sheet's web data store drops 7tv.app so the next link is a fresh login (57.12).
    func unlink(shell: ShellActions) {
        let wasSheet = store.linkedBySheet
        run("unlink", shell: shell, success: Copy.SevenTv.unlinked) {
            try await self.store.unlink()
            if wasSheet { await SevenTvLoginData.forgetSevenTv() }
        }
    }

    /// "forget 7tv login": the login sheet's web view forgets everything (the 7tv, twitch, discord and kick logins it kept).
    /// The link itself stays.
    func forgetLogin(shell: ShellActions) {
        run("forget", shell: shell, success: Copy.SevenTv.loginForgotten) { await SevenTvLoginData.forgetAll() }
    }

    func makeLive(_ row: SevenTvSetRow, channelID: String, shell: ShellActions) {
        run("live-\(row.id)", shell: shell, success: Copy.SevenTv.madeLive(row.name)) {
            try await self.store.makeLive(channelID: channelID, setID: row.id)
        }
    }

    func askNewSet(channelID: String) {
        newSetName = ""
        newSetChannel = channelID
    }

    func createSet(shell: ShellActions) {
        guard let channelID = newSetChannel else { return }
        let name = newSetName
        newSetChannel = nil
        run("new", shell: shell) {
            let row = try await self.store.createSet(channelID: channelID, name: name)
            shell.showStatus(Copy.SevenTv.created(row.name))
        }
    }

    /// Says what a link (the sheet, or the bookmarklet's `cobalt-apple://7tv-link`) came to, once.
    func sayOutcome(shell: ShellActions) {
        guard let outcome = store.unsaidOutcome else { return }
        store.acknowledge(outcome)
        switch outcome.result {
        case .linked(let name):
            // the login sheet says "linked as <name>" itself and closes a moment later; every other way closes at once
            if !store.linkedBySheet { linkShown = false }
            shell.showStatus(Copy.SevenTv.linked(name))
            doneTick += 1
        case .failed(let error):
            // the sheet says its own failure inline; the bookmarklet's lands here
            if !linkShown { shell.showStatus(Copy.SevenTv.message(for: error)) }
            failTick += 1
        }
    }
}

struct StageSevenTvCard: View {
    let model: AppModel

    @State private var controller: SevenTvController
    @Environment(\.shell) private var shell

    init(model: AppModel) {
        self.model = model
        _controller = State(initialValue: SevenTvController(model: model))
    }

    private var store: SevenTvStore { model.sevenTv }

    /// A server without the routes: no card at all.
    private var hidden: Bool { store.status == nil && store.state == .failed(.off) }

    var body: some View {
        Group {
            if hidden {
                Color.clear.frame(height: 0)
            } else {
                StageCard(title: Copy.SevenTv.title) { SevenTvCardContent(controller: controller) }
            }
        }
        .task { await store.load() }
        .task(id: store.linkOutcome?.id) { controller.sayOutcome(shell: shell) }
        .sevenTvPresentations(controller)
    }
}

// MARK: - what the card shows

struct SevenTvCardContent: View {
    let controller: SevenTvController

    @Environment(\.shell) private var shell

    private var store: SevenTvStore { controller.store }

    var body: some View {
        if let status = store.status {
            if !status.linked {
                notLinked
            } else if status.needsRelink {
                relink(status.account)
            } else {
                linked(status)
            }
        } else if case .failed(let error) = store.state {
            failed(error)
        } else {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(Copy.SevenTv.loading).font(CobaltType.caption).foregroundStyle(CobaltColor.caption)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var notLinked: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Copy.SevenTv.notLinkedBody)
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button(store.linking ? Copy.SevenTv.linking : Copy.SevenTv.link, systemImage: Symbol.SevenTv.link) {
                controller.linkShown = true
            }
            .buttonStyle(.cobaltPrimary(compact: true))
            .disabled(store.linking)
        }
    }

    private func failed(_ error: SevenTvError) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Copy.SevenTv.message(for: error))
                .font(CobaltType.caption)
                .foregroundStyle(CobaltColor.errorText)
            Button(Copy.SevenTv.retry, systemImage: Symbol.SevenTv.retry) { Task { await store.load() } }
                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
        }
    }

    private func relink(_ account: SevenTvUser?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                SevenTvAvatar(url: account?.avatarURL, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account?.name ?? Copy.SevenTv.title)
                        .font(CobaltType.bodyMedium)
                        .foregroundStyle(CobaltColor.text)
                    Label(Copy.SevenTv.signedOut, systemImage: Symbol.SevenTv.warn)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.collection)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                unlinkButton
            }
            Text(Copy.SevenTv.signedOutBody)
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
            Button(store.linking ? Copy.SevenTv.linking : Copy.SevenTv.linkAgain, systemImage: Symbol.SevenTv.link) {
                controller.linkShown = true
            }
            .buttonStyle(.cobaltPrimary(compact: true))
            .disabled(store.linking)
        }
    }

    private func linked(_ status: SevenTvStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SevenTvAccountRow(account: status.account, channels: status.channels.count, now: store.now()) { unlinkButton }
            if status.channels.count > 1 {
                SevenTvChannelChips(store: store)
            }
            if let channel = store.selectedChannel {
                SevenTvSetList(controller: controller, channel: channel)
            }
        }
    }

    private var unlinkButton: some View {
        Button { controller.confirmingUnlink = true } label: {
            Label(Copy.SevenTv.unlink, systemImage: Symbol.SevenTv.unlink)
        }
        .buttonStyle(.cobaltIcon(.small, state: controller.isBusy("unlink") ? .working : .idle))
        .disabled(controller.isBusy("unlink"))
    }
}

/// The avatar, the name, "linked · 3 channels you can edit" (or the expiry when it is close), and the unlink button.
struct SevenTvAccountRow<Trailing: View>: View {
    let account: SevenTvUser?
    let channels: Int
    let now: Date
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SevenTvAvatar(url: account?.avatarURL, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(account?.name ?? Copy.SevenTv.title)
                    .font(CobaltType.bodyMedium)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                if let account, account.expiresSoon(now: now), let days = account.daysLeft(now: now) {
                    Text(Copy.SevenTv.expiresIn(days: days))
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.collection)
                } else {
                    Text(Copy.SevenTv.linkedLine(channels: channels))
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

/// One chip per channel, the account's own first.
struct SevenTvChannelChips: View {
    let store: SevenTvStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.channels) { channel in
                    SevenTvChip(title: channel.name, selected: store.selectedChannel?.id == channel.id) {
                        Task { await store.select(channelID: channel.id) }
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.SevenTv.channelsA11y)
        .haptic(.selection, trigger: store.selectedChannelID)
    }
}

/// The picked channel's sets, live first, and "new set".
struct SevenTvSetList: View {
    let controller: SevenTvController
    let channel: SevenTvChannelInfo

    @Environment(\.shell) private var shell

    private var store: SevenTvStore { controller.store }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let sets = store.sets(of: channel.id)
            switch store.setsState(of: channel.id) {
            case .failed(let error) where sets.isEmpty:
                Text(Copy.SevenTv.message(for: error))
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.errorText)
            case .loading where sets.isEmpty, .idle where sets.isEmpty:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Copy.SevenTv.loadingSets).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
                }
            default:
                if sets.isEmpty {
                    Text(Copy.SevenTv.noSets).font(CobaltType.captionSmall).foregroundStyle(CobaltColor.caption)
                }
                ForEach(sets) { row in
                    SevenTvSetLine(controller: controller, channel: channel, row: row)
                }
            }
            if channel.can.createSets {
                Button(Copy.SevenTv.newSet, systemImage: Symbol.SevenTv.newSet) { controller.askNewSet(channelID: channel.id) }
                    .buttonStyle(.cobaltSecondary(compact: true))
                    .disabled(controller.isBusy("new"))
            }
        }
        .motion(Motion.rows, value: store.sets(of: channel.id).map(\.id))
    }
}

/// One set: its name (and "live"), how full it is, open and make live.
struct SevenTvSetLine: View {
    let controller: SevenTvController
    let channel: SevenTvChannelInfo
    let row: SevenTvSetRow

    @Environment(\.shell) private var shell

    var body: some View {
        HStack(spacing: 10) {
            Button { open() } label: { summary }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.SevenTv.setA11y(row.name, count: row.count, capacity: row.capacity, live: row.live))
            Spacer(minLength: 6)
            if channel.can.makeLive && !row.live {
                Button(Copy.SevenTv.makeLive) { controller.makeLive(row, channelID: channel.id, shell: shell) }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                    .disabled(controller.isBusy("live-\(row.id)"))
            }
            Button { open() } label: {
                Label(Copy.SevenTv.open, systemImage: Symbol.SevenTv.open)
            }
            .buttonStyle(.cobaltIcon(.small))
        }
        .padding(.vertical, 2)
    }

    private func open() {
        controller.openSet = SevenTvSetRoute(setID: row.id, channelID: channel.id)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(row.name)
                    .font(CobaltType.bodyMedium)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                if row.live { SevenTvLivePill() }
            }
            SevenTvFillBar(fill: row.fill, live: row.live)
            Text(Copy.SevenTv.count(row.count, capacity: row.capacity))
                .font(CobaltType.badge)
                .foregroundStyle(CobaltColor.caption)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
    }
}

// MARK: - the studio's row

/// The studio tab's one line where the 7TV card was: "7tv →", which shows the 7tv tab. Hidden on a server without the routes.
struct StageSevenTvShortcut: View {
    let model: AppModel

    private var store: SevenTvStore { model.sevenTv }
    private var hidden: Bool { store.status == nil && store.state == .failed(.off) }

    private var line: String {
        guard let status = store.status, status.linked else { return Copy.SevenTv.shortcutNotLinked }
        if status.needsRelink { return Copy.SevenTv.signedOut }
        return status.account.map { "\($0.name) · \(Copy.SevenTv.shortcutBody)" } ?? Copy.SevenTv.shortcutBody
    }

    var body: some View {
        Group {
            if hidden {
                Color.clear.frame(height: 0)
            } else {
                Button { model.selectedTab = .sevenTv } label: {
                    HStack(spacing: 10) {
                        SevenTvAvatar(url: store.account?.avatarURL, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Copy.SevenTv.title)
                                .font(CobaltType.bodySemibold)
                                .foregroundStyle(CobaltColor.text)
                            Text(line)
                                .font(CobaltType.captionSmall)
                                .foregroundStyle(store.status?.needsRelink == true ? CobaltColor.collection : CobaltColor.caption)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: Symbol.SevenTv.shortcut)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(CobaltColor.caption)
                            .accessibilityHidden(true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint(Copy.SevenTv.shortcutA11y)
            }
        }
        .task { if store.state == .idle { await store.load() } }
    }
}

// MARK: - small parts (the set screen uses them too)

/// "live", green.
struct SevenTvLivePill: View {
    var body: some View {
        Text(Copy.SevenTv.live)
            .font(CobaltType.pill)
            .foregroundStyle(.black)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(CobaltColor.success, in: Capsule())
    }
}

/// How full a set is: a thin bar.
struct SevenTvFillBar: View {
    let fill: Double
    var live = false
    var width: CGFloat = 120

    var body: some View {
        Capsule()
            .fill(CobaltColor.elevated)
            .frame(width: width, height: 4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(live ? CobaltColor.success : CobaltColor.focus)
                    .frame(width: max(4, width * min(1, max(0, fill))), height: 4)
            }
            .accessibilityHidden(true)
    }
}

/// A capsule chip like the emote search's: filled when picked.
struct SevenTvChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Font.cobalt(11.5, selected ? .semibold : .regular, relativeTo: .caption))
                .foregroundStyle(selected ? CobaltColor.onText : Color.primary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .background(Capsule().fill(selected ? CobaltColor.text : CobaltColor.elevated))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A 7TV account or channel picture, round; a plain circle while it loads or without one.
struct SevenTvAvatar: View {
    let url: URL?
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle().fill(CobaltColor.elevated)
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: Symbol.SevenTv.person)
            .font(.system(size: size * 0.55))
            .foregroundStyle(CobaltColor.caption)
    }
}

// MARK: - confirms, sheets, the set screen

private struct SevenTvPresentations: ViewModifier {
    @Bindable var controller: SevenTvController

    @Environment(\.shell) private var shell

    private var newSetShown: Binding<Bool> {
        Binding(get: { controller.newSetChannel != nil }, set: { if !$0 { controller.newSetChannel = nil } })
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(Copy.SevenTv.unlinkTitle, isPresented: $controller.confirmingUnlink, titleVisibility: .visible) {
                Button(Copy.SevenTv.unlink, role: .destructive) { controller.unlink(shell: shell) }
                Button(Copy.SevenTv.keep, role: .cancel) {}
            } message: {
                Text(controller.store.linkedBySheet ? Copy.SevenTv.unlinkMessageSession : Copy.SevenTv.unlinkMessage)
            }
            .alert(Copy.SevenTv.newSetTitle, isPresented: newSetShown) {
                TextField(Copy.SevenTv.setName, text: $controller.newSetName)
                    .accessibilityLabel(Copy.SevenTv.setName)
                Button(Copy.SevenTv.make) { controller.createSet(shell: shell) }
                    .disabled(SevenTvRule.cleanSetName(controller.newSetName) == nil)
                Button(Copy.SevenTv.cancel, role: .cancel) {}
            } message: {
                Text(Copy.SevenTv.newSetMessage)
            }
            .sheet(isPresented: $controller.linkShown) {
                SevenTvLoginSheet(store: controller.store)
            }
            .navigationDestination(item: $controller.openSet) { route in
                SevenTvSetScreen(model: controller.model, route: route, emoteSet: controller.setModel(for: route))
            }
            .haptic(.success, trigger: controller.doneTick)
            .haptic(.error, trigger: controller.failTick)
    }
}

extension View {
    /// The 7TV card's confirm, alerts, link sheet and set screen, with the haptics of `controller`.
    func sevenTvPresentations(_ controller: SevenTvController) -> some View {
        modifier(SevenTvPresentations(controller: controller))
    }
}
