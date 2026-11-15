# CONTRACT-SWARMS: swarms in the apps (2026-11-15)

Design (approved direction, v2): https://claude.ai/artifact/Gxp8UZKkWNnzgFitioW26B. Server: APP-API-CONTRACT sections 59
(swarms) and 61 (messages, agent detail, the `swarm` Live Activity). Harmony's words: "view, approve, decline etc swarm
including individual swarm agent in the iOS Mac app and live activity", "I want to approve via live activity and also
this whole ui is not simple and intuitive".

**Simple is the requirement.** One screen per swarm, in plain words. No "propose", "scope", "batch", "spec" or "mode" in
the UI. Lowercase house copy, IBM Plex Mono tokens, `.mediaMask()` not needed (no media drawn).

## 1. CobaltKit

- `Swarms/SwarmModels.swift`: `Swarm`, `SwarmCell`, `SwarmChange`, `SwarmMessage`, `SwarmAgent` decoded from 59.5 / 61.3
  (unknown statuses decode to a safe default; all new fields optional).
- `CobaltClient` calls: `swarms()` (GET /swarms), `swarm(id)`, `swarmAgent(id, n)`, `swarmChanges(id, offset, limit)`,
  `swarmMessages(id, agent?)`, `approveSwarm(id, hash)`, `declineSwarm(id)`, `stopSwarm(id)`, `retrySwarm(id)`,
  `decideSwarm(id, changes)`, `applySwarm(id, hash, skipClashes)`, `sendSwarm(id, to, text)`.
- `SwarmStore` (@Observable): list + one swarm; polls every 3 s while a shown swarm is running or applying, 15 s
  otherwise, stops when nothing is shown. Preview data for every state (awaiting, running with a waiting agent,
  review ready, applying, done, failed) in `PreviewClient` so screens and tests run offline.
- `JobLiveState` (`Live/JobLive.swift`) gains optional `cells: String?`, `actions: [String]?`, `hash: String?`,
  `count: Int?`; the fixture parity test gains swarm states (server fixture `job-live-states.json` gains them too).

## 2. Where it lives

- iPhone: more → "swarms" (badge = swarms waiting for you). iPad and Mac: a "swarms" sidebar item with the same badge.
- Deep links: `cobalt-apple://swarm/<id>` opens the swarm screen, `cobalt-apple://swarm/<id>/review` the check screen.

## 3. Screens

1. **Swarms list**: three groups, "waiting for you", "running", "finished". A row is the name and one plain line
   ("claude code asks · 48 min left", "running · 12 of 20", "336 renamed", "declined").
2. **Swarm screen** (one screen that fills in as the swarm moves):
   - Waiting: "<planner> asks · expires in 52 min", the name as a big sentence, three fact rows (what happens to your
     data: "you check every change before it happens" for propose, "it only looks, nothing changes" for read, "it changes
     things itself, only <writes in words>" for act; "<n> agents, <size> each"; "about <low>, never more than <cap>"),
     a "see exactly what it's told" row (pushes the prompt, first items, tools and writes in plain lists), and
     decline / approve at the bottom. Approve asks for Face ID / Touch ID (LocalAuthentication) first.
   - Running: "running · 3 min", the sentence, a bar, "12 of 20 agents done" + money, the agent grid (10 a row on
     iPhone, one square per agent: grey waiting, white pulsing running, amber waiting-on-a-question, green done, red
     failed), any failed or asking agents as rows ("agent 7 failed twice · retry", "agent 3 is asking claude code"),
     stop at the bottom. Reduce Motion: no pulse.
   - Review ready: "342 changes ready", "check first" and "apply 338" (Face ID). Done / failed: one line + "open".
3. **Agent sheet** (half sheet on iPhone, inspector column on Mac/iPad): "agent 4", "done in 41 s · 1¢ · items
   151–200", what it did (steps), its changes, and its conversation as bubbles (agent left, owner/you right, "→ all
   agents" marked). A reply box at the bottom while the swarm runs (sends `sender: you`). Arrows step to the next agent.
4. **Check changes**: a list of "old → new" rows with a tick each; clashes unticked with "another change already uses
   this name"; tap the new name to edit it; one "apply <n>" button (Face ID).

## 4. Live Activity (kind `swarm`, drawn by `JobLiveActivity`)

- The grid strip: `cells` as a row of small rounded cells (up to 40 drawn; beyond that one bar coloured by share).
- `actions` become buttons in the Lock Screen card and the expanded island: `approve` and `apply` are
  `LiveActivityIntent`s with `authenticationPolicy = .requiresAuthentication`, so the system asks for Face ID first;
  they call the API with the device's own session (never a client key). `decline` and `stop` are intents without auth.
  `check` and `open` are links. After an intent succeeds the app updates the activity at once (no wait for the push).
- Compact island while waiting for you: an amber "?" and "swarm"; running: the ring and "12/20".
- Mac: a notification with approve / decline actions (UNNotificationCategory, same intents) when a swarm waits.

## 5. Tests

Model decoding for every 59.5/61.3 shape, store polling stops when hidden, the Live Activity renders each swarm state
within the 160 pt budget, button lists per state, Face ID gate on approve/apply, deep links route.
