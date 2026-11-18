// What a save looks like on the button, the toast and the popup. Built from GET /studio/<id>
// (step, step_bytes, step_total, waking, queue_ahead, service, error.code, public_url).

export type SaveProgress = {
    step: string | null;
    bytes: number | null;
    total: number | null;
    waking: boolean;
    queueAhead: number | null;
    service: string | null;
    code: string | null;
    publicUrl: string | null;
};

export const EMPTY_PROGRESS: SaveProgress = {
    step: null,
    bytes: null,
    total: null,
    waking: false,
    queueAhead: null,
    service: null,
    code: null,
    publicUrl: null,
};

export type SaveFace = {
    label: string;
    /** 0..1 draws the ring. "spin" is the indeterminate ring (queued, waking, starting). null hides it. */
    ring: number | "spin" | null;
    toast: string;
    headline: string;
    fraction: number | null;
    open: boolean;
    copy: boolean;
    retry: boolean;
    details: boolean;
};

const FRIENDLY: Record<string, string> = {
    "error.webp.no_video": "Couldn't find a video in this post",
    "error.api.fetch.empty": "Couldn't find a video in this post",
    "error.api.content.video.unavailable": "This video isn't available",
    "error.api.content.video.private": "This video is private",
    "error.api.content.video.age": "This video needs a sign-in to watch",
    "error.api.youtube.login": "YouTube asked us to sign in",
    "error.studio.busy": "Capystore is busy. Try again in a moment.",
    "error.studio.line_full": "Capystore's queue is full. Try again in a moment.",
    "error.studio.too_large": "This file is too big to save",
    "error.studio.save_lost": "Capystore lost track of this save",
    "error.studio.expired": "This save expired",
    "error.studio.cancelled": "This save was cancelled",
    "error.studio.not_found": "Capystore couldn't find this save",
    "error.studio.not_video": "This isn't a video",
    "error.studio.upload_failed": "Capystore couldn't store this file",
    "error.api.fetch.fail": "The download failed",
};

export function friendlyError(code: string | null | undefined): string {
    if (code && FRIENDLY[code]) return FRIENDLY[code]!;
    return "Couldn't save this post";
}

export function progressOf(body: Record<string, unknown> | null | undefined): SaveProgress {
    const b = body ?? {};
    const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : null);
    const code = b.error && typeof b.error === "object" ? (b.error as { code?: unknown }).code : null;
    return {
        step: typeof b.step === "string" ? b.step : null,
        bytes: num(b.step_bytes),
        total: num(b.step_total),
        waking: b.waking === true,
        queueAhead: num(b.queue_ahead),
        service: typeof b.service === "string" ? b.service : null,
        code: typeof code === "string" ? code : null,
        publicUrl: typeof b.public_url === "string" ? b.public_url : null,
    };
}

function fraction(bytes: number | null, total: number | null): number | null {
    if (bytes === null || total === null || total <= 0) return null;
    return Math.min(1, Math.max(0, bytes / total));
}

function percent(f: number): string {
    return `${Math.round(Math.min(1, Math.max(0, f)) * 100)}%`;
}

/** "14.2 of 37.6 MB" — one unit, one decimal, decimal megabytes. */
export function sizePair(bytes: number, total: number): string {
    const mb = bytes >= 1_000_000 || total >= 1_000_000;
    const div = mb ? 1_000_000 : 1_000;
    const unit = mb ? "MB" : "KB";
    return `${(bytes / div).toFixed(1)} of ${(total / div).toFixed(1)} ${unit}`;
}

export function describeSave(status: "saving" | "saved" | "error", p: SaveProgress): SaveFace {
    if (status === "error") {
        return {
            label: "Retry",
            ring: null,
            toast: friendlyError(p.code),
            headline: friendlyError(p.code),
            fraction: null,
            open: false,
            copy: false,
            retry: true,
            details: true,
        };
    }
    if (status === "saved") {
        return {
            label: "Saved",
            ring: 1,
            toast: "Saved to Capystore · Open · Copy link",
            headline: "Saved to Capystore",
            fraction: 1,
            open: true,
            copy: true,
            retry: false,
            details: false,
        };
    }
    if (p.step === "queued") {
        const ahead = p.queueAhead ?? 0;
        const toast = ahead > 0 ? `Saving to Capystore · ${ahead} ahead of you` : "Saving to Capystore · next up";
        return { label: "Queued", ring: "spin", toast, headline: "Queued", fraction: null, open: false, copy: false, retry: false, details: false };
    }
    if (p.waking) {
        return {
            label: "Starting",
            ring: "spin",
            toast: "Waking the server…",
            headline: "Waking the server…",
            fraction: null,
            open: false,
            copy: false,
            retry: false,
            details: false,
        };
    }
    const f = fraction(p.bytes, p.total);
    const site = p.service && p.service !== "file" ? p.service : "the web";
    if (p.step === "storing" || p.step === "saving") {
        const pct = f === null ? null : percent(f);
        return {
            label: pct ?? "Starting",
            ring: f ?? "spin",
            toast: pct ? `Storing in your library · ${pct}` : "Storing in your library",
            headline: "Storing in your library",
            fraction: f,
            open: false,
            copy: false,
            retry: false,
            details: false,
        };
    }
    if (f !== null && p.bytes !== null && p.total !== null) {
        return {
            label: percent(f),
            ring: f,
            toast: `Downloading from ${site} · ${sizePair(p.bytes, p.total)}`,
            headline: `Downloading from ${site}`,
            fraction: f,
            open: false,
            copy: false,
            retry: false,
            details: false,
        };
    }
    return {
        label: "Starting",
        ring: "spin",
        toast: p.step === "fetching" ? `Downloading from ${site}` : "Starting…",
        headline: p.step === "fetching" ? `Downloading from ${site}` : "Starting",
        fraction: null,
        open: false,
        copy: false,
        retry: false,
        details: false,
    };
}
