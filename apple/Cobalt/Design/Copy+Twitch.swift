import Foundation

/// Copy for the twitch tab (APP-API-CONTRACT 70; all new, lowercase): the channel list, the player, the chat and the composer.
/// Plain values only, since `Cobalt/Design` is compiled into the extensions too.
extension Copy {
    enum Twitch {
        static let title = "twitch"

        // MARK: the list

        static let searchPrompt = "channel name or twitch link"
        static let open = "watch"
        static let yourChannel = "your channel"
        static let liveNow = "live now"
        static let following = "following"
        static let recent = "recent"
        static let noneLive = "nobody you follow is live"
        static let loading = "loading twitch…"
        static let readOnlyTitle = "watching without signing in"
        static let readOnlyBody = "connect twitch in the live stage to chat as yourself and see who you follow."
        static let scopesTitle = "connect twitch again to chat"
        static let scopesBody = "the live stage's twitch connection was made before chat. connect it once more in the live stage and chat turns on."
        static let reconnectTitle = "twitch signed you out"
        static let reconnectBody = "connect twitch again in the live stage."
        static let openStudio = "open live stage"
        static let playerSignIn = "sign in to twitch"
        static func viewers(_ n: Int) -> String {
            n >= 1000 ? String(format: "%.1fk", Double(n) / 1000).replacingOccurrences(of: ".0k", with: "k") : "\(n)"
        }
        static let live = "live"
        static let offline = "offline"

        // MARK: watching

        static let back = "channels"
        static let clip = "clip last 30 s"
        static let clipping = "making the clip…"
        static let clipSaved = "clip saving to your library"
        static let clipFailed = "twitch didn't make the clip"
        static let watchingNow = "watching"
        static let openOnTwitch = "open on twitch"
        static let playingElsewhere = "playing on the other screen"

        // MARK: delay & player mode (70.4)

        static func seconds(_ s: Double) -> String { String(format: "%.1f s", s) }
        static func delay(_ s: Double) -> String { seconds(s) }
        static func behind(_ s: Double) -> String { "\(seconds(s)) behind" }
        static let jumpToLive = "jump to live"
        static let catchingUp = "catching up…"
        static let playerMode = "player"
        static let playerLowLatency = "low latency"
        static let playerEmbed = "twitch embed"
        static let playerEmbedShort = "embed"
        static let usingEmbed = "using embed"
        static let quality = "quality"
        static let mute = "mute"
        static let unmute = "unmute"
        static let audioOnly = "audio only"
        static let loadingStream = "loading stream…"
        static let pipEnter = "picture in picture"
        static let pipExit = "exit picture in picture"
        static let inPiP = "playing in picture in picture"

        // MARK: on a tv (70.5)

        static let watchOnTV = "watch on the tv"
        static let tvTitle = "watch on the tv"
        static let close = "close"
        static let tvModeTitle = "tv mode"
        static let tvModeBadge = "best for chat"
        static let tvModeBody = "the stream fills the tv, chat stays here. about as far behind live as on the phone, so chat lines up. keep capystore open: locking the phone ends screen mirroring."
        static let tvModeSteps = ["swipe down from the top right", "tap screen mirroring", "pick your tv"]
        static let tvModeWaiting = "waiting for a tv… capystore switches by itself"
        static let tvModeUse = "put the stream on the tv"
        static let videoOnlyTitle = "video only"
        static let videoOnlyBody = "the tv plays the stream by itself, so you can lock the phone or use other apps. it runs several seconds behind, so chat waits to match."
        static let chatDelayTitle = "chat waits"
        static func chatDelay(_ s: Int) -> String { s == 0 ? "chat on time" : "chat waits \(s) s" }
        static func chatDelayChoice(_ s: Int) -> String { s == 0 ? "don't wait" : "\(s) s" }
        static let pickTV = "pick a tv"
        static let onTV = "on the tv"
        static let airPlaying = "playing on airplay"
        static let airPlay = "airplay"
        static let dim = "dim"
        static let undim = "undim"
        static let chatOnTV = "chat on tv"
        static let mirrorInstead = "mirror"
        static let tvBrand = "capystore"
        static let tvIdle = "pick a channel on the phone"
        static let toLive = "to live"

        // MARK: chat

        static let chat = "chat"
        static let connecting = "joining chat…"
        static func reconnecting(_ s: Int) -> String { "chat dropped, trying again in \(s) s" }
        static let failed = "chat can't connect"
        static let readOnlyChat = "read only"
        static let composerPrompt = "send a message"
        static let composerReadOnly = "connect twitch in the live stage to chat"
        static let send = "send"
        static let paused = "paused"
        static func newLines(_ n: Int) -> String { n == 1 ? "1 new message" : "\(n) new messages" }
        static let jumpDown = "back to live chat"
        static let reply = "reply"
        static let copyText = "copy message"
        static func replyingTo(_ name: String) -> String { "replying to @\(name)" }
        static let cancelReply = "cancel reply"
        static let deleted = "message deleted"
        static func slow(_ s: Int) -> String { "slow \(s) s" }
        static let emoteOnly = "emote only"
        static let subsOnly = "subs only"
        static let followersOnly = "followers only"
        static let addToSet = "add to a 7tv set…"
        static let emotes = "emotes"
        static let emoteFilter = "find an emote"
        static let emotesLoading = "loading this channel's emotes…"
        static let emotesNone = "no emote by that name"
        static let showEmotes = "emotes"
        static let hideEmotes = "hide emotes"
        static let hideKeyboard = "hide keyboard"
        static let emotesChannel = "this channel · 7tv"
        static let emotesYours = "your twitch emotes"
        static let emotesGlobal = "7tv global"
        // the picker's sections and tiles (70.6)
        static func emotesChannelSevenTv(_ channel: String) -> String { "\(channel) · 7tv" }
        static func emotesChannelTwitch(_ channel: String) -> String { "\(channel) · twitch" }
        static let emotesTwitchGlobal = "twitch global"
        static let emotesRecent = "recent"
        static let emotesEmpty = "no emotes here yet"
        static let copyName = "copy name"
        static let locked = "subscribe to use"

        // MARK: in the pane

        static let pause = "pause"
        static let play = "play"
        static let stop = "stop watching"
        static func watching(_ n: Int) -> String { "\(viewers(n)) watching" }

        // MARK: dual stream

        static let watchAlongside = "watch alongside"
        static let addSecondStream = "add 2nd stream"
        static let swapSecondStream = "switch 2nd stream"
        static let pickSecondStreamTitle = "add 2nd stream"
        static let pickSecondStreamPrompt = "channel name or twitch link"
        static let pickSecondStreamEmpty = "pick a live channel or type any twitch login"
        static let dualFocusInset = "focus"
        static let dualSplit5050 = "50/50"
        static let dualSideBySide32x9 = "32:9 side by side"
        static let dualFocus16x9 = "16:9 focus + inset"
        static let swapFocus = "swap focus"
        static let tapToFocus = "tap to focus"
        static let audioMix = "mix"
        static let audioPinned = "pinned"
        static let audioFollowsFocus = "follows focus"
        static let audioUnpin = "follow focus"
        static let audioMixerLabel = "audio balance"
        static func keepOnly(_ name: String) -> String { "keep only \(name)" }
        static func dropStream(_ name: String) -> String { "drop \(name)" }
        static let dropSecondary = "drop 2nd stream"
        static let dualAirPlayUnavailable = "airplay pauses in dual stream"
        static let dualPiP = "dual picture in picture"
        static let floatingWindow = "floating window"
        static let closeFloatingWindow = "return to window"
        static let suspendedOnLock = "paused while locked"
        static let thermalSteppedDown = "reduced quality (thermal)"

        // MARK: clip, record & split-frame studio

        static let clipShort = "clip"
        static let clipTwitchServer = "clip on twitch"
        static func clipLast(_ seconds: Int) -> String { "clip last \(seconds) s" }
        static func durationChoice(_ seconds: Int) -> String { "\(seconds)s" }
        static let record = "record"
        static let recordPlusChat = "record (+ chat)"
        static let stopRecording = "stop rec"
        static let recordingPill = "rec"
        static let savingDraft = "saving draft…"
        static let drafts = "drafts"
        static let draftsTitle = "stream drafts"
        static let draftsEmptyTitle = "no stream drafts yet"
        static let draftsEmptyBody = "tap clip to save the last 30 s or 60 s from the rolling buffer, or record to capture a longer segment with synced chat."
        static let draftKindClip = "clip"
        static let draftKindRecording = "recording"
        static let editNow = "edit now"
        static let openInEditor = "edit split-frame"
        static let sendToStudio = "send to studio"
        static let sendToStudioSub = "no render · opens live layers"
        static let sendingToStudio = "sending to studio…"
        static let sentToStudio = "opened in studio"
        static let renderVideo = "render"
        static let renderingVideo = "rendering…"
        static let savedPrivate = "saved to library (private)"
        static let draftNewBadge = "new"
        static let chatIncluded = "+ chat"
        static func chatLines(_ count: Int) -> String { count == 1 ? "1 chat line" : "\(count) chat lines" }
        static func buffered(_ current: Int, _ max: Int) -> String { "\(current) / \(max) s buffered" }
        static func partialBufferNote(_ actual: Int, requested: Int) -> String {
            "only \(actual) s was buffered (requested \(requested) s)"
        }
        static func savedDraftToast(_ seconds: Int, chatCount: Int) -> String {
            chatCount > 0 ? "saved \(seconds) s + \(chatCount) chat" : "saved \(seconds) s draft"
        }
        static func chatDroppedWarning(_ seconds: Int) -> String {
            "chat dropped for \(seconds) s (reconnect). the video is whole."
        }
        static let embedBufferNote = "switch to low latency to clip or record on device"
        static let waitingForBuffer = "buffering stream…"
        static let regionA = "A"
        static let regionB = "B"
        static let regionALabel = "region A · facecam"
        static let regionBLabel = "region B · gameplay"
        static let layoutSplit5050 = "50/50"
        static let layoutSplit4060 = "40/60"
        static let layoutSplit3565 = "35/65"
        static let layoutPiP = "pip"
        static let layoutSingle = "single"
        static let swapRegions = "swap A ⇅ B"
        static let sourcePickerHint = "drag A & B on the 16:9 frame · corners resize aspect-locked"
        static let seamHint = "drag seam (snaps to 35 / 40 / 50 / 60 / 65)"
        static let chatLayer = "chat overlay"
        static let chatPlacementBottom = "bottom"
        static let chatPlacementSeam = "seam"
        static let chatPlacementTop = "top"
        static let chatPlacementBand = "band"
        static let chatLookGlass = "liquid glass"
        static let chatLookClear = "clear text"
        static let chatSize = "size"
        static let chatEmotes = "7tv emotes"
        static let chatBadges = "badges"
        static let chatPaints = "paints"
        static let chatSyncNudge = "sync nudge"
        static let chatDroppedHere = "chat dropped · reconnecting"
        static let laneChat = "chat"
        static let renameDraft = "rename draft…"
        static let renameDraftTitle = "rename draft"
        static let deleteDraft = "delete draft"
        static let studioTag = "stream draft"
    }
}
