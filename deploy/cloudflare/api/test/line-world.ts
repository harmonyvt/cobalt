// The world of the line tests (APP-API-CONTRACT.md section 17): the poster world (Worker, the Durable
// Object's services with the public bucket, real SQL on node:sqlite, fake helper and buckets) with
// a real NotifyService behind a recording webhook, a recording live service, a second API key, and
// a Durable Object that routes the new /studio/line* paths like index.ts does.
import { handleNotifyRoute, isNotifyRoute, NotifyService } from "../src/notify";
import { handleStudioRoute, isStudioRoute } from "../src/studio";
import { hashKey } from "../src/keys";
import { handleRequest } from "../src/worker";
import { fixedLengthPair } from "./studio-fakes";
import { CLIENT, KEY_ID, json, world } from "./poster-world";

export const KEY2_ID = "key-row-2";
export const CLIENT2 = "7c1d9e4a-3b5f-4a2e-8d6c-0e9f1b2a3c4d";
export const HOOK = "https://hark.example/api/webhook/T0pS3cretHookToken";
export const auth2 = { authorization: `Api-Key ${CLIENT2}` };

export type HarkCall = { title: string; body: string; url?: string };
export class FakeHark {
    calls: HarkCall[] = [];
    // what the webhook answers (500 = a send that is retried)
    status = 200;
    // holds every send until it resolves (a slow webhook)
    gate: Promise<void> | null = null;
    // sees the call before it is answered
    onCall: ((c: HarkCall) => void) | null = null;
    fetch = async (_url: string, init: RequestInit): Promise<Response> => {
        const call = JSON.parse(String(init.body));
        this.calls.push(call);
        this.onCall?.(call);
        if (this.gate) await this.gate;
        return new Response('{"ok":true}', { status: this.status });
    };
}

export class LiveLog {
    events: { sid: string; job?: string; e: any }[] = [];
    onSave = async (sid: string, e: unknown) => {
        this.events.push({ sid, e });
    };
    onRender = async (sid: string, job: string, e: unknown) => {
        this.events.push({ sid, job, e });
    };
    hasActiveRuns = async () => false;
}

export async function lineWorld(opts: { hook?: string | null; posters?: boolean; helperFn?: (path: string, init?: RequestInit) => Promise<Response> } = {}) {
    const w = world(opts.helperFn ? { helperFn: opts.helperFn } : {});
    await w.addKey();
    const hark = new FakeHark();
    const notify = new NotifyService({
        storage: w.kv,
        db: w.db,
        now: w.clock.now,
        webhookUrl: opts.hook === undefined ? HOOK : opts.hook,
        fetch: hark.fetch,
    });
    const live = new LiveLog();
    // `posters: false` leaves out the public bucket, so no poster record keeps the sweep pending by accident
    const studio = w.make({ notify, live, ...(opts.posters === false ? { media: undefined, mediaBaseUrl: undefined } : {}) });
    const container = {
        async fetch(r: Request) {
            const p = new URL(r.url).pathname;
            if (isNotifyRoute(p)) return handleNotifyRoute(notify, r);
            if (isStudioRoute(p)) return handleStudioRoute(studio, r);
            return new Response('{"status":"ok"}', { headers: { "content-type": "application/json" } });
        },
    };
    const call = (url: string, init: RequestInit = {}) =>
        handleRequest(new Request(`https://api.capybaraharmony.com${url}`, init), w.env, container, {
            now: w.clock.now,
            sleep: w.clock.sleep,
            fixedLength: fixedLengthPair,
        });
    const addKey2 = async () =>
        w.db.raw
            .prepare("INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, ?)")
            .run(KEY2_ID, "phone", await hashKey(CLIENT2), "7c1d9e4a", 1);

    // polls a session (this world's Durable Object) until it is no longer saving
    const settle = async (sid: string, tries = 20) => {
        for (let i = 0; i < tries; i++) {
            const r = await studio.advance(sid, 0);
            if ((r.body as any).status !== "saving") return r;
        }
        throw new Error("the save never finished");
    };
    const keys = (prefix: string) => [...w.kv.m.keys()].filter((k) => k.startsWith(prefix));
    const entries = () =>
        keys("line:").map((k) => ({ key: k, ...(w.kv.m.get(k) as any) })) as any[];
    const rows = (sql: string, ...args: unknown[]) => w.db.raw.prepare(sql).all(...(args as any[])) as any[];
    const render = (sid: string, body: Record<string, unknown>) => studio.render(sid, json({ start: 0, length: 2, ...body }));
    const sweeps = async (n: number) => {
        for (let i = 0; i < n; i++) await studio.sweep();
    };
    // the keyed GETs/DELETEs through the Worker
    const keyed = (url: string, method = "GET", headers: Record<string, string> = { authorization: `Api-Key ${CLIENT}` }, body?: string) =>
        call(url, { method, headers, ...(body !== undefined ? { body } : {}) });
    return { ...w, hark, notify, live, studio, container, call, addKey2, settle, keys, entries, rows, render, sweeps, keyed, CLIENT, KEY_ID, sweepsArmed: w.sweepsArmed };
}
export type LW = Awaited<ReturnType<typeof lineWorld>>;
