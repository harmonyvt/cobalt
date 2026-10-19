// The StageRoom Durable Object (APP-API-CONTRACT.md section 29.1, 29.6): holds the canvas WebSockets
// (hibernation API, so an idle room costs nothing) and fans the events out. One instance,
// idFromName("main"). It also keeps the last spotlight and the chaos `until` so a page that connects
// mid-chaos catches up from the Worker's `state` answer. Reached only through the STAGE_ROOM binding by
// the Worker (which has already checked the canvas token); never from the internet. Imported only by the
// Worker entry (index.ts): `cloudflare:workers` does not exist under node. The state rules are
// `reduceRoom` in stage.ts, tested there.

import { DurableObject } from "cloudflare:workers";
import { emptyRoom, reduceRoom, type CanvasEvent, type RoomState } from "./stage";

const KEY = "room";

export class StageRoom extends DurableObject {
    constructor(ctx: DurableObjectState, env: Cloudflare.Env) {
        super(ctx, env);
        // the page may ping to keep the socket warm; answered without waking the object
        ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
    }

    private async load(): Promise<RoomState> {
        return { ...emptyRoom(), ...((await this.ctx.storage.get<RoomState>(KEY)) ?? {}) };
    }

    async fetch(request: Request): Promise<Response> {
        const { pathname } = new URL(request.url);
        if (pathname === "/ws") {
            if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") return new Response("expected a websocket", { status: 426 });
            const pair = new WebSocketPair();
            this.ctx.acceptWebSocket(pair[1]);
            return new Response(null, { status: 101, webSocket: pair[0] });
        }
        if (pathname === "/state" && request.method === "GET") {
            return new Response(JSON.stringify(await this.load()), { headers: { "content-type": "application/json" } });
        }
        if (pathname === "/event" && request.method === "POST") {
            const event = (await request.json()) as CanvasEvent;
            await this.ctx.storage.put(KEY, reduceRoom(await this.load(), event, Date.now()));
            const text = JSON.stringify(event);
            for (const ws of this.ctx.getWebSockets()) {
                try {
                    ws.send(text);
                } catch {
                    // a socket that just went away
                }
            }
            if (event.type === "rotated") {
                // the old token's pages are done (29.6): every socket is closed after the event
                for (const ws of this.ctx.getWebSockets()) {
                    try {
                        ws.close(1000, "rotated");
                    } catch {
                        // already closed
                    }
                }
            }
            return new Response(null, { status: 204 });
        }
        return new Response("not found", { status: 404 });
    }

    // The page only listens; anything it sends is ignored.
    webSocketMessage(): void {}

    webSocketClose(ws: WebSocket, code: number): void {
        try {
            // 1005/1006 are not sendable close codes
            ws.close(code >= 1000 && code < 5000 && code !== 1005 && code !== 1006 ? code : 1000);
        } catch {
            // already closed
        }
    }
}
