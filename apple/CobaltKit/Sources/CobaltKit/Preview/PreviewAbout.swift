import Foundation
import Synchronization

// The preview server's "what it's about" (APP-API-CONTRACT 34): `GET`/`PATCH /library/about` for the preview posts, and the
// scored list the chat attaches. Served with `AppModel.previewSearch(_:)` (any mode but `.off`). Nothing on the network.

/// The tags the owner edited on the preview server, by post key (`nil` value: reset). Lives in the search state.
final class PreviewAboutState: Sendable {
    private let edits = Mutex<[String: [String]]>([:])
    private let sets = Mutex<[String]>([])

    /// The owner's tags for a post, nil when never edited (or reset).
    func tags(_ key: String) -> [String]? { edits.withLock { $0[key] } }

    /// `PATCH` calls so far, as `"<key> <tag,tag>"` or `"<key> reset"`.
    var calls: [String] { sets.withLock { $0 } }

    func set(_ key: String, tags: [String]?) {
        edits.withLock { $0[key] = tags }
        sets.withLock { $0.append("\(key) \(tags.map { $0.joined(separator: ",") } ?? "reset")") }
    }
}

extension PreviewData {
    /// A post the preview library does not hold: the fursuit-on-an-airplane reel, the sample of the mockup.
    static let aboutFursuitKey = "PrEvIeWfursuit"

    private struct AboutSeed {
        var probe: LibraryAbout.Probe
        var about: LibraryAbout.About?
        var words: [LibraryAbout.Word]
        var title: String?
    }

    private static func word(_ w: String, _ s: Double) -> LibraryAbout.Word { .init(word: w, score: s) }

    private static func aboutSeed(_ key: String, now: Date) -> AboutSeed? {
        let wrote = now.addingTimeInterval(-3 * 3_600)
        switch key {
        case aboutFursuitKey:
            return AboutSeed(
                probe: .done,
                about: .init(
                    sentence: "a person in a fox fursuit sits in an airplane seat and waves at the camera while passengers watch.",
                    tags: ["fursuit", "furry", "airplane", "first class", "costume", "passengers", "funny", "travel"],
                    edited: false, soundTags: ["laughter", "music"],
                    transcript: "wait is that a fox in first class. sir, you cannot bring the tail into the cabin. it is part of me.",
                    language: "en", frames: 3, hasAudio: true, model: "claude-haiku-5-5", writtenAt: wrote),
                words: [word("fursuit", 0.42), word("furry", 0.39), word("airplane", 0.31), word("costume", 0.24),
                        word("cosplay", 0.19), word("laughter", 0.12), word("travel", 0.08), word("mascot", 0.05)],
                title: "Furry in Furst Class?!?!")
        case "Dd55fEyN1Yy":
            return AboutSeed(
                probe: .done,
                about: .init(
                    sentence: "boats rock in a windy harbour while a dog watches the water from the pier.",
                    tags: ["harbour", "boats", "dog", "wind", "sea", "pier"], edited: false, soundTags: ["wind"],
                    transcript: nil, language: nil, frames: 3, hasAudio: true, model: "claude-haiku-5-5", writtenAt: wrote),
                words: [word("harbour", 0.37), word("boat", 0.33), word("dog", 0.22), word("sea", 0.2), word("wind", 0.11)],
                title: nil)
        case "Dd7P496wolG":
            return AboutSeed(probe: .pending, about: nil, words: [], title: nil)
        case "2105432512428445875":
            return AboutSeed(probe: .done, about: nil, words: [], title: nil)
        case "Dd5JFkMDt4N":
            return AboutSeed(
                probe: .none,
                about: .init(
                    sentence: "a latte with leaf art on a cafe table.", tags: ["coffee", "latte art", "cafe", "cup"],
                    edited: false, soundTags: [], transcript: nil, language: nil, frames: 0, hasAudio: false,
                    model: "claude-haiku-5-5", writtenAt: wrote),
                words: [word("coffee", 0.4), word("latte", 0.34), word("cafe", 0.3), word("cup", 0.18)], title: nil)
        default:
            return AboutSeed(
                probe: .done,
                about: .init(
                    sentence: "a short clip saved from the web.", tags: ["clip", "short", "funny", "loop"], edited: false,
                    soundTags: ["music"], transcript: nil, language: nil, frames: 3, hasAudio: true,
                    model: "claude-haiku-5-5", writtenAt: wrote),
                words: [word("loop", 0.21), word("funny", 0.15), word("clip", 0.1)], title: nil)
        }
    }

    /// `GET /library/about` for a preview post (or the fursuit sample); nil is `404 error.library.not_found`. `edited` is
    /// the owner's tags (nil: the written ones). The four nearest posts are the first others of the preview library.
    static func about(postKey: String, posts: [LibraryPost], edited: [String]?, now: Date) -> LibraryAbout? {
        let known = posts.first { $0.id == postKey }
        guard known != nil || postKey == aboutFursuitKey, var seed = aboutSeed(postKey, now: now) else { return nil }
        if let edited, var about = seed.about {
            about.tags = edited
            about.edited = true
            seed.about = about
        }
        let near = posts.filter { $0.id != postKey }.prefix(4)
        let scores = [0.71, 0.64, 0.52, 0.47]
        let neighbours = near.enumerated().map { LibraryAbout.Neighbour(postID: $0.element.id, score: scores[$0.offset]) }
        var status: LibrarySearchStatus
        if known != nil {
            status = searchStatus(postKey: postKey, posts: posts, now: now)
                ?? LibrarySearchStatus(postKey: postKey, state: .pending)
        } else {
            status = LibrarySearchStatus(
                postKey: postKey, state: .indexed, model: "google/embeddinggemma-2", dims: 256,
                embeddedAt: now.addingTimeInterval(-50 * 60), attempts: 1, hasImage: true,
                input: .init(
                    title: seed.title, text: "instagram_Dd9fursuit · instagram.com/reel/Dd9fursuit",
                    imageURL: nil),
                embeddedMatchesInput: true)
        }
        if let title = seed.title, var input = status.input {
            input.title = title
            if let about = seed.about {
                input.text = ([input.text ?? "", about.sentence ?? ""] + [about.tags.joined(separator: ", ")]
                    + [about.soundTags.joined(separator: ", ")] + [String((about.transcript ?? "").prefix(1_200))])
                    .filter { !$0.isEmpty }.joined(separator: " · ")
            }
            status.input = input
        }
        return LibraryAbout(
            postKey: postKey, probe: seed.probe, about: seed.about, words: seed.words, neighbours: neighbours,
            posts: Dictionary(uniqueKeysWithValues: near.map { ($0.id, $0) }), index: status)
    }

    /// The scored list of the preview chat for "which of these are furry": every preview post, best first.
    static func chatRanked(posts: [LibraryPost]) -> ChatRanked {
        let scores: [Double] = [0.62, 0.55, 0.47, 0.38, 0.29, 0.21]
        let why: [[String]] = [["fursuit", "costume"], ["dog", "pier"], ["mascot"], ["cat"], [], []]
        let hits = posts.prefix(scores.count).enumerated().map {
            ChatRanked.Hit(postID: $0.element.id, score: scores[$0.offset], why: why[$0.offset])
        }
        return ChatRanked(title: "furry videos", query: "furry", within: "lia share 11", hits: Array(hits))
    }
}

extension PreviewClient {
    /// `GET /library/about` for the preview posts after a short think (`PreviewData.about`). A server without
    /// `features.search` is `.unsupported`.
    public func libraryAbout(postKey: String) async throws -> LibraryAbout {
        try await clock.sleep(seconds: 0.25 * timeScale)
        guard searchMode != .off else { throw PipelineFailure.unsupported }
        let posts = try await library(cursor: nil, limit: 50).posts
        guard let about = PreviewData.about(
            postKey: postKey, posts: posts, edited: searchState.about.tags(postKey), now: clock.now())
        else { throw CobaltError.api(code: "error.library.not_found", httpStatus: 404) }
        return about
    }

    /// `PATCH /library/about`: the tags clean as the server cleans them (0 to 16); a post it does not know is `404`.
    public func setLibraryAboutTags(postKey: String, tags: [String]?) async throws -> LibraryAbout {
        try await clock.sleep(seconds: 0.2 * timeScale)
        guard searchMode != .off else { throw PipelineFailure.unsupported }
        if let tags, tags.count > 64 { throw CobaltError.api(code: "error.library.bad_request", httpStatus: 400) }
        searchState.about.set(postKey, tags: tags.map(LibraryAbout.cleanTags))
        return try await libraryAbout(postKey: postKey)
    }
}
