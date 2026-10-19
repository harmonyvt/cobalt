// src/stage-pages.ts (APP-API-CONTRACT.md 30.4, 30.5, 30.7): the three pages are strings, so these tests check
// the hooks the contract names, that interpolated values are escaped, that the locked page is inert, and that every
// inline script parses. Behaviour in a real browser was checked by hand against a fake server.
import vm, { Script } from "node:vm";
import { describe, expect, it } from "vitest";
import { livePage, storeLockedPage, storePage } from "../src/stage-pages";

const BASE = "https://studio.capybaraharmony.com/";

function scripts(html: string): string[] {
    return [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]!);
}

describe("livePage", () => {
    const html = livePage({ stageBaseUrl: BASE, preview: false });

    it("is a self-contained html document with one inline script and no external script", () => {
        expect(html.startsWith("<!doctype html>")).toBe(true);
        expect(scripts(html)).toHaveLength(1);
        expect(html).not.toMatch(/<script[^>]*\ssrc=/i);
        expect(html).not.toMatch(/<link[^>]+rel="stylesheet"[^>]+href="(?!https:\/\/fonts\.googleapis\.com\/)/);
        // the only hosts in it are the font hosts, the svg namespace and the interpolated base url (a data attribute)
        const hosts = new Set([...html.matchAll(/https?:\/\/([a-z0-9.-]+)/gi)].map((m) => m[1]!.toLowerCase()));
        expect([...hosts].filter((h) => !/^(fonts\.googleapis\.com|fonts\.gstatic\.com|www\.w3\.org|studio\.capybaraharmony\.com)$/.test(h))).toEqual([]);
        expect(html).toContain("IBM+Plex+Mono");
    });

    it("derives its token from the path and talks to state and ws", () => {
        const js = scripts(html)[0]!;
        expect(js).toContain("location.pathname");
        expect(js).toContain("BASE + '/state'");
        expect(js).toContain("BASE + '/ws'");
        expect(js).toContain("'wss:'");
        expect(js).toContain("new WebSocket(");
        // backoff 1 s up to 30 s
        expect(js).toContain("wsBackoff = 1000");
        expect(js).toContain("Math.min(wsBackoff * 2, 30000)");
    });

    it("handles every event of 30.6 and ignores the rest", () => {
        const js = scripts(html)[0]!;
        for (const t of ["settings", "pool", "summon", "chaos", "shuffle", "pin", "unpin", "skip", "rotated"]) {
            expect(js).toContain(`case '${t}':`);
        }
        expect(js).toContain("default:");
    });

    it("carries the canvas hooks and lowercase copy", () => {
        for (const id of ["stage", "tiles", "spot", "spvid", "chaosrow", "toast", "hint"]) expect(html).toContain(`id="${id}"`);
        expect(html).toContain("#2f8af9");
        expect(html).toContain("1920px");
        expect(html).toContain("1080px");
        const js = scripts(html)[0]!;
        expect(js).toContain("summoned by @");
        expect(js).toContain("spotlight · picked at random");
        expect(js).toContain("chaos mode · ");
        expect(js).toContain("spend points: ");
        expect(html).toContain(">pinned<");
        expect(js).toContain("' spent '");
    });

    it("keeps tile videos muted, looped and inline", () => {
        const js = scripts(html)[0]!;
        expect(js).toContain("vid.muted = true");
        expect(js).toContain("vid.loop = true");
        expect(js).toContain("vid.playsInline = true");
        expect(js).toContain("cfg.video_max");
    });

    it("preview is a data attribute: always muted and no hint come from it", () => {
        expect(html).toContain('data-preview="0"');
        const p = livePage({ stageBaseUrl: BASE, preview: true });
        expect(p).toContain('data-preview="1"');
        const js = scripts(p)[0]!;
        expect(js).toContain("!!cfg.sound && !SILENT");
        expect(js).toContain("var SILENT = PREVIEW || AMBIENT");
        expect(js).toContain("!SILENT && cfg.on_air");
    });

    it("escapes the base url and uses no top-level await", () => {
        const evil = livePage({ stageBaseUrl: 'https://x.test/"><script>alert(1)</script>', preview: false });
        expect(evil).not.toContain("<script>alert(1)");
        expect(evil).toContain("&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;/");
        expect(scripts(evil)).toHaveLength(1);
        expect(scripts(html)[0]).not.toMatch(/^\s*await\s/m);
    });

    it("builds titles with textContent, never innerHTML", () => {
        const js = scripts(html)[0]!;
        expect(js).not.toContain("innerHTML");
        expect(js).not.toContain("insertAdjacentHTML");
        expect(js).not.toContain("document.write");
    });

    it("parses", () => {
        expect(() => new Script(scripts(html)[0]!)).not.toThrow();
    });
});

describe("storePage", () => {
    const html = storePage({ stageBaseUrl: BASE, twitchClientId: "abc123client" });

    it("is self-contained and calls the three store routes", () => {
        expect(html.startsWith("<!doctype html>")).toBe(true);
        expect(html).not.toMatch(/<script[^>]*\ssrc=/i);
        const js = scripts(html)[0]!;
        expect(js).toContain("/store/api/pool?");
        expect(js).toContain("/store/api/rewards");
        expect(js).toContain("/store/api/me");
        expect(js).toContain("limit=40");
        expect(js).toContain("'&q=' + enc(curQ)");
        expect(js).toContain("IntersectionObserver");
        expect(js).toContain("navigator.clipboard");
        expect(js).toContain("execCommand('copy')");
        expect(js).toContain("https://www.twitch.tv/popout/");
        expect(js).toContain("/chat?popout=");
    });

    it("has the mockup's copy", () => {
        for (const s of [
            "capystore studio",
            "live now",
            "spend channel points to put stuff on stream.",
            "find something below",
            "tap summon to copy its code",
            "redeem summon in twitch",
            "tonight's pool",
            "search the pool",
            "only what's in tonight's pool shows here. signing in just tells this page who you are; it never touches your points. points are spent on twitch.",
            "now redeem summon in twitch chat and paste it.",
            "open chat",
            "nothing in the pool right now.",
            "your summons",
        ]) {
            expect(html).toContain(s);
        }
    });

    it("signs in with the implicit grant, kept in sessionStorage, fragment removed, revoked on sign out", () => {
        expect(html).toContain('data-twitch-client="abc123client"');
        expect(html).toContain("sign in with twitch");
        const js = scripts(html)[0]!;
        expect(js).toContain("https://id.twitch.tv/oauth2/authorize?response_type=token&client_id=");
        expect(js).toContain("'&redirect_uri=' + enc(REDIRECT)");
        expect(js).toContain("REDIRECT = BASE + 'store'");
        expect(js).toContain("&scope=&state=");
        expect(js).toContain("sessionStorage");
        expect(js).toContain("history.replaceState");
        expect(js).toContain("'Bearer ' + token");
        expect(js).toContain("https://id.twitch.tv/oauth2/revoke");
        expect(js).toContain("client_id: CLIENT, token: t");
        expect(js).not.toContain("localStorage");
        expect(js).not.toContain("document.cookie");
        expect(html).toContain(`data-stage-base="${BASE}"`);
    });

    it("words every refund reason the redeem route writes", () => {
        const js = scripts(html)[0]!;
        for (const reason of ["off_air", "no_match", "no_effect", "disabled"]) expect(js).toContain(`${reason}: '`);
    });

    it("has no sign-in at all without a client id", () => {
        for (const none of [null, "", "   "]) {
            const h = storePage({ stageBaseUrl: BASE, twitchClientId: none });
            expect(h).not.toContain("sign in with twitch");
            expect(h).not.toContain("id.twitch.tv");
            expect(h).not.toContain("data-twitch-client");
            expect(h).not.toContain('id="account"');
            expect(h).not.toContain("/store/api/me");
            expect(h).not.toContain("sessionStorage");
            expect(() => new Script(scripts(h)[0]!)).not.toThrow();
        }
    });

    it("escapes the client id and the base url", () => {
        const h = storePage({ stageBaseUrl: 'https://x.test/"><img src=x onerror=alert(1)>', twitchClientId: '"><script>alert(2)</script>' });
        expect(h).not.toContain("<script>alert(2)");
        expect(h).not.toContain("<img src=x");
        expect(h).toContain("&quot;&gt;&lt;script&gt;alert(2)&lt;/script&gt;");
        expect(scripts(h)).toHaveLength(1);
    });

    it("builds titles with textContent only", () => {
        const js = scripts(html)[0]!;
        // the only innerHTML uses are clearing a node and the constant twitch logo
        const uses = [...js.matchAll(/innerHTML\s*=\s*([^;]*);/g)].map((m) => m[1]!.trim());
        for (const u of uses) expect(u === "''" || u.startsWith("'<svg ")).toBe(true);
        expect(js).not.toContain("insertAdjacentHTML");
    });

    it("works at phone width: viewport meta, 16px gutter, columns collapse", () => {
        expect(html).toContain('name="viewport" content="width=device-width,initial-scale=1"');
        expect(html).toContain("padding:0 16px 140px");
        expect(html).toContain("@media (max-width:560px)");
    });

    it("parses", () => {
        expect(() => new Script(scripts(html)[0]!)).not.toThrow();
    });
});

describe("storeLockedPage", () => {
    const html = storeLockedPage();

    it("says only nothing here., with no script", () => {
        expect(html).toContain("<p>nothing here.</p>");
        expect(html).not.toMatch(/<script/i);
        expect(html).not.toMatch(/\son[a-z]+=/i);
        const text = html.replace(/<style>[\s\S]*?<\/style>/, "").replace(/<title>[\s\S]*?<\/title>/, "").replace(/<[^>]*>/g, "").trim();
        expect(text).toBe("nothing here.");
    });

    it("carries no client id, sign-in, or request to anywhere", () => {
        expect(html).not.toMatch(/twitch|client|sign in|https?:\/\//i);
        expect(html).not.toContain("<link");
    });
});

// ---- the canvas page's heartbeat, run for real in a vm with a fake socket and a fake clock ----------------------------

type Timer = { id: number; at: number; fn: () => void; every: number | null };

function runCanvas() {
    let clock = 0;
    let nextId = 1;
    let timers: Timer[] = [];
    const sockets: FakeSocket[] = [];
    const fetches: string[] = [];

    class FakeSocket {
        static OPEN = 1;
        readyState = 0;
        sent: string[] = [];
        closed = false;
        onopen: null | (() => void) = null;
        onmessage: null | ((m: { data: string }) => void) = null;
        onclose: null | (() => void) = null;
        onerror: null | (() => void) = null;
        constructor(readonly url: string) {
            sockets.push(this);
        }
        send(s: string) {
            this.sent.push(s);
        }
        close() {
            this.closed = true;
        }
        open() {
            this.readyState = 1;
            this.onopen?.();
        }
    }

    // a stand-in for every DOM object the page touches: any property is another stand-in, any call returns one
    const any: any = new Proxy(function () {}, {
        get: (_t, k) => (k === Symbol.toPrimitive ? () => 0 : k === "length" ? 0 : any),
        set: () => true,
        apply: () => any,
        construct: () => any,
    });
    const doc = { body: { getAttribute: () => null }, getElementById: () => any, createElement: () => any };
    const sandbox: Record<string, unknown> = {
        document: doc,
        location: { pathname: "/live/tok", search: "", protocol: "https:", host: "studio.capybaraharmony.com" },
        window: { addEventListener() {}, innerWidth: 1920, innerHeight: 1080 },
        WebSocket: FakeSocket,
        // a state request that never finishes is enough here: the page only needs to have asked
        fetch: (u: string) => {
            fetches.push(u);
            return new Promise(() => {});
        },
        setTimeout: (fn: () => void, ms = 0) => {
            const t = { id: nextId++, at: clock + ms, fn, every: null };
            timers.push(t);
            return t.id;
        },
        setInterval: (fn: () => void, ms = 0) => {
            const t = { id: nextId++, at: clock + ms, fn, every: ms };
            timers.push(t);
            return t.id;
        },
        clearTimeout: (id: number) => void (timers = timers.filter((t) => t.id !== id)),
        clearInterval: (id: number) => void (timers = timers.filter((t) => t.id !== id)),
        requestAnimationFrame: () => 0,
        Date: { now: () => clock, parse: Date.parse },
        console,
    };
    const js = scripts(livePage({ stageBaseUrl: BASE, preview: false }))[0]!;
    vm.runInNewContext(js, sandbox);
    const advance = (ms: number) => {
        const end = clock + ms;
        for (;;) {
            const due = timers.filter((t) => t.at <= end).sort((a, b) => a.at - b.at || a.id - b.id)[0];
            if (!due) break;
            clock = due.at;
            if (due.every !== null) due.at += Math.max(due.every, 1);
            else timers = timers.filter((t) => t !== due);
            due.fn();
        }
        clock = end;
    };
    return { sockets, advance, fetches };
}

describe("livePage heartbeat (30.5)", () => {
    it("pings every 30 s on an open socket and stays on it while the room answers pong", () => {
        const c = runCanvas();
        expect(c.sockets).toHaveLength(1);
        c.sockets[0]!.open();
        c.advance(29_999);
        expect(c.sockets[0]!.sent).toEqual([]);
        c.advance(1);
        for (let i = 1; i <= 4; i++) {
            expect(c.sockets[0]!.sent).toEqual(Array(i).fill("ping"));
            c.advance(2000);
            c.sockets[0]!.onmessage!({ data: "pong" });
            c.advance(28_000);
        }
        expect(c.sockets).toHaveLength(1);
        expect(c.sockets[0]!.closed).toBe(false);
    });

    it("with no pong within 10 s the socket is dropped and a new one made (the usual backoff)", () => {
        const c = runCanvas();
        c.sockets[0]!.open();
        c.advance(30_000);
        expect(c.sockets[0]!.sent).toEqual(["ping"]);
        c.advance(9_999);
        expect(c.sockets).toHaveLength(1);
        expect(c.sockets[0]!.closed).toBe(false);
        c.advance(1);
        expect(c.sockets[0]!.closed).toBe(true);
        expect(c.sockets).toHaveLength(1);
        c.advance(1000);
        expect(c.sockets).toHaveLength(2);
        expect(c.sockets[1]!.url).toBe("wss://studio.capybaraharmony.com/live/tok/ws");
        // the dropped socket's late close does not make a third, and the new one pings in its turn
        c.sockets[0]!.onclose?.();
        c.advance(5000);
        expect(c.sockets).toHaveLength(2);
        c.sockets[1]!.open();
        c.advance(30_000);
        expect(c.sockets[1]!.sent).toEqual(["ping"]);
    });

    it("any frame is a sign of life, and a close by the other side leaves no old heartbeat behind", () => {
        const c = runCanvas();
        c.sockets[0]!.open();
        c.advance(30_000);
        expect(c.sockets[0]!.sent).toEqual(["ping"]);
        // an event instead of the pong, 5 s later
        c.advance(5_000);
        c.sockets[0]!.onmessage!({ data: JSON.stringify({ type: "pool" }) });
        c.advance(20_000);
        expect(c.sockets[0]!.closed).toBe(false);
        // closed by the other side: reconnects by the old path
        c.sockets[0]!.onclose!();
        c.advance(1000);
        expect(c.sockets).toHaveLength(2);
        // the first socket got no more pings, and was not closed by a stale pong timer
        c.advance(120_000);
        expect(c.sockets[0]!.sent).toEqual(["ping"]);
        expect(c.sockets[0]!.closed).toBe(false);
    });
});
