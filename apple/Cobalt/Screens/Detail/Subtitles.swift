import CobaltKit
import SwiftUI

// Timed subtitles (APP-API-CONTRACT 47; `features.transcripts`): what was said in a post's video, line by line, each word
// lit as it is said. The detail of a video post loads its transcript once and hands this session down the environment:
// the hero's bar shows the CC button, the subtitles go under the video (default) or on the picture, the "heard" list
// shows every line with its time (tap to jump), and a search's "said at 0:12" opens the post playing from there.
// Whether subtitles are on, and where they go, is the owner's choice and stays between launches. Full screen uses the
// system player, which shows none.

/// One detail's subtitles: the transcript, the owner's choice, and the hero's transport it follows.
@MainActor @Observable
final class SubtitleSession {
    enum Place: String { case under, picture }

    private static let onKey = "subtitlesOn"
    private static let placeKey = "subtitlesPlace"

    private(set) var postKey: String?
    private(set) var transcript: LibraryTranscript?
    /// The owner wants subtitles (kept between launches).
    var on: Bool { didSet { UserDefaults.standard.set(on, forKey: Self.onKey) } }
    var place: Place { didSet { UserDefaults.standard.set(place.rawValue, forKey: Self.placeKey) } }
    /// A search's "said at" turned them on for this opening only.
    private(set) var forcedOn = false
    /// The playing hero's transport (its bar adopts it while it is on screen).
    private(set) var transport: HeroTransport?
    /// Where to start once a hero is playing (a search's "said at").
    @ObservationIgnored private var startAt: Double?

    init() {
        let defaults = UserDefaults.standard
        on = defaults.bool(forKey: Self.onKey)
        place = defaults.string(forKey: Self.placeKey).flatMap(Place.init(rawValue:)) ?? .under
    }

    /// There are lines to show.
    var available: Bool { transcript?.hasLines == true }

    /// Subtitles are showing at `place`.
    func shows(_ where: Place) -> Bool { available && (on || forcedOn) && place == `where` && transport != nil }

    /// The clip's time, 0 without a hero.
    var time: Double { transport?.time ?? 0 }

    // MARK: loading

    func load(_ library: LibraryModel, postKey: String) async {
        guard self.postKey != postKey || transcript == nil else { return }
        if self.postKey != postKey {
            self.postKey = postKey
            transcript = nil
        }
        do {
            let t = try await library.transcript(postKey: postKey)
            guard self.postKey == postKey else { return }
            transcript = t
        } catch {
            // no transcript: no button, no list (the "heard" text stays as it was)
        }
    }

    // MARK: the hero

    func adopt(_ t: HeroTransport) {
        transport = t
        if let s = startAt, t.hasPlayer {
            startAt = nil
            t.jump(to: s)
        }
    }

    func release(_ t: HeroTransport) {
        if transport === t { transport = nil }
    }

    // MARK: the owner

    func toggle() {
        if on || forcedOn {
            on = false
            forcedOn = false
        } else {
            on = true
        }
    }

    /// A line in the "heard" list: the clip plays from there.
    func jump(to seconds: Double) {
        if let transport, transport.hasPlayer {
            transport.jump(to: seconds)
        } else {
            startAt = seconds
        }
    }

    /// A search's "said at": play from there with subtitles on.
    func start(at seconds: Double) {
        forcedOn = true
        jump(to: seconds)
    }
}

private struct SubtitleSessionKey: EnvironmentKey {
    static var defaultValue: SubtitleSession? { nil }
}

extension EnvironmentValues {
    /// The detail's subtitles, set only on a video post's own video tab.
    var subtitles: SubtitleSession? {
        get { self[SubtitleSessionKey.self] }
        set { self[SubtitleSessionKey.self] = newValue }
    }
}

// MARK: - one line

/// The line on screen at `time`, each word lit as it is said. Under the video it is page text; on the picture it is
/// white on a dark plate.
struct SubtitleLineText: View {
    let transcript: LibraryTranscript
    let time: Double
    var onPicture = false

    var body: some View {
        let index = transcript.lineIndex(at: time)
        Text(index.map { styled(transcript.lines[$0]) } ?? AttributedString(" "))
            .font(Font.cobalt(onPicture ? 14 : 15, .medium, relativeTo: .body))
            .multilineTextAlignment(.center)
            .lineLimit(onPicture ? 3 : 2, reservesSpace: !onPicture)
            .padding(.horizontal, onPicture ? 10 : 0)
            .padding(.vertical, onPicture ? 5 : 0)
            .background {
                if onPicture, index != nil {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.62))
                }
            }
            .accessibilityHidden(true)
    }

    private func styled(_ line: LibraryTranscript.Line) -> AttributedString {
        let said: Color = onPicture ? .white : CobaltColor.text
        let now: Color = onPicture ? .white : CobaltColor.linkBlue
        let coming: Color = onPicture ? .white.opacity(0.62) : .secondary
        guard !line.words.isEmpty else {
            var whole = AttributedString(line.text)
            whole.foregroundColor = said
            return whole
        }
        var out = AttributedString()
        for (i, word) in line.words.enumerated() {
            var piece = AttributedString(i == 0 ? word.text : " " + word.text)
            switch line.phase(of: word, at: time) {
            case .said: piece.foregroundColor = said
            case .now:
                piece.foregroundColor = now
                if onPicture { piece.underlineStyle = .single }
            case .coming: piece.foregroundColor = coming
            }
            out += piece
        }
        return out
    }
}

// MARK: - under the video

/// The subtitles under the hero (the default place): two lines' room so the page never jumps.
struct SubtitleStrip: View {
    @Environment(\.subtitles) private var session

    var body: some View {
        if let session, session.shows(.under), let transcript = session.transcript {
            SubtitleLineText(transcript: transcript, time: session.time)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .transition(.opacity)
        }
    }
}

// MARK: - the bar's button

/// CC in the hero's bar: a tap turns subtitles on or off; a long press (or a right click) picks where they go.
struct SubtitleButton: View {
    let session: SubtitleSession
    let transport: HeroTransport
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showing: Bool { session.on || session.forcedOn }

    var body: some View {
        Button {
            session.toggle()
            transport.reveal()
        } label: {
            Image(systemName: showing ? Symbol.Subtitles.on : Symbol.Subtitles.off)
                .font(.system(size: 15, weight: .semibold))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace, options: .speed(2)))
                .foregroundStyle(CobaltColor.badgeInk)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Picker(Copy.Subtitles.place, selection: Binding(get: { session.place }, set: { session.place = $0; session.on = true })) {
                Label(Copy.Subtitles.underVideo, systemImage: Symbol.Subtitles.under).tag(SubtitleSession.Place.under)
                Label(Copy.Subtitles.onPicture, systemImage: Symbol.Subtitles.onPicture).tag(SubtitleSession.Place.picture)
            }
        }
        .accessibilityLabel(showing ? Copy.Subtitles.turnOff : Copy.Subtitles.turnOn)
        .accessibilityAction(named: Text(session.place == .under ? Copy.Subtitles.onPicture : Copy.Subtitles.underVideo)) {
            session.place = session.place == .under ? .picture : .under
            session.on = true
        }
    }
}

// MARK: - the "heard" list

/// Every line with its time; the one being said is lit, a tap plays from there. Copy as text or as a .srt file.
struct SubtitleHeardList: View {
    let session: SubtitleSession
    let transcript: LibraryTranscript
    @State private var copied: String?

    var body: some View {
        let current = session.transport.flatMap { transcript.lastLineIndex(at: $0.time) }
        VStack(alignment: .leading, spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(transcript.lines.enumerated()), id: \.offset) { i, line in
                            row(line, lit: i == current).id(i)
                        }
                    }
                }
                .frame(maxHeight: 220)
                .scrollIndicators(.automatic)
                .onChange(of: current) { _, now in
                    guard let now, session.transport?.isPlaying == true else { return }
                    withAnimation(Motion.rows) { proxy.scrollTo(now, anchor: .center) }
                }
            }
            HStack(spacing: 12) {
                Text(Copy.Subtitles.tapToJump)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                copyButton(Copy.Subtitles.copyText) { transcript.lines.map(\.text).joined(separator: "\n") }
                copyButton(Copy.Subtitles.copySrt) { transcript.srt() }
            }
            .font(CobaltType.badge)
        }
    }

    private func row(_ line: LibraryTranscript.Line, lit: Bool) -> some View {
        Button {
            session.jump(to: line.start)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(HeroClock.text(line.start))
                    .font(CobaltType.badge)
                    .monospacedDigit()
                    .foregroundStyle(lit ? CobaltColor.linkBlue : .secondary)
                    .frame(minWidth: 34, alignment: .leading)
                Text(line.text)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(lit ? CobaltColor.linkBlue : CobaltColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .background {
                if lit { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(CobaltColor.linkBlue.opacity(0.1)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.Subtitles.lineA11y(HeroClock.text(line.start), line.text))
        .accessibilityHint(Copy.Subtitles.tapToJump)
    }

    private func copyButton(_ title: String, _ text: @escaping () -> String) -> some View {
        Button {
            Pasteboard.copy(text())
            copied = title
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if copied == title { copied = nil }
            }
        } label: {
            Label(copied == title ? Copy.Subtitles.copied : title, systemImage: copied == title ? Symbol.Media.copied : Symbol.Subtitles.copy)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(CobaltColor.linkBlue)
    }
}

// MARK: - search: "said in it"

/// Under the search line: the results that were said in their video, each with its moment. A tap opens the post playing
/// from there, subtitles on.
struct LibrarySaidStrip: View {
    let library: LibraryModel
    let open: (LibraryPost, LibrarySaid) -> Void

    var body: some View {
        let said = library.saidResults
        if !said.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label(Copy.Subtitles.saidInIt, systemImage: Symbol.Subtitles.said)
                    .font(CobaltType.badge)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(said.prefix(12), id: \.post.id) { entry in
                            if let first = entry.said.first { chip(entry.post, first) }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .transition(.opacity)
        }
    }

    private func chip(_ post: LibraryPost, _ said: LibrarySaid) -> some View {
        Button {
            open(post, said)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(HeroClock.text(said.start))
                    .font(CobaltType.badge)
                    .monospacedDigit()
                    .foregroundStyle(CobaltColor.linkBlue)
                Text(said.text)
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
                if said.match == .meaning {
                    Text(Copy.Subtitles.byMeaning)
                        .font(CobaltType.badge)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 280, alignment: .leading)
            .background(Capsule().fill(CobaltColor.linkBlue.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.Subtitles.jumpTo(HeroClock.text(said.start), said.text))
    }
}
