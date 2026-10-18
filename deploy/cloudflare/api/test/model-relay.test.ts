// The Anthropic relay (src/model-fetch.ts): chat and captions send their requests through a Durable
// Object pinned to North America, because Anthropic answers 403 from some Cloudflare locations.
// A fake namespace stands in for the Durable Object and records what reached "upstream".
import { describe, expect, it } from "vitest";
import { chatModelFrom } from "../src/chat";
import { captionerFrom } from "../src/roast";
import { RELAY_LOCATION, RELAY_URL_HEADER, relayFetch, upstreamRequest, type RelayNamespace } from "../src/model-fetch";

function fakeRelay(answer: (req: Request) => Response | Promise<Response>) {
    const seen: { hints: (string | undefined)[]; upstream: Request[] } = { hints: [], upstream: [] };
    const ns: RelayNamespace = {
        idFromName: (name) => `id:${name}`,
        get: (_id, options) => {
            seen.hints.push(options?.locationHint);
            return {
                async fetch(request: Request) {
                    // what ModelRelay.fetch does, with a fake network
                    const body = request.method === "GET" ? undefined : await request.arrayBuffer();
                    const up = upstreamRequest(request, body);
                    if (!up) return new Response("bad relay target", { status: 400 });
                    seen.upstream.push(up.clone());
                    return answer(up);
                },
            };
        },
    };
    return { ns, seen };
}

const message = (text: string) => ({
    id: "msg_1",
    type: "message",
    role: "assistant",
    model: "claude-haiku-5-5",
    content: [{ type: "text", text }],
    stop_reason: "end_turn",
    stop_sequence: null,
    usage: { input_tokens: 1, output_tokens: 1 },
});

function sse(text: string): Response {
    const events = [
        ["message_start", { type: "message_start", message: { ...message(""), content: [], stop_reason: null } }],
        ["content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }],
        ["content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } }],
        ["content_block_stop", { type: "content_block_stop", index: 0 }],
        ["message_delta", { type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: 1 } }],
        ["message_stop", { type: "message_stop" }],
    ];
    const body = events.map(([e, d]) => `event: ${e}\ndata: ${JSON.stringify(d)}\n\n`).join("");
    return new Response(body, { headers: { "content-type": "text/event-stream" } });
}

describe("model relay", () => {
    it("streams a chat turn through the relay to api.anthropic.com, pinned to North America", async () => {
        const { ns, seen } = fakeRelay(() => sse("nya~ (=^･ω･^=)"));
        const model = chatModelFrom({ ANTHROPIC_API_KEY: "sk-ant-test", ROAST_BASE_URL: "" }, relayFetch(ns))!;
        const deltas: string[] = [];
        const turn = await model.turn({ system: "s", tools: [], messages: [{ role: "user", content: "hi" }], onText: (d) => deltas.push(d) });
        expect(deltas.join("")).toBe("nya~ (=^･ω･^=)");
        expect(turn.stop_reason).toBe("end_turn");
        expect(seen.hints).toEqual([RELAY_LOCATION]);
        const up = seen.upstream[0];
        expect(up.url).toBe("https://api.anthropic.com/v1/messages");
        expect(up.method).toBe("POST");
        expect(up.headers.get("x-api-key")).toBe("sk-ant-test");
        expect(up.headers.get(RELAY_URL_HEADER)).toBeNull();
        expect(JSON.parse(await up.text())).toMatchObject({ model: "claude-haiku-5-5", stream: true });
    });

    it("sends captions through the relay too", async () => {
        const { ns, seen } = fakeRelay(() => Response.json(message(JSON.stringify({ title: "a sleepy cat :3" }))));
        const captioner = captionerFrom({ ANTHROPIC_API_KEY: "sk-ant-test" }, relayFetch(ns))!;
        await captioner.caption({ kind: "file", files: [], name: "x" } as any).catch(() => null);
        expect(seen.upstream.length).toBeGreaterThan(0);
        expect(seen.upstream[0].url).toBe("https://api.anthropic.com/v1/messages");
    });

    it("refuses targets other than Anthropic and AI Gateway", () => {
        const at = (url: string) => new Request("https://model-relay.internal/", { method: "POST", headers: { [RELAY_URL_HEADER]: url } });
        expect(upstreamRequest(at("https://evil.example/v1/messages"), undefined)).toBeNull();
        expect(upstreamRequest(at("http://api.anthropic.com/v1/messages"), undefined)).toBeNull();
        expect(upstreamRequest(new Request("https://model-relay.internal/"), undefined)).toBeNull();
        expect(upstreamRequest(at("https://gateway.ai.cloudflare.com/v1/a/g/anthropic/v1/messages"), undefined)?.url).toBe(
            "https://gateway.ai.cloudflare.com/v1/a/g/anthropic/v1/messages",
        );
    });

    it("passes an upstream 403 back unchanged", async () => {
        const { ns } = fakeRelay(() => Response.json({ error: { type: "forbidden", message: "Request not allowed" } }, { status: 403 }));
        const model = chatModelFrom({ ANTHROPIC_API_KEY: "sk-ant-test" }, relayFetch(ns))!;
        await expect(model.turn({ system: "s", tools: [], messages: [{ role: "user", content: "hi" }], onText: () => {} })).rejects.toThrow(/403/);
    });
});
