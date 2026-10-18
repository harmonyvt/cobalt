// The ModelRelay Durable Object: forwards Anthropic API requests from a fixed location (see
// src/model-fetch.ts for why). Reached only through the MODEL_RELAY binding, never from the internet.
// Imported only by the Worker entry (index.ts): `cloudflare:workers` does not exist under node.

import { DurableObject } from "cloudflare:workers";
import { upstreamRequest } from "./model-fetch";

export class ModelRelay extends DurableObject {
    async fetch(request: Request): Promise<Response> {
        const body = request.method === "GET" || request.method === "HEAD" ? undefined : await request.arrayBuffer();
        const upstream = upstreamRequest(request, body);
        if (!upstream) return new Response("bad relay target", { status: 400 });
        return fetch(upstream);
    }
}
