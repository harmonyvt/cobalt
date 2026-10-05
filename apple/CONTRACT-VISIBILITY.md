# cobalt for apple: one file per rendition, public or private (owner request, 2026-10-05)

Owner (verbatim): "i noticed that the saved links are private by default? and they have no thumbnail until
made public? this shouldnt be the case and there shouldnt be seperate private and public of the same media
it should just be a toggle if this means cleaning up the data structure and migrating do please".

Additive to `CONTRACT-MEDIA.md`, `CONTRACT-LIBRARY2.md`, `CONTRACT-SHARE-QUICK.md` and
`deploy/cloudflare/APP-API-CONTRACT.md` (this becomes its **section 16**). Code read on 2026-10-05 against the
`apple-app` worktree at `b2813e27f`, uncommitted state included (a CobaltKit lane had `Models/MediaItem.swift`,
`Pipeline/*`, `Store/{OfflineStore,StoredMedia,SharedJobStore}.swift`, `Share/ShareModel.swift`,
`Live/LiveSink.swift` dirty at the time). Production D1 and both R2 buckets were read **read-only** the same day
(10:50-11:00 UTC; SELECT and `cf r2 objects list` only). **One D1 migration (`0008_visibility.sql`, additive),
one keyed toggle route, one keyed migration route, additive response fields, one capability flag. No R2 object
is moved or deleted by the migration.** Marked **(owner)** where the owner asked, **(lane)** for calls made here
and open to review.

---

## 0. What exists today (read and measured, not assumed)

### 0.1 Storage and rows

- Every saved link's original goes to R2 `cobalt-originals` (`originals/<sid>.<ext>`; uploads
  `uploads/<id>.<ext>`) with one `media_items` row (`kind 'private'`, `source 'saved'|'upload'`,
  `bucket 'originals'`) inserted when the save is ready (`api/src/studio.ts:1249-1264`).
- "public share" / host (`POST /studio/<sid>/publish`, `api/src/publish.ts:51-131`; `POST
  /library/items/<id>/publish`, `api/src/app-routes.ts:807-880`; web `itemPublish`, `web/src/library.ts:594`)
  **copies** the original into R2 `cobalt-media` under a new `<10 base62>.<ext>` and inserts a **second row**
  (`kind 'public'`, `source 'host'`, `bucket 'media'`, `url`). Object `cache-control: public, max-age=31536000,
  immutable` (`publish.ts:83`). Both rows land in the same post (same `POST_KEY_SQL`), so the app lists them as
  two files: "private copy" and "mp4 link" (`Models/Library.swift:25-30` roles, `:111-119` pills).
- `public: true` on `POST /studio` / `PUT /studio/upload?public=1` (section 13.2) runs the same copy at save time
  (`studio.ts:1285-1376` `afterReady`/`hostPublic`). The app's link save never sends it
  (`API/HTTPCobaltClient.swift:252-255` `createStudio` sends only `url`); only the share sheet does
  (`HTTPCobaltClient.swift:268`). Absent = private is the pinned server default (13.2).
- `media.capybaraharmony.com` is the **R2 custom domain of `cobalt-media`** (no Worker), and it also serves the
  app's own distribution under `apps/<32 hex>/` (4 `.ipa`, `icon.png`, `source.json`; `deploy/apple/release.sh`),
  edge-cached by Cloudflare (`release.sh:350-354` purges `source.json` with `cf cache purge` after each release).
- Posters (13.3) are public unguessable JPEGs in `cobalt-media`, recorded on the original's row and shared with
  its host copy. Webps are public objects in `cobalt-media` with no private copy.

### 0.2 Why the owner saw "no thumbnail until made public" (the server is not the cause)

- **Server: every original has a poster.** 57 of 57 live originals have `poster` set (query in 0.4); `GET
  /library` sends `poster_url` on the private file and on the post (`app-routes.ts:577`, `:602`).
- **App 1.4 and 1.5 (the owner's phone):** the library card drew only this device's poster or the first frame of
  a *public* file. `RemoteStill.swift` at `59927b0d7` (1.4) says so in its doc comment: "Private-only media have
  neither, and keep their placeholder". 1.5 decoded `poster_url` (`Library.swift:23`) but never drew it
  (`LibraryParts.swift:132-136` at `9512de9f6`: local posters only). The owner's iPhone (`iPhone16,2`) last sent
  telemetry as **1.4 (5) at 09:32 UTC** today; 1.6 (7) was published at 10:45 UTC.
- **App 1.6 (current branch):** the library is fixed (`LibraryParts.swift:93-112` `FaceChain` reads
  `face.posterURL ?? item.post?.posterURL`), but the **detail hero still is not**: for a video this device does
  not hold, `RenditionHero` builds `RemoteHero(poster: nil, …)` (`RenditionHero.swift:24-26`) and `HeroRemote`
  takes its still only from a webp URL or the hosted mp4 (`RenditionHero.swift:47-62`); the evicted-local branch
  passes the local record's poster only (`RenditionHero.swift:459`). `Rendition.posterURL` (the server poster,
  `MediaItem.swift:142`) is never read there. Hosting adds `hosted.url`, so a frame appears: exactly "no
  thumbnail until made public".

### 0.3 Why saves are private

The app's link save and upload never ask for public (0.1), and the server default for an absent flag is private
(13.2, kept for API clients). Only the share sheet asks. Sessions: 58 link saves, **1** asked for public.

### 0.4 Production data (D1 `cobalt-keys` and both buckets, read 2026-10-05 10:50-11:00 UTC)

| what | count | bytes |
|---|---|---|
| live `media_items` rows | 92 | |
| originals (`bucket 'originals'`): `saved` / `upload` | 57 (53 / 4), all `video/*`, **57 with a poster** | 316,853,857 |
| host copies (`source 'host'`, live) | 6 (all `video/mp4`) | 18,733,827 |
| webps (`studio` 27 + `webp` 2) | 29 | 45,061,126 |
| posts (live) | 59 | |
| posts: original only / original + webps / original + host / original + host + webps / webps only | 30 / 21 / 5 / 1 / 2 | |
| host rows matched to exactly one live original (by the session's `r2_key`), **same byte count, same poster** | **6 of 6** (5 `saved`, 1 `upload` via `upload:<id>` session) | |
| host rows unmatched / several hosts for one original / objects missing / size mismatch | 0 / 0 / 0 / 0 | |
| `cobalt-media` objects | 98 = 57 posters + 29 webps + 6 host mp4 + 6 `apps/…` | 95,907,165 |
| `cobalt-originals` objects | 57 = the 57 originals (none orphaned, none missing) | 316,853,857 |
| objects with no row (besides `apps/`) / rows with no object | 0 / 0 | |
| `media_titles` rows | 0 | |
| private-only originals (would stay private, owner question 1) | **51** | 298,120,030 |

The six pairs (host row → original row, mirror object, etag today):

| host row | original row | public object | etag |
|---|---|---|---|
| `DkvzGUb1UhW7ARDq` | `mkudC5urEwe5bHqT` (saved) | `2k13zJWqF3.mp4` | `f5b35e9d…2916` |
| `iW7FB0qHNz3KC0cQ` | `3nNlVVe3bxzjVRDC` (saved) | `sXQ4ZhtO4n.mp4` | `1cee506d…57cc` |
| `EnvWklsHwMy2Bt5j` | `7I1TfHWIxZ8IWAhL` (saved) | `z8YAG5VRIc.mp4` | `00ccbc36…94e3` |
| `uFTtcSja7Xiw4XDS` | `ZwuxPrIZDW6qhHW5` (upload) | `Nm9psEx9F9.mp4` | `e8cd477a…1dca` |
| `Y660GlJnxC2cCb9o` | `IsM4eRa7of1XwGN4` (saved) | `IKS2f4xaEP.mp4` | `3d4235a3…0997` |
| `qWkzAhFzs1iVJGyJ` | `JDLkxlG9Aa2R6S0V` (saved) | `fD5Sj8lQyD.mp4` (no object metadata: web-published) | `1e3fd036…4c21` |

---

## 1. Decisions

1. **(lane) Storage: (c) the original stays private and canonical; "public" is a mirror object at a stable public
   name, owned by the same row.** One row per rendition, one file in every list and screen. Toggle on = the
   mirror exists in `cobalt-media` at the row's `public_key`; toggle off = the mirror is deleted and the edge
   cache purged. `media.capybaraharmony.com` stays a plain R2 custom domain.
   - **Why not (a) move the single object between buckets.** Every reader of an original takes it from
     `cobalt-originals` by key: the studio source and renders (`studio.ts:1487`, `:1610`), poster jobs
     (`poster.ts:254`), `GET /library/items/<id>/file` (`app-routes.ts:687-718`), reopen (`:916`), web downloads
     (`web/src/library.ts:599`, `web/src/logs.ts:276`), plus `studio_sessions.r2_key` itself. Moving the bytes
     rewrites the studio Durable Object's hottest paths for no visible gain, and a move is a copy plus a delete
     anyway (R2 has no rename).
   - **Why not (b) one private bucket behind a Worker on the media domain.** It puts code on the most-shared
     path: every Discord embed range request, the Feather `apps/` feed and every webp and poster would go
     through a Worker that must re-implement R2's public serving (Range, `If-None-Match`, `HEAD`,
     content-type, caching) and read D1 per request or cache visibility (which needs the same purge as (c)).
     Its failure mode is the worst one: a bug in the check exposes **every** private original, because they
     would sit in the bucket the public domain reads. The domain swap itself (detach the R2 custom domain,
     attach a Worker route) is a live cut-over for links already on Discord. Cost would be fine at this size;
     risk and blast radius are not.
   - **What (c) costs.** A public video is stored twice (today 18.7 MB; at most the size of the library,
     currently 317 MB, about half a cent a month on R2, inside the free 10 GB). Toggle on is an R2-to-R2 copy
     (the existing `copyToMedia`/`publishStudio` stream copy; seconds for tens of MB). Privacy is physical: a
     private file has no object under the public domain.
2. **(lane) The row is the media file.** `kind`, `bucket`, `r2_key` keep their meaning (where the canonical bytes
   live). New: `visibility` (`'public' | 'private'`), `public_key` (the mirror's key, kept after toggle-off so the
   same link comes back), `public_id` (the id old apps know the public face by), `merged_into` (on a retired host
   row). `url` keeps its meaning, "the public URL, public rows only": it is set exactly while the row is public.
3. **(owner) Public by default for new saves, uploads and shares from the app.** The app sends `public: true`
   (link save, upload `?public=1`, share sheet) when Settings "make new saves public" is on (default on). The
   server default for an absent flag stays private (13.2): the web page, the macOS Shortcut and plain API
   callers keep their behaviour; old apps (which never send it) keep private saves until updated.
4. **(lane) A toggle, with the same link every time.** Off deletes the mirror and purges the edge; the row keeps
   `public_key`, so turning it back on re-copies to the same URL (what a shared link toggle means). Order is
   privacy-first: **off deletes the object before the row says private** (a failed delete leaves a truthful
   "public"); **on copies before the row says public** (never a public row with no file). Every toggle ends
   with one reconcile pass (re-read, re-head, fix once) so racing on/off calls converge.
5. **(lane) Edge cache.** Toggle off purges the URL through the Cloudflare API (new Worker secret
   `MEDIA_PURGE_TOKEN`, a token scoped to Zone > Cache Purge on `capybaraharmony.com`, and text var
   `MEDIA_ZONE_ID`); toggle on also purges (clears a cached 404). New mirrors get `cache-control: public,
   max-age=3600` (not `immutable`), so even a failed purge ends within an hour. The six existing mirrors keep
   their one-year metadata (rewriting them is not worth it): for them the purge is what matters. Not
   revocable by anyone: copies already in a viewer's browser or in Discord's media proxy.
6. **(lane, owner question 2) Webps stay always public, no toggle.** A webp is made to be shared, has no private
   copy, and already has its own delete (`DELETE /media/<name>.webp`). The toggle is on the video (the
   original). Posts with only webps are public.
7. **(owner, 13.3 stands) Posters always, public-unguessable.** Every video original gets one regardless of
   visibility (already true: 57/57); the poster of a private video stays a public unguessable JPEG (owner's
   section 13 decision). The app shows it everywhere a server picture can appear: library (done in 1.6),
   **detail hero** (new, wave U0), table thumbnail, context-menu preview. **(lane, P2)** `isPosterType` also
   takes `image/png`, `image/jpeg` and `image/heic` (a helper 4xx gives up as today), so a private image
   upload not on the device has a picture too (0 in production today).
8. **(lane, owner question 1) Existing private saves stay private.** The migration only merges what is already
   public (6). Nothing is published retroactively without the owner saying so; question 1 offers a one-call
   "make all public" if he wants it.
9. **(lane) Old apps (1.0-1.6) keep working, and see what they see today.** `GET /library` without `v=2`
   answers the legacy shape: a public original is listed as its private file plus a synthesized `host` file
   (`id` = `public_id`, `url`, `kind 'public'`), exactly the pair those builds expect. The old host routes become
   "make public" and stay idempotent; every route that takes an item id also resolves a `public_id`.
10. **(owner, 12 stands) Delete everything deletes everything**: the rows, the originals, the mirrors
    (`public_key`), the posters (refcounted, unchanged), the sessions' originals, the title; and purges the
    mirror URLs.
11. **(lane) The data step is a keyed Worker route, not a script**: `POST /library/visibility/migrate`, dry run
    by default, `limit` per call, idempotent and resumable, with `undo`. The same merge function also runs
    lazily inside the toggle (so the window between deploy and migration cannot mint a second mirror). It
    writes D1 only; it verifies objects with R2 `head` through the bindings; **it never moves or deletes an R2
    object**: both objects of each pair are needed (the original is canonical, the old host object becomes the
    mirror at its existing URL). Retired host rows stay as tombstones (`deleted_at` + `merged_into`): they are
    the rollback record. There is no destructive cleanup step.
12. **(lane) The web library toggles through the API** (service binding to the new route) instead of keeping its
    own copy of the publish code (`web/src/library.ts:561-628`), so purge and reconcile live in one place.
13. **(lane) The library's public/private badge is the video's visibility** (the toggle's state), not "any file
    is public": today a private video with public webps shows the `link` dot (`LibraryView.swift:84`), which is
    the confusion the owner is reporting. Webp-only posts: public.

---

## 2. Data model: `d1/migrations/0008_visibility.sql` (additive only)

```sql
-- One file per rendition, public or private (apple/CONTRACT-VISIBILITY.md, APP-API-CONTRACT.md section 16).
-- Additive only: nullable columns and two indexes. Nothing is rewritten here; the data step is the keyed route
-- POST /library/visibility/migrate. Old code names its columns, so apply this BEFORE deploying the Workers.

-- 'public' | 'private'. NULL = not migrated yet: read as bucket = 'media' -> 'public', else 'private'
-- (every reader uses COALESCE(visibility, CASE bucket WHEN 'media' THEN 'public' ELSE 'private' END)).
ALTER TABLE media_items ADD COLUMN visibility TEXT;
-- For an original (bucket 'originals'): the key in cobalt-media of its public mirror (<10 base62>.<ext>).
-- Kept after the row turns private, so turning it public again gives the same link. NULL = never public.
ALTER TABLE media_items ADD COLUMN public_key TEXT;
-- For an original that is or was public: the 16-base62 id old clients know its public file by (the retired
-- host row's id after the merge; minted at the first publish otherwise). Routes resolve it like an id.
ALTER TABLE media_items ADD COLUMN public_id TEXT;
-- On a retired host row (deleted_at set by the merge, not by a delete): the id of the original it became.
ALTER TABLE media_items ADD COLUMN merged_into TEXT;

CREATE INDEX idx_media_items_public_id ON media_items (public_id);
CREATE INDEX idx_media_items_public_key ON media_items (public_key);
```

Invariants (asserted in tests over every route):

- I1. `visibility = 'public'` ⇔ `url IS NOT NULL`, for every live row after the migration.
- I2. A live `bucket 'originals'` row with `visibility 'public'` has `public_key`, `public_id`, and an object at
  `cobalt-media/<public_key>`; with `'private'`, no object at `public_key` (when set).
- I3. A live `bucket 'media'` row is `'public'` (webps, studio renders, unmerged legacy hosts).
- I4. At most one live row names a given `public_key`; no live row has `bucket 'media' AND r2_key = <some
  original's public_key>` after the merge.
- I5. `studio_sessions.public_url` of every session whose `r2_key` is an original's equals that original's `url`
  (`public_state 'ready'` when public, both `NULL` after a toggle off).

---

## 3. Wire changes (APP-API-CONTRACT.md section 16; everything additive)

### 3.1 `PATCH /library/items/<id>/visibility` (keyed)

- **Gate** (`gate.ts`, in the `/library/items/<id>/<sub>` block next to `post`, `gate.ts:206-226`): sub
  `visibility`, `PATCH` → `lookupThen(req, "library_visibility", { id })`; any other method → 404. `<id>` the
  usual `^[A-Za-z0-9]{16}$`. Auth: `Authorization: Api-Key` or the web Worker's `x-cobalt-service`. No CORS,
  `cache-control: no-store`. Answered by the Worker (D1 + R2); the container and Durable Objects are never woken.
- **Body**: JSON ≤ 256 bytes, an object with `"public": true | false` (extra keys ignored). Anything else →
  `400 error.library.bad_request`, judged before the lookup.
- **Row**: `SELECT … FROM media_items WHERE (id = ?1 OR public_id = ?1) AND deleted_at IS NULL` (unknown →
  `404 error.library.not_found`). `bucket <> 'originals'` (webp, studio render, unmerged legacy host) →
  `409 error.library.not_toggleable`.
- **Lazy merge first**: if the row has no `public_key` and a live legacy `host` row matches it (rule in 4.3),
  run the 4.3 statements for that pair before anything else.
- **On** (`public: true`): `key = public_key ?? "<10 base62>.<ext of r2_key>"`, `pid = public_id ?? <16 base62>`.
  If `MEDIA.head(key)` is missing or its size differs from `bytes`: `ORIGINALS.get(r2_key)` (missing →
  `404 error.library.missing`, row unchanged) → `MEDIA.put(key, body, { httpMetadata: { contentType,
  cacheControl: "public, max-age=3600" }, customMetadata: { mirror: "1", published: "1", itemId, sessionId?,
  keyId, createdAt } })` (throws → `502 error.library.storage`, row unchanged). Then
  `UPDATE media_items SET visibility = 'public', public_key = ?, public_id = ?, url = ? WHERE id = ? AND deleted_at IS NULL`
  and `UPDATE studio_sessions SET public_state = 'ready', public_url = ? WHERE r2_key = ?row.r2_key`; purge the
  URL (best effort).
- **Off** (`public: false`): when `public_key` is set, `MEDIA.delete(public_key)` (throws → `502
  error.library.storage`, row stays public); then `UPDATE media_items SET visibility = 'private', url = NULL
  WHERE id = ?` (`public_key`, `public_id` kept) and `UPDATE studio_sessions SET public_state = NULL,
  public_url = NULL WHERE r2_key = ?`; purge the old URL.
- **Reconcile**: re-read the row; public with no object → copy once more; private with an object → delete once
  more. Then answer.
- **Response** `200 {"status":"success","item":<v2 file (3.3)>,"cache_cleared":true|false|null}`.
  `cache_cleared` reports the purge of a toggle off (`null` when nothing needed purging or the purge is not
  configured, `false` when the API call failed). **Idempotent**: on when on, off when off → `200` with no copy
  or delete. D1 failure before any change → `503 error.api.generic`.
- **Purge**: `POST https://api.cloudflare.com/client/v4/zones/${MEDIA_ZONE_ID}/purge_cache` with `{"files":[url]}`,
  `Authorization: Bearer ${MEDIA_PURGE_TOKEN}`, 3 s cap, success = `success: true`. Injected as `purge?: (urls:
  string[]) => Promise<boolean | null>` so tests and the DO run without it.

### 3.2 `POST /library/visibility/migrate?dry_run=1|0&limit=1..100&undo=0|1` (keyed or service)

The data step (section 4). `dry_run` **defaults to 1**: only an explicit `dry_run=0` writes. `limit` (default 25)
caps the pairs handled per call. Gate: `/library/visibility/migrate`, `POST` →
`lookupThen(req, "library_visibility_migrate")`, else 404. No CORS, `no-store`. Response:

```json
{ "status": "success", "dry_run": true, "undo": false,
  "report": {
    "rows_live": 92, "originals": 57, "hosts_live": 6, "webps": 29,
    "merge": { "pairs": 6, "saved": 5, "upload": 1, "already_merged": 0 },
    "skipped": { "no_original": 0, "several_originals": 0, "several_hosts": 0, "object_missing": 0, "size_mismatch": 0 },
    "after": { "rows_live": 86, "public": 35, "private": 51, "tombstones": 6 },
    "visibility_unset": 92, "posters_missing": 0, "r2_writes": 0, "r2_deletes": 0 },
  "items": [ { "host": "DkvzGUb1UhW7ARDq", "original": "mkudC5urEwe5bHqT",
               "url": "https://media.capybaraharmony.com/2k13zJWqF3.mp4", "action": "merge" } ],
  "remaining": 0 }
```

(the numbers are what today's data must produce; section 4.2.) `action` per item: `merge`, `already_merged`, or
`skip:<reason>`. After the last page (`remaining: 0`) of a `dry_run=0` call, the visibility backfill (4.3 step 4)
runs once.

### 3.3 `GET /library` (5a): `v=2`, `visibility`, legacy synthesis

- **`?v=2`** (the new app sends it when `features.visibility`): one entry per live row. Every file gains
  `"visibility": "public" | "private"` and `"visibility_toggle": <bucket = 'originals'>`; `url` is the public URL
  while public, else `null`; `kind`, `source`, `media_name`, `deletable` unchanged in meaning (an original's
  `media_name` stays `null` and `deletable` `false`: a mirror is never deleted by `DELETE /media`). Each post
  gains `"visibility"`: its original's, else `"public"`.
- **Without `v`** (old apps, old web page): the same rows, plus, for each public original, a **synthesized
  legacy host file** right after it: `{ id: public_id, kind: "public", source: "host", name: <name + "." + ext
  unless it already ends so>, url, content_type, bytes, width, height, duration, created_at, media_name:
  public_key, deletable: false, poster_url }`; the original itself is emitted with `url: null` (as today). The
  new keys (`visibility`, `visibility_toggle`) are present on real files in both shapes (additive).
- Both shapes: post `public_url` = the original's `url` (else the newest live legacy host's, as now);
  `counts.files` counts live rows (86 after the merge; old apps show that number, harmless);
  `usage.public_bytes` = `SUM(bytes)` of live public rows, `usage.private_bytes` = `SUM(bytes)` of live
  `bucket 'originals'` rows (a public original counts in both: it is stored in both).

### 3.4 Sessions, uploads, legacy host routes

- **Session bodies** (`GET /studio/<sid>`, the DO's answers, `GET /studio/recent`): gain `"item_id"` (the live
  `bucket 'originals'` row with `r2_key = session.r2_key`, else `null`) and `"visibility"` (that row's, else
  `null`). `public_state` / `public_url` keep their meaning and are kept in sync (I5).
- **`PUT /studio/upload` 201**: `item` gains the 3.3 v2 keys.
- **`public: true` at save time** (13.2): `hostPublic` (`studio.ts:1314`) and the upload's inline path
  (`app-routes.ts:377-388`) call the 3.1 "on" function on the original's row instead of `publishStudio` /
  `libraryPublish`. Retries, `public:<sid>` records, `public_state` values: unchanged. An **image** upload hosted
  this way is now one post with one file (the 5a "known gap" closes for new uploads).
- **`POST /library/items/<id>/publish`** (5c): an originals row (by `id` or `public_id`) → the "on" function →
  `201 {status, url, bytes, content_type, item_id: <public_id>}` (same shape; a repeat now returns the same link
  instead of making another copy). A `bucket 'media'` row → `409 error.library.already_public` as before.
- **`POST /studio/<sid>/publish`**: resolves the session's original row (as `item_id` above); not found → `404
  error.studio.not_found`; not ready → `409 error.studio.not_ready`; otherwise the "on" function → the same
  `201` shape. (The 7-day expiry no longer refuses it: the row outlives the session.)
- **`GET|HEAD /library/items/<id>/file`, `POST …/studio`, `PATCH|DELETE …/post`** also resolve `public_id`.
- **`DELETE /library/items/<id>/post`** (section 12): for each live row, after its canonical object, also
  `MEDIA.delete(public_key)` when set; then purge the post's public URLs (best effort, never changes the
  `200`/`502` meaning). Tombstones are already `deleted_at` and are skipped; their objects are the mirrors.
- **Capability**: `features.visibility: true` (`app-routes.ts:208-219`). Absent = false: the app keeps the old
  "public share" flow and never sends `v=2`.

### 3.5 Web library (`web/src/library.ts`, `page.html`)

- `GET /api/library` items gain `visibility`, `visibility_toggle`; `filter=public|private` filters on
  `COALESCE(visibility, …)` instead of `kind`; `usage` as 3.3. Tombstones are already excluded (`deleted_at`).
- `POST /api/library/items/<id>/publish` → service call `PATCH /library/items/<id>/visibility {"public":true}`;
  new `POST /api/library/items/<id>/private` → the same with `false` (Origin check as the other POSTs). The web's
  own `copyToMedia`/`itemPublish` copy is deleted.
- `DELETE /api/library/items/<id>` on a public original: the service call with `false` first (deletes the mirror,
  purges), then today's delete.
- Page: one tile per original with a `public` / `private` switch where the publish button was.

### 3.6 Elsewhere

- `scripts/backfill-library.mjs`: an object counts as covered when a row names it in `r2_key` **or
  `public_key`**, or its metadata has `mirror: "1"` (else it would re-add mirrors as `webp` rows).
- `test/poster-delete.test.ts` pins every `.delete(` on a bucket in `src/`: the mirror deletes are added to its
  list with a line saying why.

---

## 4. Migration plan

### 4.1 Order (owner runs every production step; lanes never write production)

1. **Apply `0008`** (from `deploy/cloudflare/web`, the global `cf`):
   `cf d1 migrations apply 42f18bb0-837a-47f7-b1e2-606eb705ab6c --dir ../d1/migrations`. Additive; the running
   Workers keep working on it.
2. **Secrets and var**: add `MEDIA_PURGE_TOKEN` to `~/.config/cobalt/secrets.json`; `MEDIA_ZONE_ID` as a text
   var in `api/cloudflare.config.ts` (lane A1 reads the zone id read-only and writes it there).
3. **Deploy API**, then **web** (the web relays to the new route). From here new public saves are single rows,
   and the toggle lazily merges any pair it touches.
4. **Dry run**: `curl -X POST -H "Authorization: Api-Key <key>"
   'https://api.capybaraharmony.com/library/visibility/migrate?dry_run=1&limit=100'`. Must report exactly 4.2's
   numbers (V checks). Anything in `skipped` stops the plan for a look.
5. **Apply**: the same with `dry_run=0`, repeated until `remaining: 0`.
6. **Verify** (V, 8.3): the six URLs answer `200` with the same etags; `GET /library?v=2` shows 59 posts, 86
   files, 6 public originals with their old URLs; `GET /library` (legacy) shows the 92-file picture old apps
   expect; a second `dry_run=0` reports `already_merged: 6`, nothing else.
7. **App 1.7** ships later (waves K, U). Old builds work throughout (decision 9).

### 4.2 Expected report today (from 0.4; a different number means the data changed or the rule is wrong)

pairs 6 (saved 5, upload 1), skipped 0, after: live rows 86, public 35 (6 originals + 29 webps), private 51,
tombstones 6; posters missing 0; R2 writes 0, deletes 0.

### 4.3 The statements (one D1 `batch` per pair, so a pair is all-or-nothing)

Candidates (the same query drives the dry run, the apply and the toggle's lazy merge):

```sql
SELECT h.id AS host_id, h.r2_key AS host_key, h.url AS host_url, h.bytes AS host_bytes, h.poster AS host_poster,
       o.id AS orig_id, o.r2_key AS orig_key, o.bytes AS orig_bytes, o.source AS orig_source, o.public_key AS orig_public_key
  FROM media_items h
  LEFT JOIN studio_sessions s ON s.id = h.session_id
  LEFT JOIN media_items o ON o.deleted_at IS NULL AND o.bucket = 'originals' AND o.r2_key = s.r2_key
 WHERE h.source = 'host' AND h.bucket = 'media' AND h.deleted_at IS NULL
 ORDER BY h.created_at, h.id;
```

(`s.r2_key` is `originals/<sid>.<ext>` for a saved link and `uploads/<id>.<ext>` for an adopted upload, so one
rule covers both; verified for all six.) Skip reasons, checked in code: no original (`orig_id` null: a host with
no session, e.g. an image hosted from an upload), several originals for one host, several hosts for one original
(the newest is NOT picked: every shared link must keep working, so the pair is left alone and reported),
`MEDIA.head(host_key)` missing, `ORIGINALS.head(orig_key)` missing, a size different from the row's `bytes`.

Per pair (`?1` orig_id, `?2` host_key, `?3` host_id, `?4` host_url, `?5` host_poster, `?6` now):

```sql
UPDATE media_items
   SET visibility = 'public', public_key = ?2, public_id = ?3, url = ?4, poster = COALESCE(poster, ?5)
 WHERE id = ?1 AND deleted_at IS NULL AND bucket = 'originals' AND (public_key IS NULL OR public_key = ?2);

UPDATE media_items SET deleted_at = ?6, merged_into = ?1
 WHERE id = ?3 AND deleted_at IS NULL AND source = 'host'
   AND EXISTS (SELECT 1 FROM media_items WHERE id = ?1 AND public_key = ?2);

UPDATE studio_sessions SET public_state = 'ready', public_url = ?4
 WHERE r2_key = (SELECT r2_key FROM media_items WHERE id = ?1 AND public_key = ?2);
```

Step 4, once after the last page:

```sql
UPDATE media_items SET visibility = CASE WHEN bucket = 'media' THEN 'public' ELSE 'private' END
 WHERE visibility IS NULL AND deleted_at IS NULL;
```

Idempotent: a merged pair fails every guard on a rerun (reported `already_merged`); a pair interrupted mid-batch
never exists (D1 batches are transactions). Resumable: `limit` pages; the state lives in the rows. Titles need
nothing: the post key does not change (both rows were in the same post).

### 4.4 Undo and rollback

- **`undo=1`** (same route, also dry-run by default), per tombstone `T` with `merged_into = O`:
  `UPDATE media_items SET deleted_at = NULL, merged_into = NULL WHERE id = T AND merged_into = O;` then
  `UPDATE media_items SET url = NULL, public_key = NULL, public_id = NULL, visibility = NULL WHERE id = O AND public_id = T;`
  For an original made public by the new code (no tombstone): insert the host row old code expects
  (`INSERT … SELECT o.public_id, 'public', 'host', 'media', o.public_key, o.url, <name.ext>, o.content_type,
  o.bytes, o.width, o.height, o.duration, o.link, COALESCE(o.session_id, (SELECT s.id FROM studio_sessions s
  WHERE s.r2_key = o.r2_key ORDER BY s.created_at DESC LIMIT 1)), o.key_id, ?now, o.poster … WHERE NOT EXISTS
  (… bucket = 'media' AND r2_key = o.public_key)`), then clear its four columns. Private toggles need nothing
  (their mirror is gone and old code agrees the row is private).
- **Code rollback** = `undo=1&dry_run=0` until `remaining: 0`, **then** redeploy the previous API and web. Never
  redeploy old code over merged data first: old `libraryPublish` would see a private original with no host row
  and copy it again.
- `0008` is never reverted (additive; old code ignores the columns).

---

## 5. Backward compatibility

| client | what it does | after this change |
|---|---|---|
| app 1.0-1.3 | `GET /library`, per-webp delete | legacy shape: identical picture (synthesized host files) |
| app 1.4-1.6 | + publish routes, posters, titles, delete post, share sheet `public: true` | legacy shape; "public share" returns the same link on repeat; ids of synthesized files (`public_id`) work on every item route; share-sheet saves become single public rows (they list as private file + host file, as today) |
| app 1.7 | `v=2`, toggle, setting | the new model |
| web library | its own D1 list | updated in the same deploy (A2) |
| studio page, Shortcut, `POST /`, `/webp` | | unchanged (no `public` sent → private, as pinned in 13.2) |
| Feather (`apps/…`) | R2 custom domain | unchanged (no Worker on the media domain) |

---

## 6. App changes

### 6.1 Pinned CobaltKit API (K builds exactly this; U builds against it)

```swift
// Models/Library.swift
public enum Visibility: String, Sendable, Codable, Equatable { case `public`, `private` }
extension LibraryFile {
    public var visibility: Visibility          // stored; `visibility`, else derived from `kind` (legacy server)
    public var canToggleVisibility: Bool       // stored; `visibility_toggle` ?? false
    public var isPublic: Bool { visibility == .public }
}
extension LibraryPost { public var visibility: Visibility? }   // stored; nil from a legacy server
// LibraryFile.Role is unchanged: `.privateCopy` now means "the original" (private or public); doc comment
// updated, name kept (dozens of call sites across Kit, UI and tests; a rename is not worth the churn).
public struct VisibilityChange: Sendable, Equatable { public let file: LibraryFile; public let cacheCleared: Bool? }

// Models/MediaItem.swift (Rendition)
public var visibility: Visibility?             // .video: the original's when the server lists it; .public when only a
                                               // hosted link / local publicURL is known; nil when local only. .webp: .public with a URL
public var canToggleVisibility: Bool           // .video whose server original says `visibility_toggle`
// merge: when the post's original file carries a v2 visibility, the video's publicURL is that file's url when
// public and nil when private (a stale local StoredVideo.publicURL never wins); otherwise today's rule
// (hostedFile?.url ?? original?.publicURL). posterURL unchanged (hosted ?? private copy).

// Models/Server.swift
public var visibility: Bool = false            // features.visibility

// API/Client.swift (+ HTTPCobaltClient, PreviewClient)
func setVisibility(item id: String, public: Bool) async throws -> VisibilityChange          // PATCH …/visibility
func createStudio(link: URL, public: Bool?) async throws -> StudioCreated                   // nil = field omitted
func upload(file: URL, name: String, contentType: String, public: Bool?, progress: …) async throws -> UploadResult  // ?public=1
func library(limit: Int, cursor: String?, v2: Bool) async throws -> LibraryPage            // v=2 when caps.visibility
// StudioSession gains `itemID: String?` (`item_id`) and `visibility: Visibility?`
// ErrorMap: error.library.not_toggleable, error.library.storage, error.library.missing → PipelineFailure cases

// Store/Settings.swift (app group, so the share extension reads it)
public var newSavesPublic: Bool                // key "save.newSavesPublic", default true

// Models/AppModel+Media.swift
/// Optimistic: the library's file and the device's record (StoredVideo.publicURL set / cleared) flip at once;
/// reverts and rethrows on failure; refreshes that post on success.
public func setVisibility(_ item: MediaItem, public: Bool) async throws -> VisibilityChange
public private(set) var visibilityInFlight: Set<String>    // media ids
```

Where `public` is sent: the link save (`Pipeline` create), uploads, and `shareSaveRequest`
(`HTTPCobaltClient.swift:268`, today hard-coded `true`) all send `settings.newSavesPublic` when
`caps.publicDefault`; nothing otherwise. A server without `features.visibility` keeps today's "public share"
(Pipeline host flow); the toggle-off path does not exist there. `LibraryRow.isPublic` (`LibraryView.swift:84-89`)
becomes the video rendition's visibility when the media has a video, else "any public file" (decision 13).

### 6.2 UI (U)

- **U0 (now; no Kit change): detail hero picture chain** = this device's poster → `rendition.posterURL` (server)
  → the first frame of a public file → the gradient. `RenditionHero` passes `rendition.posterURL` where it passes
  `nil` today (`:24-26`), and the evicted branch uses `video.posterURL ?? rendition.posterURL` (`:459`);
  `RemoteStill.swift`'s doc comment loses "Private-only media … keep their placeholder".
- **Detail, video tab** (`DetailActions`): when `rendition.canToggleVisibility`, a `VisibilityRow` under the
  secondary row replaces `public share`: a `Toggle` "public link" (`link` / `lock` symbol); under it, when public,
  the link (selectable, middle truncation) and "anyone with the link can watch it."; when private, "only you can
  see it.". `copy video link` stays in the secondary row while public. Turning **on**: the switch moves at once,
  the row shows "making the link…" and is disabled until the answer; failure: back off, inline "couldn't make
  the link. it's still private.". Turning **off**: `confirmationDialog` "turn off the public link?", message
  "links you shared stop working. turning it back on brings back the same link.", destructive "turn off", cancel
  "keep it public"; then, if `cacheCleared == false`, the footnote "it may keep loading for a little while where
  it was already opened.". Without the capability: today's `public share` button.
- **Library**: tile and iPhone row badge = `link` dot when public, `lock` dot when private (decision 13); table
  `public` column and the `public` / `private` filters use the same value; context menu gains "make public" /
  "make private…" (same confirm) when the video can toggle.
- **Settings**: a "sharing" section with `Toggle` "make new saves public" (default on), footnote "new saves,
  uploads and shares get a public link right away. you can turn it off for each one." Shown when
  `caps.publicDefault`.
- Copy lives in new `Design/Copy+Visibility.swift` (lowercase, exactly as above).

---

## 7. Lanes, waves, ownership

| wave | lane | owns (writes only these) | done when |
|---|---|---|---|
| W1 | A1 · API (`sonnet-lane`) | new `deploy/cloudflare/d1/migrations/0008_visibility.sql`, new `api/src/visibility.ts` (on/off/reconcile, candidates + merge + undo, file shapes, purge); `api/src/{app-routes,publish,studio,library,gate,worker,index,poster}.ts`; `api/cloudflare.config.ts` (`MEDIA_ZONE_ID`); new `api/test/{visibility,visibility-migrate,migration-0008}.test.ts`; edits to `api/test/{library,gate,worker,public-default,poster-delete,titles,studio-fakes,migration-0006}.test.ts`; `APP-API-CONTRACT.md` section 16 (from section 3 here); `deploy/cloudflare/README.md` | `cd deploy/cloudflare/api && npm test && npm run typecheck`; `cf deploy --dry-run` |
| W1 ‖ | A2 · WEB (`sonnet-lane`) | `deploy/cloudflare/web/src/library.ts`, `web/src/library/page.html` (+ regenerated `page.generated.ts`), `web/test/**`; `LIBRARY-CONTRACT.md` addendum | `cd deploy/cloudflare/web && npm test && npm run typecheck`; the service call mocked against 3.1's pinned shape |
| W1 ‖ | A3 · SCRIPT (`sonnet-quick`) | `deploy/cloudflare/scripts/backfill-library.mjs`, `api/test/backfill.test.ts` | covered-by-`public_key`/`mirror` cases green |
| W1 ‖ | U0 · HERO (`sonnet-quick`) | `apple/Cobalt/Screens/Detail/{RenditionHero,…}.swift` hero chain only, `Screens/Library/RemoteStill.swift` (comment) | the 4 Apple gates; preview of a private-only, not-on-device video showing its server poster |
| W1.5 | V0 · REPLAY (`sonnet-lane`) | none (evidence) | 8.2 |
| owner | deploy | 4.1 steps 1-6 | V1 green |
| W2 (after the in-flight CobaltKit lane lands: it owns `Pipeline/*`, `Store/*`, `Share/*`, `Models/{AppModel,MediaItem}.swift` today) | K · KIT (`sonnet-lane`) | `CobaltKit/Sources/CobaltKit/Models/{Library,MediaItem,LibraryModel,LibraryView,Server,Wire,AppModel+Media}.swift`; `API/{Client,HTTPCobaltClient,ErrorMap}.swift` (+ new `HTTPCobaltClient+Visibility.swift`); `Store/{Settings,OfflineStore}.swift`; `Pipeline/PipelineFlows.swift` (the `public` flag only); `Share/*` (the share request's flag only); `Preview/*` (public/private/legacy fixtures, `.visibilityFails`); `CobaltKit/Tests/**` (new files + the fixtures that assert roles) | 6.1 compiles iOS + macOS; 8.1 K tests green |
| W3 | U · UI (`sonnet-lane`) | `apple/Cobalt/Screens/Detail/{DetailActions,DetailController,DetailMenu,DetailLayouts}.swift`, new `Detail/VisibilityRow.swift`; `Screens/Library/{LibraryParts,LibraryTile,LibraryTable,LibraryMenus,LibraryController,LibraryPreviewData}.swift`; `Screens/Settings/SettingsScreen.swift` + new `Settings/SharingSettingsSection.swift`; new `Design/Copy+Visibility.swift`; `Design/Symbols+Media.swift` | gates; previews and V2 evidence |
| W4 | V2 · VERIFY (`sonnet-lane`) | none | 8.3 app half |

Not touched: `api/**`, `web/**` upstream; `deploy/apple/**`; the R2 buckets' configuration; the media domain.
No lane commits, pushes, deploys, applies a migration or writes production.

---

## 8. Gates, tests, evidence

### 8.1 Tests

- **A1** (real SQL on `node:sqlite` over every migration, fake buckets with `head/get/put/delete`, injected
  purge): `0008` applies over data and is only `ADD COLUMN`/`CREATE INDEX`; toggle on (copy, URL, session sync,
  same key and URL on the second on, no copy when present, missing original 404, put throws 502 row unchanged);
  off (delete before flip, delete throws 502 row still public, `cache_cleared` true/false/null, public_key kept);
  reconcile after an interleaved on/off; webp/studio/legacy host → 409; `public_id` resolves on every item
  route; lazy merge inside the toggle; I1-I5 after every operation; `GET /library` v2 and legacy shapes
  (synthesized file fields, ids, counts, usage) on a fixture that copies 0.4's six pair shapes (5 saved, 1
  upload via `upload:<id>`); migrate: dry run writes nothing, report numbers, limit paging, rerun
  `already_merged`, every skip reason, batch atomicity (a failing statement leaves the pair untouched), visibility
  backfill, `undo` restores the exact pre-merge rows (byte-for-byte row comparison) including a new-code public
  original; `public: true` on save and upload (video and image) makes one row; legacy publish routes return the
  same link on repeat; delete-post deletes mirrors and purges; `poster-delete` list updated; `features.visibility`.
- **A2**: list shape and filters by visibility, publish/private relays, delete of a public original calls off
  first, the page's switch (asserted as text, like 15.6).
- **K**: decode v2 and legacy (synthesized host) payloads into one video rendition each; merge rule (server
  visibility beats a stale local `publicURL`); `setVisibility` optimistic, revert on failure, store record
  updated; `newSavesPublic` default and app-group persistence; the `public` flag sent only with
  `caps.publicDefault`; `LibraryRow.isPublic` = video visibility.

### 8.2 V0 replay (before the owner deploys)

`cf d1 export 42f18bb0-837a-47f7-b1e2-606eb705ab6c --output <scratchpad>/prod.sql` (read-only export; a 324 KB
database) → load into `node:sqlite` with `0008` applied → run A1's migrate (dry run, then apply) against fake
buckets seeded from `cf r2 objects list` → assert 4.2's numbers, I1-I5, both list shapes, and `undo` back to the
exported rows. Save the report JSON and the before/after counts.

### 8.3 Evidence after deploy (V1 server half; V2 app half; saved to a session path)

- dry-run JSON = 4.2; apply JSON; rerun = `already_merged: 6`.
- `curl -sI` each of the six URLs: `200`, the etags in 0.4 unchanged.
- `GET /library?v=2&limit=50` (2 pages): 59 posts, 86 files, 6 public originals with those URLs, every original
  with `poster_url`; `GET /library` legacy: the same posts with 92 files.
- On a **test upload made for this with the e2e key** (never the owner's media): on → URL 200; off → URL 404
  and `cf-cache-status` not `HIT`, `cache_cleared: true`; on → the same URL 200; delete post → 404.
- App (simulator, preview data and a real fork read): library tile of a private-only video with its server
  poster and the `lock` dot; detail hero of a not-on-device private video with the poster (U0); toggle on →
  link row; off → confirm → private; Settings section; a 1.6 build against the new server shows today's
  picture (legacy shape).

Gates (every lane; Fable reruns): the four Apple commands (`xcodegen generate`; iOS build on iPhone 17 Pro / iOS
26.5; macOS build; `cd apple/CobaltKit && swift test`) for K/U/U0; `npm test && npm run typecheck` in `api` and
`web` for A1/A2/A3.

---

## 9. Risks

- **A revoked link keeps loading somewhere.** The edge purge needs the new token; without it, a mirror from
  before this change (`immutable`, one year) could be served from Cloudflare's edge until evicted. New mirrors
  cap that at an hour. Browsers and Discord's proxy keep what they already fetched; nothing can revoke that.
  The off confirmation says links stop working, not that every copy disappears.
- **Toggle on for a large file** is an in-request R2 copy (up to the 200 MB save cap). A client that gives up
  mid-copy leaves no row change (R2 puts are all-or-nothing) and the retry is idempotent. Not measured on a
  large file in production.
- **Deploy order.** Old code over merged data re-copies on "public share" (4.4); rollback must undo first.
  Between deploy and migrate, the toggle's lazy merge covers the six pairs.
- **`kind` no longer means visibility.** Every reader that used it that way is listed (web filter and usage,
  `LibraryView.swift:84`, `LibraryFile.role`), but a reader missed would show a public original as private.
  A1/A2 grep `kind` in `src/` and assert in tests.
- **Default public is a privacy change in the app.** It is the owner's ask, it is visible (Settings, the
  detail's switch), and it never applies to what was saved before (decision 8).
- **`cf d1 export`** may hold the database briefly while it runs (324 KB here; run it outside a save).

## 10. Owner questions (the defaults apply unless the owner says otherwise)

1. **The 51 videos saved privately before today: leave them private, or make them all public once?** Default:
   leave them private (nothing goes public that was not asked to). If "all public": one call per video through
   the toggle (≈ 298 MB copied), run by the owner after the migration.
2. **Should webps get the switch too?** Default: no, webps stay public links (decision 6). Yes means a private
   webp lives in the private bucket and a new "private webp" state across the app; a larger change.

## 11. Not verified here

- Nothing was built or run: no test, no build, no deploy. All code citations are reads of `b2813e27f` plus the
  dirty tree as of 10:50 UTC.
- That the deployed API Worker matches the branch (inferred from `0006`/`0007` applied and posters present).
- Which build the owner was on when he noticed: telemetry shows 1.4 at 09:32 UTC and nothing from 1.5/1.6 yet;
  the 1.6 library fix and the 1.6 detail-hero gap are from reading code, not from running it.
- That a zone purge by URL clears R2 custom-domain cache for mp4s, and whether Cloudflare cached 404s for these
  URLs: inferred from `release.sh:350-373` purging `source.json` on the same domain.
- Real R2-to-R2 copy time for a large file inside a Worker request.
