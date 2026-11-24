// Stage (APP-API-CONTRACT.md section 30.10): `connected_canvases`, the number of OBS canvas pages holding a socket to
// the StageRoom, on every answer that carries the stage and on the redemptions feed the app already polls.
import { describe, expect, it } from "vitest";
import { emptyRoom, roomPort } from "../src/stage";
import { world } from "./stage-world";

describe("connected_canvases", () => {
    it("is 0 with nothing connected, and what the room says otherwise, on GET and PATCH /stage and POST /stage/action", async () => {
        const w = await world();
        expect((await w.owner("GET", "/stage")).body.stage.connected_canvases).toBe(0);
        w.room.state_ = { ...emptyRoom(), viewers: 2 };
        expect((await w.owner("GET", "/stage")).body.stage.connected_canvases).toBe(2);
        const patched = await w.owner("PATCH", "/stage", { on_air: true });
        expect(patched.body.stage).toMatchObject({ on_air: true, connected_canvases: 2 });
        const acted = await w.owner("POST", "/stage/action", { type: "shuffle" });
        expect(acted.status).toBe(200);
        expect(acted.body.stage.connected_canvases).toBe(2);
        // an OBS page leaving shows on the next read
        w.room.state_ = { ...w.room.state_, viewers: 1 };
        expect((await w.owner("GET", "/stage")).body.stage.connected_canvases).toBe(1);
    });

    it("GET /stage/redemptions carries it at the top level beside the list (the 4 s feed poll)", async () => {
        const w = await world();
        const empty = await w.owner("GET", "/stage/redemptions");
        expect(empty.body).toMatchObject({ status: "success", redemptions: [], connected_canvases: 0 });
        w.room.state_ = { ...emptyRoom(), viewers: 2 };
        const feed = await w.owner("GET", "/stage/redemptions");
        expect(feed.status).toBe(200);
        expect(feed.body).toMatchObject({ redemptions: [], connected_canvases: 2 });
    });

    it("a broken room reads null (unknown, not 0) and the routes still answer", async () => {
        const w = await world();
        w.room.state_ = { ...emptyRoom(), viewers: 3 };
        w.room.broken = true;
        const got = await w.owner("GET", "/stage");
        expect(got.status).toBe(200);
        expect(got.body.stage).toHaveProperty("connected_canvases", null);
        const feed = await w.owner("GET", "/stage/redemptions");
        expect(feed.status).toBe(200);
        expect(feed.body).toHaveProperty("connected_canvases", null);
        // the room answering with no sockets is a real 0
        w.room.broken = false;
        w.room.state_ = { ...emptyRoom(), viewers: 0 };
        expect((await w.owner("GET", "/stage")).body.stage.connected_canvases).toBe(0);
    });

    it("the Worker's RoomPort passes the room's `viewers` through, and an older room that does not say reads as null (unknown)", async () => {
        const answer = (b: unknown) => ({ idFromName: () => "main", get: () => ({ fetch: async () => new Response(JSON.stringify(b)) }) });
        expect((await roomPort(answer({ chaos_until: 9, viewers: 2 })).state()).viewers).toBe(2);
        expect((await roomPort(answer({ chaos_until: 9 })).state()).viewers).toBeNull();
        expect((await roomPort(answer({ chaos_until: 9, viewers: 0 })).state()).viewers).toBe(0);
    });
});
