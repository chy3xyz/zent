-- Input for `zig build run-check-sql` (and for `check_sql sample.sql`).
-- Every statement here prepares cleanly on an empty SQLite database, so the
-- run exits 0; the semicolons that must not split a statement are the point.

SELECT 1 AS one;

-- A semicolon inside a string literal is not a statement separator:
SELECT 'a;b' AS s;

/* Nor is one inside a comment: ; ; ; */
SELECT 2 AS two;
