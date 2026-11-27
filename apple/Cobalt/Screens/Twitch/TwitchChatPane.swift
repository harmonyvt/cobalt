import CobaltKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// The live chat beside or under the player (APP-API-CONTRACT 70): the room's modes, the lines (kept at the newest unless
// the owner scrolls up, then "paused · N new"), and the composer with emote completion and replies.

struct TwitchChatPane: View {
    let model: AppModel
    /// Seconds lines wait before they show (video-only AirPlay runs the TV behind, 70.5); 0 shows them at once.
    var delay: TimeInterval = 0
    /// The "chat" word over the lines; off when a card already says it (the pane's shelf).
    var showsLabel = true
    /// Optional combined chat model coordinating 1 or 2 streams. When nil, uses `model.twitch` single-stream chat.
    /// When coordinating only 1 stream, renders crisp single-stream chat with zero dual-stream clutter.
    var combined: TwitchCombinedChatModel? = nil
    let onAddEmote: (ChatEmote) -> Void

    private var store: TwitchStore { model.twitch }

    var body: some View {
        if let combined {
            TwitchCombinedChatContent(
                store: store,
                combined: combined,
                delay: delay,
                showsLabel: showsLabel,
                canAddToSet: model.sevenTv.isLinked,
                onAddEmote: onAddEmote)
        } else {
            VStack(spacing: 0) {
                TwitchChatHeader(status: store.chat?.status ?? .connecting, room: store.chat?.room ?? TwitchRoomState(), showsLabel: showsLabel)
                if delay > 0 {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        lines(cutoff: context.date.addingTimeInterval(-delay))
                    }
                } else {
                    lines(cutoff: nil)
                }
                TwitchComposer(store: store, canAddToSet: model.sevenTv.isLinked, onAddEmote: onAddEmote)
            }
            .background(CobaltColor.bg)
        }
    }

    private func lines(cutoff: Date?) -> some View {
        TwitchChatLines(
            snapshot: store.chat,
            cutoff: cutoff,
            canAddEmotes: model.sevenTv.isLinked,
            canReply: store.canSend,
            onReply: { store.replyTo = $0 },
            onAddEmote: onAddEmote)
    }
}

private struct TwitchChatHeader: View {
    let status: TwitchChatStatus
    let room: TwitchRoomState
    var showsLabel = true

    var body: some View {
        if showsLabel || statusText != nil || !modes.isEmpty {
            HStack(spacing: 6) {
                if showsLabel {
                    Text(Copy.Twitch.chat)
                        .font(Font.cobalt(13, .semibold))
                        .foregroundStyle(CobaltColor.text)
                }
                if let s = statusText {
                    Text(s)
                        .font(Font.cobalt(12))
                        .foregroundStyle(isProblem ? CobaltColor.errorText : CobaltColor.caption)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                ForEach(modes, id: \.self) { mode in
                    Text(mode)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(TwitchChatPalette.twitch)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(TwitchChatPalette.twitch.opacity(0.12), in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
    }

    private var statusText: String? {
        switch status {
        case .idle, .connecting: return Copy.Twitch.connecting
        case .joined(let canSend): return canSend ? nil : Copy.Twitch.readOnlyChat
        case .reconnecting(let s): return Copy.Twitch.reconnecting(s)
        case .failed: return Copy.Twitch.failed
        }
    }

    private var isProblem: Bool {
        switch status {
        case .reconnecting, .failed: return true
        default: return false
        }
    }

    private var modes: [String] {
        var out: [String] = []
        if room.slowSeconds > 0 { out.append(Copy.Twitch.slow(room.slowSeconds)) }
        if room.emoteOnly { out.append(Copy.Twitch.emoteOnly) }
        if room.subsOnly { out.append(Copy.Twitch.subsOnly) }
        if room.followersOnlyMinutes >= 0 { out.append(Copy.Twitch.followersOnly) }
        return out
    }
}

private struct TwitchChatLines: View {
    let snapshot: TwitchChatSnapshot?
    /// Lines newer than this wait (the owner's own show at once); nil shows every line.
    let cutoff: Date?
    let canAddEmotes: Bool
    let canReply: Bool
    let onReply: (TwitchChatLine) -> Void
    let onAddEmote: (ChatEmote) -> Void

    /// Kept at the newest line; false once the owner scrolls up.
    @State private var following = true
    @State private var atBottom = true
    /// The newest line when the owner scrolled away, to count what came since.
    @State private var pausedAt: String?

    private static let bottom = "twitch-chat-bottom"

    private var lines: [TwitchChatLine] {
        let all = snapshot?.lines ?? []
        guard let cutoff else { return all }
        return all.filter { $0.mine || $0.timestamp <= cutoff }
    }

    private var newSincePause: Int {
        guard !following, let pausedAt, let i = lines.lastIndex(where: { $0.id == pausedAt }) else { return 0 }
        return lines.count - 1 - i
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { line in
                        TwitchChatRow(
                            line: line,
                            paint: snapshot?.paints[line.login],
                            sevenTvBadge: snapshot?.sevenTvBadges[line.login],
                            canAddEmotes: canAddEmotes,
                            onReply: canReply ? onReply : nil,
                            onAddEmote: onAddEmote)
                        .equatable()
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 40
            } action: { _, now in
                atBottom = now
            }
            .onScrollPhaseChange { old, new in
                if new == .tracking || new == .interacting {
                    if following { pausedAt = lines.last?.id }
                    following = false
                } else if new == .idle, old != .idle {
                    following = atBottom
                    if following { pausedAt = nil }
                }
            }
            .onChange(of: lines.last?.id) {
                if following { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if !following {
                    Button {
                        following = true
                        pausedAt = nil
                        withAnimation(.snappy) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                    } label: {
                        Label(
                            newSincePause > 0 ? "\(Copy.Twitch.paused) · \(Copy.Twitch.newLines(newSincePause))" : Copy.Twitch.jumpDown,
                            systemImage: Symbol.Twitch.down)
                            .font(Font.cobalt(12.5, .medium))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 32)
                            .foregroundStyle(.white)
                            .background(TwitchChatPalette.twitch, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                    .transition(.opacity)
                }
            }
        }
    }
}

// MARK: - composer

private struct TwitchComposer: View {
    let store: TwitchStore
    let canAddToSet: Bool
    let onAddEmote: (ChatEmote) -> Void

    @State private var text = ""
    @State private var sending = false
    /// The emote picker is open under the field (the keyboard is down meanwhile).
    @State private var picking = false
    @FocusState private var focused: Bool

    /// The word being typed (after the last space).
    private var lastWord: Substring {
        text.split(separator: " ", omittingEmptySubsequences: false).last ?? ""
    }

    private var completions: [ChatEmote] {
        guard focused, !lastWord.hasPrefix("@") else { return [] }
        return store.emotes.completions(for: String(lastWord))
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            if !completions.isEmpty { completionRow }
            if let reply = store.replyTo { replyBanner(reply) }
            HStack(spacing: 8) {
                Button(picking ? Copy.Twitch.hideEmotes : Copy.Twitch.showEmotes, systemImage: picking ? Symbol.Twitch.keyboard : Symbol.Twitch.emotes) {
                    togglePicker()
                }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(picking ? TwitchChatPalette.twitch : CobaltColor.caption)
                    .frame(width: 34, height: 38)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("twitch.emotes")
                TextField(store.canSend ? Copy.Twitch.composerPrompt : Copy.Twitch.composerReadOnly, text: $text)
                    .textFieldStyle(.plain)
                    .font(Font.cobalt(14.5))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.send)
                    #endif
                    .focused($focused)
                    .disabled(!store.canSend)
                    .onSubmit(send)
                    .onChange(of: text) { if text.count > 500 { text = String(text.prefix(500)) } }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 38)
                    .background(CobaltColor.surface, in: Capsule())
                #if os(iOS)
                if focused || picking {
                    Button(Copy.Twitch.hideKeyboard, systemImage: Symbol.Twitch.hideKeyboard) {
                        dismissKeyboard()
                    }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(CobaltColor.caption)
                    .frame(width: 36, height: Metrics.hit)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("twitch.hideKeyboard")
                }
                #endif
                Button(Copy.Twitch.send, systemImage: Symbol.Twitch.send, action: send)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(canSend ? TwitchChatPalette.twitch : CobaltColor.elevated, in: Circle())
                    .buttonStyle(.plain)
                    .disabled(!canSend)
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            if picking {
                TwitchEmotePicker(store: store, canAddToSet: canAddToSet, onAddEmote: onAddEmote) { pick($0) }
                    .frame(height: 260)
                    .overlay(alignment: .top) { Divider() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(CobaltColor.bg)
        .overlay(alignment: .top) { Divider() }
        .animation(.snappy(duration: 0.25), value: picking)
        // the keyboard and the picker take turns under the field
        .onChange(of: focused) { _, now in if now { picking = false } }
    }

    private func dismissKeyboard() {
        focused = false
        picking = false
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private func togglePicker() {
        if picking {
            picking = false
            if store.canSend { focused = true }
        } else {
            focused = false
            picking = true
        }
    }

    /// Puts the emote's name in the message, with a space either side, where the text ends.
    private func pick(_ emote: ChatEmote) {
        var next = text
        if !next.isEmpty, !next.hasSuffix(" ") { next += " " }
        next += emote.name + " "
        guard next.count <= 500 else { return }
        text = next
        store.noteEmotePicked(emote)
    }

    private var canSend: Bool { store.canSend && !trimmed.isEmpty && !sending }

    private var completionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(completions, id: \.self) { emote in
                    Button { complete(emote) } label: {
                        HStack(spacing: 5) {
                            EmotePicture(url: emote.url, animated: emote.animated, side: 22)
                            Text(emote.name)
                                .font(Font.cobalt(12.5, .medium))
                                .foregroundStyle(CobaltColor.text)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 32)
                        .background(CobaltColor.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
        }
    }

    private func replyBanner(_ reply: TwitchChatLine) -> some View {
        HStack(spacing: 6) {
            Image(systemName: Symbol.Twitch.reply)
            Text("\(Copy.Twitch.replyingTo(reply.displayName)): \(reply.plainText)")
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(Copy.Twitch.cancelReply, systemImage: Symbol.Twitch.close) { store.replyTo = nil }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
        }
        .font(Font.cobalt(12))
        .foregroundStyle(CobaltColor.caption)
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private func complete(_ emote: ChatEmote) {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if words.isEmpty { words = [""] }
        words[words.count - 1] = emote.name
        text = words.joined(separator: " ") + " "
    }

    private func send() {
        guard canSend else { return }
        let message = trimmed
        sending = true
        Task {
            if await store.send(message) { text = "" }
            sending = false
            if !picking { focused = true }
        }
    }
}

// MARK: - combined dual-stream chat (Phase 4 + Opus Foolproof Dual-Target Composer)

private struct TwitchCombinedChatContent: View {
    let store: TwitchStore
    let combined: TwitchCombinedChatModel
    let delay: TimeInterval
    let showsLabel: Bool
    let canAddToSet: Bool
    let onAddEmote: (ChatEmote) -> Void

    var body: some View {
        VStack(spacing: 0) {
            TwitchChatHeader(status: combined.headerStatus, room: combined.headerRoom, showsLabel: showsLabel)
            if combined.isDualChannel {
                TwitchDualChatFilterBar(
                    accents: combined.orderedAccents,
                    selection: combined.filter,
                    onSelect: { combined.setFilter($0) })
            }
            if delay > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    linesView(cutoff: context.date.addingTimeInterval(-delay))
                }
            } else {
                linesView(cutoff: nil)
            }
            TwitchDualComposer(
                store: store,
                combined: combined,
                canAddToSet: canAddToSet,
                onAddEmote: onAddEmote)
        }
        .background(CobaltColor.bg)
    }

    private func linesView(cutoff: Date?) -> some View {
        TwitchCombinedChatLines(
            combined: combined,
            cutoff: cutoff,
            canAddEmotes: canAddToSet,
            onAddEmote: onAddEmote)
    }
}

/// Filter bar (`All` | `@StreamA` | `@StreamB`) with >= 44 pt hit targets (`Metrics.hit`).
/// Peeking a filter never mutates an already-open reply or locked mid-type composer target.
private struct TwitchDualChatFilterBar: View {
    let accents: [TwitchChannelAccent]
    let selection: TwitchChatChannelFilter
    let onSelect: (TwitchChatChannelFilter) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip(
                    title: Copy.TwitchDualChat.filterAllCount(accents.count),
                    accent: nil,
                    selected: selection == .all,
                    identifier: "twitch.dual.filter.all"
                ) {
                    onSelect(.all)
                }
                ForEach(accents, id: \.channel) { accent in
                    filterChip(
                        title: Copy.TwitchDualChat.channelHandle(accent.displayName),
                        accent: accent,
                        selected: selection == .channel(accent.channel),
                        identifier: "twitch.dual.filter.\(accent.channel)"
                    ) {
                        onSelect(.channel(accent.channel))
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: Metrics.hit)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func filterChip(
        title: String,
        accent: TwitchChannelAccent?,
        selected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        let tint = accent.map { TwitchChatPalette.accentColor($0) }
        let fill: Color = if selected {
            tint?.opacity(0.22) ?? CobaltColor.text
        } else {
            CobaltColor.surface
        }
        let ink: Color = if selected {
            tint != nil ? CobaltColor.text : CobaltColor.onText
        } else {
            CobaltColor.caption
        }

        return Button(action: action) {
            HStack(spacing: 5) {
                if let tint {
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)
                }
                Text(title)
                    .font(Font.cobalt(12.5, selected ? .semibold : .medium))
                    .foregroundStyle(ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(fill, in: Capsule())
            .overlay {
                if selected, let tint {
                    Capsule().strokeBorder(tint, lineWidth: 1.25)
                }
            }
            .frame(minWidth: Metrics.hit, minHeight: Metrics.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

private struct TwitchCombinedChatLines: View {
    let combined: TwitchCombinedChatModel
    let cutoff: Date?
    let canAddEmotes: Bool
    let onAddEmote: (ChatEmote) -> Void

    @State private var following = true
    @State private var atBottom = true
    @State private var pausedAt: String?

    private static let bottom = "twitch-combined-chat-bottom"

    private var lines: [TwitchChatLine] {
        let visible = combined.visibleLines
        guard let cutoff else { return visible }
        return visible.filter { $0.mine || $0.timestamp <= cutoff }
    }

    private var newSincePause: Int {
        guard !following, let pausedAt, let i = lines.lastIndex(where: { $0.id == pausedAt }) else { return 0 }
        return lines.count - 1 - i
    }

    var body: some View {
        let isDual = combined.isDualChannel
        let avoidHues = combined.activeAccentHues
        let canReply = combined.canSendAny

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { line in
                        TwitchChatRow(
                            line: line,
                            paint: combined.paint(for: line),
                            sevenTvBadge: combined.sevenTvBadge(for: line),
                            canAddEmotes: canAddEmotes,
                            channelAccent: isDual ? combined.accent(for: line.channel) : nil,
                            avoidAccentHues: avoidHues,
                            tapToReply: isDual && canReply,
                            onReply: canReply ? { combined.beginReply(to: $0) } : nil,
                            onAddEmote: onAddEmote)
                        .equatable()
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 40
            } action: { _, now in
                atBottom = now
            }
            .onScrollPhaseChange { old, new in
                if new == .tracking || new == .interacting {
                    if following { pausedAt = lines.last?.id }
                    following = false
                } else if new == .idle, old != .idle {
                    following = atBottom
                    if following { pausedAt = nil }
                }
            }
            .onChange(of: lines.last?.id) {
                if following { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
            .onChange(of: combined.filter) {
                following = true
                pausedAt = nil
                proxy.scrollTo(Self.bottom, anchor: .bottom)
            }
            .overlay(alignment: .bottom) {
                if !following {
                    Button {
                        following = true
                        pausedAt = nil
                        withAnimation(.snappy) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                    } label: {
                        Label(
                            newSincePause > 0 ? "\(Copy.Twitch.paused) · \(Copy.Twitch.newLines(newSincePause))" : Copy.Twitch.jumpDown,
                            systemImage: Symbol.Twitch.down)
                            .font(Font.cobalt(12.5, .medium))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 32)
                            .foregroundStyle(.white)
                            .background(TwitchChatPalette.twitch, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                    .transition(.opacity)
                }
            }
        }
    }
}

/// Opus's Foolproof Dual-Target Composer:
/// - Zero dual-stream clutter when only 1 stream is active.
/// - In dual-stream mode: one >= 44 pt leading channel button opening a SwiftUI `Menu` (never tap-to-cycle).
/// - Target initializes once when keyboard opens (`reply > filter > focus`), then changes ONLY via menu or reply tap.
/// - `"Both"` lives only inside the menu; when active, shows dual-color accent border and `"send to 2"` send button.
/// - When target != focused stream, displays an explicit inline `→ channel · not in focus` indicator.
private struct TwitchDualComposer: View {
    let store: TwitchStore
    let combined: TwitchCombinedChatModel
    let canAddToSet: Bool
    let onAddEmote: (ChatEmote) -> Void

    @State private var text = ""
    @State private var sending = false
    @State private var picking = false
    @FocusState private var focused: Bool

    private var lastWord: Substring {
        text.split(separator: " ", omittingEmptySubsequences: false).last ?? ""
    }

    private var completions: [ChatEmote] {
        guard focused, !lastWord.hasPrefix("@") else { return [] }
        return combined.activeEmotes.completions(for: String(lastWord))
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var targetAccent: TwitchChannelAccent? {
        combined.composerTarget.channelLogin.flatMap { combined.accent(for: $0) }
    }

    private var channelCount: Int {
        max(2, combined.orderedAccents.count)
    }

    private var targetDisplayName: String {
        switch combined.composerTarget {
        case .both:
            return Copy.TwitchDualChat.allChannels(channelCount)
        case .channel(let ch):
            return combined.displayName(for: ch)
        }
    }

    private var promptText: String {
        guard combined.canSendToTarget else { return Copy.Twitch.composerReadOnly }
        guard combined.isDualChannel else { return Copy.Twitch.composerPrompt }
        if combined.composerTarget.isBoth {
            return Copy.TwitchDualChat.composerPromptAll(channelCount)
        }
        return Copy.TwitchDualChat.composerPrompt(targetDisplayName)
    }

    private var canSendNow: Bool { combined.canSendToTarget && !trimmed.isEmpty && !sending }

    var body: some View {
        VStack(spacing: 0) {
            if !completions.isEmpty { completionRow }
            if let reply = combined.replyTo { replyBanner(reply) }
            if combined.isTargetOutOfFocus { outOfFocusBanner }

            HStack(spacing: 6) {
                Button(
                    picking ? Copy.Twitch.hideEmotes : Copy.Twitch.showEmotes,
                    systemImage: picking ? Symbol.Twitch.keyboard : Symbol.Twitch.emotes
                ) {
                    togglePicker()
                }
                .labelStyle(.iconOnly)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(picking ? TwitchChatPalette.twitch : CobaltColor.caption)
                .frame(width: 36, height: Metrics.hit)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .accessibilityIdentifier("twitch.emotes")

                if combined.isDualChannel {
                    targetMenuButton
                }

                TextField(promptText, text: $text)
                    .textFieldStyle(.plain)
                    .font(Font.cobalt(14.5))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.send)
                    #endif
                    .focused($focused)
                    .disabled(!combined.canSendToTarget)
                    .onSubmit(send)
                    .onChange(of: text) { if text.count > 500 { text = String(text.prefix(500)) } }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 38)
                    .background(CobaltColor.surface, in: Capsule())
                    .overlay { fieldBorderOverlay }

                #if os(iOS)
                if focused || picking {
                    Button(Copy.Twitch.hideKeyboard, systemImage: Symbol.Twitch.hideKeyboard) {
                        dismissKeyboard()
                    }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(CobaltColor.caption)
                    .frame(width: 36, height: Metrics.hit)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("twitch.hideKeyboard")
                }
                #endif

                sendButton
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .padding(.vertical, 6)

            if picking {
                TwitchEmotePicker(
                    store: store,
                    canAddToSet: canAddToSet,
                    emotesOverride: combined.activeEmotes,
                    recentOverride: combined.recentEmotesForActiveTarget,
                    channelNameOverride: targetDisplayName,
                    onAddEmote: onAddEmote
                ) {
                    pick($0)
                }
                .frame(height: 260)
                .overlay(alignment: .top) { Divider() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(CobaltColor.bg)
        .overlay(alignment: .top) { Divider() }
        .animation(.snappy(duration: 0.25), value: picking)
        .onChange(of: focused) { _, now in
            if now {
                picking = false
                combined.composerDidOpen()
            } else if !picking {
                combined.composerDidClose(hasDraft: !trimmed.isEmpty)
            }
        }
        .onChange(of: picking) { _, now in
            if now {
                combined.composerDidOpen()
            } else if !focused {
                combined.composerDidClose(hasDraft: !trimmed.isEmpty)
            }
        }
        .onChange(of: combined.replyTo?.id) { _, nextID in
            if nextID != nil, combined.canSendToTarget {
                picking = false
                focused = true
            }
        }
    }

    /// Leading >= 44 pt channel selector button opening a SwiftUI `Menu` (NEVER tap-to-cycle).
    private var targetMenuButton: some View {
        let isBoth = combined.composerTarget.isBoth
        let singleTint = targetAccent.map { TwitchChatPalette.accentColor($0) } ?? TwitchChatPalette.twitch
        let gradient = TwitchChatPalette.dualAccentGradient(for: combined.orderedAccents)
        let allLabel = Copy.TwitchDualChat.allChannels(channelCount)

        return Menu {
            ForEach(combined.orderedAccents, id: \.channel) { accent in
                let isSelected = combined.composerTarget == .channel(accent.channel)
                Button {
                    combined.selectSendTarget(.channel(accent.channel))
                } label: {
                    if isSelected {
                        Label(Copy.TwitchDualChat.channelHandle(accent.displayName), systemImage: "checkmark")
                    } else {
                        Text(Copy.TwitchDualChat.channelHandle(accent.displayName))
                    }
                }
            }
            Divider()
            Button {
                combined.selectSendTarget(.both)
            } label: {
                if isBoth {
                    Label(allLabel, systemImage: "checkmark")
                } else {
                    Text(allLabel)
                }
            }
        } label: {
            HStack(spacing: 4) {
                if isBoth {
                    HStack(spacing: 2) {
                        ForEach(combined.orderedAccents, id: \.channel) { accent in
                            Circle()
                                .fill(TwitchChatPalette.accentColor(accent))
                                .frame(width: 6, height: 6)
                        }
                    }
                    Text("\(channelCount)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(CobaltColor.text)
                } else {
                    Text(targetAccent?.mark ?? "?")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(singleTint)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(CobaltColor.caption)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(isBoth ? CobaltColor.surface : singleTint.opacity(0.16), in: Capsule())
            .overlay {
                if isBoth {
                    Capsule().strokeBorder(gradient, lineWidth: 1.5)
                } else {
                    Capsule().strokeBorder(singleTint.opacity(0.55), lineWidth: 1)
                }
            }
            .frame(minWidth: Metrics.hit, minHeight: Metrics.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.TwitchDualChat.sendTargetMenu)
        .accessibilityValue(isBoth ? allLabel : Copy.TwitchDualChat.channelHandle(targetDisplayName))
        .accessibilityIdentifier("twitch.dual.targetMenu")
    }

    @ViewBuilder private var fieldBorderOverlay: some View {
        if combined.isDualChannel {
            if combined.composerTarget.isBoth {
                Capsule()
                    .strokeBorder(
                        TwitchChatPalette.dualAccentGradient(for: combined.orderedAccents),
                        lineWidth: 1.75)
            } else if let accent = targetAccent {
                Capsule()
                    .strokeBorder(TwitchChatPalette.accentColor(accent).opacity(0.45), lineWidth: 1)
            }
        }
    }

    @ViewBuilder private var sendButton: some View {
        if combined.isDualChannel && combined.composerTarget.isBoth {
            let gradient = TwitchChatPalette.dualAccentGradient(for: combined.orderedAccents)
            let sendAllLabel = Copy.TwitchDualChat.sendToAll(channelCount)
            Button(action: send) {
                HStack(spacing: 4) {
                    Text(sendAllLabel)
                        .font(Font.cobalt(12.5, .semibold))
                    Image(systemName: Symbol.Twitch.send)
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background {
                    if canSendNow {
                        Capsule().fill(gradient)
                    } else {
                        Capsule().fill(CobaltColor.elevated)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!canSendNow)
            .accessibilityLabel(sendAllLabel)
            .accessibilityIdentifier("twitch.dual.sendBoth")
        } else {
            let fill = canSendNow
                ? (combined.isDualChannel ? targetAccent.map { TwitchChatPalette.accentColor($0) } ?? TwitchChatPalette.twitch : TwitchChatPalette.twitch)
                : CobaltColor.elevated
            Button(
                combined.isDualChannel ? Copy.TwitchDualChat.sendingTo(targetDisplayName) : Copy.Twitch.send,
                systemImage: Symbol.Twitch.send,
                action: send
            )
            .labelStyle(.iconOnly)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(fill, in: Circle())
            .buttonStyle(.plain)
            .disabled(!canSendNow)
        }
    }

    private var outOfFocusBanner: some View {
        let tint = targetAccent.map { TwitchChatPalette.accentColor($0) } ?? CobaltColor.caption
        return HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(Copy.TwitchDualChat.notInFocus(targetDisplayName))
                .font(Font.cobalt(12, .medium))
                .foregroundStyle(tint)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .accessibilityIdentifier("twitch.dual.outOfFocus")
    }

    private func replyBanner(_ reply: TwitchChatLine) -> some View {
        let replyAccent = combined.isDualChannel ? combined.accent(for: reply.channel) : nil
        return HStack(spacing: 6) {
            if let accent = replyAccent {
                let tint = TwitchChatPalette.accentColor(accent)
                Text(accent.mark)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                    .padding(.horizontal, accent.mark.count > 1 ? 3 : 0)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            Image(systemName: Symbol.Twitch.reply)
            Text("\(Copy.Twitch.replyingTo(reply.displayName)): \(reply.plainText)")
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(Copy.Twitch.cancelReply, systemImage: Symbol.Twitch.close) {
                combined.cancelReply(composerOpen: focused, hasDraft: !trimmed.isEmpty)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .frame(width: 30, height: 30)
        }
        .font(Font.cobalt(12))
        .foregroundStyle(CobaltColor.caption)
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private var completionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(completions, id: \.self) { emote in
                    Button { complete(emote) } label: {
                        HStack(spacing: 5) {
                            EmotePicture(url: emote.url, animated: emote.animated, side: 22)
                            Text(emote.name)
                                .font(Font.cobalt(12.5, .medium))
                                .foregroundStyle(CobaltColor.text)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 32)
                        .background(CobaltColor.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
        }
    }

    private func dismissKeyboard() {
        focused = false
        picking = false
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private func togglePicker() {
        if picking {
            picking = false
            if combined.canSendToTarget { focused = true }
        } else {
            focused = false
            picking = true
        }
    }

    private func pick(_ emote: ChatEmote) {
        var next = text
        if !next.isEmpty, !next.hasSuffix(" ") { next += " " }
        next += emote.name + " "
        guard next.count <= 500 else { return }
        text = next
        combined.noteEmotePicked(emote)
    }

    private func complete(_ emote: ChatEmote) {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if words.isEmpty { words = [""] }
        words[words.count - 1] = emote.name
        text = words.joined(separator: " ") + " "
    }

    private func send() {
        guard canSendNow else { return }
        let message = trimmed
        sending = true
        Task {
            if await combined.send(message) { text = "" }
            sending = false
            if !picking { focused = true }
        }
    }
}
