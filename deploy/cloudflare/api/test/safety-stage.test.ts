// The stage fails closed (APP-API-CONTRACT.md section 51.4): unrated files never reach the pool, an override wins,
// and minor_sexual blocks even a general override. The post rollup is covered in safety.test.ts.
import { describe, expect, it } from "vitest";
import { world } from "./stage-world";

const ids = (items: { id: string }[]) => items.map((i) => i.id);
const poolOf = async (w: Awaited<ReturnType<typeof world>>) => (await w.siteJson(`/live/${await w.token()}/state`)).body.pool as { id: string }[];

describe("the stage safety gate", () => {
    it("drops unrated, pending, failed, gore and anything past general, and keeps an override", async () => {
        const w = await world();
        const safe = w.file();
        const unrated = w.file({ safety: "omit" });
        const pending = w.file({ safety: "pending" });
        const failed = w.file({ safety: "failed" });
        const explicit = w.file({ safety: "explicit" });
        const gory = w.file({ safety: { level: "general", gore: 1 } });
        const overridden = w.file({ safety: { level: "explicit", user_level: "general" } });
        const blocked = w.file({ safety: { level: "general", user_level: "explicit" } });
        const got = ids(await poolOf(w));
        expect(got).toContain(safe.id);
        expect(got).toContain(overridden.id);
        for (const id of [unrated.id, pending.id, failed.id, explicit.id, gory.id, blocked.id]) expect(got).not.toContain(id);
    });

    it("minor_sexual stays off the stage even when Harmony's override is general", async () => {
        const w = await world();
        const minor = w.file({ safety: { level: "general", user_level: "general", minor_sexual: 1 } });
        expect(ids(await poolOf(w))).not.toContain(minor.id);
    });

    it("a derived file inherits the strictest source until it is rated", async () => {
        const w = await world();
        const src = w.file({ safety: "explicit" });
        const crop = w.file({ safety: "omit", made_from: JSON.stringify([src.id]) });
        const rated = w.file({ safety: "general", made_from: JSON.stringify([src.id]) });
        const got = ids(await poolOf(w));
        expect(got).not.toContain(src.id);
        expect(got).not.toContain(crop.id);
        expect(got).toContain(rated.id);
    });
});
