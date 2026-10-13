# cobalt insight: the server watches a save and writes down what is in it (proposal, 2026-10-10)

Owner (verbatim, 2026-10-10): "I was thinking it would be cool to use cloudflare agents running Claude haiku 5.5 to try watch the
video and create embeddings, description or tags? We could use agent sdk but primarily focus on cloudflare so possibly just
cloudflare tools and sdks can you mockup an artifact ux ui cost etc and look at how much for backfill production please".

Design and research lane. **Nothing is built, nothing is deployed, no contract is edited.** Two files: this one, and
`deploy/cloudflare/insight-cost-model.json` (every price, limit and assumption below, each with its source, the date read and
`verified` or `estimated`, plus the production numbers and the arithmetic run once). Code read on 2026-10-10 against the `apple-app`
worktree; prices read from the vendors' own pages the same day. Marked **(owner)** where the owner asked, **(lane)** for calls
made here and open to review, each with what would change it.

## 0. The short answer

**It costs cents.** Describing the whole library once, 162 videos and 40 photos, is about **$0.23 at list price** on the
recommended pipeline, of which about **$0.15 is the Anthropic bill**; the rest is Workers AI and container seconds that sit inside
what the account already includes. Everyday running at 17 saves a day is about **$0.78 a month at list, $0.44 out of pocket**.
The Batch API would take 7 cents off the backfill and is not worth its 24 hour wait. Money is not the decision; three other things are:

1. **Where private frames go.** "Haiku watches" sends sampled frames and a transcript of every described post to Anthropic under
   the owner's own key (kept up to 30 days, not trained on; there is no zero-retention switch a personal account can flip, section 7).
   "Cloudflare only" keeps everything on Cloudflare and costs about the same; what it gives up is quality, which is not measured yet.
2. **Never touching the line.** Cutting frames is ffmpeg work, and the one helper does one job at a time for every client
   (`APP-API-CONTRACT.md` 17). The recommendation is that describing **bypasses the line entirely** (section 4.5).
3. **"Cloudflare agents" is the wrong primitive for the pipeline, and the right one for a later feature.** The describe job is a
   fixed sequence with retries, which is what Cloudflare Workflows is; the Agents SDK earns its place when there is a conversation
   ("ask my library"), section 4.4.

| | cloudflare only | **haiku watches** (recommended) | haiku + scenes |
|---|---|---|---|
| who describes | Workers AI vision model (`@cf/google/gemma-4-26b-a4b-it`) | `claude-haiku-5-5` through AI Gateway | `claude-haiku-5-5` through AI Gateway |
| frames sent | 1 per 6 s, 3 to 12 | 1 per 4 s, 4 to 24 | 1 per 2 s, 4 to 48 |
| you get | description, tags, facets, search by meaning, more like this | the same, better read text and better judgement (expected, not measured) | the same plus a caption per moment, so a search lands on `0:42` |
| an average video (43.7 s), all in, list | $0.0010 | **$0.0014** | $0.0023 |
| backfill, list price | $0.16 | **$0.23** | $0.34 |
| backfill, out of pocket | $0.03 | **$0.15** | $0.24 |
| backfill with Batch API | n/a | $0.16 | $0.22 |
| a month at 5 / 17 / 50 saves a day, list | $0.16 / $0.56 / $1.64 | **$0.23 / $0.78 / $2.29** | $0.32 / $1.10 / $3.25 |
| a month at 17 a day, out of pocket | $0.00 | **$0.44** | $0.72 |
| backfill wall clock, sharing the helper / own instance | 56 / 40 min | **72 / 56 min** | 106 / 90 min |
| leaves Cloudflare | nothing | frames + transcript to Anthropic | frames + transcript to Anthropic |

Every dollar figure is an estimate built on verified prices and unmeasured token counts (section 9 says which is which). "Out of
pocket" assumes Workers AI stays under its 10,000 free neurons a day and the container seconds stay inside the Workers Paid
allowance; neither was checked against the account's current usage.

**Recommendation (lane).** Build **haiku watches**, with **cloudflare only as the same pipeline's second describer** behind one
seam, used for the owner's own uploads by default and for anything Haiku declines. Add the scene captions of "haiku + scenes" later
as a setting, not a rebuild: it is the same request with more frames and one more array in the answer. What would change it: a
ten-clip side-by-side (section 11, question 2) in which the Workers AI model reads on-screen text and returns clean tags as well as
Haiku does; then "cloudflare only" for everything, and no key to manage.

## 1. What exists today (read, not assumed)

- **The helper already cuts frames.** `buildPosterArgs({input, output, at, side})` writes one JPEG at a timestamp, scaled to a
  longest side, rotation applied (`deploy/cloudflare/api/helper/lib.js:622`; posters use 720 px, `-q:v 4`, `:589-591`). A poster is
  made after every save by streaming the stored original from R2 into the helper again (`helper/server.js:950` `handlePoster`;
  `src/poster.ts:7-12`). HEIC cannot be decoded by the container's ffmpeg (`src/poster.ts:48`), and animated WebP cannot either
  (`src/poster.ts:15-16`).
- **One helper, one job at a time, one Durable Object.** `busy()` (`helper/server.js:278`), `maxInstances: 1`
  (`deploy/cloudflare/api/cloudflare.config.ts:26`, because cobalt's tunnel state lives in that process), instance type `basic`
  (`:20`), `getContainer(env.COBALT, "main")` (`src/index.ts:331`). `StudioService.held()` (`src/studio.ts:1194`) decides free or
  not; posters already yield to the line (`src/studio.ts:981`). The sweep runs every 5 s while anything is pending
  (`src/sweep.ts:20`), one item of a pass is capped at 30 s (`src/studio.ts:116`), and the container sleeps 45 s after its last call
  (`src/index.ts:37`).
- **Search is titles, on the device.** `.searchable` prompt `search titles`, matching title, service, ref and file names after
  loading the whole library (`apple/CONTRACT-LIBRARY2.md:220-226`, which also records the lane call "no server search parameter").
  Kind chips are `all · videos · photos · galleries · webps` (`apple/CONTRACT-GALLERY.md:290`); `MediaKind` is taken as a name
  (`:485`). A custom title always wins (`CONTRACT-LIBRARY2.md` 1.1).
- **Posts and keys.** One card per post, keyed by `POST_KEY_SQL` (`src/app-routes.ts:464`); a post key can be a session id, an
  item id or a whole link. Migrations run `0001` to `0009` (`deploy/cloudflare/d1/migrations/`), so the next is `0010`.
- **Shortcuts exist** (`apple/Cobalt/Intents/`: `SaveLinksIntent`, `LatestSavesIntent` "Get latest saves", `MakeWebpIntent`,
  `UploadFilesIntent`).
- **The deploy tool can bind what this needs.** The installed `@cloudflare/config` 0.20.0 has `bindings.ai`, `bindings.vectorize`,
  `bindings.workflow`, `exports.workflow`, `bindings.media` and `bindings.secretsStoreSecret`
  (`deploy/cloudflare/api/node_modules/@cloudflare/config/dist/public-DA8eKvPJ.d.mts:108`, `:260`, `:288`, `:1397`, `:1585`), and
  `containers` is an array (`cloudflare.config.ts:111`). Present in the types; none of it has been deployed from this repo.

## 2. What the research found (all read 2026-10-10; sources in the JSON)

**Claude Haiku 5.5** (`claude-haiku-5-5`, a dateless pinned id)

- **$0.10 in / $0.50 out per million tokens** for prompts up to 100,000 tokens; **5x that above 100,000** ($0.50 / $2.50), priced
  per request. Cache write $0.125 (5 min) or $0.20 (1 h), cache read $0.01. Batch API: half price ($0.05 / $0.25), stacks with caching.
- **No video input, no audio input.** Text and images only. A video is frames plus a transcript; there is no other way.
- **An image costs `ceil(w/28) x ceil(h/28)` tokens.** Anything over 2576 px on the long side or 4,784 tokens is scaled down first.
  Up to 600 images a request; over 20 images, each must be at most 2000 px a side; 10 MB an image, 32 MB a request. JPEG, PNG, GIF,
  WebP (an animation is read as its first frame). A 432x768 frame is 448 tokens, which is $0.000045.
- **Structured outputs** (`output_config.format`, a JSON schema) are supported on this model: the answer is schema-valid JSON unless
  the model refuses or runs out of `max_tokens`. No `maxItems`, no string lengths, at most 24 optional fields.
- Thinking is adaptive and on by default at effort `medium`; thinking tokens bill as output. The plan turns it off (accepted at
  effort `high` or below, per the Claude API reference bundled with Claude Code, cached 2026-10-06; not re-fetched today).
- Prompt caching needs a prefix of at least 512 tokens. Batches: up to 100,000 requests, most done within an hour, 24 h at worst,
  stored 29 days, not eligible for zero data retention.
- **It will not name a person from a face, and it does not process explicit images.** Both shape the design (sections 4.3, 8).
- Rate limits at the lowest tier are 1,000 requests a minute; irrelevant here.

**Cloudflare**

- **No Claude on Workers AI.** The Workers AI catalog hosts no Anthropic model. Cloudflare's wider "AI model catalog" lists
  Anthropic models as third-party, reached through AI Gateway, and **Haiku 5.5 is not in that list yet** (`anthropic/claude-haiku-4.5`
  is). So "Claude on Cloudflare" today means: the Anthropic API, called from a Worker, routed through AI Gateway.
- **AI Gateway** is free at its core (analytics, cost per request, rate limits, spend limits). Anthropic's SDK works against it by
  changing the base URL to `https://gateway.ai.cloudflare.com/v1/{account}/{gateway}/anthropic`. Two ways to pay: the owner's own
  Anthropic key (no fee), or Cloudflare "unified billing" (prepaid credits, 5% fee). Only `/v1/messages` is documented through the
  gateway; whether the Batch endpoint passes is unconfirmed. Logs store prompts and responses by default;
  `cf-aig-collect-log-payload: false` keeps the cost line and drops the content.
- **Agents SDK** (`agents` on npm): an `Agent` is a Durable Object (`DurableObject > Server > Agent`) with SQL state, `schedule()`,
  `queue()`, "fibers" for work that survives eviction, WebSockets, and chat and MCP layers on top. It bills as a Durable Object. Its
  own docs send independent, retry-heavy pipelines to Workflows and keep fibers for work that belongs to an agent's conversation.
- **Workflows**: durable steps with per-step retries; waiting on a fetch bills no CPU; a step may return 1 MiB; 10 million requests,
  30 million CPU ms and 500,000 steps a month included on Workers Paid. Queues, Durable Objects, D1 and R2 allowances are in the JSON;
  none of them is approached.
- **Workers AI**: $0.011 per 1,000 neurons, **10,000 neurons a day free**. Speech to text: `whisper-large-v3-turbo` at **$0.000513 an
  audio minute** (the whole library's 113.7 minutes is 6 cents, and 5,302 neurons, so free on one day's allowance). Text embeddings:
  `bge-m3` $0.012 per million tokens, multilingual, 60,000-token inputs. Vision models: `gemma-4-26b-a4b-it` at $0.10 / $0.30 (the
  same input price as Haiku 5.5), `llama-4-scout` $0.27 / $0.85, `llama-3.2-11b-vision` $0.049 / $0.676, `mistral-small-3.1`
  $0.351 / $0.555. **There is no image-embedding model** (no CLIP, no SigLIP), so "visual embeddings" cannot be done on Workers AI today.
- **Vectorize**: up to 1,536 dimensions, cosine; 10 filterable metadata fields per index, strings indexed by their first 64 bytes;
  vector ids at most 64 bytes; 50 results a query with metadata. Workers Paid includes 10 million stored and 50 million queried
  dimensions a month; this library is 0.28 million stored.
- **Containers** (`basic`: a quarter vCPU, 1 GiB, 4 GB): $0.00000778 a second all in at list (CPU on active use, memory and disk
  provisioned); 25 GiB-hours and 375 vCPU-minutes a month included.
- **Media Transformations** has a Workers binding (open beta) that cuts a frame or the audio out of a private R2 object with no
  container at all: `env.MEDIA.input(obj.body).output({mode: "frame", time: "12s", format: "jpg"})`. Free during the beta; then $0.50
  per 1,000 operations past 5,000 a month, where **audio is one operation per second**. Inputs up to 100 MB and 10 minutes.
- **AI Search** (the old AutoRAG) indexes documents, not video, and starts billing on 2026-11-01. Not relevant.

## 3. The three pipelines

All three are the same six steps with different settings, so a page can switch between them and so can the server:

```
save is ready ─► cut frames + audio ─► transcribe ─► describe ─► embed ─► index + record
                 (ffmpeg, own instance) (Workers AI)  (model)     (Workers AI) (Vectorize, D1)
```

| step | cloudflare only | haiku watches | haiku + scenes |
|---|---|---|---|
| frames | `max(3, min(12, ceil(d / 6)))`, 768 px | `max(4, min(24, ceil(d / 4)))`, 768 px | `max(4, min(48, ceil(d / 2)))`, 768 px |
| transcript | Whisper turbo on Workers AI | the same | the same |
| describe | Workers AI vision model, JSON mode | Haiku 5.5, strict JSON schema | Haiku 5.5, strict JSON schema with `scenes` |
| vectors a post | `card`, and `said` when there is speech | the same | the same plus one per scene |
| vectors today | about 272 | about 272 | about 1,755 |

Not offered, and why: **true image embeddings** ("find the frame that looks like this"). Workers AI has no model for it. It would
mean either CLIP inside the container (a 350 MB model on a quarter vCPU, roughly 3 s a frame, about 2.5 hours for the backfill) or a
third embedding vendor that also receives the frames. Scene captions embedded as text cover "the clip with the orange cat on a
keyboard" without either. Revisit when Workers AI ships an image-embedding model.

## 4. Decisions

### 4.1 Frames (lane)

- **Evenly spaced, not scene-detected.** Frame `i` of `n` is taken at `(i + 0.5) x d / n`: mid-segment, so never the black first
  frame or the end card. Scene detection needs a full decode on a quarter vCPU and returns an unpredictable count; 101 of the 162
  videos are under 30 s and have one or two scenes anyway. "haiku + scenes" simply samples twice as densely.
- **768 px on the long side, never upscaled, JPEG `-q:v 4`**: 448 tokens for a 9:16 frame. At 512 px on-screen captions on a phone
  clip (288 px wide) stop being readable, and reading that text is half the point; at 1024 px the cost rises 23% for little.
  The cap of 24 (or 48) frames keeps the largest request near 13,000 (24,000) tokens, far below the 100,000-token line where Haiku 5.5
  costs five times as much. That line is a hard assertion in the code, not a hope.
- **A photo is one frame at 1024 px** (about 1,036 tokens). **A gallery is one describe**: every photo as a frame, up to 12, video
  items contributing 2 frames each.
- **Frames are kept**, privately, under `insight/<id>/f-<nn>.jpg` in `cobalt-originals` (about 74 MB for today's library). That is
  what makes a prompt change cheap: describing again re-reads the frames and never needs ffmpeg. They are also the thumbnails for
  scene results. The audio cut is deleted once transcribed.

### 4.2 Transcript (lane)

- The helper cuts the audio track to 16 kHz mono (a few hundred KB a minute) in the same visit as the frames; Whisper
  `large-v3-turbo` runs on Workers AI with `vad_filter: true`.
- **Music-only clips.** Whisper invents words over music. Three guards: no audio stream or near-silence (ffmpeg `volumedetect`) skips
  Whisper; fewer than 3 words, or under 0.3 words a second, is stored as no speech; and the transcript goes to the model labelled as
  a machine transcript that may be lyrics or noise, with the model returning `audio: speech | lyrics | music | ambient | silent`.
  Lyrics are kept on purpose: "the one with that song" is a real search.
- The transcript is stored (D1, capped at 20,000 characters), shown in the detail as `said`, and embedded as its own vector.

### 4.3 What the model returns (lane)

One strict JSON document per post. Every field is required (optional fields are the scarce resource in a strict schema); "none" is
an empty string or array.

```json
{
  "title": "cat walks across a piano mid-recital",
  "description": "A tabby steps onto the keys while a child plays; the audience laughs and the pianist keeps going.",
  "tags": ["cat", "piano", "recital", "kids", "funny animals"],
  "search_phrases": ["cat interrupts piano", "kid playing piano cat"],
  "genre": "clip", "mood": "funny", "people": "few",
  "has_text": true, "on_screen_text": "wait for it", "language": "en",
  "audio": "speech", "nsfw": "no",
  "entities": [{ "name": "Steinway", "type": "brand" }],
  "scenes": [{ "t": 3.5, "caption": "a tabby jumps onto the piano bench" }]
}
```

- `title`: a suggestion, at most 60 characters. **It never replaces anything by itself** (section 6).
- `description`: one or two plain sentences. `tags`: 5 to 12, open vocabulary, lowercase, at most three words each; the request
  lists the library's 60 most used tags and asks for reuse when one fits, so the vocabulary converges instead of sprawling. The server
  normalises (trim, lowercase, dedupe, drop `#`) rather than trusting the model. `search_phrases`: 3 to 5 things the owner might type.
- **A small fixed facet set**, each an enum: `genre` (clip, meme, music, dance, tutorial, talk, gameplay, art, animal, food, sport,
  news, screen recording, photo, other), `mood` (funny, wholesome, calm, hype, sad, tense, informative, aesthetic, neutral),
  `people` (none, one, two, few, crowd), `has_text`, `language` (BCP-47, empty when none), `audio`, `nsfw` (no, suggestive, explicit).
  The facet is called `genre` because `kind` already means video, photo, gallery or webp in this app.
- `on_screen_text`: verbatim, deduplicated across frames. `entities`: brands, places, works, accounts, animals, things, and people
  **only when the name is written or spoken**; the model will not put a name to a face, and the copy must never suggest it can.
- `scenes` (haiku + scenes only; an empty array otherwise): a time and a caption per moment.
- Request shape: instructions and schema first (stable, cacheable), then the tag list, then the post's facts, then labelled frames
  (`frame 3 at 0:12`), then the transcript. Thinking off, effort `low`, `max_tokens` 4,000 (8,000 with scenes), and
  `stop_reason` checked before the JSON is parsed. What is on a frame or in a transcript is data: the call has no tools, and the worst
  a hostile caption can do is mis-tag its own post.

### 4.4 Where it runs: a Workflow, not an Agent (lane)

The owner asked for "cloudflare agents". Read against what the job is, the answer is a **Workflow** (`InsightWorkflow`, exported
from the API Worker), one instance per post and version:

- The job is a fixed sequence; no step is chosen by a model. A Workflow gives each step its own retries and remembers finished
  steps, so a Haiku timeout re-runs the describe step and never the ffmpeg. An Agent would need that written by hand ("fibers" restore
  a snapshot; the recovery is the developer's code), and Cloudflare's own Agents documentation points pipelines like this at Workflows.
- It runs outside the one Durable Object that serves every request and holds the line, which is the lesson this repo has paid for
  three times (CLAUDE.md, "runtime lessons").
- Waiting on Haiku or Whisper bills no CPU; six steps a post is 3,100 steps a month against 500,000 included.

**Where the Agents SDK does belong:** a later "ask my library" surface, a chat agent whose tools are the search routes of section 5.
That is a conversation with state, which is what the SDK is for. It would sit on top of this pipeline, not replace it. What would
change the call: the owner wanting that chat in the first release. The **Claude Agent SDK** is not a fit at all: it is Claude Code as
a library and needs a container to live in, for a job that is one API call.

**The trigger.** When a save turns `ready`, the Durable Object writes an `insight:<item id>` record and arms the sweep, exactly as
it does for `poster:<item id>`; the next sweep pass creates the Workflow instance (a single fast call, no helper) and deletes the
record. Nothing is started after a response, so saves that finish with every client gone are described too.

### 4.5 The line: bypassed (lane)

Describing **never joins the line and never holds the save helper**. Frames and audio are cut by a **second instance of the same
container image**, its own Durable Object class (`InsightHelper`), started in helper-only mode (no cobalt process), sleeping 15 s
after its last call.

Why not share the helper: a describe holds ffmpeg for 10 to 50 seconds, longer than the 30 s a sweep item may take and longer than
the 20 s an arriving save waits for a poster. Sharing would mean a new preemptible job type inside `held()`, the most delicate logic
in the server, to protect the thing the owner does 17 times a day from a background nicety. A second instance costs about 8 cents a
month more at list and cannot make a save wait, show `busy` to an old client, or take the save helper down with a poison file. The
backfill's hour of ffmpeg also stops being a reason to stay off the app.

What would change it, and the fallbacks, in order: (a) no appetite for a second instance: the same job on the shared helper at the
lowest priority, started only when nothing is held and the line is empty, cancelled when anything arrives (backfill 72 minutes
instead of 56, longer when the app is in use); (b) the Media Transformations binding once out of beta, for frames only: no container
at all, and at 17 saves a day about 4,900 frame operations a month, just inside its 5,000 free. Its audio is priced per second
(about $10 a month here), so audio would stay with the helper. All three sit behind one seam, `cutFrames(item) -> {frames, audio}`,
so the choice can be reversed without touching the rest.

### 4.6 Embeddings and the index (lane)

- **Model**: `@cf/baai/bge-m3`. Multilingual (the library is Instagram and X, not only English), priced, not beta, long inputs. Its
  1,024 dimensions are from the model's own card; the Cloudflare page read did not state them, and an index's dimensions cannot be
  changed, so the first build step is one call to confirm.
- **What is embedded.** `card`: suggested title, description, tags, search phrases, entities, on-screen text. `said`: the transcript,
  when there is speech, up to about 2,000 tokens. Kept apart because a three-minute monologue would otherwise drown the description.
  `scene`: one per scene caption (haiku + scenes only), carrying its time.
- **One vector per post is not enough; one per scene is not needed by default.** Two per post answers "what is it" and "what was
  said". Per-scene vectors matter only for long clips: 34 of 162 videos are over a minute.
- **Index** `cobalt-insight-1` (the number is the embedding generation), cosine. Vector ids are minted, never the post key (a key
  can be a link longer than the 64-byte id limit): `<insight id>:c`, `:s`, `:n07`. Metadata: `p` (insight id), `part`, `t`, `genre`,
  `kind`, `service`, `nsfw`, `at`; filter indexes on `part`, `genre`, `kind`, `service`, `nsfw`, `at` (6 of the 10 allowed, created
  before the first insert). Tags are filtered in D1, not in Vectorize.
- **D1 is the truth, Vectorize is an index of it.** The text behind every vector is in D1, so the index can be dropped and rebuilt
  for a fraction of a cent. Vectorize is eventually consistent: a post can be `ready` a few seconds before it is findable.
- **Search** = exact matches from D1 first (a tag, a title, words on screen, words said), then the nearest vectors above a score
  floor, merged per post, each result saying why it matched. At a few hundred posts a brute-force scan would also work; Vectorize is
  chosen because it is free at this size, filters by metadata, and is the Cloudflare tool the owner asked about.

### 4.7 Doing it once, and doing it again (lane)

- `INSIGHT_VERSION` is one integer in the code, raised when the prompt, schema, sampling or model changes. Every row stores the
  version it was made with. The Workflow instance id is `<insight id>-v<version>-<run>`, so a second trigger for the same work is
  refused by Workflows itself.
- A row from an older version is **stale, still shown, and never re-described by itself**. `POST /insight/backfill?stale=1` does it
  when the owner asks, and says what it will cost first (`dry_run=1`). If only the prompt changed, the kept frames and transcript are
  reused: no ffmpeg, no Whisper.
- Vector ids are deterministic, so a re-run overwrites; scene vectors left over from a longer earlier run are deleted by id.
- **Owner edits survive.** Tags carry `source` (`model` or `owner`). A re-run replaces model tags only, and a model tag the owner
  removed stays removed.

### 4.8 Storage: migration `0010_insight.sql` (sketch; additive, new tables only)

```sql
CREATE TABLE media_insights (
    post_key       TEXT PRIMARY KEY,       -- the key GET /library groups by (app-routes.ts POST_KEY_SQL)
    id             TEXT NOT NULL UNIQUE,   -- 16 base62: the R2 prefix insight/<id>/, the vector ids, the workflow instance
    item_id        TEXT NOT NULL,          -- media_items.id of the original that was watched (a gallery: item 0)
    state          TEXT NOT NULL,          -- 'queued' | 'working' | 'ready' | 'failed' | 'refused' | 'skipped'
    code           TEXT,                   -- error.insight.* when failed, refused or skipped
    hold           TEXT,                   -- per-post switch: NULL (follow the setting) | 'never' | 'cloudflare'
    pipeline       TEXT,                   -- 'cloudflare' | 'haiku' | 'haiku_scenes'
    model          TEXT,                   -- 'claude-haiku-5-5' | '@cf/google/gemma-4-26b-a4b-it'
    version        INTEGER NOT NULL,       -- INSIGHT_VERSION this row was made with
    frames_version INTEGER,                -- sampling rule the kept frames were cut with
    frames         INTEGER,                -- how many frames are kept in R2
    title          TEXT,                   -- the suggestion; the post's title is still media_titles / the default
    description    TEXT,
    genre TEXT, mood TEXT, people TEXT, has_text INTEGER, language TEXT, audio TEXT, nsfw TEXT,
    on_screen_text TEXT,
    entities       TEXT,                   -- JSON [{"name","type"}]
    search_phrases TEXT,                   -- JSON ["..."]
    transcript     TEXT,                   -- '' when there is no speech; at most 20,000 characters
    tokens_in INTEGER, tokens_out INTEGER, audio_seconds REAL,
    cost_micro_usd INTEGER,                -- what this describe cost, computed from the usage the API returned
    attempts       INTEGER NOT NULL DEFAULT 0,
    created_at     INTEGER NOT NULL, updated_at INTEGER NOT NULL, described_at INTEGER
);
CREATE INDEX idx_media_insights_state ON media_insights (state, updated_at);
CREATE INDEX idx_media_insights_item ON media_insights (item_id);

CREATE TABLE media_tags (
    post_key   TEXT NOT NULL,
    tag        TEXT NOT NULL,              -- normalised: lowercase, trimmed, at most 32 characters
    source     TEXT NOT NULL,              -- 'model' | 'owner'
    removed_at INTEGER,                    -- the owner removed a model tag: a re-run must not bring it back
    created_at INTEGER NOT NULL,
    PRIMARY KEY (post_key, tag)
);
CREATE INDEX idx_media_tags_tag ON media_tags (tag, post_key);

CREATE TABLE media_scenes (
    insight_id TEXT NOT NULL,
    i          INTEGER NOT NULL,           -- 0-based
    t          REAL NOT NULL,              -- seconds into the video
    caption    TEXT NOT NULL,
    frame      INTEGER,                    -- which kept frame shows it
    PRIMARY KEY (insight_id, i)
);

CREATE TABLE insight_settings (k TEXT PRIMARY KEY, v TEXT NOT NULL, updated_at INTEGER NOT NULL);
```

No existing table or statement changes, so "apply first, deploy after" holds as for every migration since `0006`. No full-text
virtual table: at this size `LIKE` over a few hundred rows is instant, and a D1 database with virtual tables is awkward to export.
**Deleting a post must also delete its insight**: the row, its tags and scenes, the vectors by id, and the R2 prefix. That is a new
`.delete(` on a bucket, which `test/poster-delete.test.ts:202` exists to make somebody review.

### 4.9 The describer seam (pinned for whoever builds it)

```ts
type FrameRef = { i: number; t: number; key: string; w: number; h: number };
type Cut = { frames: FrameRef[]; audio: { key: string; seconds: number } | null };
type InsightDoc = { title: string; description: string; tags: string[]; search_phrases: string[];
    genre: Genre; mood: Mood; people: People; has_text: boolean; on_screen_text: string; language: string;
    audio: AudioKind; nsfw: Nsfw; entities: { name: string; type: EntityType }[]; scenes: { t: number; caption: string }[] };
interface FrameSource { cut(item: ItemRow, rule: SampleRule): Promise<Cut> }          // own instance | shared helper | media binding
interface Describer   { describe(cut: Cut, transcript: string, facts: PostFacts): Promise<{ doc: InsightDoc; usage: Usage }> }
                                                                                      // haiku (AI Gateway) | workers ai
```

## 5. API additions: a section 20 sketch (not written into `APP-API-CONTRACT.md`)

All keyed (`Authorization: Api-Key`), all additive, `cache-control: no-store`, announced by `features.insight` on
`GET /capabilities` (missing = false, as for every feature) with `limits.insight_version` and `insight.mode`. Routes take an item
id and act on its post, like `DELETE /library/items/<id>/post`.

| route | what it does |
|---|---|
| `GET /library?v=4` | each post gains `insight`: `null`, or `{state, stale, title, description, tags, genre, mood, nsfw}` (short; the transcript is not in the list) |
| `GET /library/search?q=&limit=1..50&tag=&genre=&kind=&service=` | search by meaning. `200 {posts: [<library post> + {match: {why, part, t, snippet, score}}], took_ms}`. `why` is `tag`, `title`, `said`, `on screen`, `scene` or `meaning`; `t` is set for a scene. Empty `q` with a `tag` or facet is a plain filter. Never wakes a container |
| `GET /library/tags` | `{tags: [{tag, count}]}`, most used first |
| `GET /library/items/<id>/similar?limit=1..24` | "more like this": nearest `card` vectors to this post's, itself removed |
| `GET /library/items/<id>/insight` | the whole document: description, tags with `source`, facets, on-screen text, entities, transcript, scenes, `described_at`, `pipeline`, `model`, `version`, `stale`, `cost_micro_usd` |
| `GET /library/items/<id>/insight/frames/<n>` | one kept frame (JPEG, private, for scene results) |
| `POST /library/items/<id>/insight` | describe now, or again. Body `{}` or `{"pipeline": "cloudflare"}`. `202 {state: "queued"}`; `409 error.insight.working` |
| `PATCH /library/items/<id>/insight` | owner edits: `{"tags": {"add": [], "remove": []}}`, `{"hold": "never" \| "cloudflare" \| null}` |
| `DELETE /library/items/<id>/insight` | forget it: row, tags, scenes, vectors, kept frames |
| `GET /insight/status` | counts by state, how many are stale, this month's describes and spend (summed from `cost_micro_usd`), the settings |
| `PUT /insight/settings` | `{"mode": "off" \| "cloudflare" \| "haiku" \| "haiku_scenes", "uploads": "cloudflare" \| "haiku" \| "never", "auto": true, "daily_cap": 200}` |
| `POST /insight/backfill?limit=1..100&stale=0\|1&dry_run=0\|1` | queue what has no description (or a stale one), oldest first, like `POST /library/posters/backfill`. `200 {queued, eligible, estimate_usd}`; `dry_run=1` only counts and prices |

Errors: `error.insight.off`, `error.insight.unsupported` (HEIC, an animated WebP with no original), `error.insight.no_original`,
`error.insight.refused`, `error.insight.failed`, `error.insight.working`, `error.insight.bad_request`, `error.insight.cap`.

This reverses the lane call in `CONTRACT-LIBRARY2.md` 1.14 ("no server search parameter"), for meaning only: title search stays on
the device and stays instant.

## 6. How the app uses it

Lowercase, the house voice. Everything is hidden when the server has no `features.insight`.

| surface | today | with insight |
|---|---|---|
| library search | `search titles`, on device | prompt `search`. Title matches appear at once from the device as today; below them, after a pause in typing, results from the server, each with one quiet line saying why: `said "wait for it"`, `on screen "day 3"`, `tagged piano`, `at 0:42 · a tabby jumps onto the bench`, `close in meaning`. No match: `nothing matches "<q>".` unchanged |
| tag filter | none | tapping a tag anywhere puts it in the search field as a token (SwiftUI's own search tokens), next to the kind chips, which stay as they are. No second chip row |
| detail | tabs per rendition | an `about` block under the tabs: the description; tags as chips with `add a tag`; `said` (the transcript, two lines, expandable, `copy`); `on screen` (the text, `copy`); `more like this` (a strip of six tiles); a footer `described by haiku · 9 oct`, with `describe again` in `more` |
| titles | custom title, else `service · ref` or the file name | unchanged. When there is no custom title the detail offers the suggestion as one row, `use "cat walks across a piano mid-recital"`, which sets the custom title through the existing `PATCH .../post`. Search results show the suggestion as a second line |
| library tile | title and badges | unchanged. No sparkle, no badge |
| smart collections | none | later, and on the device: a saved search (text, tags, facets) pinned to the show menu. No server work beyond section 5 |
| shortcuts | save, latest, make webp, upload | `Find saves about…` (a phrase in, saves out, same entity as "Get latest saves") |
| sharing a public link | the link | `copy description` in the share menu, for alt text. Public files are bare R2 objects with no page of their own, so there is nowhere to put alt text automatically |
| settings | none | `describe saves`: `off · on cloudflare · with haiku`; `my own uploads`: `stay on cloudflare · with haiku · never`; `describe everything saved so far` with the count and the price before it starts; this month's count and spend |
| web library | titles | not in this pass |

States the `about` block must draw, each with its exact line: `describing…`; described (above); `not described` with `describe`;
`couldn't describe this.` with `try again`; `haiku wouldn't describe this one.` with `try on cloudflare`; `can't describe this kind of
file yet.` (HEIC); `kept on cloudflare` in the footer when that describer was used; `described with an older recipe` when stale.

Calls made here: a suggested title is **never applied silently** (owner question 4: every card changing from `instagram ·
Dd7P496wolG` to model prose is a redesign nobody asked for); describing sends **no notification** and has no Live Activity; nothing
about the orbit changes.

**For the page that mocks this up.** Take the posts from `apple/CobaltKit/Sources/CobaltKit/Preview/PreviewData.swift` (`:263-315`:
`Dd55fEyN1Yy` 37.43 s 720x1280, `Dd7P496wolG` 14.77 s, x `2105435404002562056` 5.46 s 480x568, x `2105432512428445875` 1.9 s
498x280, `Dd5JFkMDt4N` 10.77 s 720x720, x `2105358343657427103` 5.06 s 1920x1080, plus an upload). The descriptions shown for them
would be invented, and the page must say so: nobody has run a model on these clips. Seed the failures on purpose: one post Haiku
declined, one music-only clip with an empty `said`, one HEIC upload that cannot be described, one still `describing…`, one stale.
Let the reader switch the pipeline and watch three things move together: what leaves Cloudflare, what the search can answer (a
scene result with a time only exists under haiku + scenes), and the bill computed live from the JSON.

## 7. Privacy

- **What leaves, under haiku.** Up to 24 (48) downscaled frames and the transcript of each described post, to Anthropic, under the
  owner's own API key, routed through the owner's AI Gateway. Not the file, not the link's cookies, nothing about other posts except
  the list of tag words.
- **What Anthropic keeps.** Inputs and outputs are deleted within 30 days; flagged content can be kept up to 2 years; nothing is
  used for training without permission. Zero data retention exists but is arranged with Anthropic's sales team per organisation; a
  personal account cannot switch it on. Cloudflare's own zero-retention routing applies only to unified billing, and Haiku 5.5 is
  not in that catalog yet. So **today there is no zero-retention path to Haiku for this deployment**, and this document does not
  pretend otherwise. The Batch API would add 29 days of storage at Anthropic; one more reason not to use it.
- **AI Gateway logs** would store every frame sent. Requests carry `cf-aig-collect-log-payload: false`: the gateway keeps tokens,
  cost and status, not content.
- **Switches.** Global: `off`, `on cloudflare`, `with haiku`. Per post: `never describe this` and `keep this one on cloudflare`.
  A default by source (lane; owner question 1): **saved links go to Haiku** (they were public posts on Instagram or X), **the
  owner's own uploads stay on Cloudflare** unless he says otherwise. The library's public/private switch is about hosting a file,
  not about this, and is deliberately not the rule.
- **"On cloudflare" means it.** Frames from the container to private R2, Whisper, the vision model and the embeddings on Workers AI,
  vectors in Vectorize, text in D1. No third party.
- Kept frames live in the private bucket and are served only through a keyed route. (The poster of a private video is public by an
  earlier owner decision; frames do not follow it.)
- The Anthropic key is a Worker secret from `~/.config/cobalt/secrets.json`, like every other secret here, read by the Workflow
  only. It never enters a container.

## 8. Failure modes

| what goes wrong | what happens |
|---|---|
| ffmpeg cannot read the file (HEIC, a damaged upload, an animated WebP with no original) | `skipped`, `error.insight.unsupported`; not retried until the version changes |
| Whisper fails, or returns noise over music | the describe goes ahead without a transcript; `audio` comes from the model |
| Haiku is overloaded, rate-limited, or times out | the describe step retries with backoff (5 tries over about 10 minutes), then `failed`; frames are kept, so `try again` is cheap |
| Haiku declines (explicit or otherwise refused content) | `refused`. With the owner's say-so (question 3) the post is described on Cloudflare instead; otherwise `haiku wouldn't describe this one.` |
| the answer is cut off (`max_tokens`) | one retry with double the limit, then `failed` |
| valid JSON, poor content (two tags, a title in capitals) | normalised on the server; fewer than 3 usable tags is stored as is. Quality is a prompt problem and the version bump is the tool |
| a caption or transcript tries to instruct the model | no tools, a fixed schema: the worst case is wrong tags on that one post |
| a request would pass 100,000 tokens | cannot happen at the caps (largest: about 24,000); asserted before sending, since passing it silently costs 5x |
| AI Gateway is down | retried; a setting allows calling Anthropic directly |
| Vectorize write fails or lags | the index step retries; D1 already has the text; `POST /insight/backfill` can rebuild the index |
| the post is deleted while being described | the last step finds no row and removes what it wrote |
| spend runs away (a loop, a bulk import) | `daily_cap` describes a day (default 200, about 27 cents), a spend limit on the Anthropic key, a spend rule on the gateway |
| the describer's container will not start | the frames step retries, then `failed`; saves are unaffected, which is the point of 4.5 |
| Haiku 5.5 is retired | not before 2027-10-07 (Anthropic's stated date); the model id is one constant and a version bump |

## 9. Cost model

Prices are verified; token counts, timings and shares are estimates. The JSON marks each one.

### 9.1 The formula, per video of `d` seconds

```
frames  n = min(max, max(min, ceil(d / every)))
input     = 1,200 (instructions + schema) + 80 (the post's facts)
          + n x (image tokens + 8)                      image tokens: ceil(w/28) x ceil(h/28) = 448 at 432x768
          + 0.5 x 4.3 x d                               half the seconds carry speech, 4.3 tokens a second
output    = 450 (+ n x 0.5 x 40 with scenes)            thinking off
describe  = input x $0.10/M + output x $0.50/M          cloudflare only: 280 tokens an image, $0.10/M and $0.30/M
whisper   = d / 60 x $0.000513
embed     = (400 + transcript tokens up to 2,000 [+ 40 a scene]) x $0.012/M
ffmpeg    = 4 + 1.5 x n + 0.02 x d seconds, x $0.00000778 a second (a quarter vCPU, 1 GiB, 4 GB at list)
vectorize = $0 (0.28 M stored dimensions against 10 M included)
```

| a video of | 8 s | 30 s | 43.7 s (the average) | 60 s | 2 min | 7 min 11 s (the longest) |
|---|---|---|---|---|---|---|
| cloudflare only | $0.0005 | $0.0008 | $0.0010 | $0.0012 | $0.0019 | $0.0046 |
| haiku watches (frames) | $0.0007 (4) | $0.0011 (8) | **$0.0014 (11)** | $0.0018 (15) | $0.0028 (24) | $0.0056 (24) |
| haiku + scenes (frames) | $0.0007 (4) | $0.0017 (15) | $0.0023 (22) | $0.0030 (30) | $0.0047 (48) | $0.0075 (48) |

For a long video the transcription costs more than the watching: of the $0.0056 for the longest clip, $0.0037 is Whisper.

### 9.2 Backfill, bucket by bucket (haiku watches, standard API, list price)

Per-video lengths are not in hand, only the buckets, so frames per bucket are `videos x min(24, max(4, average / 4 + 0.5))`; the
`+ 0.5` stands in for the ceiling. It is exact for the first and last bucket (every video sits on the floor or the cap) and an upper
bound for the 1 to 3 minute bucket.

| bucket | videos | seconds | frames | input tokens | output tokens | describe | whisper | ffmpeg | total |
|---|---|---|---|---|---|---|---|---|---|
| under 15 s | 62 | 530 | 248 | 193,588 | 27,900 | $0.0333 | $0.0045 | $0.0049 | $0.0431 |
| 15 to 30 s | 39 | 836 | 228.5 | 155,913 | 17,550 | $0.0244 | $0.0071 | $0.0040 | $0.0357 |
| 30 to 60 s | 27 | 1,175 | 307.3 | 177,192 | 12,150 | $0.0238 | $0.0100 | $0.0046 | $0.0386 |
| 1 to 3 min | 22 | 2,116 | 528 | 273,477 | 9,900 | $0.0323 | $0.0181 | $0.0072 | $0.0577 |
| 3 min and over | 12 | 2,166 | 288 | 151,345 | 5,400 | $0.0178 | $0.0185 | $0.0041 | $0.0405 |
| **162 videos** | 162 | 6,823 | 1,600 | 951,515 | 72,900 | $0.1316 | $0.0583 | $0.0248 | **$0.2157** |
| 25 still photos | | | 25 | 58,100 | 11,250 | $0.0114 | | $0.0011 | $0.0126 |
| 4 galleries (15 photos) | | | 15 | 20,780 | 1,800 | $0.0030 | | $0.0003 | $0.0033 |
| **everything** | | | 1,640 | 1,030,395 | 85,950 | $0.1460 | $0.0583 | $0.0261 | **$0.2316** |

The first row, written out: input = 62 x 1,280 + 248 x 456 + 0.5 x 4.3 x 530 = 79,360 + 113,088 + 1,140 = 193,588 tokens, which is
$0.0194; output = 62 x 450 = 27,900 tokens, $0.0140; together $0.0333. Whisper = 530 / 60 x $0.000513 = $0.0045. ffmpeg = 62 x 4 +
248 x 1.5 + 530 x 0.02 = 631 s x $0.00000778 = $0.0049. (Totals include $0.0011 of embeddings.) The 46 webps are renditions of posts,
not things to describe. 191 describes are priced against 172 posts because the counts are files; it is an upper bound.

The same table for the other two is in the JSON (`computed.results.options.*.buckets`): cloudflare only is $0.1484 for the videos
and **$0.1587** in all; haiku + scenes is $0.3243 and **$0.3402**.

### 9.3 With prompt caching, with the Batch API

| backfill | cloudflare only | haiku watches | haiku + scenes |
|---|---|---|---|
| standard | $0.1587 | $0.2316 | $0.3402 |
| + prompt caching (9 of 10 requests read the cached instructions) | n/a | $0.2136 | $0.3222 |
| Batch API | n/a | $0.1586 | $0.2212 |
| Batch API + caching | n/a | $0.1496 | $0.2122 |
| **what a bill would show** (Anthropic tokens + neurons past the free 10,000 that day) | **$0.03** | **$0.15** | **$0.24** |

**Do not use the Batch API** (lane): it saves 7 to 12 cents once, takes up to 24 hours, stores the requests for 29 days, and is not
confirmed to pass through AI Gateway. **Caching is fine for the backfill and pointless day to day**: 17 saves a day are rarely within
five minutes of each other, and a cache write nobody reads costs 25% more than no cache. It moves the result by under 2 cents either way.

### 9.4 Every month

A new save is priced as the average post of today's library, plus 20 s of idle container around each describe.

| saves a day | posts a month | cloudflare only (list / bill) | haiku watches (list / bill) | haiku + scenes (list / bill) |
|---|---|---|---|---|
| 5 | 152 | $0.16 / $0.00 | $0.23 / $0.13 | $0.32 / $0.21 |
| **17** | **517** | $0.56 / $0.00 | **$0.78 / $0.44** | $1.10 / $0.72 |
| 50 | 1,522 | $1.64 / $0.00 | $2.29 / $1.29 | $3.25 / $2.11 |

At 17 a day the haiku pipeline's list price is $0.44 Haiku, $0.18 Whisper, $0.16 container, under a cent of embeddings; Workers AI
use is about 530 neurons a day against 10,000 free. Fixed costs: none new. Workers Paid ($5) is already paid; Vectorize, Workflows,
D1 and R2 stay inside their included amounts (Vectorize's 10 million stored dimensions last about 6,200 posts on two vectors a post,
a year at this rate, and about 960 posts with scenes; past that it is $0.05 per 100 million). Searching is free at any plausible
volume: a query embeds a dozen tokens.

### 9.5 How long the backfill takes

The describing itself is seconds a post and runs in parallel; the queue is ffmpeg. At an estimated 4 s + 1.5 s a frame + 0.02 s a
second of video:

| | cloudflare only | haiku watches | haiku + scenes |
|---|---|---|---|
| ffmpeg in all | 40 min | 56 min | 90 min |
| **on its own instance** (recommended, 4.5) | about 40 min | **about 56 min** | about 90 min |
| **sharing the single helper slot**, one start per 5 s sweep pass, nobody using the app | about 56 min | **about 72 min** | about 106 min |

Sharing the slot also means stopping whenever a save, render or poster wants the helper, so "an evening" is the honest answer there.
The 1.5 s a frame comes from the README's "a second or two of ffmpeg" for one poster; if it is 3 s, add about 41 minutes to the
middle column. Nobody has timed a run of 24 seeks on the quarter-vCPU instance.

### 9.6 Sensitivity (haiku watches backfill, base $0.2316)

| change | backfill | x |
|---|---|---|
| frames at 512 px (209 tokens) | $0.19 | 0.83 |
| half the frames (1 per 8 s, at most 12) | $0.20 | 0.84 |
| speech in every second, not half | $0.23 | 1.01 |
| ffmpeg takes 3 s a frame | $0.25 | 1.08 |
| instructions twice as long | $0.25 | 1.10 |
| thinking left on (+400 output tokens) | $0.27 | 1.16 |
| square frames (784 tokens), or 1024 px (777) | $0.28 | 1.23 |
| twice the frames (1 per 2 s, at most 48) | $0.31 | 1.34 |
| answers three times as long | $0.32 | 1.37 |
| frames at 1568 px (1,792 tokens) | $0.45 | 1.93 |

Nothing on the list moves the backfill past 50 cents. The only way to make this expensive is a request over 100,000 tokens (5x),
which the frame cap rules out, or a model a tier up: the same backfill on Sonnet 5.5 ($2 / $10) would be about $3.

## 10. If it is built: waves and ownership (sketch)

| wave | lane | owns | pinned by |
|---|---|---|---|
| 0 | contract | section 20 into `APP-API-CONTRACT.md`, `d1/migrations/0010_insight.sql`, a migration test | sections 4.8, 5 |
| 1 | frames | `api/helper/{lib,server}.js` (`/frames` job: start, poll, fetch, delete), `supervisor.js` helper-only mode, tests | `Cut` (4.9) |
| 1 | pipeline | new `api/src/insight/*.ts` (workflow, describers, prompt, schema, embed, index), `cloudflare.config.ts` bindings | `InsightDoc`, `Describer`, `FrameSource` |
| 1 | routes | new `api/src/insight-routes.ts`, a hook in `worker.ts` and `gate.ts`, the delete path in `app-routes.ts`, the trigger line in `studio.ts` | section 5 |
| 2 | kit | `CobaltKit` models, client, preview data | section 5 |
| 2 | app | search results, the `about` block, settings, the intent | section 6 |
| 3 | measure | a 10-clip side-by-side of the two describers; token counts from real usage; the timings of 9.5 | section 12 |

Wave 1's three lanes share no file. The trigger in `studio.ts` is one line next to the poster's and belongs to the routes lane alone.

## 11. Owner questions (the default applies unless the owner says otherwise)

1. **May private frames go to Anthropic?** Default: saved links yes, the owner's own uploads stay on Cloudflare, either can be
   overridden per post. (The alternatives: everything to Haiku; nothing leaves, cloudflare only.)
2. **Which pipeline to start with?** Default: haiku watches, with a ten-clip side-by-side against the Workers AI model before the
   backfill is run, since that test costs about a cent and could make the answer "cloudflare only".
3. **When Haiku declines a post, describe it on Cloudflare instead?** Default: yes.
4. **Suggested titles: offer, or apply?** Default: offer (`use "…"`). Applying them to every post without a custom title is one
   setting away and changes every card in the library.
5. **A second container instance for the describer?** Default: yes (4.5). The alternative is sharing the helper at the lowest priority.
6. **Describe automatically on every save?** Default: yes, capped at 200 a day; `off` describes only when asked.
7. **Run the backfill?** Default: after question 2, one run, all 172 posts, about 15 cents and about an hour.
8. **Scene captions?** Default: off at first; turn on per the owner's taste once search is in daily use (about 30 cents more a month).

## 12. Not verified

- **No model has been run on any clip.** Every token count (instructions 1,200, answer 450, 4.3 a second of speech, half the
  seconds carrying speech, 9:16 frames) is an estimate. The remedy is `messages.countTokens` on the real prompt and the usage the
  API returns on ten real clips.
- **Quality**, for both describers: how well Haiku 5.5 reads small on-screen text at 768 px, and whether the Workers AI model
  returns usable tags from 12 frames in one request. How Workers AI vision models take several images, and what an image costs
  them in tokens (280 is a guess), is not on the pages read.
- **That Haiku 5.5 is in the high-resolution image tier** is read from "Claude 4.7 and later models", not from a Haiku 5.5 row. It
  does not change the cost at 768 px.
- **Turning thinking off on Haiku 5.5** comes from the Claude API reference bundled with Claude Code (cached 2026-10-06), not a
  page fetched today.
- **AI Gateway**: that the Batch and Files endpoints pass through; that Haiku 5.5 will reach Cloudflare's catalog (and with it
  unified billing and Cloudflare-side zero retention); which header an authenticated gateway wants (the provider page shows both
  `cf-aig-authorization` and `Authorization`).
- **bge-m3's 1,024 dimensions** (from the model card, not the Cloudflare page); `queryById` on Vectorize (not on the pages read;
  the fallback is fetching the vector and querying with it); what Whisper on Workers AI accepts beyond the documented `audio` field,
  and its size limit.
- **ffmpeg timings** on the `basic` instance (4 s + 1.5 s a frame is inferred from the README's poster note), the idle seconds
  around a describe, and the cold start of a second instance.
- **The deploy**: a Workflow, a second container class, the AI and Vectorize bindings are in the installed tool's types and have
  never been deployed from this repo. Media Transformations' post-beta billing date and its limits through the binding (the 100 MB
  and 10 minute limits are from the URL form's page).
- **The account's current usage** against the included container hours and the free neurons; "out of pocket" assumes there is room.
- **How the pages were read.** Anthropic's pricing and batch rows were read from the raw page text. The Cloudflare pages were
  read through a fetch tool that summarises a page with a small model, so each Cloudflare number is a faithful-looking extract, not
  a copied table row. Three were cross-checked by arithmetic and agree (Whisper 46.63 neurons x $0.011 / 1,000 = $0.000513 a minute;
  gemma and bge-m3 the same way, pricing page against model page). Before money depends on one, open its `source_url`.
- **The production numbers** were passed to this lane as read from D1 on 2026-10-10 and were not re-queried. How many posts have
  only a webp and no original (and so cannot be described) is not known.
- The descriptions in any mockup are invented; section 6 says the page must say so.
