// Writes CobaltKitTests/ServerSwarmExtraCases.swift: more swarm Live Activity inputs than the fixture has, each with the
// state the SERVER's `jobOfSwarm` (deploy/cloudflare/api/src/job-live.ts) makes for it. Run from the repo root:
//   node apple/CobaltKit/Tests/gen-swarm-live-cases.mjs
// (Node 22+ strips the types; job-live.ts only has type imports.) The Swift tests then hold the app's builder to those words.
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { jobOfSwarm } from "../../../deploy/cloudflare/api/src/job-live.ts";

const MS = 1790000000 * 1000;
const base = {
    id: "Sw4rmIdSw4rmId01", name: "clean emote names", mode: "propose", status: "running", apply_status: "none",
    spec_hash: "a1b2c3d4e5f60718", planner: "claude code", est_low: 0.12, est_high: 0.4, spent_usd: 0.21, cap_usd: 2, error: null,
    reduce: null, created_at: MS, approved_at: MS + 60_000, finished_at: null, expires_at: MS + 3_600_000, cells: "ddrwq",
    changes: { total: 7, kept: 0, open: 0, clashes: 0, done: 0, failed: 0 },
};
const ended = { finished_at: MS + 600_000, cells: "ddddf" };
const ch = (total, kept, open, clashes, done, failed) => ({ total, kept, open, clashes, done, failed });
const none = ch(0, 0, 0, 0, 0, 0);

const cases = [
    ["asks_plural", { cells: "dwwrq" }, 120_000],
    ["asks_single_read_mode", { mode: "read", cells: "dwrrq", spent_usd: 0.5 }, 120_000],
    ["running_no_agents", { cells: "" }, 120_000],
    ["running_one_change", { cells: "ddrrq", changes: ch(1, 0, 0, 0, 0, 0) }, 120_000],
    ["running_skipped_count_as_ended", { cells: "dsfrq" }, 120_000],
    ["running_not_approved_yet_since", { approved_at: null, cells: "qqqqq" }, 120_000],
    ["money_under_a_cent", { mode: "read", spent_usd: 0.004 }, 120_000],
    ["money_nothing", { mode: "read", spent_usd: 0, cells: "rrrrr" }, 120_000],
    ["money_whole_dollar", { mode: "read", spent_usd: 1 }, 120_000],
    ["money_dollars_and_cents", { mode: "read", spent_usd: 12.5 }, 120_000],
    ["money_rounds_half_up", { mode: "read", spent_usd: 0.125 }, 120_000],
    ["awaiting_one_minute_left", { status: "awaiting_approval", approved_at: null, cells: "qqqqq" }, 3_600_000 - 10_000],
    ["awaiting_same_estimate", { status: "awaiting_approval", approved_at: null, cells: "qqqqq", est_low: 0.4, est_high: 0.4 }, 60_000],
    ["awaiting_big_estimate_mcp", { status: "awaiting_approval", approved_at: null, cells: "qqqqq", est_low: 0.9, est_high: 3.05, planner: "mcp" }, 60_000],
    ["awaiting_long_name", { status: "awaiting_approval", approved_at: null, cells: "qqqqq", name: "rename every emote in the nyaphelia christmas set to a tidy lowercase alias" }, 60_000],
    ["awaiting_after_its_hour", { status: "awaiting_approval", approved_at: null, cells: "qqqqq" }, 3_600_000 + 5 * 60_000],
    ["stopping_nothing_yet", { status: "stopping", cells: "" }, 120_000],
    ["ready_one_clash", { ...ended, status: "done", apply_status: "ready", changes: ch(7, 6, 1, 1, 5, 0) }, 700_000],
    ["ready_no_clash", { ...ended, status: "done", apply_status: "ready", changes: ch(7, 6, 6, 0, 0, 0) }, 700_000],
    ["ready_after_stopping", { ...ended, status: "stopped", apply_status: "ready", changes: ch(7, 6, 3, 0, 3, 0) }, 700_000],
    ["ready_nothing_open_is_just_done", { ...ended, status: "done", apply_status: "ready", changes: ch(7, 6, 0, 0, 6, 0) }, 700_000],
    ["applying_nothing_kept", { ...ended, status: "done", apply_status: "applying", changes: ch(7, 0, 0, 0, 0, 0) }, 700_000],
    ["applied_one", { ...ended, status: "done", apply_status: "applied", changes: ch(7, 1, 0, 0, 1, 0) }, 700_000],
    ["applied_with_failures", { ...ended, status: "done", apply_status: "failed", changes: ch(7, 6, 1, 0, 5, 1) }, 700_000],
    ["done_propose_without_changes", { ...ended, status: "done" }, 700_000],
    ["done_read_empty_reduce", { ...ended, mode: "read", status: "done", reduce: "  \n " }, 700_000],
    ["done_read_long_reduce", { ...ended, mode: "read", status: "done", reduce: "tagged 971 clips; 29 had no clear game, so they stay untagged until someone looks at them one by one" }, 700_000],
    ["failed_daily_cap", { ...ended, mode: "read", status: "failed", error: "error.swarm.daily_cap" }, 700_000],
    ["failed_over_cap_cents", { ...ended, mode: "read", status: "stopped", error: "error.swarm.over_cap", cap_usd: 0.5 }, 700_000],
    ["failed_too_many", { ...ended, mode: "read", status: "failed", error: "error.swarm.too_many_failed" }, 700_000],
    ["failed_all", { ...ended, mode: "read", status: "failed", error: "error.swarm.all_failed" }, 700_000],
    ["failed_off", { ...ended, mode: "read", status: "failed", error: "error.swarm.off" }, 700_000],
    ["failed_unknown_code", { ...ended, mode: "read", status: "failed", error: "error.swarm.model" }, 700_000],
    ["failed_no_code", { ...ended, mode: "read", status: "failed" }, 700_000],
    ["stopped_by_owner", { ...ended, status: "stopped" }, 700_000],
    ["stopped_not_finished_yet", { status: "stopped", finished_at: null, cells: "ddsss" }, 700_000],
    ["declined_nothing_finished", { status: "declined", approved_at: null, finished_at: null, cells: "sssss" }, 30_000],
    ["expired_by_the_sweep", { status: "expired", approved_at: null, cells: "qqqqq", finished_at: MS + 3_600_000 }, 3_700_000],
];

const camel = (s) => s.replace(/_([a-z])/g, (_, c) => c.toUpperCase());
const sw = (v) => JSON.stringify(v); // a Swift string literal for these ASCII-or-simple texts
const swStr = (v) => `"${[...v].map((c) => (c === "\\" ? "\\\\" : c === '"' ? '\\"' : c === "\n" ? "\\n" : c)).join("")}"`;
const opt = (v, f) => (v === null ? "nil" : f(v));
function swiftInput(i) {
    const c = i.changes;
    return `SwarmLiveInput(
            id: ${swStr(i.id)}, name: ${swStr(i.name)}, mode: .${i.mode}, status: .${camel(i.status)}, applyStatus: .${i.apply_status},
            specHash: ${swStr(i.spec_hash)}, planner: ${swStr(i.planner)}, estLow: ${i.est_low}, estHigh: ${i.est_high},
            spentUSD: ${i.spent_usd}, capUSD: ${i.cap_usd}, error: ${opt(i.error, swStr)}, reduce: ${opt(i.reduce, swStr)},
            createdAt: ${i.created_at}, approvedAt: ${opt(i.approved_at, String)}, finishedAt: ${opt(i.finished_at, String)},
            expiresAt: ${opt(i.expires_at, String)}, cells: ${swStr(i.cells)},
            changes: .init(total: ${c.total}, kept: ${c.kept}, open: ${c.open}, clashes: ${c.clashes}, done: ${c.done}, failed: ${c.failed}))`;
}

let out = `import Foundation
@testable import CobaltKit

// GENERATED by apple/CobaltKit/Tests/gen-swarm-live-cases.mjs: do not edit by hand. Each case is an input to the server's
// \`jobOfSwarm\` (deploy/cloudflare/api/src/job-live.ts) and the attributes and state it wrote when the file was made; the tests
// hold the app's builder to the same bytes. Regenerate with \`node apple/CobaltKit/Tests/gen-swarm-live-cases.mjs\` after the
// server's words change.

struct ServerSwarmExtraCase {
    var name: String
    var input: SwarmLiveInput
    var nowMs: Double
    /// The server's attributes and state, compact JSON in its key order.
    var attributes: String
    var state: String
    /// \`input\` is what a \`Swarm\` answer maps to (the kept changes not done are \`kept - done\`; no changes outside propose mode).
    var viaSwarm: Bool
}

let serverSwarmExtraCases: [ServerSwarmExtraCase] = [
`;
for (const [name, patch, offset] of cases) {
    const input = { ...base, ...patch };
    if (input.mode !== "propose" && !patch.changes) input.changes = none;
    const job = jobOfSwarm(input, MS + offset);
    const c = input.changes;
    const consistent = input.mode === "propose" ? c.open === c.kept - c.done && c.clashes <= c.open : c.total === 0;
    out += `    ServerSwarmExtraCase(
        name: ${swStr(name)},
        input: ${swiftInput(input)},
        nowMs: ${MS + offset}, attributes: #"${JSON.stringify(job.attributes)}"#,
        state: #"${JSON.stringify(job.state)}"#, viaSwarm: ${consistent}),
`;
}
out += "]\n";
const here = dirname(fileURLToPath(import.meta.url));
writeFileSync(join(here, "CobaltKitTests/ServerSwarmExtraCases.swift"), out);
console.log(`wrote ${cases.length} cases`);
