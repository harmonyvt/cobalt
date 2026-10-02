import { describe, expect, it } from "vitest";
import { KEY_ID_HEADER, PORT_HEADER, SERVICE_HEADER, stripInternalHeaders } from "../src/headers";

describe("stripInternalHeaders", () => {
    it("removes cf-container-target-port whatever its case", () => {
        for (const name of [PORT_HEADER, "CF-Container-Target-Port", "Cf-Container-Target-port"]) {
            const out = stripInternalHeaders(new Headers({ [name]: "9100", accept: "x" }));
            expect(out.has(PORT_HEADER)).toBe(false);
            expect(out.get("accept")).toBe("x");
        }
    });
    it("removes a client-supplied key id and every repeated value", () => {
        const h = new Headers();
        h.append("X-Cobalt-Key-Id", "victim");
        h.append("x-cobalt-key-id", "victim2");
        expect(stripInternalHeaders(h).has(KEY_ID_HEADER)).toBe(false);
    });
    it("removes the service credential header, whatever its case or how often it repeats", () => {
        const h = new Headers({ "X-Cobalt-Service": "k", accept: "x" });
        h.append("x-cobalt-service", "k2");
        const out = stripInternalHeaders(h);
        expect(out.has(SERVICE_HEADER)).toBe(false);
        expect(out.get("accept")).toBe("x");
    });
    it("keeps everything else and does not mutate the input", () => {
        const h = new Headers({ authorization: "Api-Key k", origin: "o", [PORT_HEADER]: "9100" });
        const out = stripInternalHeaders(h);
        expect([...out.keys()].sort()).toEqual(["authorization", "origin"]);
        expect(h.has(PORT_HEADER)).toBe(true);
    });
});
