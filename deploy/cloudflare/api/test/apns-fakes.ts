// Fakes shared by the Live Activity tests: a generated P-256 key as a PKCS#8 PEM
// and Apple as a script (each push takes the next answer).
import type { ApnsAnswer, ApnsRequest, Transport, TransportMeta } from "../src/apns";

export async function makePem(): Promise<string> {
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
    const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
    const b64 = btoa(String.fromCharCode(...der)).match(/.{1,64}/g)!.join("\n");
    return `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`;
}

export const ok = (apnsId = "APNS-ID-1"): ApnsAnswer => ({ status: 200, reason: null, apnsId });
export const bad = (status: number, reason: string | null): ApnsAnswer => ({ status, reason, apnsId: null });

export type AppleStep = ApnsAnswer | Error | ((r: ApnsRequest, n: number) => ApnsAnswer | Promise<ApnsAnswer>);

// Every request that reached "Apple", parsed; answers come from `script` (the last
// step repeats; an empty script answers 200).
export class Apple {
    calls: { req: ApnsRequest; meta: TransportMeta }[] = [];
    // how many requests the current script has answered (clearing `calls` does not
    // rewind the script; assigning a new script does)
    private served = 0;
    private steps: AppleStep[] = [];
    constructor(script: AppleStep[] = []) {
        this.steps = script;
    }
    set script(v: AppleStep[]) {
        this.steps = v;
        this.served = 0;
    }
    get script(): AppleStep[] {
        return this.steps;
    }
    transport: Transport = async (req, meta) => {
        const n = this.served++;
        this.calls.push({ req, meta });
        const step = this.steps[Math.min(n, this.steps.length - 1)] ?? ok();
        if (step instanceof Error) throw step;
        return typeof step === "function" ? step(req, n) : step;
    };
    get hosts() {
        return this.calls.map((c) => c.req.host);
    }
    // the parsed pushes: token (from the path), event, priority, expiration, payload
    get pushes() {
        return this.calls.map(({ req }) => ({
            host: req.host,
            token: req.path.replace("/3/device/", ""),
            priority: Number(req.headers["apns-priority"]),
            expiration: Number(req.headers["apns-expiration"]),
            payload: JSON.parse(req.body) as { aps: Record<string, any> },
        }));
    }
}
