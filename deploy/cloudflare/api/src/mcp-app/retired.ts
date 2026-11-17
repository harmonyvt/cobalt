// The twelve older MCP tools the app tools replaced (MCP-APP-CONTRACT.md section 6.3). They are no longer listed, but a
// call to one still works for a while, for old clients and saved agent prompts: it runs the replacement app tool with the
// arguments mapped here. The op registry keeps them (the chat AI still uses them); only the MCP stops listing them.
// Free of Cloudflare imports.
type Json = Record<string, unknown>;

export type Retired = {
    // the app tool that answers in its place
    tool: string;
    // the old tool's arguments as the app tool's input
    map(args: Json): Json;
};

// the app tool takes the old arguments as they are (it has every option the old tool had)
const same = (args: Json): Json => args;

const LIST_LIMIT = 100;

export const RETIRED_TOOLS: Record<string, Retired> = {
    library_search: { tool: "search_library", map: same },
    // library.list matched substrings of title, names, link and caption: match "text" keeps that; an empty query was no query
    // library.list answered 100 posts unless asked for fewer or more
    library_list: { tool: "search_library", map: ({ query, ...rest }) => ({ limit: LIST_LIMIT, ...(typeof query === "string" && query.length > 0 ? { query, match: "text" } : {}), ...rest }) },
    library_post: { tool: "show_post", map: same },
    edits_get: { tool: "show_edit", map: ({ id }) => ({ id }) },
    edits_list: { tool: "show_edit", map: () => ({}) },
    // these two answered every row; the app tools answer 20 unless asked for more
    collections_list: { tool: "list_collections", map: () => ({ limit: 500 }) },
    links_list: { tool: "list_share_links", map: () => ({ limit: 500 }) },
    links_create: { tool: "create_share_link", map: same },
    make_webp: { tool: "convert_to_webp", map: same },
    // name, title, public and queue: upload_files takes the single-file form flat
    upload_begin: { tool: "upload_files", map: same },
    library_save: { tool: "save_link", map: same },
    jobs_wait: { tool: "job_status", map: same },
};
