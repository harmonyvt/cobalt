import CobaltKit
import SwiftUI

/// The card the 7tv circle opens into. An empty field is the emotes already saved.
/// Typing asks our API. A tap saves, or removes our copy. Nothing is copied from here.
struct EmoteSearchCard: View {
    let model: AppModel
    let close: () -> Void

    @State private var query = ""
    @State private var hits: [EmoteHit] = []
    @State private var searching = false
    @State private var missed = false
    @State private var failed = false
    @State private var busy = Set<String>()
    @State private var token = 0

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
            caption
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)], spacing: 12) {
                    if typing {
                        ForEach(hits) { hit in
                            tile(
                                id: hit.id,
                                name: hit.name,
                                url: hit.previewURL,
                                mark: hit.libraryID != nil,
                                action: { Task { await tap(hit) } })
                        }
                    } else {
                        ForEach(saved) { file in
                            tile(
                                id: file.id,
                                name: file.name,
                                url: file.url,
                                mark: false,
                                action: { Task { await remove(file) } })
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .task { await model.library.refresh() }
        .task(id: query) { await search() }
    }

    @ViewBuilder
    private var caption: some View {
        if failed {
            Text(Copy.emoteSearchDown).font(Font.cobalt(12)).foregroundStyle(CobaltColor.errorText)
        } else if typing && missed && !searching {
            Text(Copy.emoteSearchMiss).font(Font.cobalt(12)).foregroundStyle(CobaltColor.caption)
        } else if !typing && saved.isEmpty {
            Text(Copy.emoteSearchEmpty).font(Font.cobalt(12)).foregroundStyle(CobaltColor.caption)
        }
    }

    private func tile(id: String, name: String, url: URL?, mark: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 64, height: 64)
                    if busy.contains(id) {
                        ProgressView().controlSize(.small)
                    } else if mark {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                Text(name)
                    .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .disabled(busy.contains(id))
        .accessibilityLabel(mark ? "\(name), saved" : name)
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        token += 1
        let mine = token
        failed = false
        missed = false
        guard !q.isEmpty else {
            hits = []
            searching = false
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard mine == token, !Task.isCancelled else { return }
        searching = true
        defer { if mine == token { searching = false } }
        do {
            let found = try await model.library.searchEmotes(query: q)
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
            failed = false
        } catch {
            failed = true
        }
    }
}
