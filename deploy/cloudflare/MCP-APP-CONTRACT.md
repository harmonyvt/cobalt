# capystore as an MCP app (APP-API-CONTRACT.md section 55)

Owner (2026-11-11): "Add a single MCP server that works as an app in Claude, ChatGPT, and Grok, using the open MCP Apps UI
standard (tools + ui:// HTML widgets)", then "I want studio possibly? the timeline? and like when i convert to webp,
collections, share links and when it uploads files to capystore", then "I want you to implement and delegate please".
Mockup: https://claude.ai/artifact/HULkU9NF2qdercxogPdtDu (source `/mnt/project-files/capystore-mcp-app/mockup.html`).

The existing MCP server (section 35: `POST /mcp`, `POST /mcp/k/<secret>`, the registry's chat ops as tools) stays where it
is, with the same URLs, keys, private link and threads, and no daily render or save cap. Three things change:

1. Its hand-written JSON-RPC core is replaced by the official MCP TypeScript SDK (`@modelcontextprotocol/server` 2.x, the
   successor of `@modelcontextprotocol/sdk`, which is what `@modelcontextprotocol/ext-apps` 2.x pairs with) inside the same
   Worker. Stateless: one server per request, JSON answers, no sessions, no SSE.
2. It gains **app tools**: a few narrow tools that return a text answer plus `structuredContent`, each tied to a widget.
3. It gains **widgets**: `ui://capystore/<view>.html` resources (`text/html;profile=mcp-app`), drawn by hosts that
   support MCP Apps (Claude, ChatGPT). A host that draws nothing (Grok, the xAI API, Claude Code) still gets the text.

Nothing here needs a migration, a new binding or a new secret.

## 1. Files and who owns them

All under `deploy/cloudflare/api/`.

| Files | Owner |
| - | - |
| `src/mcp-app/types.ts`, `src/mcp-app/shapes.ts` (initial version), this document | the main thread |
| `src/mcp.ts`, `src/registry/ops/mcp.ts`, `src/mcp-app/server.ts` (if wanted), `test/mcp.test.ts`, `test/mcp-link.test.ts`, `test/mcp-app-core.test.ts`, `package.json`, `package-lock.json` | **core lane** |
| `src/mcp-app/tools.ts`, `src/mcp-app/tools/**`, `test/mcp-app-tools.test.ts`; may add optional fields to `shapes.ts` | **tools lane** |
| `src/mcp-app/widgets/**`, `scripts/build-widgets.mjs`, `src/mcp-app/widgets.generated.ts`, `test/mcp-app-widgets.test.ts`, `widgets-dev/**` | **widgets lane** |

Lanes never commit or push, never touch another lane's files, and say in their report anything they needed from another
lane. `package.json` belongs to the core lane: another lane that needs a script or a dev dependency names it in its report.

## 2. Seams (`src/mcp-app/types.ts`)

- The core imports `APP_TOOLS` from `src/mcp-app/tools.ts` and `WIDGETS` from `src/mcp-app/widgets.generated.ts`. Both
  exist as empty stubs, so each lane compiles alone.
- An `AppTool` has a zod `input`, a zod `output`, `readOnly`, a `view`, and `run(ctx, input)` returning
  `{ text, structured }`. The core turns that into `{ content: [{ type: "text", text }], structuredContent: structured }`.
  A thrown `OpError` (or any error) becomes `{ content: [text], isError: true }`, worded as the existing tools word it.
- `AppToolCtx.call(callName, input)` runs a registry chat op as the MCP thread, exactly as an existing MCP tool call does
  (same `runOp`, same thread key; no daily render or save cap for MCP calls). App tools are compositions of existing ops plus read-only D1 reads
  through `ctx.op.db`; they are **not** registry ops, so `openapi.json`, the route snapshot and `npm run gen` do not move.
- A `Widget` is `{ view, uri, title, html }`.

## 3. Wire shapes (`src/mcp-app/shapes.ts`)

The zod schemas there are the contract between tools and widgets. Rules:

- Every result carries `view`. Objects are loose. Anything that can be missing is `null`, never absent.
- URLs handed to a widget must be loadable by a browser with no credentials: public `media.capybaraharmony.com` files and
  `share.capybaraharmony.com` links. A private or off post has `thumb_url: null` (the widget draws a placeholder).
  Share links are always `share.capybaraharmony.com` links, never raw media links, wherever a link is for a person.
- The tools lane may add optional (nullable) fields; it lists them in its report. Widgets ignore fields they don't know.

## 4. Tools

The older tools keep their names, except the twelve that the app tools replaced (section 6.3). App tool names must not
collide with the listed older tools.

| Tool | Kind | View | Built on |
| - | - | - | - |
| `search_library` | read | `search` | `library.search` when offered, else `library.list` with `query` |
| `show_post` | read | `post` | `library.post` (+ transcript start, caption) |
| `show_edit` | read | `edit` | `edits.get`, `edits.list` |
| `list_collections` | read | `collections` | `collections.list`, `links.list` |
| `list_share_links` | read | `links` | `links.list`, `collections.list` |
| `convert_to_webp` | write | `webp` | `make.webp` |
| `upload_files` | write | `upload` | `upload.begin` |
| `create_share_link` | write | `links` | `links.create`, `collections.add` |
| `save_link` | write | `save` | `library.save` |
| `job_status` | write (it can move a job on) | none | `jobs.wait` with a short wait; a save by its session |

Inputs (zod, all objects):

Since the migration (section 6.3) each tool also takes every option of the older tool it replaced; all added fields are
optional and the defaults stay widget-sized.

- `search_library { query?: string 1..200, kind?, since?, until? (ISO date or ms), source? (a host), within?, match?:
  "meaning"|"text", limit?: 1..1000 = 12 }`: with no `query` it lists newest first (`mode: "list"`, `query: ""`);
  `mode` is `"meaning"`, `"text"` or `"list"`. `within` (a collection, a link or a list of posts) is meaning search only:
  it errors rather than being ignored while meaning search is off or failing. `match: "text"` forces the title/name/link/
  caption substring match. At most 500 rows by meaning, 1000 by list. Items carry `score`, `why`, `said`, `source_link`
  and `caption` (null when the search did not give them).
- `show_post { id: string }`: every file with `id`, `role`, `name`, `url`, `share_url`, `private_url`, `private_file_url`
  (what `library.post` gave the caller; a hidden post is an error and gives no URL).
- `show_edit { id?: string, query?: string }`: an id, or a title to find; neither, or several matches: `project: null`
  and the list in `projects` (up to 100). A project carries its raw `timeline` (what `edits_update` takes back; its
  `sources`, with names and pictures, are not passed on).
- `list_collections { name?: string, limit?: 1..500 = 20 }`: collections carry `link_ids` and `post_ids`.
- `list_share_links { collection?: string, query?: string, limit?: 1..500 = 20 }`: links carry `post_ids` and a private
  link's `file_urls`.
- `convert_to_webp { id: string, start?: number, end?: number, crop?: {x,y,w,h}, width?: 320|480 = 480, quality?:
  "low"|"med"|"high" = "med" }`: without both `start` and `end` nothing runs and the answer is `state: "pick"` (for a
  source of 10 s or less the whole clip is the default range and it runs).
- `upload_files { files?: [{ name?: string, title?: string }] 1..10, name?, title?, public?: boolean, queue?: boolean }`:
  no `files`: one link; the flat `name` and `title` are the single-file form of `upload_begin`.
- `create_share_link { ids: string[] | string (no tool limit; the op allows 10 files), title?: string, private?: boolean, collection?: string }`
- `save_link { url: http(s) URL, engine?: "auto"|"cobalt"|"ytdlp" = "auto", items?, public?, title?, wait?: 0..60 = 8 }`
  (`auto` leaves the op's engine unset); the answer carries `save_id` and `saves_left_today` (`null`: no cap here).
- `job_status { job: string, seconds?: 0..25 = 8 }`: besides state and post, `file_id`, `post_id`, `queue_ahead`, a finished
  render's `file`, and for a helper (`agent:<id>`) its `agent` report.

Every read tool has `annotations.readOnlyHint: true`; write tools `readOnlyHint: false`, `destructiveHint: false` (they
only add things), and `openWorldHint: false` except `save_link`. `job_status` is visible to the model too, so a host
with no widgets can follow a job. Every tool has `outputSchema` (from `output`) and a `title`.

The **text** must stand alone: a count line, then numbered rows with title, kind, id and (where there is one) the share
link, one compact line each; 10 rows, or as many as the caller asked for with `limit` (cut at `MCP_RESULT_MAX` with the
usual note); for a job, what is running and what the user will get. No JSON dump in the text (the one exception is a
project's timeline, which an agent hands back to `edits_update`).

Not in this step: deletes, status changes, rendering an edit, rerolling links (they stay on the existing tools, marked
`destructiveHint`), and changing a timeline from the chat.

## 5. Widgets

- One bundle, eight views. `scripts/build-widgets.mjs` inlines `src/mcp-app/widgets/` (shared bridge, shared CSS, one
  renderer per view) into self-contained HTML and writes `WIDGETS` (one entry per view, the same bundle with that view as
  the default) to `widgets.generated.ts`. `--check` fails when the generated file is stale, like `gen:check`.
- No framework, no remote script, no remote font. Light and dark from the host's theme (host context), falling back to
  `prefers-color-scheme`. Looks like the mockup.
- The bridge is the MCP Apps one: JSON-RPC over `postMessage` (`ui/initialize`, `ui/notifications/initialized`,
  tool input and tool result notifications, `tools/call`, open link, size changes, host context). Message names and
  shapes come from `node_modules/@modelcontextprotocol/ext-apps` (its spec types), not from memory. `window.openai` is
  used only behind a feature check, and only for what the standard lacks (full screen).
- A view draws from the tool result's `structuredContent` by its `view` field. Buttons call tools through the bridge:
  a tapped post calls `show_post` and the bundle swaps to the post view; the webp view calls `convert_to_webp` with the
  picked range, then `job_status` until done; the save view polls `job_status`; a collection opens `list_share_links`.
- The upload view sends each chosen file with `PUT` straight to its `upload_url` (XHR, for progress) and shows the item
  the PUT answers.
- Copy buttons use `navigator.clipboard` from a click, with a visible fallback (select the text) when it is refused.

## 6. Core: what a host sees

- `initialize`: capabilities `tools` and `resources`; the instructions gain two lines on the app tools.
- `tools/list`: the app tools first, then the older tools that are not retired (6.3). `?tools=app` on the URL lists the
  app tools only (and the retired names do not answer there). An app tool with a view carries `_meta.ui.resourceUri` (and
  the legacy `_meta["ui/resourceUri"]`), as `registerAppTool` writes them; so do the older tools of 6.5.
- `resources/list`, `resources/read`: the widgets, `mimeType: "text/html;profile=mcp-app"`, with `_meta.ui.csp`:
  `resourceDomains` = the media and share origins, `connectDomains` = the API origin (the upload PUT).
  `_meta.ui.domain`: only if a host needs it; if set, it is worked out per request from the URL the host connected to
  (for the private link that URL holds the secret) and only for that host.
- `PUT /mcp/upload/<token>` answers CORS for any origin (the token is the credential; a widget's sandbox origin is not
  knowable ahead of time), with its `OPTIONS` preflight.
- Existing behaviour that must not change: auth and the 401/403/404/405/503 answers, the private link, batches, the
  per-key thread, `look` returning images, result cutting at `MCP_RESULT_MAX`, tool names, input schemas and annotations
  of the older tools that stay listed, `test/route-snapshot.test.ts`.

### 6.3 Retired tools

The chat AI keeps every op; only the MCP stops listing twelve (`MCP_RETIRED_CALLS` in `src/mcp.ts`), because each duplicates
an app tool and models kept picking the old one, which draws no widget. `src/mcp-app/retired.ts` maps each old tool name
to its replacement; a `tools/call` of an old name is answered by that app tool (not listed, not offered under
`?tools=app`), with the arguments mapped as below. Hosts (Claude, Claude Code, ChatGPT, Grok) only let the model call tools
that `tools/list` shows, so the aliases help only raw JSON-RPC clients and scripts. Saved prompts, skills and permission
allowlists (for example Claude Code's `mcp__Capystore__library_search`) that name an old tool must be changed to the new
names. Delete the map when no script still calls the old names.

| Old tool | App tool | Arguments |
| - | - | - |
| `library_search` | `search_library` | as they are |
| `library_list` | `search_library` | as they are, `limit` 100 when absent (as library_list); a non-empty `query` adds `match: "text"` (library_list was the substring match), an empty one is dropped |
| `library_post` | `show_post` | as they are |
| `edits_get`, `edits_list` | `show_edit` | `{ id }`, `{}` |
| `collections_list`, `links_list` | `list_collections`, `list_share_links` | `{ limit: 500 }` (they answered every row) |
| `links_create` | `create_share_link` | as they are |
| `make_webp` | `convert_to_webp` | as they are |
| `upload_begin` | `upload_files` | as they are (the flat `name`, `title`, `public`, `queue`) |
| `library_save` | `save_link` | as they are |
| `jobs_wait` | `job_status` | as they are (`seconds` default 8, not 15) |

The app tools still call the retired ops through `ctx.call`, so the registry, `openapi.json` and the route snapshot do not
move.

### 6.4 structuredContent on every tool

Every other tool answers `structuredContent` too: the op's JSON when it is a plain object, `{ items: [...] }` for an array,
none for a string or null (and none when the JSON is past `MCP_RESULT_MAX`, or for `look`, which answers images). The
text is exactly the op's JSON as before. No `outputSchema` is advertised for them.

### 6.5 Widgets after a write

`src/mcp-app/follow.ts` gives some older write tools a widget, without touching their ops: the op runs and answers its
text as always, then the view is built from a fresh read with the app tools' own helpers and sent as `structuredContent`;
the tool carries `_meta.ui.resourceUri` in `tools/list`. Any failure of the read falls back to 6.4.

| Tools | View | Built from |
| - | - | - |
| `collections_create`, `collections_add`, `collections_update` | `collections` | that collection, as `list_collections` builds it |
| `links_update`; `links_private`, `links_rotate` on a gallery link | `links` | that link, `created` set to it |
| `library_title`; `library_visibility`, `library_status` on one post | `post` | that post, as `show_post` builds it |

A private link of a single file, several posts, or a hidden result have no view. Ask-tier tools keep `destructiveHint`.

## 7. Sign-in

Step 1 (this change): the private link `POST /mcp/k/<secret>` is the "no authentication" URL for Claude, ChatGPT and
Grok; a client key as `Bearer` still works for clients that send headers (Claude Code, the xAI API's `authorization`).
Step 2 (later, its own change): OAuth 2.1 with the API Worker as the authorization server and Cloudflare Access as the
login, one session row per host.

## 8. Checks

- `npm test && npm run typecheck && npm run gen:check` in `deploy/cloudflare/api`.
- The official client (`@modelcontextprotocol/client`) against the server in a test: initialize, list tools and resources,
  read a widget, call each app tool on a seeded database.
- The widgets in Chromium (Playwright) inside a test host built on ext-apps' `app-bridge`: each view renders from a
  fixture, a tap calls the right tool, light and dark.
- By hand, after a deploy: MCP Inspector, then the prompt set in `deploy/cloudflare/MCP-APP.md` per host.
