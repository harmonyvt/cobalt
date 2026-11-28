import Foundation
import Testing
@testable import CobaltKit

@Suite("Multi-Platform Live Streams (Twitch / Kick / YouTube)")
struct StreamPlatformTests {

    // MARK: - StreamAddress Parsing & Normalization

    @Test("Parses Twitch logins, mentions, and URLs")
    func parsesTwitchAddresses() {
        let cases: [(String, String)] = [
            ("nyaphelia", "nyaphelia"),
            ("  @Nyaphelia  ", "nyaphelia"),
            ("twitch:xQc", "xqc"),
            ("https://www.twitch.tv/caedrel", "caedrel"),
            ("https://m.twitch.tv/Caedrel?referrer=raid", "caedrel"),
            ("twitch.tv/lirik/", "lirik"),
        ]
        for (input, expectedLogin) in cases {
            let parsed = StreamAddress.parse(input)
            #expect(parsed == StreamAddress(platform: .twitch, identifier: expectedLogin), "Failed for input: \(input)")
            #expect(parsed?.platform == .twitch)
            #expect(parsed?.canonicalKey == expectedLogin)
            #expect(parsed?.displayLabel == expectedLogin)
            #expect(parsed?.webURL?.absoluteString == "https://www.twitch.tv/\(expectedLogin)")
            #expect(TwitchStore.login(from: input) == expectedLogin)
        }
    }

    @Test("Parses Kick prefixes and URLs")
    func parsesKickAddresses() {
        let cases: [(String, String)] = [
            ("kick:xQc", "xqc"),
            ("kick:trainwreckstv", "trainwreckstv"),
            ("https://kick.com/xQc", "xqc"),
            ("https://www.kick.com/nick-mercs?ref=home", "nick-mercs"),
            ("kick.com/adinross/", "adinross"),
        ]
        for (input, expectedSlug) in cases {
            let parsed = StreamAddress.parse(input)
            #expect(parsed == StreamAddress(platform: .kick, identifier: expectedSlug), "Failed for input: \(input)")
            #expect(parsed?.platform == .kick)
            #expect(parsed?.canonicalKey == "kick:\(expectedSlug)")
            #expect(parsed?.displayLabel == expectedSlug)
            #expect(parsed?.webURL?.absoluteString == "https://kick.com/\(expectedSlug)")
            #expect(TwitchStore.login(from: input) == "kick:\(expectedSlug)")
        }
    }

    @Test("Parses YouTube live URLs, handles, channel IDs, and preserves case-sensitive IDs")
    func parsesYouTubeAddresses() {
        // Video IDs (11 chars, case-sensitive!)
        let videoInputs = [
            "https://www.youtube.com/watch?v=jfKfPfyJRdk",
            "https://youtu.be/jfKfPfyJRdk?si=abc123",
            "https://www.youtube.com/live/jfKfPfyJRdk?feature=share",
            "https://m.youtube.com/embed/jfKfPfyJRdk",
            "yt:jfKfPfyJRdk",
            "youtube:jfKfPfyJRdk",
        ]
        for input in videoInputs {
            let parsed = StreamAddress.parse(input)
            #expect(parsed?.platform == .youtube, "Failed for input: \(input)")
            #expect(parsed?.youtubeTarget == .videoID("jfKfPfyJRdk"))
            #expect(parsed?.canonicalKey == "yt:jfKfPfyJRdk")
            #expect(parsed?.displayLabel == "jfKfPfyJRdk")
            #expect(parsed?.webURL?.absoluteString == "https://www.youtube.com/watch?v=jfKfPfyJRdk")
            #expect(TwitchStore.login(from: input) == "yt:jfKfPfyJRdk")
        }

        // Handles (lowercased)
        let handleInputs = [
            "https://www.youtube.com/@LofiGirl",
            "https://www.youtube.com/@LofiGirl/live",
            "youtube.com/@LofiGirl/live",
            "yt:@LofiGirl",
            "youtube:@LofiGirl",
        ]
        for input in handleInputs {
            let parsed = StreamAddress.parse(input)
            #expect(parsed?.platform == .youtube, "Failed for input: \(input)")
            #expect(parsed?.youtubeTarget == .handle("lofigirl"))
            #expect(parsed?.canonicalKey == "yt:@lofigirl")
            #expect(parsed?.displayLabel == "@lofigirl")
            #expect(parsed?.webURL?.absoluteString == "https://www.youtube.com/@lofigirl/live")
        }

        // Channel IDs (UC..., case-sensitive!)
        let channelID = "UCSJ4gkVC6NrvII8umztf0Ow"
        let channelInputs = [
            "https://www.youtube.com/channel/\(channelID)",
            "https://www.youtube.com/channel/\(channelID)/live",
            "yt:channel/\(channelID)",
            "yt:\(channelID)",
        ]
        for input in channelInputs {
            let parsed = StreamAddress.parse(input)
            #expect(parsed?.platform == .youtube, "Failed for input: \(input)")
            #expect(parsed?.youtubeTarget == .channelID(channelID))
            #expect(parsed?.canonicalKey == "yt:channel/\(channelID)")
            #expect(parsed?.displayLabel == channelID)
            #expect(parsed?.webURL?.absoluteString == "https://www.youtube.com/channel/\(channelID)/live")
        }
    }

    @Test("Rejects invalid stream addresses and non-streaming URLs")
    func rejectsInvalidAddresses() {
        #expect(StreamAddress.parse("") == nil)
        #expect(StreamAddress.parse("   ") == nil)
        #expect(StreamAddress.parse("kick:") == nil)
        #expect(StreamAddress.parse("yt:") == nil)
        #expect(StreamAddress.parse("https://example.com/someuser") == nil)
        #expect(StreamAddress.parse("https://www.youtube.com/playlist?list=PL123") == nil)
        #expect(StreamAddress.parse("bad name with spaces") == nil)
    }

    @Test("Platform capabilities restrict chat sending, embed fallback, and server clips to Twitch")
    func platformCapabilities() {
        #expect(StreamPlatform.twitch.supportsSendingChat == true)
        #expect(StreamPlatform.twitch.supportsEmbedFallback == true)
        #expect(StreamPlatform.twitch.supportsServerClip == true)

        #expect(StreamPlatform.kick.supportsSendingChat == false)
        #expect(StreamPlatform.kick.supportsEmbedFallback == false)
        #expect(StreamPlatform.kick.supportsServerClip == false)

        #expect(StreamPlatform.youtube.supportsSendingChat == false)
        #expect(StreamPlatform.youtube.supportsEmbedFallback == false)
        #expect(StreamPlatform.youtube.supportsServerClip == false)
    }

    // MARK: - PaneItem Case Preservation

    @Test("PaneItem multi-stream operations preserve case-sensitive YouTube IDs and Kick keys")
    func paneItemPreservesCanonicalCase() {
        let ytKey = "yt:jfKfPfyJRdk"
        let kickKey = "kick:xqc"
        let twitchKey = "nyaphelia"

        let single = PaneItem.stream(ytKey)
        let dual = single.promotedToDual(secondary: kickKey)
        #expect(dual == .dualStream(primary: ytKey, secondary: kickKey))

        let triple = dual?.addingStream(twitchKey)
        #expect(triple == .multiStream(channels: [ytKey, kickKey, twitchKey]))

        // Duplicate rejection respects canonical equality
        #expect(triple?.addingStream("https://youtu.be/jfKfPfyJRdk") == nil)
        #expect(triple?.addingStream("https://kick.com/xQc") == nil)

        // Removal keeps exact case of remaining YouTube ID
        let afterRemove = triple?.removingStream(kickKey)
        #expect(afterRemove == .dualStream(primary: ytKey, secondary: twitchKey))

        let demoted = afterRemove?.demotedToSingle(keeping: ytKey)
        #expect(demoted == .stream(ytKey))
    }

    // MARK: - Kick Stream Resolver Parsing

    @Test("Parses Kick v2 channel JSON for live and offline channels")
    func parsesKickChannelJSON() throws {
        let liveJSON = """
        {
          "id": 668,
          "user_id": 676,
          "slug": "xqc",
          "playback_url": "https://fa723fc1b171.us-west-2.playback.live-video.net/api/video/v1/us-west-2.master.m3u8",
          "user": {
            "username": "xQc",
            "profile_pic": "https://files.kick.com/images/user/676/profile_image/avatar.webp"
          },
          "chatroom": {
            "id": 668123
          },
          "livestream": {
            "id": 9991,
            "is_live": true,
            "session_title": "LATE NIGHT VARIETY",
            "viewer_count": 42150,
            "created_at": "2026-11-28T09:00:00Z",
            "thumbnail": { "url": "https://images.kick.com/video_thumbnails/9991/thumb.webp" },
            "categories": [{ "name": "Just Chatting" }]
          }
        }
        """

        let payload = try KickStreamResolver.parseChannelJSON(Data(liveJSON.utf8), canonicalKey: "kick:xqc")
        #expect(payload.metadata.kickChannelID == 668)
        #expect(payload.metadata.kickUserID == 676)
        #expect(payload.metadata.kickChatroomID == 668123)
        #expect(payload.metadata.isLive == true)
        #expect(payload.playbackURL?.absoluteString.contains("master.m3u8") == true)
        #expect(payload.metadata.displayName == "xQc")
        #expect(payload.metadata.title == "LATE NIGHT VARIETY")
        #expect(payload.metadata.category == "Just Chatting")
        #expect(payload.metadata.viewerCount == 42150)
        #expect(payload.metadata.avatarURL?.absoluteString.hasSuffix("avatar.webp") == true)
        #expect(payload.metadata.thumbnailURL?.absoluteString.hasSuffix("thumb.webp") == true)

        let offlineJSON = """
        {
          "id": 668,
          "slug": "xqc",
          "user": { "username": "xQc" },
          "chatroom": { "id": 668123 },
          "livestream": null
        }
        """
        let offline = try KickStreamResolver.parseChannelJSON(Data(offlineJSON.utf8), canonicalKey: "kick:xqc")
        #expect(offline.metadata.isLive == false)
        #expect(offline.playbackURL == nil)
        #expect(offline.metadata.kickChatroomID == 668123)
    }

    // MARK: - YouTube Live Resolver Parsing

    @Test("Extracts YouTube watch page JSON, video ID, live chat continuation, and player HLS URL")
    func parsesYouTubeWatchPageAndPlayerResponse() throws {
        let html = """
        <!doctype html><html><head><title>lofi hip hop radio</title></head><body>
        <script>
        var ytInitialPlayerResponse = {"videoDetails":{"videoId":"jfKfPfyJRdk","title":"lofi hip hop radio - beats to relax/study to","author":"Lofi Girl","isLive":true,"isLiveContent":true,"thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/jfKfPfyJRdk/hqdefault_live.jpg"}]}},"playabilityStatus":{"status":"OK"},"streamingData":{"hlsManifestUrl":"https://manifest.googlevideo.com/api/manifest/hls_variant/file/index.m3u8"}};
        var ytInitialData = {"contents":{"twoColumnWatchNextResults":{"conversationBar":{"liveChatRenderer":{"continuations":[{"reloadContinuationData":{"continuation":"0ofMyAMaE2t0c3RDb250aW51YXRpb24%3D"}}]}}}}};
        </script>
        </body></html>
        """

        let page = YouTubeLiveResolver.parseWatchPageHTML(html, canonicalKey: "yt:@lofigirl")
        #expect(page.videoID == "jfKfPfyJRdk")
        #expect(page.isLive == true)
        #expect(page.chatContinuation == "0ofMyAMaE2t0c3RDb250aW51YXRpb24%3D")
        #expect(page.displayName == "Lofi Girl")
        #expect(page.title == "lofi hip hop radio - beats to relax/study to")
        #expect(page.thumbnailURL?.absoluteString == "https://i.ytimg.com/vi/jfKfPfyJRdk/hqdefault_live.jpg")

        let playerJSON = """
        {
          "playabilityStatus": { "status": "OK" },
          "videoDetails": {
            "videoId": "jfKfPfyJRdk",
            "title": "lofi hip hop radio {chill \\"beats\\"}",
            "author": "Lofi Girl",
            "isLive": true,
            "isLiveContent": true
          },
          "streamingData": {
            "hlsManifestUrl": "https://manifest.googlevideo.com/api/manifest/hls_variant/android/index.m3u8"
          }
        }
        """
        let player = try YouTubeLiveResolver.parsePlayerResponseJSON(Data(playerJSON.utf8))
        #expect(player.isLive == true)
        #expect(player.status == "OK")
        #expect(player.author == "Lofi Girl")
        #expect(player.hlsManifestURL?.absoluteString.contains("/android/index.m3u8") == true)
    }

    @Test("extractJSONObject handles nested braces and escaped quotes inside strings")
    func extractsNestedJSONSafely() {
        let sample = #"prefix var ytInitialPlayerResponse = {"title":"hello \"}\" world","nested":{"a":1,"b":"{still string}"}}; trailing"#
        let extracted = YouTubeLiveResolver.extractJSONObject(in: sample, after: "var ytInitialPlayerResponse =")
        #expect(extracted == #"{"title":"hello \"}\" world","nested":{"a":1,"b":"{still string}"}}"#)
    }

    // MARK: - Kick Chat Parser

    @Test("Parses Kick Pusher chat frames, inline [emote:id:name] tokens, 7TV emotes, and deletions")
    func parsesKickChatFrames() {
        let sevenTvJSON = """
        {
          "emote_set": {
            "emotes": [
              {
                "id": "60ae958e229664e8667aea38",
                "name": "KEKW",
                "data": {
                  "animated": false,
                  "host": {
                    "url": "//cdn.7tv.app/emote/60ae958e229664e8667aea38",
                    "files": [
                      { "name": "2x.webp", "format": "WEBP" },
                      { "name": "1x.png", "format": "PNG" }
                    ]
                  }
                }
              }
            ]
          }
        }
        """
        let sevenTv = KickChatParser.parseSevenTvEmotes(Data(sevenTvJSON.utf8), source: .sevenTv)
        #expect(sevenTv["KEKW"]?.url.absoluteString == "https://cdn.7tv.app/emote/60ae958e229664e8667aea38/2x.webp")

        let innerPayload = """
        {"id":"msg-42","chatroom_id":668123,"content":"hello [emote:37226:KEKWait] KEKW !","type":"message","created_at":"2026-11-28T10:00:00Z","sender":{"id":900,"username":"Harmony","slug":"harmony","identity":{"color":"#53FC18","badges":[{"type":"moderator","text":"Moderator"}]}}}
        """
        let escapedInner = innerPayload
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
        let frame = """
        {"event":"App\\\\Events\\\\ChatMessageEvent","data":"\(escapedInner)","channel":"chatrooms.668123.v2"}
        """

        let parsed = KickChatParser.parseFrame(frame, channelKey: "kick:xqc", namedEmotes: sevenTv)
        guard case .message(let line) = parsed else {
            Issue.record("Expected .message event, got \(String(describing: parsed))")
            return
        }
        #expect(line.id == "msg-42")
        #expect(line.channel == "kick:xqc")
        #expect(line.displayName == "Harmony")
        #expect(line.color == 0x53FC18)
        #expect(line.fragments.contains {
            if case .emote(let e) = $0 {
                return e.name == "KEKWait" && e.source == .kick && e.url.absoluteString == "https://files.kick.com/emotes/37226/fullsize"
            }
            return false
        })
        #expect(line.fragments.contains {
            if case .emote(let e) = $0 {
                return e.name == "KEKW" && e.source == .sevenTv
            }
            return false
        })

        // Delete event
        let deleteFrame = #"{"event":"App\\Events\\MessageDeletedEvent","data":"{\"id\":\"del-1\",\"message\":{\"id\":\"msg-42\"}}"}"#
        let deleted = KickChatParser.parseFrame(deleteFrame, channelKey: "kick:xqc")
        #expect(deleted == .deleted(messageID: "msg-42"))
    }

    // MARK: - YouTube Live Chat Parser

    @Test("Parses YouTube live_chat poll response including custom emojis and SuperChat")
    func parsesYouTubeLiveChatPoll() {
        let json = """
        {
          "continuationContents": {
            "liveChatContinuation": {
              "continuations": [
                {
                  "invalidationContinuationData": {
                    "continuation": "next-cont-token-99",
                    "timeoutMs": 3500
                  }
                }
              ],
              "actions": [
                {
                  "addChatItemAction": {
                    "item": {
                      "liveChatTextMessageRenderer": {
                        "id": "yt-msg-1",
                        "timestampUsec": "1764324000000000",
                        "authorName": { "simpleText": "StudyBuddy" },
                        "authorExternalChannelId": "UC1234567890123456789012",
                        "message": {
                          "runs": [
                            { "text": "great beats " },
                            {
                              "emoji": {
                                "emojiId": "UC_custom_1",
                                "shortcuts": [":lofiCat:"],
                                "isCustomEmoji": true,
                                "image": {
                                  "thumbnails": [{ "url": "https://yt3.ggpht.com/custom-cat=w48-h48-c-k-nd" }]
                                }
                              }
                            }
                          ]
                        }
                      }
                    }
                  }
                },
                {
                  "addChatItemAction": {
                    "item": {
                      "liveChatPaidMessageRenderer": {
                        "id": "yt-super-2",
                        "timestampUsec": "1764324001000000",
                        "authorName": { "simpleText": "GenerousFan" },
                        "purchaseAmountText": { "simpleText": "$5.00" },
                        "message": {
                          "runs": [{ "text": "keep it going!" }]
                        }
                      }
                    }
                  }
                }
              ]
            }
          }
        }
        """

        let result = YouTubeLiveChatParser.parsePollResponse(Data(json.utf8), channelKey: "yt:jfKfPfyJRdk")
        #expect(result.nextContinuation == "next-cont-token-99")
        #expect(result.timeoutMs == 3500)
        #expect(result.lines.count == 2)

        let first = result.lines[0]
        #expect(first.id == "yt-msg-1")
        #expect(first.channel == "yt:jfKfPfyJRdk")
        #expect(first.displayName == "StudyBuddy")
        #expect(first.fragments.contains {
            if case .emote(let e) = $0 {
                return e.name == ":lofiCat:" && e.source == .youtube
            }
            return false
        })

        let second = result.lines[1]
        #expect(second.id == "yt-super-2")
        #expect(second.displayName == "GenerousFan")
        if case .notice(let banner) = second.kind {
            #expect(banner.contains("$5.00"))
        } else {
            Issue.record("Expected .notice kind for SuperChat, got \(second.kind)")
        }
        #expect(second.fragments.contains {
            if case .text(let s) = $0 { return s.contains("keep it going!") }
            return false
        })
    }
}
