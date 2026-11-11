// Serves widgets-dev/ for a person: `node widgets-dev/serve.mjs [port]`, then open the printed address.
import { createServer } from "node:http";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join, extname } from "node:path";
import { fileURLToPath } from "node:url";
import { buildHost } from "./build.mjs";
const here = dirname(fileURLToPath(import.meta.url));
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".json": "application/json" };
export function serve(port = 0) {
    const srv = createServer((req, res) => {
        const p = new URL(req.url, "http://x").pathname;
        const f = join(here, p === "/" ? "index.html" : p);
        if (!f.startsWith(here) || !existsSync(f) || f.includes("..")) { res.writeHead(404).end("not found"); return; }
        res.writeHead(200, { "content-type": TYPES[extname(f)] || "application/octet-stream" }).end(readFileSync(f));
    });
    return new Promise((r) => srv.listen(port, "127.0.0.1", () => r(srv)));
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
    await buildHost();
    const srv = await serve(Number(process.argv[2]) || 5173);
    console.log(`widgets dev host: http://127.0.0.1:${srv.address().port}/  (#search.grid etc. loads a fixture)`);
}
