// The web Worker's copy of the session code (src/sessions.ts) must match the API Worker's (api/src/sessions.ts): both
// mint the same rows. The API's file is dependency-free, so this test imports it and compares.
import { describe, expect, it } from "vitest";
import * as api from "../../api/src/sessions";
import { hashKey as apiHashKey, SESSION_TTL_MS as API_TTL } from "../../api/src/keys";
import { hashKey } from "../src/keys";
import * as web from "../src/sessions";

describe("the session SQL is the API Worker's, character for character", () => {
    it("insert, cap and the active-session filter", () => {
        expect(web.SESSION_INSERT_SQL).toBe(api.SESSION_INSERT_SQL);
        expect(web.SESSION_CAP_SQL).toBe(api.SESSION_CAP_SQL);
        expect(web.ACTIVE_SESSION_SQL).toBe(api.ACTIVE_SESSION_SQL);
    });
    it("the constants", () => {
        expect(web.SESSION_TTL_MS).toBe(API_TTL);
        expect(web.MAX_SESSIONS).toBe(api.MAX_SESSIONS);
        expect(web.MAX_DEVICE_LENGTH).toBe(api.MAX_DEVICE_LENGTH);
        expect([...web.PLATFORMS]).toEqual([...api.PLATFORMS]);
    });
    it("tokens hash the same way (the vector both suites pin)", async () => {
        const KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
        expect(await hashKey(KEY)).toBe("fdf22b6208069ca909f67671aa94460362cf0f181093d0ad9f31e12e08fad7d9");
        expect(await apiHashKey(KEY)).toBe(await hashKey(KEY));
    });
    it("device names are cleaned the same way", () => {
        for (const d of ["harmony’s iphone", "  x  ", "x".repeat(40), "x".repeat(41), "", "a\nb", "a b", "😀".repeat(40), "😀".repeat(41), 5, null]) {
            expect(web.cleanDevice(d)).toBe(api.cleanDevice(d));
        }
    });
});

describe("deviceFromUserAgent (42.4)", () => {
    const cases: [string | null, string][] = [
        ["Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Safari/605.1.15", "safari on mac"],
        ["Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36", "chrome on windows"],
        ["Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0", "firefox on linux"],
        ["Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Mobile/15E148 Safari/604.1", "safari on iphone"],
        ["Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36 Edg/140.0.0.0", "edge on windows"],
        ["Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36", "chrome on android"],
        ["curl/8.0", "browser"],
        ["", "browser"],
        [null, "browser"],
    ];
    it.each(cases)("%s -> %s", (ua, want) => {
        expect(web.deviceFromUserAgent(ua)).toBe(want);
        expect(web.cleanDevice(web.deviceFromUserAgent(ua))).toBe(want);
    });
});
