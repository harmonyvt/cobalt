// D1's `batch([...])` for the tests: the statements run in ONE transaction, so a failing statement
// leaves none of them applied (what the real binding guarantees, and what the migration relies on).
// The shared fake (../../test-support/d1-sqlite.ts) has no batch; the statements it hands out run
// synchronously inside `run()`, so BEGIN / COMMIT around them is a real transaction on node:sqlite.
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";

export function withBatch(db: FakeD1): FakeD1 {
    (db as any).batch = async (statements: { run(): Promise<{ meta?: { changes?: number } }> }[]) => {
        db.raw.exec("BEGIN");
        const results = [];
        try {
            for (const s of statements) results.push(await s.run());
            db.raw.exec("COMMIT");
        } catch (e) {
            db.raw.exec("ROLLBACK");
            throw e;
        }
        return results;
    };
    return db;
}

export const createBatchD1 = (migrationSql?: string): FakeD1 => withBatch(migrationSql === undefined ? createFakeD1() : createFakeD1(migrationSql));
