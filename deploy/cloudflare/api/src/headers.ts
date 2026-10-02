// Headers that only this Worker may set. A client-supplied copy must never
// reach the Durable Object or the container:
//  - cf-container-target-port: @cloudflare/containers' Container.fetch()
//    honours it (node_modules/@cloudflare/containers/dist/lib/container.js,
//    "cf-container-target-port"), so a client could otherwise pick ANY container
//    port, e.g. the internal webp helper on 9100, and bypass the gate.
//  - x-cobalt-key-id: set by the Worker after a successful D1 key lookup and
//    trusted by the Durable Object as the caller's identity.
//  - x-cobalt-service: the web Worker's service credential (the internal
//    COBALT_API_KEY). The Worker reads it from the incoming request to decide
//    whether the caller is the library service, and it is never forwarded.
export const PORT_HEADER = "cf-container-target-port";
export const KEY_ID_HEADER = "x-cobalt-key-id";
export const SERVICE_HEADER = "x-cobalt-service";

export const STRIPPED_FROM_CLIENT = [PORT_HEADER, KEY_ID_HEADER, SERVICE_HEADER] as const;

// Headers.delete() is case-insensitive and removes every value of the name.
export function stripInternalHeaders(headers: Headers): Headers {
    const out = new Headers(headers);
    for (const name of STRIPPED_FROM_CLIENT) out.delete(name);
    return out;
}
