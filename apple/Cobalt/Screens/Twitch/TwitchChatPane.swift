import CobaltKit
import SwiftUI

// The live chat beside or under the player (APP-API-CONTRACT 70): the room's modes, the lines (kept at the newest unless
// the owner scrolls up, then "paused · N new"), and the composer with emote completion and replies.

struct TwitchChatPane: View {
    let model: AppModel
    /// Seconds lines wait before they show (video-only AirPlay runs the TV behind, 70.5); 0 shows them at once.
    var delay: TimeInterval = 0
    /// The "chat" word over the lines; off when a card already says it (the pane's shelf).
    var showsLabel = true
    let onAddEmote: (ChatEmote) -> Void

    private var store: TwitchStore { model.twitch }

    var body: some View {
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
