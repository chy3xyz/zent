-- Portable DDL: no `AUTOINCREMENT` (SQLite-only) and no `CREATE INDEX IF NOT
-- EXISTS` (MySQL rejects it), so the `migrate` example's own migrations run on
-- every dialect it can connect to. Idempotency comes from the runner's version
-- table, not from `IF NOT EXISTS` on the index.
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT UNIQUE NOT NULL
);

CREATE INDEX idx_users_email ON users(email);
