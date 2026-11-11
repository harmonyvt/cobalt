# capystore in Claude, ChatGPT and Grok

capystore's MCP server (`https://api.capybaraharmony.com/mcp`) is also an MCP App: besides the tools it always had, it
has ten app tools whose answers Claude and ChatGPT draw as widgets (search grid, post card, editor timeline, webp
maker, collections, share links, upload tray, save progress). A host that draws nothing still gets a full text answer.
Design and wire contract: `MCP-APP-CONTRACT.md`.

## The URL to add

Use the **private link** (settings > mcp in the app, or settings > instances on the web): it looks like
`https://api.capybaraharmony.com/mcp/k/<secret>` and needs no sign-in, which is what all three hosts accept. Switching
the mode to "private" turns the plain `/mcp` URL off for everyone but that link; rotating the link cuts every host off
at once. Treat the link like a password.

The tool list is the ten app tools first, then the older tools that do not overlap them (about 55). Twelve older tools
that the app tools replaced (`library_search`, `library_list`, `library_post`, `edits_get`, `edits_list`,
`collections_list`, `links_list`, `links_create`, `make_webp`, `upload_begin`, `library_save`, `jobs_wait`) are no longer
listed, so a model picks the app tool and the host can draw a widget; each app tool takes every option those had. A call
to an old name still works for raw JSON-RPC clients and scripts: the server answers it with the app tool. Claude, Claude Code,
ChatGPT and Grok only call tools that are listed, so saved prompts, skills and permission allowlists that name an old tool
must be changed to the new name. Every tool also answers
`structuredContent`, and some older write tools (`collections_*`, `links_update`, `links_private`, `links_rotate`,
`library_title`, `library_visibility`, `library_status`) end on a widget as well.

A host that struggles with the full list can use the short list: add `?tools=app` to the URL
(`.../mcp/k/<secret>?tools=app`) and only the app tools are offered (the old names do not answer there).

Clients that send headers (Claude Code, the xAI API) can keep using `https://api.capybaraharmony.com/mcp` with
`Authorization: Bearer <client key>`.

## What the widgets look like

Compact by default so they fit a phone chat: one-line headers, dense rows, and every list shows its first 3 items with a
"show N more" button (a grid shows its first row). The expand button in each header asks the host for full screen, the roomy
view with everything shown. Private posts, thumbnails and timeline sources play through signed one-hour links (a lock badge says
so); if a link ran out, "refresh preview" in the widget asks again. The timeline has a real preview player: scrub the tracks,
press play, overlays are boxed where they sit on the frame, and a finished render can be played instead.

## Claude

1. claude.ai > Settings > Connectors > **Add custom connector**.
2. Name `capystore`, URL the private link. No OAuth fields.
3. In a chat, turn the connector on. The first time a widget shows, Claude asks to allow it.

Claude Code: `claude mcp add --transport http capystore https://api.capybaraharmony.com/mcp --header "Authorization: Bearer <key>"`
(tools only: a terminal draws no widgets).

A local plugin is not needed: a Claude plugin for capystore would only wrap this same URL.

## ChatGPT

1. chatgpt.com/plugins > **+** > **Add custom MCP server** (developer mode has to be on for the account).
2. URL the private link, authentication "No authentication", accept the warning, create.
3. Install it, start a new chat, type `@capystore`.
4. After a deploy that changes tools or widgets: open the connection's page and **Refresh**.

## Grok

1. grok.com/connectors > **New Connector** > **Custom**.
2. URL the private link.

Grok's documentation does not say it draws MCP App widgets, so expect text answers and links. For uploads that means
the `curl` line from `upload_files` rather than a drop zone.

xAI API: `tools: [{ type: "mcp", server_url: "https://api.capybaraharmony.com/mcp", authorization: "<client key>" }]`.

## Trying it without deploying

The Worker cannot run on a laptop (Durable Objects, containers, D1, R2), so there are two local tools instead, both in
`deploy/cloudflare/api`:

- `npm run widgets:dev`: the widgets alone in a test host (the real MCP Apps host bridge), with fixtures for every view
  and state. `npm run widgets:test` clicks through all of them in Chromium and saves screenshots to `widgets-dev/shots/`.
- `npm run mcp:dev`: the real MCP server code over demo data on `http://localhost:8788/mcp`. To try it in a real host,
  tunnel it and tell the server its public address:

  ```sh
  cloudflared tunnel --url http://localhost:8788        # or: ngrok http 8788
  npm run mcp:dev -- --public-url https://<the tunnel address>
  ```

  then add `https://<the tunnel address>/mcp` in Claude, ChatGPT or Grok as above. It never touches the real library.

After editing anything under `src/mcp-app/widgets/`, run `npm run widgets` (it rewrites `widgets.generated.ts`;
`npm test` fails while that file is stale).

## Checks

- `npm test && npm run typecheck && npm run gen:check` in `deploy/cloudflare/api`.
- MCP Inspector: `npx @modelcontextprotocol/inspector`, transport "Streamable HTTP", URL the private link (or the local
  one). Check: `tools/list` shows the app tools first, each with an output schema; `resources/list` shows eight
  `ui://capystore/*.html` entries; a `search_library` call answers text plus structured content.

### Prompt set (run in each host after a deploy)

| Kind | Prompt | Expect |
| - | - | - |
| direct | "search capystore for pink cat girl" | `search_library`, the grid (Grok: a numbered list) |
| direct | "show my capystore share links" | `list_share_links`, rows with copy buttons |
| direct | "open my latest edit in capystore" | `show_edit`, the timeline with a playing preview (a private clip shows the lock badge) |
| direct | "show that private video" | `show_post` of a private post: it plays, lock badge "private · link valid 1 h" |
| direct | "show my collections" | `list_collections`, the grid |
| indirect | "what did I save most recently?" | `search_library` or `library_list`, newest first |
| indirect | "I need a looping sticker of the jumpscare clip" | finds the post, then `convert_to_webp` with the range picker |
| indirect | "put these two clips in one link for Discord" | `create_share_link`, a `share.capybaraharmony.com` link |
| indirect | "I have a video on my computer to add" | `upload_files`, the drop zone (Grok: a curl line) |
| negative | "what's the weather in Melbourne?" | no capystore tool call |
| negative | "delete everything in my library" | no delete without asking first |
| negative | "search the web for cat videos" | no capystore tool call |

### Host differences (fill in after the first real run)

| | Claude | ChatGPT | Grok |
| - | - | - | - |
| Widgets drawn | to confirm | to confirm | not expected |
| `ui.domain` | optional per Claude's docs; sent only to Claude | not sent | not sent |
| Full screen | standard display-mode request | `window.openai` fallback | n/a |
| Upload drop zone | to confirm (needs the widget's PUT to the API allowed by CSP) | to confirm | curl line |

## Not built yet

OAuth 2.1 sign-in (the private link is the credential for now), changing a timeline from the chat, and deletes or
status changes as app tools (the older tools still do those, marked destructive).
