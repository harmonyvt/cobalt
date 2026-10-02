import { describe, expect, it } from "vitest";
import { hashKey, lookupKey } from "../src/keys";
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";

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
