import CobaltKit
import SwiftUI

/// The card the 7tv circle opens into. The chips pick what shows: `saved` (the emotes already saved; typing there
/// searches 7TV's top of all time, as before) or a 7TV list (trending or top by day, week, month, all time, new, the
/// global set), which typing narrows by name (APP-API-CONTRACT 20.1). A tap saves, or removes our copy. Nothing is
/// copied from here.
struct EmoteSearchCard: View {
    let model: AppModel
    let close: () -> Void

    @State private var query = ""
    /// Nil is `saved`.
    @State private var sort: EmoteSort?
    @State private var hits: [EmoteHit] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var loadingMore = false
    @State private var searching = false
    @State private var missed = false
    @State private var failed = false
    @State private var busy = Set<String>()
    @State private var token = 0
    /// A saved emote the owner tapped: the confirm before its copy is removed.
    @State private var removing: LibraryFile?
    /// Bumped on each finished save, remove and failure: drives the haptics.
    @State private var savedTick = 0
    @State private var removedTick = 0
    @Environment(\.hapticsEnabled) private var haptics

    private var saved: [LibraryFile] {
        model.library.posts
            .filter(\.isEmote)
            .sorted { $0.createdAt > $1.createdAt }
            .flatMap(\.files)
            .filter { $0.source == .emote }
    }

    private var typing: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 7TV results show (not the saved emotes): a list chip, or a name typed under `saved`.
    private var showingHits: Bool { sort != nil || typing }

    /// What `search()` depends on: a new chip or new text starts over at page 1.
    private struct Ask: Equatable { var query: String; var sort: EmoteSort? }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField(Copy.seventvA11y, text: $query)
                    .textFieldStyle(.plain)
                    .font(Font.cobalt(16))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    #endif
                    .autocorrectionDisabled()
                if searching { ProgressView().controlSize(.small) }
                CloseButton { close() }
            }
            sortChips
            caption
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)], spacing: 12) {
                    if showingHits {
                        ForEach(hits) { hit in
                            tile(
                                id: hit.id,
                                name: hit.name,
                                url: hit.previewURL,
                                animated: hit.animated,
                                mark: hit.libraryID != nil,
                                action: { Task { await tap(hit) } })
                            .onAppear {
                                if hit.id == hits.last?.id { Task { await more() } }
                            }
                        }
                    } else {
                        ForEach(saved) { file in
                            tile(
                                id: file.id,
                                name: file.name,
                                url: file.url,
                                // A saved webp carries no flag. A still shows its one frame; an animated one plays.
                                animated: true,
                                mark: false,
                                action: { removing = file })
                            .contextMenu {
                                Button(Copy.emoteRemove, systemImage: "trash", role: .destructive) {
                                    Task { await remove(file) }
                                }
                            }
                        }
                    }
                }
                if loadingMore {
                    ProgressView().controlSize(.small).padding(.vertical, 8)
                }
            }
            .frame(maxHeight: 280)
        }
        .task { await model.library.refresh() }
        .task(id: Ask(query: query, sort: sort)) { await search() }
        .haptic(.selection, trigger: sort, enabled: haptics)
        .confirmationDialog(
            removing.map { Copy.emoteRemoveTitle($0.name) } ?? "", isPresented: removingPresented, titleVisibility: .visible,
            presenting: removing
        ) { file in
            Button(Copy.emoteRemove, role: .destructive) { Task { await remove(file) } }
            Button(Copy.emoteKeep, role: .cancel) {}
        } message: { _ in
            Text(Copy.emoteRemoveMessage)
        }
        .haptic(.success, trigger: savedTick, enabled: haptics)
        .haptic(.impact(weight: .light), trigger: removedTick, enabled: haptics)
        .haptic(.error, trigger: failed, enabled: haptics) { $0 }
    }

    private var removingPresented: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }

    @ViewBuilder
    private var caption: some View {
        if failed {
            Text(Copy.emoteSearchDown).font(Font.cobalt(12)).foregroundStyle(CobaltColor.errorText)
        } else if showingHits && missed && !searching {
            Text(typing ? Copy.emoteSearchMiss : Copy.emoteBrowseMiss).font(Font.cobalt(12)).foregroundStyle(CobaltColor.caption)
        } else if !showingHits && saved.isEmpty {
            Text(Copy.emoteSearchEmpty).font(Font.cobalt(12)).foregroundStyle(CobaltColor.caption)
        }
    }

    private func tile(id: String, name: String, url: URL?, animated: Bool, mark: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    EmotePicture(url: url, animated: animated)
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(mark ? CobaltColor.elevated : Color.clear))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(CobaltColor.text, lineWidth: mark ? 1.5 : 0)
                        }
                        .scaleEffect(busy.contains(id) ? 0.92 : 1)
                        .opacity(busy.contains(id) ? 0.6 : 1)
                    if busy.contains(id) {
                        ProgressView().controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if mark {
                        // the same tick as library and gallery select mode
                        LibraryPickMark(ticked: true)
                            .offset(x: 6, y: -6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(Motion.chip, value: mark)
                .animation(Motion.press, value: busy.contains(id))
                Text(name)
                    .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .disabled(busy.contains(id))
        .accessibilityLabel(mark ? "\(name), saved" : name)
        .accessibilityHint(mark ? Copy.emoteSavedHint : Copy.emoteSaveHint)
    }

    private var sortChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(Copy.emoteSaved, selected: sort == nil) { sort = nil }
                ForEach(EmoteSort.allCases) { option in
                    chip(Copy.emoteSort(option), selected: sort == option) { sort = option }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.emoteSortsA11y)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
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

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        token += 1
        let mine = token
        failed = false
        missed = false
        loadingMore = false
        page = 1
        hasMore = false
        guard sort != nil || !q.isEmpty else {
            hits = []
            searching = false
            return
        }
        // a chip tap loads at once; typing waits for a pause
        if !q.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
        guard mine == token, !Task.isCancelled else { return }
        searching = true
        defer { if mine == token { searching = false } }
        do {
            let found: [EmoteHit]
            if let sort {
                let first = try await model.library.browseEmotes(query: q, sort: sort, page: 1)
                found = first.items
                guard mine == token else { return }
                hasMore = first.hasMore
            } else {
                found = try await model.library.searchEmotes(query: q)
            }
            guard mine == token else { return }
            hits = found
            missed = found.isEmpty
            failed = false
        } catch {
            guard mine == token else { return }
            hits = []
            failed = true
        }
    }

    /// The next page of a list chip, when the last tile shows.
    private func more() async {
        guard let sort, hasMore, !loadingMore, !searching else { return }
        let mine = token
        let next = page + 1
        loadingMore = true
        defer { if mine == token { loadingMore = false } }
        do {
            let found = try await model.library.browseEmotes(query: query.trimmingCharacters(in: .whitespacesAndNewlines), sort: sort, page: next)
            guard mine == token else { return }
            let seen = Set(hits.map(\.id))
            hits += found.items.filter { !seen.contains($0.id) }
            page = next
            hasMore = found.hasMore
        } catch {
            guard mine == token else { return }
            hasMore = false
        }
    }

    private func tap(_ hit: EmoteHit) async {
        if let libraryID = hit.libraryID {
            busy.insert(hit.id)
            defer { busy.remove(hit.id) }
            do {
                try await model.library.removeEmote(fileID: libraryID)
                if let index = hits.firstIndex(where: { $0.id == hit.id }) {
                    var next = hit
                    next.libraryID = nil
                    next.libraryURL = nil
                    hits[index] = next
                }
                removedTick += 1
                failed = false
            } catch {
                failed = true
            }
            return
        }
        busy.insert(hit.id)
        defer { busy.remove(hit.id) }
        do {
            let saved = try await model.library.saveEmote(id: hit.id)
            if let index = hits.firstIndex(where: { $0.id == hit.id }) {
                var next = hit
                next.libraryID = saved.id
                next.libraryURL = saved.url
                hits[index] = next
            }
            savedTick += 1
            failed = false
        } catch {
            failed = true
        }
    }

    private func remove(_ file: LibraryFile) async {
        busy.insert(file.id)
        defer { busy.remove(file.id) }
        do {
            try await model.library.removeEmote(fileID: file.id)
            removedTick += 1
            failed = false
        } catch {
            failed = true
        }
    }
}
