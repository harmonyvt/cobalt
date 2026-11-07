#!/usr/bin/env node
// The labelled Clef pilot (APP-API-CONTRACT.md section 51.6).
//
// Harmony labels up to 60 library files by hand, this puts the list where the 15-minute cron can see it, and the
// cron rates those files with Clef-omni (and nothing else) and writes a report. There is no Haiku column.
//
//   labels.json:  { "items": [ { "id": "<media item id>", "label": "general" }, ... ] }
//                 label is whatever Harmony called it (general, sensitive, questionable, explicit, or a note).
//
//   node deploy/cloudflare/api/scripts/safety-pilot.mjs labels.json --dry-run
//   node deploy/cloudflare/api/scripts/safety-pilot.mjs labels.json
//   node deploy/cloudflare/api/scripts/safety-pilot.mjs --report
//
// The upload uses Wrangler (`r2 object put`), into the private bucket cobalt-originals at about/pilot-labels.json.
// Deploy itself stays on the `cf` CLI; Wrangler is only how this script puts one object. The cron prepares a clip
// for each id (even an old file) and then calls Clef, at most 20 files a run and no faster than one call every
// 3 seconds. A file whose clip is not ready yet shows as "not_ready"; the next runs fill those in. When every id
// has a Clef answer (or a prep failure that will not be tried again), the labels object is removed so the cron
// goes back to new saves only. A prep that failed before the current prep path (`prep_rev`) is tried again, and a
// report row with no Clef level is still queued if the labels file is already gone.
//
//   node deploy/cloudflare/api/scripts/safety-pilot.mjs --report
// prints id, Harmony's label, Clef's level, and the gore / drawn / minor_sexual flags.
//
// Full-library backfill is not this script. Set SAFETY_BACKFILL=1 on the Worker when that should start.
// Thresholds (no re-rate): SAFETY_STAGE_MAX, SAFETY_GORE_AT, SAFETY_MINOR_AT.
// The binding's max request size is undocumented. A ~3 MB clip plus the mp3 is what src/safety-clef.ts sends;
// test/safety.test.ts builds that body and checks it stays under 12 MB of JSON.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const LABELS_KEY = "about/pilot-labels.json";
const REPORT_KEY = "about/pilot-report.json";
const BUCKET = "cobalt-originals";

const args = process.argv.slice(2);
const dry = args.includes("--dry-run");
const report = args.includes("--report");
const file = args.find((a) => !a.startsWith("--"));

function wrangler(cmd) {
    return execFileSync("npx", ["wrangler", ...cmd], { encoding: "utf8" });
}

function labelsFrom(path) {
    const raw = JSON.parse(readFileSync(path, "utf8"));
    const list = Array.isArray(raw) ? raw : raw.items;
    if (!Array.isArray(list) || list.length === 0) throw new Error("labels file needs an items array");
    if (list.length > 60) throw new Error(`at most 60 labels; got ${list.length}`);
    for (const item of list) {
        if (!item || typeof item.id !== "string" || typeof item.label !== "string") throw new Error("each item needs an id and a label");
        if (!/^[A-Za-z0-9]{8,64}$/.test(item.id)) throw new Error(`bad id ${item.id}`);
    }
    return list;
}

function printReport(body) {
    console.log(["id", "label", "clef", "gore", "drawn", "minor_sexual", "note"].join("\t"));
    for (const row of body.rows ?? []) {
        const c = row.clef;
        const note = row.error === "failed" && typeof row.prep_error === "string" && row.prep_error ? `failed: ${row.prep_error.replace(/\t/g, " ")}` : (row.error ?? "");
        console.log([row.id, row.label, c?.level ?? "", c ? (c.gore ? "yes" : "no") : "", c ? (c.drawn ? "yes" : "no") : "", c ? (c.minor_sexual ? "yes" : "no") : "", note].join("\t"));
    }
    if ((body.rows ?? []).length === 0) console.log("(no rows yet; the cron has not rated this list)");
}

if (report) {
    const raw = wrangler(["r2", "object", "get", `${BUCKET}/${REPORT_KEY}`, "--remote", "--pipe"]);
    printReport(JSON.parse(raw));
} else if (!file) {
    console.error("usage: node deploy/cloudflare/api/scripts/safety-pilot.mjs <labels.json> [--dry-run]");
    console.error("       node deploy/cloudflare/api/scripts/safety-pilot.mjs --report");
    process.exit(1);
} else {
    const items = labelsFrom(file);
    console.log(`${items.length} labelled file${items.length === 1 ? "" : "s"}`);
    if (dry) {
        console.log(`dry run: would upload ${file} to r2://${BUCKET}/${LABELS_KEY}`);
        process.exit(0);
    }
    wrangler(["r2", "object", "put", `${BUCKET}/${LABELS_KEY}`, "--file", file, "--content-type", "application/json", "--remote"]);
    console.log(`uploaded to r2://${BUCKET}/${LABELS_KEY}`);
    console.log("The 15-minute cron rates up to 20 of these a run. Then:");
    console.log("  node deploy/cloudflare/api/scripts/safety-pilot.mjs --report");
}
