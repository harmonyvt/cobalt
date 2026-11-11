# capystore as an MCP app (APP-API-CONTRACT.md section 55)

Owner (2026-11-11): "Add a single MCP server that works as an app in Claude, ChatGPT, and Grok, using the open MCP Apps UI
standard (tools + ui:// HTML widgets)", then "I want studio possibly? the timeline? and like when i convert to webp,
collections, share links and when it uploads files to capystore", then "I want you to implement and delegate please".
Mockup: https://claude.ai/artifact/HULkU9NF2qdercxogPdtDu (source `/mnt/project-files/capystore-mcp-app/mockup.html`).

The existing MCP server (section 35: `POST /mcp`, `POST /mcp/k/<secret>`, the registry's chat ops as tools) stays where it
is, with the same URLs, keys, private link, threads and caps. Three things change:

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
  (same `runOp`, same thread key, same daily caps). App tools are compositions of existing ops plus read-only D1 reads
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

Existing tools keep their names (`library_search`, `links_create`, ...). App tool names must not collide with them.

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

- `search_library { query: string 1..200, kind?: "video"|"image"|"gallery", since?: ISO date, limit?: 1..24 = 12 }`
- `show_post { id: string }`
- `show_edit { id?: string, query?: string }`: an id, or a title to find; neither, or several matches: `project: null`
  and the list in `projects`.
- `list_collections { name?: string, limit?: 1..50 = 20 }`
- `list_share_links { collection?: string, query?: string, limit?: 1..50 = 20 }`
- `convert_to_webp { id: string, start?: number, end?: number, width?: 320|480 = 480, quality?: "low"|"med"|"high" = "med" }`:
  without both `start` and `end` nothing runs and the answer is `state: "pick"` (for a source of 10 s or less the whole
  clip is the default range and it runs).
- `upload_files { files?: [{ name: string, title?: string }] 1..10, public?: boolean }`: no `files`: one link.
- `create_share_link { ids: string[] 1..10, title?: string, private?: boolean, collection?: string }`
- `save_link { url: http(s) URL, engine?: "auto"|"cobalt"|"ytdlp" = "auto" }`
- `job_status { job: string }`

Every read tool has `annotations.readOnlyHint: true`; write tools `readOnlyHint: false`, `destructiveHint: false` (they
only add things), and `openWorldHint: false` except `save_link`. `job_status` is visible to the model too, so a host
with no widgets can follow a job. Every tool has `outputSchema` (from `output`) and a `title`.

The **text** must stand alone: a count line, then up to 10 numbered rows with title, kind, id and (where there is one)
the share link; for a job, what is running and what the user will get. No JSON dump in the text.

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
- `tools/list`: the app tools first, then the existing tools, unchanged. `?tools=app` on the URL lists the app tools only
  (for a host that does badly with ~100 tools). An app tool with a view carries `_meta.ui.resourceUri` (and the legacy
  `_meta["ui/resourceUri"]`), as `registerAppTool` writes them.
- `resources/list`, `resources/read`: the widgets, `mimeType: "text/html;profile=mcp-app"`, with `_meta.ui.csp`:
  `resourceDomains` = the media and share origins, `connectDomains` = the API origin (the upload PUT).
  `_meta.ui.domain`: only if a host needs it; if set, it is worked out per request from the URL the host connected to
  (for the private link that URL holds the secret) and only for that host.
- `PUT /mcp/upload/<token>` answers CORS for any origin (the token is the credential; a widget's sandbox origin is not
  knowable ahead of time), with its `OPTIONS` preflight.
- Existing behaviour that must not change: auth and the 401/403/404/405/503 answers, the private link, batches, the
  per-key thread, `look` returning images, result cutting at `MCP_RESULT_MAX`, tool names, descriptions, input schemas
  and annotations of the existing tools, `test/route-snapshot.test.ts`.

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
