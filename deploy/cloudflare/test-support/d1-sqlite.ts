// A D1Database look-alike backed by Node's real SQLite (`node:sqlite`), so the
// Worker tests run the actual SQL (including UPDATE ... RETURNING and
// INSERT ... SELECT ... WHERE) against the real migration file. Only the D1
// surface the Workers use is implemented: prepare().bind().{run,all,first}.
import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const MIGRATION_SQL = readFileSync(
    fileURLToPath(new URL("../d1/migrations/0001_api_keys.sql", import.meta.url)),
    "utf8",
);

// Every migration in d1/migrations, in file-name order (0001_, 0002_, ...): the
// default schema, so tests run against the real, complete database layout.
// MIGRATION_SQL (0001 alone) stays exported for callers that pass it explicitly.
const MIGRATIONS_DIR = fileURLToPath(new URL("../d1/migrations/", import.meta.url));
export const ALL_MIGRATIONS_SQL = readdirSync(MIGRATIONS_DIR)
    .filter((f) => f.endsWith(".sql"))
    .sort()
    .map((f) => readFileSync(MIGRATIONS_DIR + f, "utf8"))
    .join("\n");

export type FakeD1 =D1Database & {
    raw: DatabaseSync;
    // Make every subsequent statement throw, as an unreachable D1 would.
    breakIt(): void;
};

export function createFakeD1(migrationSql: string = ALL_MIGRATIONS_SQL): FakeD1 {
    const raw = new DatabaseSync(":memory:");
    raw.exec(migrationSql);
    let broken = false;

    const statement = (sql: string, params: SQLInputValue[] = []) => {
        const guard = () => {
            if (broken) throw new Error("D1_ERROR: simulated outage");
        };
        const s = {
            bind: (...p: SQLInputValue[]) => statement(sql, p),
            async run() {
                guard();
                const r = raw.prepare(sql).run(...params);
                return { success: true, results: [], meta: { changes: Number(r.changes) } };
            },
            async all() {
                guard();
                const rows = raw.prepare(sql).all(...params).map((r) => ({ ...r }));
                return { success: true, results: rows, meta: { changes: rows.length } };
            },
            async first(col?: string) {
                guard();
                const row = raw.prepare(sql).get(...params);
                if (!row) return null;
                return col ? (row as Record<string, unknown>)[col] : { ...row };
            },
        };
        return s;
    };

    return {
        raw,
        breakIt() {
            broken = true;
        },
        prepare: (sql: string) => statement(sql),
    } as unknown as FakeD1;
}
