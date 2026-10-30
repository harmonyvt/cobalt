// The chat's workbench box (APP-API-CONTRACT.md section 33.11): what the Workbench Durable Object does, free of Cloudflare
// imports so the tests run it under node against a stub container. src/workbench.ts wires it to the Containers library.
//
// One box for the whole server (the container app allows one instance). It belongs to one chat thread while awake: a
// call from another thread wipes it first, so no file ever crosses threads. It sleeps SLEEP_MS after its last call, and a
// sleeping container keeps nothing (its disk goes with it). Awake time is counted per UTC day against the cap.
import { Clip, dayOf, emptyLedger, markActive, markAsleep, markAwake, rollDay, SLEEP_MS, usedMs, type Ledger } from "./workbench-rules";

export const RUN_DEFAULT_S = 60;
export const RUN_MAX_S = 120;
export const WORKDIR = "/workspace";
// the unprivileged user every command runs as (deploy/cloudflare/workbench/Dockerfile)
export const BOX_USER = "1000:1000";
// The platform re-signs intercepted HTTPS with this CA; box-init adds it to the system bundle, and these cover tools
// that read their own (exec does not inherit the start env).
export const CA_PATH = "/etc/cloudflare/certs/cloudflare-containers-ca.crt";
export const BOX_ENV: Record<string, string> = {
    HOME: "/home/box",
    PATH: "/opt/ytdlp/bin:/usr/local/bin:/usr/bin:/bin",
    LANG: "C.UTF-8",
    CURL_CA_BUNDLE: "/etc/ssl/certs/ca-certificates.crt",
    SSL_CERT_FILE: "/etc/ssl/certs/ca-certificates.crt",
    REQUESTS_CA_BUNDLE: "/etc/ssl/certs/ca-certificates.crt",
    NODE_EXTRA_CA_CERTS: CA_PATH,
};
// keeps the container's activity timer fresh while a command runs (the library would stop it after SLEEP_MS)
const RENEW_EVERY_MS = 20_000;

export type BoxProcess = {
    readonly stdout: ReadableStream<Uint8Array> | null;
    readonly stderr: ReadableStream<Uint8Array> | null;
    readonly exitCode: Promise<number>;
    kill(signal?: number): void;
};

export type BoxExecOptions = {
    cwd?: string;
    env?: Record<string, string>;
    user?: string;
    signal?: AbortSignal;
    stdin?: ReadableStream<Uint8Array>;
    stdout?: "pipe" | "ignore";
    stderr?: "pipe" | "ignore";
};

export type WorkbenchDeps = {
    storage: { get<T>(key: string): Promise<T | undefined>; put(key: string, value: unknown): Promise<void> };
    now: () => number;
    running: () => boolean;
    // start the container (interception is in place before it runs) and wait until it is up
    start: () => Promise<void>;
    // kill it; its disk goes with it
    wipe: () => Promise<void>;
    exec: (argv: string[], o: BoxExecOptions) => Promise<BoxProcess>;
    renew: () => void;
    capMinutes: number;
    setTimer?: (fn: () => void, ms: number) => unknown;
    clearTimer?: (t: unknown) => void;
    every?: (fn: () => void, ms: number) => unknown;
    stopEvery?: (t: unknown) => void;
};

export type BoxRun = { code: number; stdout: string; stderr: string; timed_out: boolean; ms: number };
export type BoxStat = { size: number; head: number[] };
export type BoxError = { error: string };
export type BoxWrite = { size: number };

// A name box.pull may write in /workspace: one plain file name, no path, no dot files.
export const BOX_NAME_REGEX = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

const LEDGER_KEY = "workbench:ledger";

async function drain(stream: ReadableStream<Uint8Array> | null, clip: Clip): Promise<void> {
    if (!stream) return;
    const reader = stream.getReader();
    for (;;) {
        const { done, value } = await reader.read();
        if (done) return;
        if (value) clip.push(value);
    }
}

export class WorkbenchCore {
    #d: WorkbenchDeps;
    // set after box-init ran in the current container
    #ready = false;

    constructor(d: WorkbenchDeps) {
        this.#d = d;
    }

    async ledger(): Promise<Ledger> {
        return rollDay((await this.#d.storage.get<Ledger>(LEDGER_KEY)) ?? emptyLedger(this.#d.now()), this.#d.now());
    }

    async #save(l: Ledger): Promise<void> {
        await this.#d.storage.put(LEDGER_KEY, l);
    }

    // The container stopped (the library's onStop): close the awake stretch.
    async stopped(): Promise<void> {
        // a late notice of a stop the box already got past (wiped and started again for the next thread): nothing to close
        if (this.#d.running()) return;
        this.#ready = false;
        const l = await this.ledger();
        if (l.awake_since !== null || l.owner !== null) await this.#save(markAsleep(l, this.#d.now()));
    }

    // Today's use, for the model's error and the tests.
    async usage(): Promise<{ day: string; used_minutes: number; cap_minutes: number }> {
        const now = this.#d.now();
        return { day: dayOf(now), used_minutes: Math.round(usedMs(await this.ledger(), now) / 600) / 100, cap_minutes: this.#d.capMinutes };
    }

    // The box, awake and this thread's: wipes another thread's box, refuses past the daily cap.
    async #prepare(thread: string): Promise<BoxError | null> {
        const now = this.#d.now();
        let l = await this.ledger();
        // a stop nobody told us about (the object was evicted while the container slept)
        if (!this.#d.running() && l.awake_since !== null) l = markAsleep(l, now);
        const cap = this.#d.capMinutes * 60_000;
        if (usedMs(l, now) >= cap) {
            if (this.#d.running()) {
                await this.#d.wipe().catch(() => {});
                l = markAsleep(l, now);
            }
            await this.#save(l);
            return { error: `the workbench is used up for today (${this.#d.capMinutes} awake minutes); it opens again at midnight UTC` };
        }
        if (this.#d.running() && l.owner !== thread) {
            // another thread's box: never hand its files over
            await this.#d.wipe();
            l = markAsleep(l, now);
            this.#ready = false;
        }
        if (!this.#d.running()) {
            this.#ready = false;
            l = markAwake(l, now, thread);
            await this.#save(l);
            await this.#d.start();
        } else {
            l = markActive(l, now);
            await this.#save(l);
        }
        this.#d.renew();
        if (!this.#ready) {
            const init = await this.#d.exec(["/usr/local/bin/box-init"], { user: "0:0", stdout: "ignore", stderr: "pipe" });
            const err = new Clip();
            await drain(init.stderr, err);
            const code = await init.exitCode;
            if (code !== 0) return { error: `the workbench did not start (box-init ${code}: ${err.text().trim().slice(0, 300)})` };
            this.#ready = true;
        }
        return null;
    }

    async #touch(): Promise<void> {
        this.#d.renew();
        await this.#save(markActive(await this.ledger(), this.#d.now()));
    }

    #keepAwake(): () => void {
        const every = this.#d.every ?? ((fn, ms) => setInterval(fn, ms));
        const stop = this.#d.stopEvery ?? ((t) => clearInterval(t as ReturnType<typeof setInterval>));
        const t = every(() => this.#d.renew(), RENEW_EVERY_MS);
        return () => stop(t);
    }

    // cobalt.box.run: one shell command as the box user in /workspace. Output cut to 8 KB per stream.
    async run(thread: string, cmd: string, timeoutS: number = RUN_DEFAULT_S): Promise<BoxRun | BoxError> {
        const p = await this.#prepare(thread);
        if (p) return p;
        const limit = Math.min(Math.max(1, Math.floor(timeoutS)), RUN_MAX_S) * 1000;
        const t0 = this.#d.now();
        const abort = new AbortController();
        let timedOut = false;
        const setT = this.#d.setTimer ?? ((fn, ms) => setTimeout(fn, ms));
        const clearT = this.#d.clearTimer ?? ((t) => clearTimeout(t as ReturnType<typeof setTimeout>));
        const stopKeep = this.#keepAwake();
        let proc: BoxProcess | null = null;
        const timer = setT(() => {
            timedOut = true;
            abort.abort();
            try {
                proc?.kill(9);
            } catch {
                // already gone
            }
        }, limit);
        try {
            proc = await this.#d.exec(["bash", "-c", cmd], { cwd: WORKDIR, env: BOX_ENV, user: BOX_USER, signal: abort.signal });
            const out = new Clip();
            const err = new Clip();
            const code = await Promise.all([drain(proc.stdout, out), drain(proc.stderr, err)]).then(
                () => proc!.exitCode,
                () => proc!.exitCode.catch(() => -1),
            );
            return { code: timedOut ? 124 : code, stdout: out.text(), stderr: timedOut ? `${err.text()}\n(killed after ${limit / 1000} s)`.trimStart() : err.text(), timed_out: timedOut, ms: this.#d.now() - t0 };
        } catch (e) {
            if (timedOut) return { code: 124, stdout: "", stderr: `(killed after ${limit / 1000} s)`, timed_out: true, ms: this.#d.now() - t0 };
            return { error: `the command could not start: ${e instanceof Error ? e.message : String(e)}` };
        } finally {
            clearT(timer);
            stopKeep();
            await this.#touch();
        }
    }

    // box.pull: bytes from the library into /workspace/<name> (written as <name>.part, then renamed, so a half-written file
    // never has the name). Returns the size on disk; the op compares it with the size it sent.
    async write(thread: string, name: string, body: ReadableStream<Uint8Array>): Promise<BoxWrite | BoxError> {
        if (!BOX_NAME_REGEX.test(name) || name.includes("..")) {
            await body.cancel().catch(() => {});
            return { error: `not a plain file name: ${name}` };
        }
        const p = await this.#prepare(thread);
        if (p) {
            await body.cancel().catch(() => {});
            return p;
        }
        const stopKeep = this.#keepAwake();
        try {
            const script = 'f="$1"; cat > "$f.part" && mv -f -- "$f.part" "$f" && stat -L -c %s -- "$f"';
            const proc = await this.#d.exec(["bash", "-c", script, "box-put", name], { cwd: WORKDIR, env: BOX_ENV, user: BOX_USER, stdin: body });
            const out = new Clip();
            const err = new Clip();
            await Promise.all([drain(proc.stdout, out), drain(proc.stderr, err)]);
            const code = await proc.exitCode;
            if (code !== 0) return { error: err.text().trim().slice(0, 300) || `could not write ${name}` };
            const size = Number(out.text().trim());
            return Number.isSafeInteger(size) ? { size } : { error: `could not write ${name}` };
        } catch (e) {
            return { error: `could not write ${name}: ${e instanceof Error ? e.message : String(e)}` };
        } finally {
            stopKeep();
            await this.#touch();
        }
    }

    // box.save, step 1: the file's size and first 64 bytes (the Worker types it by them).
    async stat(thread: string, path: string): Promise<BoxStat | BoxError> {
        const p = await this.#prepare(thread);
        if (p) return p;
        const script = 'f="$1"; [ -f "$f" ] || { echo "no such file: $f" >&2; exit 2; }; stat -L -c %s -- "$f" && head -c 64 -- "$f" | od -An -v -tx1';
        const proc = await this.#d.exec(["bash", "-c", script, "box-stat", path], { cwd: WORKDIR, env: BOX_ENV, user: BOX_USER });
        const out = new Clip();
        const err = new Clip();
        await Promise.all([drain(proc.stdout, out), drain(proc.stderr, err)]);
        const code = await proc.exitCode;
        await this.#touch();
        if (code !== 0) return { error: err.text().trim().slice(0, 300) || `could not read ${path}` };
        const [first, ...rest] = out.text().trim().split("\n");
        const size = Number(first);
        if (!Number.isSafeInteger(size)) return { error: `could not read ${path}` };
        const head = rest.join(" ").trim().split(/\s+/).filter(Boolean).map((h) => parseInt(h, 16));
        return { size, head };
    }

    // box.save, step 2: the file's bytes as a stream (the Worker gives it a known length and stores it like an upload).
    async read(thread: string, path: string): Promise<ReadableStream<Uint8Array> | BoxError> {
        const p = await this.#prepare(thread);
        if (p) return p;
        const proc = await this.#d.exec(["cat", "--", path], { cwd: WORKDIR, env: BOX_ENV, user: BOX_USER, stderr: "ignore" });
        if (!proc.stdout) return { error: `could not read ${path}` };
        const stopKeep = this.#keepAwake();
        const touch = () => {
            stopKeep();
            void this.#touch().catch(() => {});
        };
        // the stream ends (or is cancelled) before the box may sleep again
        const reader = proc.stdout.getReader();
        return new ReadableStream<Uint8Array>({
            async pull(c) {
                const { done, value } = await reader.read();
                if (done) {
                    touch();
                    c.close();
                } else c.enqueue(value);
            },
            async cancel(reason) {
                touch();
                await reader.cancel(reason).catch(() => {});
            },
        });
    }
}

export { SLEEP_MS };
