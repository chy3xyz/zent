-- Dropping the table drops its indexes, so no separate `DROP INDEX` — MySQL
-- has no `DROP INDEX IF EXISTS` (MariaDB does), and the table statement is the
-- one form all four servers accept.
DROP TABLE IF EXISTS users;
