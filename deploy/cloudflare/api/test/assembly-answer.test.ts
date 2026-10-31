import { describe, expect, it } from "vitest";
import { assemblyFrom } from "../src/about-writer";

const answer = { text: "Hello there.", language_code: "en", words: [{ text: "Hello", start: 0, end: 400, confidence: 0.9 }, { text: "there.", start: 450, end: 900, confidence: 0.9 }] };
const hear = (raw: unknown) => assemblyFrom({ run: async () => raw })!.transcribe(new Uint8Array([1, 2, 3]));

describe("AssemblyAI answers", () => {
    for (const [name, raw] of [
        ["a plain object", answer],
        ["JSON text", JSON.stringify(answer)],
        ["a Response", () => new Response(JSON.stringify(answer))],
        ["wrapped in result", { result: answer }],
        ["wrapped in response", { response: answer }],
    ] as const) {
        it(`reads ${name}`, async () => {
            const heard = await hear(typeof raw === "function" ? raw() : raw);
            expect(heard.text).toBe("Hello there.");
            expect(heard.language).toBe("en");
            expect((heard.lines ?? []).length).toBeGreaterThan(0);
        });
    }
    it("says what an unreadable answer looked like", async () => {
        await expect(hear({ id: "x", status: "queued" })).rejects.toThrow("bad assemblyai answer: keys id,status");
        await expect(hear("not json")).rejects.toThrow("bad assemblyai answer: string");
    });
});
