import { describe, expect, it } from "vitest";
import { extractFirstUrl, normalizeUrlField } from "../src/worker";

const post = (body: unknown, type = "application/json") =>
    new Request("https://api.capybaraharmony.com/webp", {
        method: "POST",
        headers: { "content-type": type },
        body: typeof body === "string" ? body : JSON.stringify(body),
    });

describe("extractFirstUrl", () => {
    it("finds the first link in shortcut-style text", () => {
        expect(extractFirstUrl("\nhttps://x.com/maria_rcks/status/2105237035271258436?s=20")).toBe(
            "https://x.com/maria_rcks/status/2105237035271258436?s=20",
        );
        expect(extractFirstUrl("look (https://vimeo.com/288386543). ok")).toBe("https://vimeo.com/288386543");
        expect(extractFirstUrl("no link here")).toBeNull();
    });
});

describe("normalizeUrlField", () => {
    it("leaves a bare url untouched (same request object)", async () => {
        const r = post({ url: "https://x.com/a/status/1" });
        expect(await normalizeUrlField(r)).toBe(r);
    });
    it("extracts the first url from free text and keeps other fields", async () => {
        const r = await normalizeUrlField(post({ url: "file.txt\nhttps://x.com/a/status/1 more", length: 3 }));
        expect(await r.json()).toEqual({ url: "https://x.com/a/status/1", length: 3 });
    });
    it("trims whitespace around a url", async () => {
        const r = await normalizeUrlField(post({ url: "  https://x.com/a/status/1\n" }));
        expect(await r.json()).toEqual({ url: "https://x.com/a/status/1" });
    });
    it("passes through non-json and non-string url bodies", async () => {
        const a = post("url=x", "application/x-www-form-urlencoded");
        expect(await normalizeUrlField(a)).toBe(a);
        const b = post({ url: 5 });
        expect(await normalizeUrlField(b)).toBe(b);
    });
});
