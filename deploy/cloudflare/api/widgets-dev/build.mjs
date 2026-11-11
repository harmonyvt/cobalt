// Bundles the dev host (ext-apps' real AppBridge + the generated widgets) into widgets-dev/dist/. Run by check.mjs.
import { build } from "esbuild";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
const here = dirname(fileURLToPath(import.meta.url));
export async function buildHost() {
    await build({ entryPoints: [join(here, "host.js")], bundle: true, format: "iife", outfile: join(here, "dist/host.js"), platform: "browser", target: "es2022", logLevel: "warning", define: { "process.env.NODE_ENV": '"development"' } });
}
if (process.argv[1] === fileURLToPath(import.meta.url)) { await buildHost(); console.log("built widgets-dev/dist/host.js"); }
