// The board's pure parts (APP-API-CONTRACT.md section 62.4): a big page keeps every row's pictures.
import { describe, expect, it } from "vitest";
import { BOARD_MEDIA_MAX, boardPage, toRow } from "../src/swarm-board";
import { mediaHostsOf } from "../src/media-refs";

const BASES = { mediaBaseUrl: "https://media.capybaraharmony.com/", shareBaseUrl: "https://share.capybaraharmony.com/", hosts: mediaHostsOf({}) };
const emote = (i: number) => `01HEMOTE${String(i).padStart(18, "0")}`;

describe("boardPage", () => {
    it("200 rows with 8 refs each: every row still shows its first 4 pictures (resolved in chunks)", async () => {
        const rows = Array.from({ length: 200 }, (_, r) =>
            toRow({ name: `row ${r}`, media: Array.from({ length: 8 }, (_, k) => emote(r * 8 + k)) }, 1, r + 1, { media: ["media"] }, BASES),
        );
        expect(rows[0]!.refs.length).toBeGreaterThan(BOARD_MEDIA_MAX);
        const db = {} as D1Database; // emotes need no library
        const page = await boardPage(db, rows, { limit: 200 }, BASES);
        expect(page.rows).toHaveLength(200);
        for (const [r, row] of page.rows.entries()) expect(row.media.map((m) => m.ref)).toEqual([0, 1, 2, 3].map((k) => emote(r * 8 + k)));
    });
});
