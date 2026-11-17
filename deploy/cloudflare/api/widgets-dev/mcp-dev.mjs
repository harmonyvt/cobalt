// The local MCP dev server: the real MCP code path over demo data, to try the app in a host without a deploy.
//   node widgets-dev/mcp-dev.mjs --public-url https://xxxx.trycloudflare.com
// Run `npm run widgets` first when the widgets changed (this serves src/mcp-app/widgets.generated.ts as it is).
import { build } from "esbuild";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const dist = join(here, "dist");

// The server code (TypeScript, shared with the Worker) bundled for node. Packages stay external (api/node_modules).
async function bundle(entry, outName) {
    mkdirSync(dist, { recursive: true });
    const out = join(dist, outName);
    await build({
        entryPoints: [join(here, entry)],
        outfile: out,
        bundle: true,
        format: "esm",
        platform: "node",
        target: "node22",
        packages: "external",
        logLevel: "warning",
        plugins: [
            {
                // test-support/d1-sqlite.ts finds the migrations from its own file URL, which a bundle changes
                name: "keep-import-meta-url",
                setup(b) {
                    b.onLoad({ filter: /d1-sqlite\.ts$/ }, (args) => ({
                        contents: readFileSync(args.path, "utf8").replaceAll("import.meta.url", JSON.stringify(pathToFileURL(args.path).href)),
                        loader: "ts",
                    }));
                },
            },
        ],
    });
    return out;
}
export const buildDevServer = () => bundle("mcp-dev-entry.ts", "mcp-dev-entry.mjs");
// the real tools, shapes and widgets, for a script that checks the server's answers
export const buildToolsBundle = () => bundle("mcp-dev-tools.ts", "mcp-dev-tools.mjs");

// A small mp4 for the demo videos, made once with ffmpeg when it is installed; null otherwise (pictures only).
export function sampleVideo() {
    const file = join(dist, "demo-sample.mp4");
    if (existsSync(file)) return file;
    mkdirSync(dist, { recursive: true });
    const r = spawnSync(
        "ffmpeg",
        ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=360x640:rate=24:duration=44", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "veryfast", "-crf", "34", "-movflags", "+faststart", file],
        { stdio: "ignore" },
    );
    if (r.status === 0 && existsSync(file)) return file;
    rmSync(file, { force: true });
    return null;
}

export async function startDev(opts = {}) {
    const entry = await buildDevServer();
    const { startDevServer } = await import(`${pathToFileURL(entry).href}?t=${Date.now()}`);
    return startDevServer({ sampleVideo: sampleVideo(), ...opts });
}

const HELP = `capystore MCP dev server: the real MCP app code over DEMO data, to try it in Claude, ChatGPT or Grok.

It serves the real tools and widgets (src/mcp-app) at POST /mcp with no sign-in, on a seeded in-memory library (about 13
posts, 3 share links, 2 collections, 2 edit projects). Container-backed ops are faked in-process: the webp encode (about 7 s),
the save (about 5 s; a link with "fail" in it fails), the editor reads, and PUT /mcp/upload/<token> takes real bytes into
memory. It serves its own pictures and share pages, and never touches the real library, the cloud or any secret.

Usage
  npm run widgets                       # first, when the widgets changed
  node widgets-dev/mcp-dev.mjs --public-url https://xxxx.trycloudflare.com

Options
  --public-url <url>   the https origin hosts reach this server at (or PUBLIC_URL); default http://localhost:<port>.
                       The widgets' CSP names this origin for pictures and the upload PUT.
  --port <n>           default 8788 (or PORT)
  --host <addr>        bind address; default all interfaces
  --webp-seconds <n>   how long the fake webp encode takes (default 7)
  --save-seconds <n>   how long the fake save takes (default 5)
  --help

Tunnel (a host needs a public https URL; start one yourself, this never does)
  cloudflared tunnel --url http://localhost:8788
  ngrok http 8788
Then restart this with --public-url set to the tunnel URL, and add <public url>/mcp as a connector (no sign-in).
Claude also wants a ui.domain for the connector: it is printed below the URL.
`;

if (process.argv[1] === fileURLToPath(import.meta.url)) {
    const args = process.argv.slice(2);
    if (args.includes("--help") || args.includes("-h")) {
        console.log(HELP);
        process.exit(0);
    }
    const flag = (name) => {
        const i = args.indexOf(name);
        return i >= 0 ? args[i + 1] : undefined;
    };
    const known = new Set(["--public-url", "--port", "--host", "--webp-seconds", "--save-seconds"]);
    for (const a of args) {
        if (a.startsWith("-") && !known.has(a)) {
            console.error(`unknown option ${a} (see --help)`);
            process.exit(2);
        }
    }
    const port = Number(flag("--port") ?? process.env.PORT ?? 8788);
    const publicUrl = flag("--public-url") ?? process.env.PUBLIC_URL;
    if (publicUrl && !/^https?:\/\/[^/\s]+\/?$/.test(publicUrl)) {
        console.error("--public-url must be an origin like https://xxxx.trycloudflare.com");
        process.exit(2);
    }
    let dev;
    try {
        dev = await startDev({
            port,
            host: flag("--host"),
            publicUrl,
            webpMs: flag("--webp-seconds") ? Number(flag("--webp-seconds")) * 1000 : undefined,
            saveMs: flag("--save-seconds") ? Number(flag("--save-seconds")) * 1000 : undefined,
            log: (l) => console.log(`[dev] ${l}`),
        });
    } catch (e) {
        console.error(e && e.code === "EADDRINUSE" ? `port ${port} is in use: pick another with --port` : e);
        process.exit(1);
    }
    console.log(`capystore MCP dev server (demo data only)`);
    console.log(`  listening:   http://localhost:${dev.port}`);
    console.log(`  MCP URL:     ${dev.mcpUrl}   (paste into the host, no sign-in)`);
    console.log(`  tools only:  ${dev.mcpUrl}?tools=app`);
    console.log(`  Claude ui.domain for that URL: ${dev.claudeDomain}`);
    console.log(`  media/share: ${dev.mediaBase} and ${dev.publicOrigin}/s/`);
    if (!publicUrl) console.log(`  no --public-url: fine for a local client; a host needs a tunnel (see --help)`);
    if (!sampleVideo()) console.log(`  ffmpeg not found: demo videos show their poster only`);
    const stop = () => dev.close().then(() => process.exit(0));
    process.on("SIGINT", stop);
    process.on("SIGTERM", stop);
}
