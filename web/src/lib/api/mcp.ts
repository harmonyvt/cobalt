// tiny client for the same-origin /api/mcp endpoints of the deployed site (the
// web worker checks cloudflare access, then asks the api). same rules as
// keys.ts: never follow redirects, an expired session is "expired".

export type McpMode = "off" | "public" | "private";

export type McpSettings = {
    mode: McpMode;
    public_url: string;
    link: null | {
        hint: string;
        tail: string;
        made_at: number;
        last_used_at: number | null;
        used_by: string | null;
        calls_today: number;
    };
};

export type McpChange = { settings: McpSettings; link_url?: string };

export type McpResult<T> =
    | { ok: true; data: T }
    | { ok: false; reason: "expired" | "unavailable" }
    | { ok: false; reason: "api"; code: string };

const call = async <T>(path: string, init: RequestInit, getMeansUnavailable = false): Promise<McpResult<T>> => {
    let res: Response;
    try {
        res = await fetch(path, { ...init, redirect: "manual", cache: "no-store", credentials: "same-origin" });
    } catch {
        return { ok: false, reason: "unavailable" };
    }
    if (res.type === "opaqueredirect" || res.status === 0 || res.status === 401) {
        return { ok: false, reason: "expired" };
    }
    if (getMeansUnavailable && res.status === 404) return { ok: false, reason: "unavailable" };
    if (res.status === 200) {
        try {
            return { ok: true, data: (await res.json()) as T };
        } catch {
            return { ok: false, reason: "unavailable" };
        }
    }
    try {
        const body = await res.json();
        if (typeof body?.error === "string") return { ok: false, reason: "api", code: body.error };
    } catch {
        // fall through
    }
    return { ok: false, reason: "api", code: "server_error" };
};

export const getMcp = async (): Promise<McpResult<McpSettings>> => {
    const res = await call<McpSettings>("/api/mcp", { method: "GET", headers: { accept: "application/json" } }, true);
    if (res.ok && typeof res.data?.mode !== "string") return { ok: false, reason: "unavailable" };
    return res;
};

export const setMcpMode = (mode: McpMode) =>
    call<McpChange>("/api/mcp", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ mode }),
    });

export const rotateMcpLink = () => call<McpChange>("/api/mcp/rotate", { method: "POST" });
