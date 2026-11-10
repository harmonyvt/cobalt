// src/d1-timing.ts fails open: in a runtime without node:async_hooks, D1_TIMING "1" changes nothing and logs nothing.
import { describe, expect, it, vi } from "vitest";
import { createFakeD1 } from "../../test-support/d1-sqlite";

vi.mock("node:async_hooks", () => {
    throw new Error('No such module "node:async_hooks".');
});

describe("withD1Timing without AsyncLocalStorage", () => {
    it("the handler gets the env itself, the answer goes out, and there is no line", async () => {
        const { withD1Timing, timedDb } = await import("../src/d1-timing");
        const real = createFakeD1("CREATE TABLE t (id INTEGER PRIMARY KEY)");
        const env = { DB: real as D1Database, D1_TIMING: "1" };
        const lines: string[] = [];
        for (let i = 0; i < 2; i++) {
            const res = await withD1Timing(
                new Request("https://api.capybaraharmony.com/library"),
                env,
                async (e) => {
                    expect(e).toBe(env);
                    expect(e.DB).toBe(real);
                    await e.DB.prepare("SELECT count(*) AS c FROM t").first();
                    return new Response("ok", { status: 201 });
                },
                (l) => lines.push(l),
            );
            expect([res.status, await res.text()]).toEqual([201, "ok"]);
        }
        expect(lines).toEqual([]);
        // the tests' own counter needs no AsyncLocalStorage
        const t = timedDb(real);
        await t.db.prepare("SELECT 1").first();
        expect(t.stats.n).toBe(1);
    });
});
