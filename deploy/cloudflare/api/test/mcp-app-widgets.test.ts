// The MCP app widgets (MCP-APP-CONTRACT.md section 5): the generated file is fresh, and every entry is one
// self-contained page with the right default view. The browser proof is widgets-dev/check.mjs.
import { execFileSync } from "node:child_process";
import { describe, expect, it } from "vitest";
import { WIDGETS } from "../src/mcp-app/widgets.generated";
import { VIEWS, widgetUri } from "../src/mcp-app/shapes";

const CEILING = 60 * 1024;

describe("widgets.generated.ts", () => {
    it("is fresh (build-widgets --check)", () => {
        expect(() => execFileSync("node", ["scripts/build-widgets.mjs", "--check"], { stdio: "pipe" })).not.toThrow();
    });

    it("has one entry per view, in order, with the right uri", () => {
        expect(WIDGETS.map((w) => w.view)).toEqual([...VIEWS]);
        for (const w of WIDGETS) {
            expect(w.uri).toBe(widgetUri(w.view));
            expect(w.title.length).toBeGreaterThan(0);
        }
    });

    for (const w of WIDGETS) {
        describe(w.view, () => {
            const html = w.html;
            it("starts on its own view", () => {
                expect(html).toContain(`data-default-view="${w.view}"`);
                expect(html).not.toContain("__DEFAULT_VIEW__");
                for (const other of WIDGETS) if (other !== w) expect(html).not.toContain(`data-default-view="${other.view}"`);
            });
            it("is self-contained", () => {
                expect(html.startsWith("<!doctype html>")).toBe(true);
                expect(/<script[^>]*\ssrc=/i.test(html)).toBe(false);
                expect(/<link[\s>]/i.test(html)).toBe(false);
                expect(/@import|@font-face/i.test(html)).toBe(false);
                expect(/\bimport\s*[({"'\w]/.test(html.replace(/important/g, ""))).toBe(false);
                expect(/\burl\(\s*["']?https?:/i.test(html)).toBe(false);
                // the only http(s) strings are the app's own link and the schema-less checks in the code
                const urls = html.match(/https?:\/\/[^\s"'`)<>]*/g) ?? [];
                expect(urls.filter((u) => !u.startsWith("https://cobalt.capybaraharmony.com"))).toEqual([]);
            });
            it("stays under the size ceiling", () => {
                expect(Buffer.byteLength(html)).toBeLessThan(CEILING);
            });
        });
    }

    it("one page differs between entries only by the default view", () => {
        const a = WIDGETS[0]!.html.replace(`data-default-view="${WIDGETS[0]!.view}"`, "X");
        for (const w of WIDGETS) expect(w.html.replace(`data-default-view="${w.view}"`, "X")).toBe(a);
    });
});
