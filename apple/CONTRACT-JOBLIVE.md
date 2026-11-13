# CONTRACT-JOBLIVE: one Live Activity for every job (2026-11-13)

Design: https://claude.ai/artifact/Swx9r1Fe1KRNg2LcDLpxqG (approved by Harmony). Part 1 (server timings and the quiet
watchdog) is APP-API-CONTRACT 8.12. This is part 2: one ActivityKit type, one widget, one content shape for saves,
uploads, makes, editor renders and chat replies. The server writes every word the island shows; the widget only draws.

## 1. Why

- Today there are three activity types (`CobaltActivityAttributes`, `CobaltEditActivityAttributes`,
  `CobaltChatActivityAttributes`), three widgets and three copy tables, and the save island draws a fixed four-step rail
  (fetch, save, read, webp) that most jobs never finish ("step 1 of 4").
- After: `CobaltJobActivityAttributes` with `JobLiveState`. Each job sends the steps it really has, by name.

## 2. The type (CobaltKit, `Live/JobLive.swift`)

```swift
public struct JobLiveAttributes: Codable, Hashable, Sendable {      // also ActivityAttributes on iOS
    public var id: String       // the run id (save/webp run uuid, editor render id, chat thread id)
    public var kind: String     // "save" | "upload" | "make" | "edit" | "chat"
    public var title: String    // the source line: "twitch · KindStupidClip", "IMG_0412.mov", "edit · birthday cut"
    public var agent: Bool      // started by the chat agent or an MCP client: draws the "agent" chip
    public var open: String?    // deep link a tap opens (cobalt-apple://...)
}
// iOS: public struct CobaltJobActivityAttributes: ActivityAttributes { ContentState = JobLiveState; same fields }
// The push-to-start "attributes-type" is exactly "CobaltJobActivityAttributes".

public struct JobLiveState: Codable, Hashable, Sendable {
    public var phase: Phase     // waiting | working | quiet | done | failed | lost
    public var steps: [String]  // 1...5 short lowercase names, in order ("download", "store")
    public var step: Int        // index of the current step; == steps.count when done
    public var headline: String // <= 60 chars: "downloading from twitch"
    public var detail: String?  // <= 90 chars: "4.2 of 9.1 MB", "frame 42 of 150", the failure reason
    public var fraction: Double?// 0...1 for the bar and the compact ring; nil = indeterminate (working) or no bar
    public var compact: String? // <= 7 chars, the compact island's trailing text: "46%", "42/150", "3"
    public var since: Double    // unix seconds the clock counts from
    public var result: String?  // done: "1280×720 · 30 s · 8.9 MB"
    public var link: String?    // done: a URL to copy (webp, share link); draws "copy link"
    public var rows: [Row]?     // several jobs at once (2.1)
    public struct Row: Codable, Hashable, Sendable { public var title: String; public var status: String; public var phase: Phase }
}
```

Absent optionals are omitted from JSON (never null). Unknown `phase` decodes as `working`; unknown keys are ignored.
`JobLiveState` round-trips the fixture `deploy/cloudflare/api/test/fixtures/job-live-states.json` byte for byte
(both test suites read it: the parity pin).

### 2.1 Several at once

Phone-only, as today's busy period: when 2+ app-started jobs run at once, the app shows one activity with `kind: "many"`,
`title: "3 jobs"`, `headline: "1 done, 2 going"`, `rows` (at most 3, newest first) and `fraction` = done/total. Server
pushes never send `rows`.

## 3. Steps, words and timings per kind (the server's `jobState`, `deploy/cloudflare/api/src/job-live.ts`)

| kind | steps | working headlines (detail) | done |
|---|---|---|---|
| save (link) | download, store (+ publish when public) | "downloading from <service>" (bytes of total, or the clock) · "storing in your library" (bytes) · "publishing" | "saved" · result |
| upload (file) | upload, store | "uploading" (bytes of total) · "storing in your library" | "saved" · result |
| make | wait (only if queued), make, publish | "waiting for its turn" ("2 ahead") · "making the webp" ("frame 42 of 150") · "packing the webp" | "webp ready" · result · link |
| edit | wait (only if queued), prepare, render, save | "waiting for its turn" · "sending the clips" · "rendering" ("63%") · "saving the video" | "video ready" · result |
| chat | think, tools, write | "thinking" · "using tools" ("3 so far · search, save") · "writing" (last words) | "reply ready" · first words |

- A device-only stage of a save (reading frames for the trim) is step "read" inserted after "store" only while it runs;
  `ready` (waiting on the owner) is `phase: waiting`, headline "ready to trim".
- `failed`: `phase: failed`, the step that failed stays current, headline "couldn't <verb>" ("couldn't save",
  "couldn't make the webp", "couldn't render", "couldn't reply"), detail = the plain reason (the app's failure copy,
  ported to the server's `plainReason`).
- `quiet`: no state change for 3 minutes (server: on the next sweep pass; app: the activity's `staleDate`, which the
  server sets to the last change + 180 s): headline "still working, no news for 3 min", detail "open capystore to check on it".
  The widget shows `quiet` when `context.isStale` too, with the same words.
- `lost`: the quiet watchdog (8.12) at 10 minutes: headline "lost track of this <job>", detail "it may still finish: look in
  your library."; ends.
- Dismissal (8.12): done 60 s (120 s with `link`), failed and lost 300 s. Alerts: start "your agent is saving from x" (agent
  runs only), end "saved to capystore" / "webp ready" / "video ready" / "capystore couldn't finish".

## 4. Wire (APP-API-CONTRACT 8.13)

- `PUT /live/start-token` takes `type: "job"`; the server keeps it as `live:jobstart:<key id>`, next to the old token.
  Push-to-start (share sheet, agent jobs) uses the job token when the key has one, the old one otherwise.
- Every registration takes `type: "job"`: `PUT /live/runs/<run>`, `PUT /live/edits/<rid>`, the chat token route. A run
  registered with it is pushed `JobLiveState` (`attributes-type` "CobaltJobActivityAttributes" on a start); one without
  it gets today's payloads. Old app builds keep working unchanged.
- `relayState` (device stages) is unchanged: the app relays today's `LiveContentState`; the server builds the job state.

## 5. App (part 2b, built on the Mac)

- New: `CobaltKit/Live/JobLive.swift` (types, decoding, a local builder `JobLiveState(save:attributes:)` etc. for runs the
  app shows without push, pinned to the fixture), `CobaltWidgets/JobLiveActivity.swift` (Lock Screen card, compact,
  minimal, expanded; drawn from `JobLiveState` only; the mockup's layout; 160 pt budget as `LiveLock`).
- `LiveActivityManager`, `EditLiveManager`, `ChatLiveManager` request `Activity<CobaltJobActivityAttributes>` and register
  with `type: "job"`; the start token observer watches the new type (and stops registering the old one).
- `CobaltWidgetsBundle` keeps the three old widgets one release (activities already on screen), then they are deleted with
  `LiveViews.swift`, `LiveLockScreen.swift`, `LiveSummaryViews.swift` and the rail copy in a follow-up.
- Tests: fixture parity, every phase per kind renders within 160 pt at `.xLarge` (the existing harness), `isStale` shows
  quiet, done shows result + actions, `rows` draws at most 3.
