import Foundation
import Testing
@testable import CobaltKit

@Suite("Live Stream Classification, Watch Deep Links & Share Extension Routing")
struct WatchDeepLinkTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "cobalt.watch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Shared URL Classification

    @Test("Classifies unambiguous live URLs across Twitch, Kick, and YouTube")
    func classifiesUnambiguousLiveURLs() {
        let twitchCases: [(String, String)] = [
            ("https://www.twitch.tv/gigguk", "gigguk"),
            ("https://twitch.tv/Gigguk/", "gigguk"),
            ("https://m.twitch.tv/caedrel?referrer=raid", "caedrel"),
            ("https://go.twitch.tv/lirik", "lirik"),
            ("https://www.twitch.tv/popout/nyaphelia/chat", "nyaphelia"),
            ("https://www.twitch.tv/nyaphelia/home", "nyaphelia"),
        ]
        for (raw, expected) in twitchCases {
            let kind = StreamAddress.classifySharedURL(URL(string: raw)!)
            #expect(kind == .live(StreamAddress(platform: .twitch, identifier: expected)), "Failed for \(raw)")
            #expect(kind?.isLive == true)
        }

        let kickCases: [(String, String)] = [
            ("https://kick.com/xqc", "xqc"),
            ("https://www.kick.com/xQc?ref=share", "xqc"),
            ("https://m.kick.com/nick-mercs/", "nick-mercs"),
            ("https://kick.com/popout/adinross/chat", "adinross"),
        ]
        for (raw, expected) in kickCases {
            let kind = StreamAddress.classifySharedURL(URL(string: raw)!)
            #expect(kind == .live(StreamAddress(platform: .kick, identifier: expected)), "Failed for \(raw)")
            #expect(kind?.isLive == true)
        }

        let channelID = "UCSJ4gkVC6NrvII8umztf0Ow"
        let youtubeLiveCases: [(String, StreamAddress)] = [
            (
                "https://www.youtube.com/live/jfKfPfyJRdk?si=abc123",
                StreamAddress(platform: .youtube, identifier: "jfKfPfyJRdk", youtubeTarget: .videoID("jfKfPfyJRdk"))
            ),
            (
                "https://m.youtube.com/live/jfKfPfyJRdk",
                StreamAddress(platform: .youtube, identifier: "jfKfPfyJRdk", youtubeTarget: .videoID("jfKfPfyJRdk"))
            ),
            (
                "https://www.youtube.com/@LofiGirl/live",
                StreamAddress(platform: .youtube, identifier: "@lofigirl", youtubeTarget: .handle("lofigirl"))
            ),
            (
                "https://m.youtube.com/@LofiGirl/live?feature=share",
                StreamAddress(platform: .youtube, identifier: "@lofigirl", youtubeTarget: .handle("lofigirl"))
            ),
            (
                "https://www.youtube.com/channel/\(channelID)/live",
                StreamAddress(platform: .youtube, identifier: "channel/\(channelID)", youtubeTarget: .channelID(channelID))
            ),
        ]
        for (raw, expected) in youtubeLiveCases {
            let kind = StreamAddress.classifySharedURL(URL(string: raw)!)
            #expect(kind == .live(expected), "Failed for \(raw)")
            #expect(kind?.isLive == true)
        }
    }

    @Test("Classifies ambiguous YouTube video and channel URLs separately from unambiguous live URLs")
    func classifiesAmbiguousYouTubeURLs() {
        let channelID = "UCSJ4gkVC6NrvII8umztf0Ow"
        let ambiguousCases: [(String, StreamAddress)] = [
            (
                "https://www.youtube.com/watch?v=jfKfPfyJRdk",
                StreamAddress(platform: .youtube, identifier: "jfKfPfyJRdk", youtubeTarget: .videoID("jfKfPfyJRdk"))
            ),
            (
                "https://m.youtube.com/watch?v=jfKfPfyJRdk&feature=share",
                StreamAddress(platform: .youtube, identifier: "jfKfPfyJRdk", youtubeTarget: .videoID("jfKfPfyJRdk"))
            ),
            (
                "https://youtu.be/jfKfPfyJRdk?si=shareToken",
                StreamAddress(platform: .youtube, identifier: "jfKfPfyJRdk", youtubeTarget: .videoID("jfKfPfyJRdk"))
            ),
            (
                "https://www.youtube.com/@LofiGirl",
                StreamAddress(platform: .youtube, identifier: "@lofigirl", youtubeTarget: .handle("lofigirl"))
            ),
            (
                "https://www.youtube.com/channel/\(channelID)",
                StreamAddress(platform: .youtube, identifier: "channel/\(channelID)", youtubeTarget: .channelID(channelID))
            ),
        ]
        for (raw, expected) in ambiguousCases {
            let kind = StreamAddress.classifySharedURL(URL(string: raw)!)
            #expect(kind == .ambiguousYouTube(expected), "Failed for \(raw)")
            #expect(kind?.isLive == false)
        }
    }

    @Test("Excludes clips, VODs, YouTube Shorts, playlists, and non-stream links so they save normally")
    func excludesClipsVODsShortsAndNonStreams() {
        let excluded = [
            // Twitch clips, VODs, collections, directory
            "https://clips.twitch.tv/FunnyClipSlug123",
            "https://www.twitch.tv/gigguk/clip/FunnyClipSlug123",
            "https://www.twitch.tv/gigguk/clips",
            "https://www.twitch.tv/videos/2198765432",
            "https://www.twitch.tv/gigguk/videos",
            "https://www.twitch.tv/gigguk/video/2198765432",
            "https://www.twitch.tv/gigguk/v/2198765432",
            "https://www.twitch.tv/collections/abc123def",
            "https://www.twitch.tv/directory/following",
            // Kick clips & VODs
            "https://kick.com/xqc?clip=clip_01JABCDEF",
            "https://www.kick.com/xqc/clips/clip_01JABCDEF",
            "https://kick.com/video/12345678-1234-1234-1234-1234567890ab",
            "https://kick.com/xqc/videos",
            "https://kick.com/videos/999",
            "https://clips.kick.com/clip_01JABCDEF",
            "https://kick.com/browse",
            // YouTube Shorts, playlists, clips, non-live channel tabs
            "https://www.youtube.com/shorts/jfKfPfyJRdk",
            "https://m.youtube.com/shorts/jfKfPfyJRdk?feature=share",
            "https://www.youtube.com/playlist?list=PL1234567890",
            "https://www.youtube.com/clip/UgkxSomeClipId",
            "https://www.youtube.com/@LofiGirl/videos",
            "https://www.youtube.com/@LofiGirl/shorts",
            "https://music.youtube.com/watch?v=jfKfPfyJRdk",
            // Other sites & non-HTTP schemes
            "https://x.com/someone/status/1234567890",
            "https://www.instagram.com/p/Ddy0-gpGg5U/",
            "https://www.tiktok.com/@user/video/1234567890",
            "cobalt-apple://watch?channel=gigguk",
        ]
        for raw in excluded {
            let url = URL(string: raw)!
            #expect(StreamAddress.classifySharedURL(url) == nil, "Should be excluded: \(raw)")
            if raw.hasPrefix("http") {
                #expect(StreamAddress.parse(raw) == nil, "parse(_:) should reject non-stream URL: \(raw)")
            }
        }
    }

    @Test("Extracts and classifies stream URLs embedded in mobile app promotional share copy")
    func extractsAndClassifiesPromoShareText() {
        let twitchPromo = "Watch Gigguk with me on Twitch! https://www.twitch.tv/gigguk"
        let twitchResult = StreamAddress.classifySharedText(twitchPromo)
        #expect(twitchResult?.url.absoluteString == "https://www.twitch.tv/gigguk")
        #expect(twitchResult?.kind == .live(StreamAddress(platform: .twitch, identifier: "gigguk")))

        let kickPromo = "Check out xQc live on Kick: https://kick.com/xqc."
        let kickResult = StreamAddress.classifySharedText(kickPromo)
        #expect(kickResult?.url.absoluteString == "https://kick.com/xqc")
        #expect(kickResult?.kind == .live(StreamAddress(platform: .kick, identifier: "xqc")))

        let ytPromo = "Check out this stream! https://youtu.be/jfKfPfyJRdk?si=abc123"
        let ytResult = StreamAddress.classifySharedText(ytPromo)
        #expect(ytResult?.url.absoluteString == "https://youtu.be/jfKfPfyJRdk?si=abc123")
        #expect(ytResult?.kind == .ambiguousYouTube(
            StreamAddress(platform: .youtube, identifier: "jfKfPfyJRdk", youtubeTarget: .videoID("jfKfPfyJRdk"))
        ))

        let barePromo = "Live right now at twitch.tv/caedrel!"
        let bareResult = StreamAddress.classifySharedText(barePromo)
        #expect(bareResult?.url.absoluteString == "https://twitch.tv/caedrel")
        #expect(bareResult?.kind == .live(StreamAddress(platform: .twitch, identifier: "caedrel")))

        // Promo copy containing a clip or Short must NOT misclassify as a live stream,
        // while extractSharedURL still preserves the link for normal media saving.
        let clipPromo = "Look at this clip! https://clips.twitch.tv/FunnyClipSlug"
        #expect(StreamAddress.classifySharedText(clipPromo) == nil)
        #expect(StreamAddress.extractSharedURL(from: clipPromo)?.absoluteString == "https://clips.twitch.tv/FunnyClipSlug")

        let shortPromo = "Watch this Short: https://www.youtube.com/shorts/jfKfPfyJRdk"
        #expect(StreamAddress.classifySharedText(shortPromo) == nil)
        #expect(StreamAddress.extractSharedURL(from: shortPromo)?.absoluteString == "https://www.youtube.com/shorts/jfKfPfyJRdk")
    }

    // MARK: - WatchDeepLink Parsing & Building

    @Test("Builds and parses cobalt-apple://watch deep links across channel, url, and path forms")
    func parsesAndBuildsWatchDeepLinks() {
        let addresses: [StreamAddress] = [
            StreamAddress(platform: .twitch, identifier: "gigguk"),
            StreamAddress(platform: .kick, identifier: "xqc"),
            StreamAddress(platform: .youtube, identifier: "jfKfPfyJRdk", youtubeTarget: .videoID("jfKfPfyJRdk")),
            StreamAddress(platform: .youtube, identifier: "@lofigirl", youtubeTarget: .handle("lofigirl")),
            StreamAddress(platform: .youtube, identifier: "channel/UCSJ4gkVC6NrvII8umztf0Ow", youtubeTarget: .channelID("UCSJ4gkVC6NrvII8umztf0Ow")),
        ]

        // Round-trip ?channel=...&mode=open|add
        for address in addresses {
            for mode in [WatchDeepLinkMode.open, .add] {
                let link = WatchDeepLink(address: address, mode: mode)
                let parsed = WatchDeepLink(url: link.url)
                #expect(parsed == link, "Round-trip failed for \(address.canonicalKey) mode=\(mode.rawValue)")
            }
        }

        // ?url=<percent-encoded https url>
        let encodedTwitch = WatchDeepLink.url(forWebURL: URL(string: "https://www.twitch.tv/Gigguk")!, mode: .open)
        #expect(WatchDeepLink(url: encodedTwitch) == WatchDeepLink(
            address: StreamAddress(platform: .twitch, identifier: "gigguk"),
            mode: .open
        ))

        let encodedYT = WatchDeepLink.url(forWebURL: URL(string: "https://youtu.be/jfKfPfyJRdk?si=abc")!, mode: .add)
        #expect(WatchDeepLink(url: encodedYT) == WatchDeepLink(
            address: StreamAddress(platform: .youtube, identifier: "jfKfPfyJRdk", youtubeTarget: .videoID("jfKfPfyJRdk")),
            mode: .add
        ))

        // Path form: cobalt-apple://watch/<canonicalKey>
        #expect(WatchDeepLink(url: URL(string: "cobalt-apple://watch/gigguk")!) == WatchDeepLink(
            address: StreamAddress(platform: .twitch, identifier: "gigguk"),
            mode: .open
        ))
        #expect(WatchDeepLink(url: URL(string: "cobalt-apple://watch/kick:xqc?mode=add")!) == WatchDeepLink(
            address: StreamAddress(platform: .kick, identifier: "xqc"),
            mode: .add
        ))
        #expect(WatchDeepLink(url: URL(string: "cobalt-apple://watch/yt:jfKfPfyJRdk")!) == WatchDeepLink(
            address: StreamAddress(platform: .youtube, identifier: "jfKfPfyJRdk", youtubeTarget: .videoID("jfKfPfyJRdk")),
            mode: .open
        ))
        #expect(WatchDeepLink(url: URL(string: "cobalt-apple://watch/yt:channel/UCSJ4gkVC6NrvII8umztf0Ow?mode=add")!) == WatchDeepLink(
            address: StreamAddress(platform: .youtube, identifier: "channel/UCSJ4gkVC6NrvII8umztf0Ow", youtubeTarget: .channelID("UCSJ4gkVC6NrvII8umztf0Ow")),
            mode: .add
        ))

        // Rejects invalid / non-stream watch URLs
        #expect(WatchDeepLink(url: URL(string: "cobalt-apple://watch")!) == nil)
        #expect(WatchDeepLink(url: URL(string: "cobalt-apple://open?channel=gigguk")!) == nil)
        #expect(WatchDeepLink(url: URL(string: "https://watch?channel=gigguk")!) == nil)
        #expect(WatchDeepLink(url: WatchDeepLink.url(forWebURL: URL(string: "https://clips.twitch.tv/FunnyClip")!)) == nil)
        #expect(WatchDeepLink(url: WatchDeepLink.url(forWebURL: URL(string: "https://www.youtube.com/shorts/jfKfPfyJRdk")!)) == nil)
        #expect(WatchDeepLink(url: WatchDeepLink.url(forWebURL: URL(string: "https://example.com/foo")!)) == nil)
    }

    // MARK: - ActiveStreamPresence & SharedStreamMatch

    @Test("Tracks ActiveStreamPresence in shared defaults with deduplication, 4-stream cap, and TTL expiry")
    func tracksActiveStreamPresence() {
        let defaults = makeIsolatedDefaults()
        let t0 = Date(timeIntervalSince1970: 1_764_000_000)

        let gigguk = StreamAddress(platform: .twitch, identifier: "gigguk")
        let kickXqc = StreamAddress(platform: .kick, identifier: "xqc")
        let ytLofi = StreamAddress(platform: .youtube, identifier: "jfKfPfyJRdk", youtubeTarget: .videoID("jfKfPfyJRdk"))
        let caedrel = StreamAddress(platform: .twitch, identifier: "caedrel")
        let lirik = StreamAddress(platform: .twitch, identifier: "lirik")

        // Empty -> cannot add to stream
        #expect(ActiveStreamPresence.current(defaults: defaults, now: t0).isEmpty)
        #expect(ActiveStreamPresence.canAddToStream(gigguk, defaults: defaults, now: t0) == false)

        // 1 active stream -> can add another, not duplicate
        ActiveStreamPresence.update(channels: ["Gigguk"], defaults: defaults, now: t0)
        #expect(ActiveStreamPresence.current(defaults: defaults, now: t0) == ["gigguk"])
        #expect(ActiveStreamPresence.canAddToStream(kickXqc, defaults: defaults, now: t0) == true)
        #expect(ActiveStreamPresence.canAddToStream(gigguk, defaults: defaults, now: t0) == false)

        // 3 active streams -> can add a 4th
        ActiveStreamPresence.update(channels: ["gigguk", "kick:xqc", ytLofi.canonicalKey], defaults: defaults, now: t0)
        #expect(ActiveStreamPresence.canAddToStream(caedrel, defaults: defaults, now: t0) == true)

        // 4 active streams (cap) -> cannot add a 5th
        ActiveStreamPresence.update(channels: ["gigguk", "kick:xqc", ytLofi.canonicalKey, "caedrel"], defaults: defaults, now: t0)
        #expect(ActiveStreamPresence.canAddToStream(lirik, defaults: defaults, now: t0) == false)

        // TTL expiration clears stale presence
        let expired = t0.addingTimeInterval(ActiveStreamPresence.defaultMaxAge + 1)
        #expect(ActiveStreamPresence.current(defaults: defaults, now: expired).isEmpty)
        #expect(ActiveStreamPresence.canAddToStream(lirik, defaults: defaults, now: expired) == false)

        // Clear removes presence immediately
        ActiveStreamPresence.update(channels: ["gigguk"], defaults: defaults, now: t0)
        ActiveStreamPresence.clear(defaults: defaults)
        #expect(ActiveStreamPresence.current(defaults: defaults, now: t0).isEmpty)
    }

    @Test("SharedStreamMatch decides auto-open vs chooser card based on stream kind and active presence")
    @MainActor
    func sharedStreamMatchDecisions() async {
        let defaults = makeIsolatedDefaults()
        let now = Date(timeIntervalSince1970: 1_764_000_000)

        let twitchURL = URL(string: "https://www.twitch.tv/gigguk")!
        let ytWatchURL = URL(string: "https://www.youtube.com/watch?v=jfKfPfyJRdk")!

        // Live URL with no active streams -> auto-open
        let liveAlone = InstantShare.matchSharedStream(url: twitchURL, defaults: defaults, now: now)
        #expect(liveAlone?.shouldAutoOpen == true)
        #expect(liveAlone?.canAddToStream == false)
        #expect(liveAlone?.watchURL(mode: .open).absoluteString == "cobalt-apple://watch?channel=gigguk&mode=open")

        // Live URL with another stream playing -> chooser with Add to Stream
        ActiveStreamPresence.update(channels: ["caedrel"], defaults: defaults, now: now)
        let liveWithActive = InstantShare.matchSharedStream(url: twitchURL, defaults: defaults, now: now)
        #expect(liveWithActive?.shouldAutoOpen == false)
        #expect(liveWithActive?.canAddToStream == true)
        #expect(liveWithActive?.watchURL(mode: .add).absoluteString == "cobalt-apple://watch?channel=gigguk&mode=add")

        // Live URL for channel already playing -> auto-open (no redundant Add to Stream)
        ActiveStreamPresence.update(channels: ["gigguk"], defaults: defaults, now: now)
        let liveSame = InstantShare.matchSharedStream(url: twitchURL, defaults: defaults, now: now)
        #expect(liveSame?.shouldAutoOpen == true)
        #expect(liveSame?.canAddToStream == false)

        // Ambiguous YouTube URL never auto-opens, shows Add to Stream when another stream is active
        let ytWithActive = InstantShare.matchSharedStream(url: ytWatchURL, defaults: defaults, now: now)
        #expect(ytWithActive?.shouldAutoOpen == false)
        #expect(ytWithActive?.canAddToStream == true)

        ActiveStreamPresence.clear(defaults: defaults)
        let ytAlone = InstantShare.matchSharedStream(url: ytWatchURL, defaults: defaults, now: now)
        #expect(ytAlone?.shouldAutoOpen == false)
        #expect(ytAlone?.canAddToStream == false)

        // End-to-end NSExtensionItem detection from promotional share copy
        let item = NSExtensionItem()
        item.attributedContentText = NSAttributedString(string: "Watch Gigguk with me on Twitch! https://www.twitch.tv/gigguk")
        let detected = await InstantShare.detectSharedStream(inputItems: [item], defaults: defaults, now: now)
        #expect(detected?.address == StreamAddress(platform: .twitch, identifier: "gigguk"))
        #expect(detected?.shouldAutoOpen == true)
    }

    // MARK: - AppModel Watch Routing & TwitchStore Presence

    @Test("AppModel routes cobalt-apple://watch in open and add modes across single, dual, and multi-stream layouts")
    @MainActor
    func appModelWatchLinkRouting() {
        let model = AppModel.preview(.happy)
        model.selectedTab = .save

        // 1. Open first stream via deep link
        let openFirst = URL(string: "cobalt-apple://watch?channel=gigguk&mode=open")!
        model.open(openFirst)
        #expect(model.selectedTab == .twitch)
        #expect(model.watchRequest?.link.address == StreamAddress(platform: .twitch, identifier: "gigguk"))
        let item1 = model.takeWatchRequest(currentPaneItem: nil)
        #expect(item1 == .stream("gigguk"))
        #expect(model.watchRequest == nil)

        // 2. Add Kick stream -> promotes 1 -> 2 (.dualStream)
        let addKick = URL(string: "cobalt-apple://watch?channel=kick:xqc&mode=add")!
        #expect(model.openWatchLink(addKick) == true)
        let item2 = model.takeWatchRequest(currentPaneItem: item1)
        #expect(item2 == .dualStream(primary: "gigguk", secondary: "kick:xqc"))

        // 3. Add YouTube stream via ?url= -> promotes 2 -> 3 (.multiStream) preserving video ID case
        let addYT = WatchDeepLink.url(forWebURL: URL(string: "https://www.youtube.com/live/jfKfPfyJRdk")!, mode: .add)
        #expect(model.openWatchLink(addYT) == true)
        let item3 = model.takeWatchRequest(currentPaneItem: item2)
        #expect(item3 == .multiStream(channels: ["gigguk", "kick:xqc", "yt:jfKfPfyJRdk"]))

        // 4. Adding a duplicate keeps the existing layout intact
        let addDuplicate = URL(string: "cobalt-apple://watch?channel=kick:xQc&mode=add")!
        #expect(model.openWatchLink(addDuplicate) == true)
        #expect(model.takeWatchRequest(currentPaneItem: item3) == item3)

        // 5. Add 4th stream -> reaches cap
        let addFourth = URL(string: "cobalt-apple://watch?channel=caedrel&mode=add")!
        #expect(model.openWatchLink(addFourth) == true)
        let item4 = model.takeWatchRequest(currentPaneItem: item3)
        #expect(item4 == .multiStream(channels: ["gigguk", "kick:xqc", "yt:jfKfPfyJRdk", "caedrel"]))

        // 6. Add 5th stream at cap preserves the 4 active streams
        let addFifth = URL(string: "cobalt-apple://watch?channel=lirik&mode=add")!
        #expect(model.openWatchLink(addFifth) == true)
        #expect(model.takeWatchRequest(currentPaneItem: item4) == item4)

        // 7. mode=open replaces active streams with a single stream
        let replace = URL(string: "cobalt-apple://watch?channel=lirik&mode=open")!
        #expect(model.openWatchLink(replace) == true)
        #expect(model.takeWatchRequest(currentPaneItem: item4) == .stream("lirik"))

        // 8. mode=add when nothing is playing opens a single stream
        #expect(model.openWatchLink(addKick) == true)
        #expect(model.takeWatchRequest(currentPaneItem: nil) == .stream("kick:xqc"))
    }

    @Test("TwitchStore updates and clears ActiveStreamPresence on open, openMulti, and close")
    @MainActor
    func twitchStoreUpdatesPresence() {
        let model = AppModel.preview(.happy)
        let defaults = model.settings.defaults
        ActiveStreamPresence.clear(defaults: defaults)

        model.twitch.open("gigguk")
        #expect(ActiveStreamPresence.current(defaults: defaults) == ["gigguk"])

        model.twitch.openMulti(channels: ["gigguk", "kick:xqc"])
        #expect(ActiveStreamPresence.current(defaults: defaults) == ["gigguk", "kick:xqc"])

        model.twitch.close()
        #expect(ActiveStreamPresence.current(defaults: defaults).isEmpty)
    }
}
