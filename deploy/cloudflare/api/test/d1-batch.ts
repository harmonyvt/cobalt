// D1's `batch([...])` for the tests: the statements run in ONE transaction, so a failing statement
// leaves none of them applied (what the real binding guarantees, and what the migration relies on).
// The shared fake (../../test-support/d1-sqlite.ts) has no batch; the statements it hands out run
// synchronously inside `run()` and `all()`, so BEGIN / COMMIT around them is a real transaction on node:sqlite.
//
// Each statement answers what the binding's batch answers for it. A plain write goes through `run()`, as it always
// did here (tests break one statement of a batch by replacing its `run`). A statement that answers rows (a SELECT, a
// write with RETURNING) goes through `all()`, so code that reads several things in one batch gets its rows. The fake's
// statements do not say which they are, so `prepare` is made to remember each statement's SQL.
import { createFakeD1, type FakeD1 } from "../../test-support/d1-sqlite";

// the SQL of a statement prepared after withBatch; copied along by `bind` and by an object spread
const SQL = Symbol("sql");
type Tagged = { [SQL]?: string; bind(...p: unknown[]): Tagged; run(): Promise<{ meta?: { changes?: number } }>; all(): Promise<{ results: unknown[] }> };

export function withBatch(db: FakeD1): FakeD1 {
    const tag = (st: Tagged, sql: string): Tagged => {
        const bind = st.bind.bind(st);
        st.bind = (...p: unknown[]) => tag(bind(...p), sql);
        st[SQL] = sql;
        return st;
    };
    const prepare = db.prepare.bind(db);
    (db as any).prepare = (sql: string) => tag(prepare(sql) as unknown as Tagged, sql);

    // Whether the statement answers rows. SQLite knows (its result columns); a Node whose node:sqlite has no
    // `columns()` yet reads the SQL instead.
    const answersRows = (sql: string): boolean => {
        const st = db.raw.prepare(sql) as unknown as { columns?: () => unknown[] };
        if (typeof st.columns === "function") return st.columns().length > 0;
        return /^\s*(?:SELECT|WITH)\b/i.test(sql) || /\bRETURNING\b/i.test(sql);
    };
    const count = (fn: "changes" | "total_changes") => Number((db.raw.prepare(`SELECT ${fn}() AS n`).get() as { n: number | bigint }).n);

    (db as any).batch = async (statements: Tagged[]) => {
        db.raw.exec("BEGIN");
        const results = [];
        try {
            for (const s of statements) {
                const sql = s[SQL];
                if (sql === undefined || !answersRows(sql)) {
                    results.push(await s.run());
                    continue;
                }
                // `changes()` keeps the last write's count after a SELECT: only read when this statement wrote
                const before = count("total_changes");
                const r = await s.all();
                const wrote = count("total_changes") > before;
                results.push({ success: true, results: r.results, meta: { changes: wrote ? count("changes") : 0 } });
            }
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
