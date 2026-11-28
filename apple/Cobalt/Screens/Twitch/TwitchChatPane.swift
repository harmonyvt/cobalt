import CobaltKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// The live chat beside or under the player (APP-API-CONTRACT 70): the room's modes, the lines (kept at the newest unless
// the owner scrolls up, then "paused · N new"), and the full-width composer dock with multi-line input, 500-char limit
// indicator, emote completion, replies, and redesigned emote picker.

struct TwitchChatPane: View {
    let model: AppModel
    /// Seconds lines wait before they show (video-only AirPlay runs the TV behind, 70.5); 0 shows them at once.
    var delay: TimeInterval = 0
    /// The "chat" word over the lines; off when a card already says it (the pane's shelf).
    var showsLabel = true
    /// Optional combined chat model coordinating 1...4 streams. When nil, uses `model.twitch` single-stream chat.
    /// When coordinating only 1 stream, renders crisp single-stream chat with zero dual-stream clutter.
    var combined: TwitchCombinedChatModel? = nil
    /// Whether this pane renders the composer directly at its bottom. `TwitchStreamPage` sets this to `false`
    /// and docks `TwitchChatComposerDock` full-width underneath both streams and chat.
    var includesComposer = true
    /// Extra trailing padding on the filter bar so floating top-right system orbs never obscure the last chip.
    var filterTrailingClearance: CGFloat = 0
    let onAddEmote: (ChatEmote) -> Void

    private var store: TwitchStore { model.twitch }

    var body: some View {
        if let combined {
            TwitchCombinedChatContent(
                model: model,
                combined: combined,
                delay: delay,
                showsLabel: showsLabel,
                includesComposer: includesComposer,
                filterTrailingClearance: filterTrailingClearance,
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
                if includesComposer {
                    TwitchChatComposerDock(model: model, combined: nil, onAddEmote: onAddEmote)
                }
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
                            .font(Font.cobalt(12.5, .semibold).monospacedDigit())
                            .padding(.horizontal, 14)
                            .frame(minHeight: 34)
                            .foregroundStyle(.white)
                            .mediaGlassCapsule(tint: TwitchChatPalette.twitch)
                            .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                }
            }
        }
    }
}

// MARK: - combined multi-stream chat

private struct TwitchCombinedChatContent: View {
    let model: AppModel
    let combined: TwitchCombinedChatModel
    let delay: TimeInterval
    let showsLabel: Bool
    let includesComposer: Bool
    let filterTrailingClearance: CGFloat
    let onAddEmote: (ChatEmote) -> Void

    var body: some View {
        VStack(spacing: 0) {
            TwitchChatHeader(status: combined.headerStatus, room: combined.headerRoom, showsLabel: showsLabel)
            if combined.isDualChannel {
                TwitchDualChatFilterBar(
                    accents: combined.orderedAccents,
                    selection: combined.filter,
                    trailingClearance: filterTrailingClearance,
                    onSelect: { combined.setFilter($0) })
            }
            if delay > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    linesView(cutoff: context.date.addingTimeInterval(-delay))
                }
            } else {
                linesView(cutoff: nil)
            }
            if includesComposer {
                TwitchChatComposerDock(model: model, combined: combined, onAddEmote: onAddEmote)
            }
        }
        .background(CobaltColor.bg)
    }

    private func linesView(cutoff: Date?) -> some View {
        TwitchCombinedChatLines(
            combined: combined,
            cutoff: cutoff,
            canAddEmotes: model.sevenTv.isLinked,
            onAddEmote: onAddEmote)
    }
}

/// Filter bar (`All` | `@StreamA` | `@StreamB`) with >= 44 pt hit targets (`Metrics.hit`).
/// Peeking a filter never mutates an already-open reply or locked mid-type composer target.
private struct TwitchDualChatFilterBar: View {
    let accents: [TwitchChannelAccent]
    let selection: TwitchChatChannelFilter
    var trailingClearance: CGFloat = 0
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
            .padding(.leading, 10)
            .padding(.trailing, max(10, trailingClearance))
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
                        .shadow(color: selected ? tint.opacity(0.65) : .clear, radius: 3)
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
                    Capsule().strokeBorder(tint.opacity(0.85), lineWidth: 1.25)
                } else if !selected {
                    Capsule().strokeBorder(CobaltColor.hairline, lineWidth: 0.75)
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
                            .font(Font.cobalt(12.5, .semibold).monospacedDigit())
                            .padding(.horizontal, 14)
                            .frame(minHeight: 34)
                            .foregroundStyle(.white)
                            .mediaGlassCapsule(tint: TwitchChatPalette.twitch)
                            .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                }
            }
        }
    }
}

// MARK: - Full-Width Multi-Line Chat Composer Dock

/// Unified full-width chat composer supporting both single-stream and multi-stream (`TwitchCombinedChatModel`) sessions:
/// - Spans the entire display width beneath streams and chat on iPhone Duo, iPad, and macOS.
/// - Multi-line expanding `TextField(..., axis: .vertical)` (`1...5` lines) with live Twitch 500-char counter + ring.
/// - Opus's foolproof dual-target locking (`reply > filter > focus`), explicit `Menu` target picker, and full-width emote tray.
struct TwitchChatComposerDock: View {
    let model: AppModel
    var combined: TwitchCombinedChatModel? = nil
    let onAddEmote: (ChatEmote) -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var text = ""
    @State private var sending = false
    /// The emote picker is open under the field (the keyboard is down meanwhile).
    @State private var picking = false
    @State private var dockWidth: CGFloat = 0
    @FocusState private var focused: Bool

    private var store: TwitchStore { model.twitch }
    private var canAddToSet: Bool { model.sevenTv.isLinked }
    private var isDual: Bool { combined?.isDualChannel == true }
    private var isWideDock: Bool { dockWidth >= 520 || sizeClass == .regular }

    private var activeEmotes: TwitchEmoteList {
        combined?.activeEmotes ?? store.emotes
    }

    private var canSendToTarget: Bool {
        combined?.canSendToTarget ?? store.canSend
    }

    private var activeReply: TwitchChatLine? {
        combined != nil ? combined?.replyTo : store.replyTo
    }

    private var currentWord: Substring {
        TwitchChatComposerRules.currentToken(in: text)
    }

    private var completions: [ChatEmote] {
        guard focused, !currentWord.hasPrefix("@") else { return [] }
        return activeEmotes.completions(for: String(currentWord))
    }

    private var charCount: Int {
        TwitchChatComposerRules.characterCount(text)
    }

    private var remainingChars: Int {
        TwitchChatComposerRules.remainingCharacters(text)
    }

    private var counterTone: TwitchChatComposerRules.CounterTone {
        TwitchChatComposerRules.tone(for: text)
    }

    private var isOverLimit: Bool {
        counterTone == .overLimit
    }

    private var preparedMessage: String {
        TwitchChatComposerRules.preparedForSend(text)
    }

    private var targetAccent: TwitchChannelAccent? {
        guard let combined else { return nil }
        return combined.composerTarget.channelLogin.flatMap { combined.accent(for: $0) }
    }

    private var channelCount: Int {
        max(2, combined?.orderedAccents.count ?? 2)
    }

    private var targetDisplayName: String {
        guard let combined else {
            return store.displayName(for: store.channel ?? "")
        }
        switch combined.composerTarget {
        case .both:
            return Copy.TwitchDualChat.allChannels(channelCount)
        case .channel(let ch):
            return combined.displayName(for: ch)
        }
    }

    private var activeTargetChannel: String? {
        if let combined {
            return combined.composerTarget.channelLogin
        }
        return store.channel
    }

    private var promptText: String {
        if !canSendToTarget {
            if let ch = activeTargetChannel {
                let platform = StreamAddress.platform(for: ch)
                if !platform.supportsSendingChat {
                    return Copy.Twitch.composerReadOnlyPlatform(platform.lowercaseName)
                }
            }
            return Copy.Twitch.composerReadOnly
        }
        guard let combined, combined.isDualChannel else { return Copy.Twitch.composerPrompt }
        if combined.composerTarget.isBoth {
            return Copy.TwitchDualChat.composerPromptAll(channelCount)
        }
        return Copy.TwitchDualChat.composerPrompt(targetDisplayName)
    }

    private var canSendNow: Bool {
        canSendToTarget && TwitchChatComposerRules.canSend(text) && !sending
    }

    private var showCounter: Bool {
        canSendToTarget && (focused || charCount > 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !completions.isEmpty { completionRow }
            if let reply = activeReply { replyBanner(reply) }
            if let combined, combined.isTargetOutOfFocus { outOfFocusBanner(combined: combined) }

            HStack(alignment: .bottom, spacing: 8) {
                Button(
                    picking ? Copy.Twitch.hideEmotes : Copy.Twitch.showEmotes,
                    systemImage: picking ? Symbol.Twitch.keyboard : Symbol.Twitch.emotes
                ) {
                    togglePicker()
                }
                .labelStyle(.iconOnly)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(picking ? TwitchChatPalette.twitch : CobaltColor.caption)
                .frame(width: 38, height: 40)
                .background(
                    picking ? TwitchChatPalette.twitch.opacity(0.14) : CobaltColor.surface,
                    in: Circle()
                )
                .overlay {
                    Circle().strokeBorder(
                        picking ? TwitchChatPalette.twitch.opacity(0.45) : CobaltColor.hairline.opacity(0.75),
                        lineWidth: 0.75
                    )
                }
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .accessibilityIdentifier("twitch.emotes")

                if let combined, combined.isDualChannel {
                    targetMenuButton(combined: combined)
                }

                // Multi-line expanding input container with embedded 500-char counter + progress ring.
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(promptText, text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Font.cobalt(14.5))
                        .lineLimit(1...5)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .focused($focused)
                        .disabled(!canSendToTarget)
                        #if os(macOS)
                        .onSubmit(send)
                        #endif
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 9)

                    if showCounter {
                        characterLimitBadge
                            .padding(.bottom, 8)
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, showCounter ? 10 : 14)
                .frame(minHeight: 40)
                .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay { fieldBorderOverlay }

                #if os(iOS)
                if focused || picking {
                    Button(Copy.Twitch.hideKeyboard, systemImage: Symbol.Twitch.hideKeyboard) {
                        dismissKeyboard()
                    }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(CobaltColor.caption)
                    .frame(width: 38, height: 40)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("twitch.hideKeyboard")
                }
                #endif

                sendButton
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if picking {
                TwitchEmotePicker(
                    store: store,
                    canAddToSet: canAddToSet,
                    emotesOverride: combined?.activeEmotes,
                    recentOverride: combined?.recentEmotesForActiveTarget,
                    channelNameOverride: combined != nil ? targetDisplayName : nil,
                    onAddEmote: onAddEmote
                ) {
                    pick($0)
                }
                .frame(height: isWideDock ? 288 : 248)
                .overlay(alignment: .top) { Divider() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(CobaltColor.bg)
        .overlay(alignment: .top) { Divider() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if abs(width - dockWidth) > 1 { dockWidth = width }
        }
        .animation(.snappy(duration: 0.22), value: picking)
        .onChange(of: focused) { _, now in
            if now {
                picking = false
                combined?.composerDidOpen()
            } else if !picking {
                combined?.composerDidClose(hasDraft: !preparedMessage.isEmpty)
            }
        }
        .onChange(of: picking) { _, now in
            if now {
                combined?.composerDidOpen()
            } else if !focused {
                combined?.composerDidClose(hasDraft: !preparedMessage.isEmpty)
            }
        }
        .onChange(of: activeReply?.id) { _, nextID in
            if nextID != nil, canSendToTarget {
                picking = false
                focused = true
            }
        }
    }

    /// Twitter/X-inspired circular limit progress ring + monospaced count (`used/500` or `-over`).
    private var characterLimitBadge: some View {
        let progress = min(1.0, Double(charCount) / Double(TwitchChatComposerRules.maxLength))
        let ringColor: Color = switch counterTone {
        case .normal:
            charCount == 0 ? CobaltColor.hairline : TwitchChatPalette.twitch.opacity(0.75)
        case .caution:
            Color.orange
        case .overLimit:
            CobaltColor.errorText
        }
        let textColor: Color = switch counterTone {
        case .normal: CobaltColor.caption
        case .caution: Color.orange
        case .overLimit: CobaltColor.errorText
        }
        let label = isOverLimit ? "\(remainingChars)" : "\(charCount)/\(TwitchChatComposerRules.maxLength)"

        return HStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(CobaltColor.hairline.opacity(0.6), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)

            Text(label)
                .font(Font.cobalt(11, isOverLimit || counterTone == .caution ? .semibold : .medium).monospacedDigit())
                .foregroundStyle(textColor)
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityIdentifier("twitch.composer.charLimit")
        .accessibilityLabel("\(charCount) of \(TwitchChatComposerRules.maxLength) characters")
    }

    /// Leading channel selector button opening a SwiftUI `Menu` (NEVER tap-to-cycle).
    /// Because the dock spans the full display width, shows the actual `@channel` handle instead of a single letter.
    private func targetMenuButton(combined: TwitchCombinedChatModel) -> some View {
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
            HStack(spacing: 5) {
                if isBoth {
                    HStack(spacing: 2) {
                        ForEach(combined.orderedAccents, id: \.channel) { accent in
                            Circle()
                                .fill(TwitchChatPalette.accentColor(accent))
                                .frame(width: 6, height: 6)
                        }
                    }
                    Text(Copy.TwitchDualChat.allShort(channelCount))
                        .font(Font.cobalt(12.5, .semibold))
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(1)
                } else {
                    Circle()
                        .fill(singleTint)
                        .frame(width: 7, height: 7)
                    Text(isWideDock ? Copy.TwitchDualChat.channelHandle(targetDisplayName) : (targetAccent?.mark ?? targetDisplayName))
                        .font(Font.cobalt(12.5, .semibold))
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(1)
                        .frame(maxWidth: isWideDock ? 140 : 44, alignment: .leading)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(CobaltColor.caption)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(isBoth ? CobaltColor.surface : singleTint.opacity(0.14), in: Capsule())
            .overlay {
                if isBoth {
                    Capsule().strokeBorder(gradient, lineWidth: 1.5)
                } else {
                    Capsule().strokeBorder(singleTint.opacity(0.55), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.TwitchDualChat.sendTargetMenu)
        .accessibilityValue(isBoth ? allLabel : Copy.TwitchDualChat.channelHandle(targetDisplayName))
        .accessibilityIdentifier("twitch.dual.targetMenu")
    }

    @ViewBuilder private var fieldBorderOverlay: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if isOverLimit {
            shape.strokeBorder(CobaltColor.errorText.opacity(0.85), lineWidth: 1.5)
        } else if let combined, combined.isDualChannel {
            if combined.composerTarget.isBoth {
                shape.strokeBorder(
                    TwitchChatPalette.dualAccentGradient(for: combined.orderedAccents),
                    lineWidth: 1.5
                )
            } else if let accent = targetAccent {
                shape.strokeBorder(TwitchChatPalette.accentColor(accent).opacity(focused ? 0.7 : 0.42), lineWidth: 1)
            }
        } else {
            shape.strokeBorder(
                focused ? TwitchChatPalette.twitch.opacity(0.55) : CobaltColor.hairline.opacity(0.85),
                lineWidth: focused ? 1.15 : 0.75
            )
        }
    }

    @ViewBuilder private var sendButton: some View {
        if let combined, combined.isDualChannel, combined.composerTarget.isBoth {
            let gradient = TwitchChatPalette.dualAccentGradient(for: combined.orderedAccents)
            let sendAllLabel = Copy.TwitchDualChat.sendToAll(channelCount)
            Button(action: send) {
                HStack(spacing: 5) {
                    Text(sendAllLabel)
                        .font(Font.cobalt(12.5, .semibold))
                    Image(systemName: Symbol.Twitch.send)
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .frame(height: 40)
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
                ? (isDual ? targetAccent.map { TwitchChatPalette.accentColor($0) } ?? TwitchChatPalette.twitch : TwitchChatPalette.twitch)
                : CobaltColor.elevated
            Button(
                isDual ? Copy.TwitchDualChat.sendingTo(targetDisplayName) : Copy.Twitch.send,
                systemImage: Symbol.Twitch.send,
                action: send
            )
            .labelStyle(.iconOnly)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(fill, in: Circle())
            .buttonStyle(.plain)
            .disabled(!canSendNow)
        }
    }

    private func outOfFocusBanner(combined: TwitchCombinedChatModel) -> some View {
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
        let replyAccent = combined?.isDualChannel == true ? combined?.accent(for: reply.channel) : nil
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
                if let combined {
                    combined.cancelReply(composerOpen: focused, hasDraft: !preparedMessage.isEmpty)
                } else {
                    store.replyTo = nil
                }
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
                        .padding(.horizontal, 9)
                        .frame(height: 32)
                        .background(CobaltColor.surface, in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(CobaltColor.hairline.opacity(0.7), lineWidth: 0.5)
                        }
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
            if canSendToTarget { focused = true }
        } else {
            focused = false
            picking = true
        }
    }

    private func pick(_ emote: ChatEmote) {
        var next = text
        if !next.isEmpty, !next.hasSuffix(" "), !next.hasSuffix("\n") { next += " " }
        next += emote.name + " "
        guard TwitchChatComposerRules.characterCount(next) <= TwitchChatComposerRules.maxLength else { return }
        text = next
        if let combined {
            combined.noteEmotePicked(emote)
        } else {
            store.noteEmotePicked(emote)
        }
    }

    private func complete(_ emote: ChatEmote) {
        text = TwitchChatComposerRules.replacingCurrentToken(in: text, with: emote.name)
    }

    private func send() {
        guard canSendNow else { return }
        let message = preparedMessage
        sending = true
        Task {
            let ok: Bool
            if let combined {
                ok = await combined.send(message)
            } else {
                ok = await store.send(message)
            }
            if ok { text = "" }
            sending = false
            if !picking { focused = true }
        }
    }
}
