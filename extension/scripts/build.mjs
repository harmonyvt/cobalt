// Bundles the extension into dist/ for Chrome's "Load unpacked" and for the Safari Xcode script.
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import * as esbuild from "esbuild";

const manifest = JSON.parse(readFileSync(new URL("../src/manifest.json", import.meta.url), "utf8"));

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const out = resolve(root, "dist");

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

await esbuild.build({
    absWorkingDir: root,
    entryPoints: {
        background: "src/background.ts",
        "content/x": "src/entries/x.ts",
        "content/youtube": "src/entries/youtube.ts",
        "content/twitch": "src/entries/twitch.ts",
        "content/instagram": "src/entries/instagram.ts",
        popup: "src/popup.ts",
        options: "src/options.ts",
    },
    bundle: true,
    format: "iife",
    target: "es2022",
    outdir: out,
    legalComments: "none",
});

for (const file of ["src/popup.html", "src/popup.css", "src/options.html", "src/options.css"]) {
    cpSync(resolve(root, file), resolve(out, file.slice("src/".length)));
}
cpSync(resolve(root, "assets"), resolve(out, "assets"), { recursive: true });
writeFileSync(resolve(out, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
console.log("wrote", out);
