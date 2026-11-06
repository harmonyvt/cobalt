// The labelled pilot (APP-API-CONTRACT.md section 51.6). Harmony puts about/pilot-labels.json in the private bucket;
// the 15-minute cron rates those files with Clef and writes about/pilot-report.json beside it. Clef only: the report
// is her label next to Clef's level, probabilities and flags, for her to calibrate the thresholds. At most 60 ids.

import { PILOT_LABELS_KEY, PILOT_REPORT_KEY, SAFETY_PILOT_MAX } from "./safety";

export type PilotLabel = { id: string; label: string };

export type PilotClef = {
    level: string;
    probs: unknown;
    gore: boolean;
    drawn: boolean;
    minor_sexual: boolean;
    model: string | null;
};

export type PilotRow = { id: string; label: string; clef: PilotClef | null; error: "not_ready" | "failed" | null };

export type PilotReport = { labels_hash: string; rows: PilotRow[] };

type ReadBucket = { get(key: string): Promise<{ body: ReadableStream; size: number } | null> };
type WriteBucket = ReadBucket & {
    put(key: string, value: Uint8Array | string, options?: { httpMetadata?: { contentType?: string } }): Promise<unknown>;
    delete?(key: string): Promise<unknown>;
};

const ID_RE = /^[A-Za-z0-9]{8,64}$/;

export function parsePilotLabels(raw: unknown): PilotLabel[] | null {
    const list = Array.isArray(raw) ? raw : raw && typeof raw === "object" && Array.isArray((raw as { items?: unknown }).items) ? (raw as { items: unknown[] }).items : null;
    if (!list) return null;
    const out: PilotLabel[] = [];
    const seen = new Set<string>();
    for (const item of list) {
        if (!item || typeof item !== "object") continue;
        const id = (item as { id?: unknown }).id;
        const label = (item as { label?: unknown }).label;
        if (typeof id !== "string" || !ID_RE.test(id) || seen.has(id)) continue;
        if (typeof label !== "string") continue;
        const clean = label.replace(/\s+/g, " ").trim().slice(0, 80);
        if (!clean) continue;
        seen.add(id);
        out.push({ id, label: clean });
        if (out.length >= SAFETY_PILOT_MAX) break;
    }
    return out.length > 0 ? out : null;
}

async function readJson(bucket: ReadBucket, key: string): Promise<unknown> {
    const o = await bucket.get(key).catch(() => null);
    if (!o) return null;
    try {
        return JSON.parse(await new Response(o.body).text());
    } catch {
        return null;
    }
}

export async function readPilotLabels(bucket: ReadBucket): Promise<PilotLabel[] | null> {
    return parsePilotLabels(await readJson(bucket, PILOT_LABELS_KEY));
}

export async function readPilotReport(bucket: ReadBucket): Promise<PilotReport | null> {
    const v = await readJson(bucket, PILOT_REPORT_KEY);
    if (!v || typeof v !== "object") return null;
    const rows = (v as { rows?: unknown }).rows;
    const labels_hash = (v as { labels_hash?: unknown }).labels_hash;
    if (typeof labels_hash !== "string" || !Array.isArray(rows)) return null;
    return { labels_hash, rows: rows.filter((r): r is PilotRow => !!r && typeof r === "object" && typeof (r as PilotRow).id === "string") };
}

export async function writePilotReport(bucket: WriteBucket, report: PilotReport): Promise<void> {
    await bucket.put(PILOT_REPORT_KEY, JSON.stringify(report, null, 2), { httpMetadata: { contentType: "application/json" } });
}

export function formatPilotReport(labels: PilotLabel[], report: PilotReport | null): string {
    const byId = new Map((report?.rows ?? []).map((r) => [r.id, r]));
    const lines = ["id\tlabel\tclef\tgore\tdrawn\tminor_sexual\tnote"];
    for (const l of labels) {
        const row = byId.get(l.id);
        if (!row || !row.clef) {
            lines.push([l.id, l.label, "", "", "", "", row?.error ?? "waiting"].join("\t"));
            continue;
        }
        lines.push([l.id, l.label, row.clef.level, row.clef.gore ? "yes" : "no", row.clef.drawn ? "yes" : "no", row.clef.minor_sexual ? "yes" : "no", row.error ?? ""].join("\t"));
    }
    return lines.join("\n") + "\n";
}

export { PILOT_LABELS_KEY, PILOT_REPORT_KEY };
