import { describe, expect, it } from "vitest";
import { countryOf, hashKey, lookupKey, SESSION_TTL_MS } from "../src/keys";
import { ALL_MIGRATIONS_SQL, createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";

const KEY = "0b5f2c3e-6c1a-4f5e-9a57-1d0e6c9f2a11";
const KEY_SHA256 = "fdf22b6208069ca909f67671aa94460362cf0f181093d0ad9f31e12e08fad7d9";

const insert = (db: FakeD1, hash: string, revokedAt: number | null = null) =>
    db.raw
        .prepare(
            "INSERT INTO api_keys (id, name, key_hash, prefix, created_at, revoked_at) VALUES (?, ?, ?, ?, ?, ?)",
        )
        .run("id-" + hash.slice(0, 6), "test", hash, "0b5f2c3e", 1, revokedAt);

const lastUsed = (db: FakeD1) =>
    db.raw.prepare("SELECT last_used_at AS t FROM api_keys").get()?.t;

describe("hashKey", () => {
    it("is lowercase hex SHA-256 (same vector as the web Worker tests)", async () => {
        expect(await hashKey(KEY)).toBe(KEY_SHA256);
    });
});

describe("lookupKey against real SQLite and the real migration", () => {
    it("returns the key id for an active key and stamps last_used_at", async () => {
        const db = createFakeD1();
        insert(db, KEY_SHA256);
        expect(lastUsed(db)).toBeNull();
        expect(await lookupKey(db, KEY, 1234)).toBe("id-" + KEY_SHA256.slice(0, 6));
        expect(lastUsed(db)).toBe(1234);
    });
    it("rejects an unknown key without touching anything", async () => {
        const db = createFakeD1();
        insert(db, KEY_SHA256);
        expect(await lookupKey(db, "11111111-1111-4111-8111-111111111111", 99)).toBeNull();
        expect(lastUsed(db)).toBeNull();
    });
    it("rejects a revoked key and does not stamp it", async () => {
        const db = createFakeD1();
        insert(db, KEY_SHA256, 5);
        expect(await lookupKey(db, KEY, 99)).toBeNull();
        expect(lastUsed(db)).toBeNull();
    });
    it("propagates D1 failures (the Worker turns them into 503)", async () => {
        const db = createFakeD1();
        db.breakIt();
        await expect(lookupKey(db, KEY, 1)).rejects.toThrow();
    });
});

// Section 42.2: sessions expire and slide; keys never expire; the country of the last use is kept.
describe("lookupKey: device sessions (section 42.2)", () => {
    const SESSION = "5a1e2b3c-4d5e-4f60-8a71-92b3c4d5e6f7";
    const seed = async (db: FakeD1, o: { kind?: string; expires_at?: number | null; revoked_at?: number | null; token?: string } = {}) =>
        db.raw
            .prepare(
                "INSERT INTO api_keys (id, name, key_hash, prefix, created_at, kind, expires_at, revoked_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            )
            .run("s-1", "phone", await hashKey(o.token ?? SESSION), "5a1e2b3c", 1, o.kind ?? "session", o.expires_at ?? null, o.revoked_at ?? null);
    const row = (db: FakeD1) =>
        db.raw.prepare("SELECT last_used_at, expires_at, last_country FROM api_keys WHERE id = 's-1'").get() as {
            last_used_at: number | null;
            expires_at: number | null;
            last_country: string | null;
        };

    it("SESSION_TTL_MS is 90 days", () => {
        expect(SESSION_TTL_MS).toBe(90 * 24 * 60 * 60 * 1000);
    });
    it("an unexpired session is accepted and its expiry slides to now + 90 days", async () => {
        const db = createFakeD1();
        await seed(db, { expires_at: 2_000 });
        expect(await lookupKey(db, SESSION, 1_500, "JP")).toBe("s-1");
        expect(row(db)).toEqual({ last_used_at: 1_500, expires_at: 1_500 + SESSION_TTL_MS, last_country: "JP" });
    });
    it("an expired session is refused like an unknown key and is not touched", async () => {
        const db = createFakeD1();
        await seed(db, { expires_at: 1_000 });
        expect(await lookupKey(db, SESSION, 1_000)).toBeNull();
        expect(await lookupKey(db, SESSION, 5_000)).toBeNull();
        expect(row(db)).toEqual({ last_used_at: null, expires_at: 1_000, last_country: null });
    });
    it("a revoked session is refused even before it expires", async () => {
        const db = createFakeD1();
        await seed(db, { expires_at: 10_000, revoked_at: 5 });
        expect(await lookupKey(db, SESSION, 100)).toBeNull();
    });
    it("a key never gets an expiry; the country is only overwritten by a known one", async () => {
        const db = createFakeD1();
        await seed(db, { kind: "key" });
        expect(await lookupKey(db, SESSION, 100, "DE")).toBe("s-1");
        expect(await lookupKey(db, SESSION, 200)).toBe("s-1");
        expect(await lookupKey(db, SESSION, 300, "not a country")).toBe("s-1");
        expect(row(db)).toEqual({ last_used_at: 300, expires_at: null, last_country: "DE" });
    });
    it("before migration 0026 the key check still works (no such column: the old statement)", async () => {
        const pre = ALL_MIGRATIONS_SQL.slice(0, ALL_MIGRATIONS_SQL.indexOf("-- Device sessions (APP-API-CONTRACT.md section 42)"));
        const db = createFakeD1(pre);
        insert(db, KEY_SHA256);
        expect(await lookupKey(db, KEY, 77, "US")).toBe("id-" + KEY_SHA256.slice(0, 6));
        expect(lastUsed(db)).toBe(77);
    });
});

describe("countryOf", () => {
    it("reads cf.country when it is a two-letter code", () => {
        const r = (cf: unknown) => Object.assign(new Request("https://x/"), { cf }) as Request;
        expect(countryOf(r({ country: "GB" }))).toBe("GB");
        expect(countryOf(r({ country: "gb" }))).toBeNull();
        expect(countryOf(r(undefined))).toBeNull();
        expect(countryOf(undefined)).toBeNull();
    });
});
