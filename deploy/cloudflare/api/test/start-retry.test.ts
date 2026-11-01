// src/start-retry.ts: a container start that fails right after a deploy is tried again; cobalt's own answers pass through.
import { describe, expect, it } from "vitest";
import { fetchWithStartRetry, isStartFailure } from "../src/start-retry";

const failed = () => new Response("Failed to start container: ", { status: 500 });
const noInstance = () => new Response("There is no Container instance available at this time. This is likely because you have reached your max concurrent instance count", { status: 503 });
const ok = () => new Response(JSON.stringify({ status: "tunnel", url: "https://x" }), { status: 200 });

function world(answers: Array<() => Response>) {
    const bodies: string[] = [];
    const waits: number[] = [];
    const send = async (r: Request) => {
        bodies.push(r.method === "POST" ? await r.text() : "");
        return (answers.shift() ?? ok)();
    };
    const sleep = async (ms: number) => void waits.push(ms);
    return { send, sleep, bodies, waits };
}

const post = () => new Request("https://api.test/", { method: "POST", headers: { "content-type": "application/json", authorization: "Api-Key k" }, body: JSON.stringify({ url: "https://youtu.be/x" }) });

describe("container start retry", () => {
    it("knows the library's start failures from cobalt's own errors", async () => {
        expect(await isStartFailure(failed())).toBe(true);
        expect(await isStartFailure(noInstance())).toBe(true);
        expect(await isStartFailure(new Response(JSON.stringify({ status: "error", error: { code: "error.api.fetch.fail" } }), { status: 500 }))).toBe(false);
        expect(await isStartFailure(new Response("Failed to start container: x", { status: 429 }))).toBe(false);
        expect(await isStartFailure(ok())).toBe(false);
    });

    it("a failed start, then a running container: the save gets the second answer, with the same body", async () => {
        const w = world([failed, noInstance, ok]);
        const res = await fetchWithStartRetry(post(), w.send, w.sleep);
        expect(res.status).toBe(200);
        expect(w.waits).toEqual([2000, 4000]);
        expect(w.bodies).toEqual(Array(3).fill(JSON.stringify({ url: "https://youtu.be/x" })));
    });

    it("gives up after the last wait and answers the library's failure", async () => {
        const w = world([failed, failed, failed, failed, failed]);
        const res = await fetchWithStartRetry(post(), w.send, w.sleep);
        expect(res.status).toBe(500);
        expect(await res.text()).toMatch(/^Failed to start container/);
        expect(w.waits).toEqual([2000, 4000, 6000]);
    });

    it("never retries cobalt's own answer, and keeps a GET bodiless", async () => {
        const err = () => new Response(JSON.stringify({ status: "error" }), { status: 500 });
        const w = world([err]);
        expect((await fetchWithStartRetry(post(), w.send, w.sleep)).status).toBe(500);
        expect(w.waits).toEqual([]);
        const g = world([failed, ok]);
        expect((await fetchWithStartRetry(new Request("https://api.test/tunnel?id=1"), g.send, g.sleep)).status).toBe(200);
        expect(g.waits).toEqual([2000]);
    });
});
