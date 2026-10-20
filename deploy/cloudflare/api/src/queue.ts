// GET /queue (APP-API-CONTRACT.md section 23): one snapshot of the server's own work for the app's
// queue screen: the key's view of the line (GET /studio/line), the search index and the posters.
// Each part is fetched on its own and is null when it fails; the answer is always 200.
//
// `line` is the Durable Object's GET /studio/line answer, asked the way the Worker proxies that route.
// The Durable Object answers it from its storage and D1 before any container code (index.ts), so it
// never starts the container.

import { searchQueue, type SearchQueue } from "./embed";
import { posterBacklog } from "./poster";
import { queueEdits } from "./edits";
import type { StudioReply } from "./studio";

// A line answer slower than this is left out (null).
export const QUEUE_LINE_MS = 5_000;

export type QueueDeps = {
    db: D1Database;
    mediaBaseUrl: string;
    now: () => number;
    // the Space is configured (features.search)
    searchEnabled: boolean;
    // GET /studio/line from the Durable Object for this key: its JSON body, or null
    line: () => Promise<unknown>;
};

export async function queueSnapshot(d: QueueDeps): Promise<StudioReply> {
    const now = d.now();
    const [line, search, posters, edits] = await Promise.all([
        withTimeout(d.line(), QUEUE_LINE_MS).catch(() => null),
        searchQueue({ db: d.db, mediaBaseUrl: d.mediaBaseUrl, now, enabled: d.searchEnabled }).catch((e): SearchQueue | null => {
            console.error("[queue] search failed", String(e));
            return null;
        }),
        posterBacklog(d.db, now).then(
            (pending) => ({ pending }),
            () => null,
        ),
        // the editor's renders (section 31.13): one D1 query, the render container is never woken; null while the read
        // fails or migration 0021 is not applied
        queueEdits(d.db, now).catch((e): null => {
            console.error("[queue] edits failed", e instanceof Error ? e.message : String(e));
            return null;
        }),
    ]);
    return { status: 200, body: { status: "success", now, line, search, posters, edits } };
}

function withTimeout<T>(p: Promise<T>, ms: number): Promise<T | null> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    return Promise.race([
        p,
        new Promise<null>((resolve) => {
            timer = setTimeout(() => resolve(null), ms);
        }),
    ]).finally(() => clearTimeout(timer));
}
