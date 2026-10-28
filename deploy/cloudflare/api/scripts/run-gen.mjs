// Runs scripts/gen.ts under plain node: esbuild bundles it (and the registry it reads) into one temporary module first.
// `node scripts/run-gen.mjs` writes the generated files; `--check` only compares them (APP-API-CONTRACT.md 33.13).
import { build } from "esbuild";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "../../../..");
// inside node_modules, so the bundle's own imports (zod and the rest) resolve as they do for the sources
const cache = join(here, "../node_modules/.cache");
mkdirSync(cache, { recursive: true });
const dir = mkdtempSync(join(cache, "cobalt-gen-"));
const out = join(dir, "gen.mjs");
try {
    await build({
        entryPoints: [join(here, "gen.ts")],
        bundle: true,
        platform: "node",
        format: "esm",
        target: "node22",
        outfile: out,
        // the packages stay where npm put them
        packages: "external",
        logLevel: "warning",
    });
    const gen = await import(pathToFileURL(out).href);
    process.exitCode = gen.main(root, process.argv.includes("--check"));
} finally {
    rmSync(dir, { recursive: true, force: true });
}
