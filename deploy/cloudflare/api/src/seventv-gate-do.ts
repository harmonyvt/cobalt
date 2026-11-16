// The SevenTvGate Durable Object (APP-API-CONTRACT.md section 62.5): one object, "gate", that paces every 7TV API call.
// The rules are in seventv-gate.ts. Its state is only in memory: an eviction starts a fresh pace, which is fine.
import { DurableObject } from "cloudflare:workers";
import { GateCore, handleGateRoute } from "./seventv-gate";

export class SevenTvGate extends DurableObject {
    private core = new GateCore(() => Date.now());

    override async fetch(request: Request): Promise<Response> {
        return handleGateRoute(this.core, request);
    }
}
