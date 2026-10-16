import CobaltKit
import Foundation
import Observation
import SwiftUI

extension KeyboardWords {
    static let typeHint = "type : and a name for emotes"
    static let keepTyping = "keep typing to search 7tv"
    static let emoteNoAccess = "allow full access for 7tv emotes"
}

/// Typing mode: letters go into the app behind the keyboard. A ":" followed by a word asks 7TV, and the bar above
/// the keys shows the emotes used here first, then the search. Tap inserts the emote's link; hold copies the file.
@MainActor @Observable
final class KeyboardTypingModel {
    enum Layer { case letters, numbers }

    /// Typing mode is on. Kept, so the keyboard opens on whichever mode it was left on.
    private(set) var on = false
    var layer: Layer = .letters
    var shifted = false
    /// The word after ":" before the cursor; nil when nothing is being completed.
    private(set) var query: String?
    private(set) var note: String?
    private(set) var recents: [EmoteHit] = []
    private var found: [EmoteHit] = []
    private var foundFor: String?

    @ObservationIgnored var insert: @MainActor (String) -> Void = { _ in }
    @ObservationIgnored var deleteBackward: @MainActor () -> Void = {}
    @ObservationIgnored var pick: @MainActor (EmoteHit) -> Void = { _ in }
    @ObservationIgnored var hold: @MainActor (EmoteHit) -> Void = { _ in }
    /// The keyed client, or why there is none.
    @ObservationIgnored var client: @MainActor () -> Result<HTTPCobaltClient, KeyboardClientMissing> = { .failure(.noKey) }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var token = 0

    private static let modeKey = "keyboard.typing"
    private static let recentsKey = "keyboard.emoteRecents"
    /// One letter matches only the recents; 7TV is asked from two.
    static let searchFrom = 2

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        on = defaults.bool(forKey: Self.modeKey)
        recents = EmoteRecents.decode(defaults.data(forKey: Self.recentsKey))
    }

    func setOn(_ typing: Bool) {
        on = typing
        defaults.set(typing, forKey: Self.modeKey)
    }

    var suggestions: [EmoteHit] {
        guard let query else { return [] }
        let remote: [EmoteHit]
        if foundFor == query {
            remote = found
        } else if let foundFor, query.lowercased().hasPrefix(foundFor.lowercased()) {
            // the next answer is coming: keep what still matches instead of emptying the bar
            remote = EmoteRecents.matching(query, in: found)
        } else {
            remote = []
        }
        return EmoteRecents.suggestions(query: query, recents: recents, found: remote)
    }

    /// The host's text changed (a key, a paste, the cursor moved).
    func contextChanged(before text: String?, autoCapitalize: Bool) {
        let next = EmoteTrigger.query(before: text)
        if next != query {
            query = next
            note = nil
        }
        guard layer == .letters, autoCapitalize, next == nil else { return }
        let before = text ?? ""
        shifted = before.isEmpty || before.hasSuffix("\n")
            || [". ", "! ", "? "].contains { before.hasSuffix($0) }
    }

    func type(_ text: String) {
        let out = shifted ? text.uppercased() : text
        shifted = false
        insert(out)
    }

    func search() async {
        guard let q = query, q.count >= Self.searchFrom else { return }
        let client: HTTPCobaltClient
        switch self.client() {
        case .success(let ready): client = ready
        case .failure(let missing):
            note = missing == .noAccess ? KeyboardWords.emoteNoAccess : KeyboardWords.noKey
            return
        }
        token += 1
        let mine = token
        do {
            let hits = try await client.searchEmotes(query: q)
            guard mine == token, query == q else { return }
            found = hits
            foundFor = q
            note = suggestions.isEmpty ? KeyboardWords.emoteMiss : nil
        } catch {
            // a keystroke cancels the search: a newer one is coming, 7tv is not down
            guard mine == token, query == q, !Task.isCancelled else { return }
            note = suggestions.isEmpty ? KeyboardWords.emoteDown : nil
        }
    }

    /// Used here: first in the bar from now on. A saved copy replaces the one without a link.
    func remember(_ hit: EmoteHit) {
        recents = EmoteRecents.adding(hit, to: recents)
        defaults.set(EmoteRecents.encode(recents), forKey: Self.recentsKey)
        if let index = found.firstIndex(where: { $0.id == hit.id }), hit.libraryURL != nil { found[index] = hit }
    }
}

enum KeyboardClientMissing: Error { case noAccess, noKey }

/// Gallery or typing, whichever the keyboard was left on.
struct KeyboardRootView: View {
    let gallery: KeyboardGalleryModel
    let typing: KeyboardTypingModel

    var body: some View {
        if typing.on {
            KeyboardTypingView(model: typing, gallery: gallery)
        } else {
            KeyboardGalleryView(model: gallery) { typing.setOn(true) }
        }
    }
}

struct KeyboardTypingView: View {
    let model: KeyboardTypingModel
    let gallery: KeyboardGalleryModel

    var body: some View {
        VStack(spacing: 6) {
            bar
                .frame(height: 40)
                // the globe owns the top right corner when iOS asks for one
                .padding(.trailing, 52)
            TypingKeys(model: model) { model.setOn(false) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: model.query) {
            guard let q = model.query, q.count >= KeyboardTypingModel.searchFrom else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await model.search()
        }
    }

    @ViewBuilder
    private var bar: some View {
        if let transfer = gallery.transfer {
            line("\(transfer.title) · \(transfer.detail)", CobaltColor.text)
        } else if let notice = gallery.notice {
            switch notice {
            case .copied: line(KeyboardWords.copied, CobaltColor.text)
            case .failed(let message): line(message, CobaltColor.errorText)
            }
        } else if let query = model.query {
            let suggestions = model.suggestions
            if suggestions.isEmpty {
                line(model.note ?? (query.count < KeyboardTypingModel.searchFrom ? KeyboardWords.keepTyping : ""),
                     CobaltColor.caption)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(suggestions) { hit in
                            SuggestionChip(hit: hit, saving: gallery.savingEmoteID == hit.id) {
                                model.pick(hit)
                            } hold: {
                                model.hold(hit)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollEdgeEffectHidden(true)
            }
        } else {
            line(KeyboardWords.typeHint, CobaltColor.caption)
        }
    }

    private func line(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(Font.cobalt(12))
            .textCase(.lowercase)
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, 52)
    }
}

/// One emote in the bar. The long press is exclusive of the tap.
private struct SuggestionChip: View {
    let hit: EmoteHit
    let saving: Bool
    let pick: () -> Void
    let hold: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                EmotePicture(url: hit.previewURL, animated: hit.animated, side: 28)
                if saving { ProgressView().controlSize(.mini) }
            }
            Text(hit.name)
                .font(Font.cobalt(13))
                .lineLimit(1)
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(height: 36)
        .background(Capsule().fill(CobaltColor.elevated))
        .contentShape(Capsule())
        .gesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in hold() }
                .exclusively(before: TapGesture().onEnded { pick() })
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hit.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { pick() }
        .accessibilityAction(named: Text("copy the file")) { hold() }
    }
}

/// QWERTY into the host app, with ":" on the bottom row.
private struct TypingKeys: View {
    let model: KeyboardTypingModel
    let showGallery: () -> Void

    private static let letters = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private static let numbers = ["1234567890", "-/:;()$&@\"", ".,?!'"]

    private var rows: [String] { model.layer == .letters ? Self.letters : Self.numbers }

    var body: some View {
        VStack(spacing: 8) {
            characters(rows[0])
            characters(rows[1])
                .padding(.horizontal, model.layer == .letters ? 18 : 0)
            HStack(spacing: 6) {
                if model.layer == .letters {
                    function(model.shifted ? "shift.fill" : "shift", label: "shift") { model.shifted.toggle() }
                        .frame(width: 44)
                } else {
                    Color.clear.frame(width: 44)
                }
                characters(rows[2])
                RepeatingKey(action: model.deleteBackward) {
                    keyFace(Image(systemName: "delete.left"), fill: CobaltColor.elevated.opacity(0.55))
                }
                .frame(width: 44)
                .accessibilityLabel("delete")
            }
            HStack(spacing: 6) {
                function(nil, text: model.layer == .letters ? "123" : "abc", label: "more keys") {
                    model.layer = model.layer == .letters ? .numbers : .letters
                }
                .frame(width: 48)
                function("square.grid.2x2", label: "library") { showGallery() }
                    .frame(width: 44)
                character(":")
                    .frame(width: 44)
                key(Text("space").font(Font.cobalt(14)), fill: CobaltColor.elevated) { model.insert(" ") }
                    .accessibilityLabel("space")
                function(nil, text: "return", label: "return") { model.insert("\n") }
                    .frame(width: 72)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        .frame(maxHeight: .infinity)
    }

    private func characters(_ row: String) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(row), id: \.self) { ch in character(String(ch)) }
        }
    }

    private func character(_ text: String) -> some View {
        let shown = model.shifted ? text.uppercased() : text
        return key(Text(shown).font(Font.cobalt(18)), fill: CobaltColor.elevated) { model.type(text) }
            .accessibilityLabel(shown)
    }

    private func function(_ symbol: String?, text: String = "", label: String, action: @escaping () -> Void) -> some View {
        Group {
            if let symbol {
                key(Image(systemName: symbol).font(.system(size: 16, weight: .medium)), fill: CobaltColor.elevated.opacity(0.55), action: action)
            } else {
                key(Text(text).font(Font.cobalt(14)), fill: CobaltColor.elevated.opacity(0.55), action: action)
            }
        }
        .accessibilityLabel(label)
    }

    private func key<V: View>(_ face: V, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { keyFace(face, fill: fill) }
            .buttonStyle(KeyPress())
    }

    private func keyFace<V: View>(_ face: V, fill: Color) -> some View {
        face
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
            .contentShape(Rectangle())
    }
}

private struct KeyPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// Fires on touch down, then repeats while held (delete).
private struct RepeatingKey<Face: View>: View {
    let action: @MainActor () -> Void
    @ViewBuilder let face: () -> Face
    @State private var repeating: Task<Void, Never>?

    var body: some View {
        face()
            .opacity(repeating == nil ? 1 : 0.55)
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 40, perform: {}, onPressingChanged: { pressing in
                repeating?.cancel()
                repeating = nil
                guard pressing else { return }
                action()
                repeating = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    while !Task.isCancelled {
                        action()
                        try? await Task.sleep(for: .milliseconds(80))
                    }
                }
            })
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}
