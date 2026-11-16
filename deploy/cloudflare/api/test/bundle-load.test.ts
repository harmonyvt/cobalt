// The Worker as one bundle, loaded the way Cloudflare loads it: every module evaluated in the bundle's order. The other
// tests import modules one by one, in their own order, so an import cycle that reads an export before its module has run
// (2026-11-15: make.ts -> swarm.ts -> chat.ts -> the registry -> editor.ts reading make.ts's ProjectSchema) passes them and
// only fails at upload ("Cannot read properties of undefined"). `cloudflare:*` and @cloudflare/containers are stubbed.
import { build } from "esbuild";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { expect, it } from "vitest";

const STUB = `export class DurableObject {} export class WorkerEntrypoint {} export class RpcTarget {} export class WorkflowEntrypoint {}
export class Container {} export function getContainer() {} export const env = {}; export default {};`;

it("the bundled Worker loads without reading an export before its module has run", async () => {
    const dir = mkdtempSync(join(tmpdir(), "cobalt-bundle-"));
    const stub = join(dir, "stub.mjs");
    writeFileSync(stub, STUB);
    const out = join(dir, "worker.mjs");
    await build({
        entryPoints: [join(__dirname, "../src/index.ts")],
        bundle: true,
        format: "esm",
        platform: "neutral",
        mainFields: ["module", "main"],
        conditions: ["workerd", "worker", "browser"],
        external: ["node:*"],
        alias: { "@cloudflare/containers": stub },
        plugins: [{ name: "cf", setup: (b) => b.onResolve({ filter: /^cloudflare:/ }, () => ({ path: stub })) }],
        outfile: out,
        logLevel: "silent",
    });
    const mod = await import(pathToFileURL(out).href);
    expect(mod.default).toBeDefined();
}, 60_000);
