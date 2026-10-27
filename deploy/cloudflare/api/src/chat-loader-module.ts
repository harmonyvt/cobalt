// Chat code mode (APP-API-CONTRACT.md section 27): the module source a Dynamic Worker runs for one code
// run (chat-loader.ts). No Cloudflare imports here, so the tests evaluate the same source under node.

import { CODE_TIMEOUT_MS } from "./chat-limits";

// The module the sandbox runs: `evaluate(dispatcher)` builds `cobalt`, captures console, runs the code.
export function sandboxModule(code: string): string {
    return [
        `import { WorkerEntrypoint } from "cloudflare:workers";`,
        `export default class Run extends WorkerEntrypoint {`,
        `  async evaluate(__d) {`,
        `    const __logs = [];`,
        `    const __fmt = (a) => a.map((x) => typeof x === "string" ? x : (() => { try { return JSON.stringify(x); } catch { return String(x); } })()).join(" ");`,
        `    console.log = (...a) => { if (__logs.length < 200) __logs.push(__fmt(a)); };`,
        `    console.info = console.log;`,
        `    console.warn = (...a) => { if (__logs.length < 200) __logs.push("[warn] " + __fmt(a)); };`,
        `    console.error = (...a) => { if (__logs.length < 200) __logs.push("[error] " + __fmt(a)); };`,
        // cobalt.library.search(...) and the old flat cobalt.search(...): every name is callable and also a namespace;
        // the dotted path is what the Worker's dispatcher looks up (section 33.3)
        `    const __node = (path) => new Proxy(async function () {}, {`,
        `      get: (_, name) => typeof name !== "string" || name === "then" ? undefined : __node(path ? path + "." + name : name),`,
        `      apply: async (_, __, args) => {`,
        `        const r = JSON.parse(await __d.call(path, JSON.stringify(args)));`,
        `        if (r.error) throw new Error(r.error);`,
        `        return r.result;`,
        `      },`,
        `    });`,
        `    const cobalt = __node("");`,
        `    try {`,
        `      const result = await Promise.race([`,
        `        (async () => {`,
        code,
        `        })(),`,
        `        new Promise((_, reject) => setTimeout(() => reject(new Error("timed out after ${CODE_TIMEOUT_MS / 1000} s")), ${CODE_TIMEOUT_MS})),`,
        `      ]);`,
        `      let out; try { out = JSON.stringify(result === undefined ? null : result); } catch { out = JSON.stringify(String(result)); }`,
        `      return { result: out, logs: __logs };`,
        `    } catch (e) {`,
        `      return { error: e && e.message ? String(e.message) : String(e), logs: __logs };`,
        `    }`,
        `  }`,
        `}`,
    ].join("\n");
}

