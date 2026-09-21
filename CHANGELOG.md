# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [0.73.2] - 2026-09-21

## [0.73.1] - 2026-09-21

### Fixed
- **The integration suites compile again.** v0.73.0 renamed
  `CrudService.get` to `getOwned` and two call sites in
  `tests/integration/` were missed, so `zig build test-integration` did not
  build there (the library itself was unaffected — the unit suite, and any
  consumer using the library rather than these tests, was fine). Pin v0.73.1
  rather than v0.73.0 if you run this repository's integration suite.

## [0.73.0] - 2026-09-21

### Breaking
- **`CrudService.get` is `getOwned`.** The method returns a row copied into the
  caller's allocator, while `client.<entity>.deinitRow(&e)` frees with the
  *client's* allocator — the same `Entity` type, so nothing but the call site
  said which allocator was right, and pairing them wrongly is a mismatched free
  (a request arena corrupted, or "free of invalid memory" taking the process
  down). Every call site now states the ownership. `EntityClient.deinitRowWith
  (allocator, &e)` is the release for such a row: it names the allocator that
  allocated.
- **`Sum` / `Avg` answer `error.EmptyAggregate` on an empty set.** They used to
  answer `error.TypeMismatch` — the same error a value that is not a number
  produces through `getFloat`, so "there is no data" was reported as a type
  problem and the two could not be told apart. The member lives in a
  `Sum`/`Avg`-only error set (`QueryError || error{EmptyAggregate}`) so the
  shared readers (`All`, `First`, `Count`, …) are not widened with an error
  none of them can return. `SumOrZero` and `Max`/`Min` are unchanged.

### Fixed
- **A column-level `UNIQUE` is now enforced on a table that already exists.**
  The declaration is inline in `CREATE TABLE` and `ALTER TABLE ADD COLUMN`
  cannot carry it, so a table created before the field was marked unique never
  got the constraint — and with no unique index the statement
  `SaveOrUpdateOn` builds is rejected outright ("ON CONFLICT clause does not
  match any PRIMARY KEY or UNIQUE constraint" on SQLite and PostgreSQL), so
  every upsert against that table failed at runtime while the schema said it
  worked. The migration now adds a unique index over the one column — the
  dialect-neutral form, no table rebuild — skipping it only when an unreadable
  unique index already covers the column, or the server cannot index the type
  (MySQL BLOB/TEXT/JSON, where the create-table path warns too). A deploy whose
  data already violates the declaration fails loudly on the `CREATE UNIQUE
  INDEX` and rolls back, rather than leaving the promise unkept.

## [0.72.0] - 2026-09-21

### Fixed
- **A restore is scoped by the policy's filters and the interceptor chain.**
  `Delete().Restore(id)` checked the policy's decision and then dropped
  `result.getFilters()`, and never ran the interceptor chain — the one write
  path that did neither, where every sibling (`Save`, both soft/hard deletes,
  both bulk paths) appends both. A policy that scopes rows by tenant therefore
  let a caller resurrect any row it could name, and a multi-tenant interceptor
  never reached the restore statement. An out-of-scope restore now matches no
  row and answers `false`.
- **`queryTargets*` / `QueryEdge` answer a mid-read driver failure instead of a
  short page.** `queryTargetsImpl` read `next() == null` as "finished" without
  asking `nextError()`, so a step failure after the first row — a deadline
  firing mid-read, a server error mid-consume — handed the caller the rows read
  so far as the whole neighbour list, with no error and no flag. Every other
  bulk reader in the tree asks; this one was the exception. Its error path also
  freed the list buffer but not the already-scanned entities' heap strings.
- **`IDs()` projects the primary key.** It built its projection from
  `info.fields[0]`, and a custom `pk` keeps the declaration order (`fromSchema`
  injects `id` first only for the default key) — so on a schema whose key is
  not the first declared field it answered with that field's values. A textual
  key is now a compile error: the alternative is the driver coercing a uuid
  into a number that names no row.
- **The EntQL `has()` / `not_has()` lowerings and the `WithEdgeOptions` inner
  join keep the target's soft-delete scope.** They built
  `.has_neighbors_with` without the flag — which defaults to `false` — while the
  typed `Has{Edge}()` / `NotHas{Edge}()` predicates have always carried it, so
  `has(cars)` was satisfied by a parent whose only car was trashed and
  `not_has(cars)` was not: both disagreeing with the typed predicates, and an
  inner-joined page keeping a parent whose `edges` then came back null.
- **An m2m existence predicate is qualified to the target table.** The m2m
  EXISTS body joins the junction `j` and the target `t`, and the junction's
  columns are literally `<table>_id`, so a predicate left bare could bind to the
  junction: an EntQL `has(groups, user_id = …)` on a Group without a `user_id`
  column became a filter on the junction's `user_id` — already constrained to
  the outer row's id — and answered with no error. Such a field now fails at
  prepare time.

## [0.71.0] - 2026-09-21

### Fixed
- **A uuid primary key the caller never set is `error.MissingPrimaryKey` on
  every dialect, decided before the statement runs.** The RETURNING path
  (PostgreSQL, SQLite) answered `error.TypeMismatch` after the fact:
  PostgreSQL rejects the INSERT (NOT NULL), while SQLite's rowid-table quirk
  *accepts* the NULL into a `TEXT PRIMARY KEY` and RETURNING hands back NULL
  *after* the write — a type error naming the wrong mistake, with the keyless
  row already on disk. MySQL has decided this before the statement since
  v0.69.0; the RETURNING branch now makes the same decision at the same place,
  so the two dialects cannot drift.
- **Insert log lines report the rows the server actually wrote.** Both insert
  log sites hardcoded `rows_affected = 1`: the RETURNING site logged 1 for a
  `SaveIgnore` the server ignored (nothing written) — it now logs 0 when no
  RETURNING row comes back — and the MySQL site forwards the driver's own
  count and `rows_affected_known`, so an upsert that updated logs 2 and an
  ignored insert logs 0 instead of an unconditional 1.
- **The pool records an `all.append` OOM as itself.** `selectNoLock`'s
  create-connection path recorded the failure reason for `openConnection` and
  for the `PooledEntry` allocation but not for the `all.append` that follows,
  so an out-of-memory there surfaced as `PoolExhausted` through the generic
  mapping; it now reports `error.OutOfMemory`, matching its sibling paths.

## [0.70.0] - 2026-09-21

### Breaking
- **SQLite now enforces foreign keys.** `SQLiteDriver.open` issues
  `PRAGMA foreign_keys = ON` on every connection it returns and **verifies the
  read-back** — the pragma is per connection, and it is a silent no-op inside a
  transaction while still answering `SQLITE_OK`, so issuing it is not evidence
  it took. SQLite ships the switch OFF, so until now the `FOREIGN KEY` clauses
  `migrateSchema` writes were recorded and never checked: a dangling reference
  was accepted, a cascading delete removed nothing, and dropping a referenced
  parent succeeded. An insert naming a parent row that does not exist is now
  refused with `error.ForeignKeyViolation`, a cascading delete really removes
  the children, and `DROP TABLE` of a referenced table fails while rows still
  point at it — check your test and database cleanup order (drop the child or
  junction table first); SQLite reports the same failure MySQL reports as
  errno 3730.

  Every connect path was checked: `openWithOptions` holds the only
  `sqlite3_open` in library code, and the pool's caller-supplied factories all
  call `open`. A consumer that builds a `SQLiteDriver` around its own handle
  still bypasses the pragma — `enforceForeignKeys()` is public for exactly that.
  A database that already holds dangling references can opt out per connection
  with `.{ .enforce_foreign_keys = false }`, which means what it says: references
  are no longer checked.

### Fixed
- **The pool no longer waits out its budget while it has room to serve you.**
  A health check failing on a *freshly opened* connection closed that
  connection — which is exactly what freed room below `max_connections` — and
  the borrow then parked on the condition variable, where nothing could wake
  it: the only signal a waiter can get is another borrower's `release`, so with
  no other borrower in the pool it spent the whole `max_wait_ms` and reported
  `PoolWaitTimeout` instead of the error that actually happened. Reachable
  behind a proxy or a half-open connection. **Waiting now happens only while it
  can be served**: the pool at its ceiling with every connection lent out. With
  room below the ceiling the attempt goes to the bounded `max_retries` /
  `retry_backoff_ms` path instead, each backoff capped by the caller's remaining
  budget, so `max_wait_ms` stays a hard upper bound.
- **A borrow that only met failed health checks reports that error**
  (`PingFailed` / `ConnectionFailed`) rather than `PoolExhausted` or
  `PoolWaitTimeout`. `PoolExhausted` keeps its meaning — at the ceiling with
  everything lent out — and a budget that runs out during either the wait or
  the retries is still `PoolWaitTimeout`, so the budget outranks an error
  recorded earlier in the call. One existing test's expectation moved with it:
  "evicts connection on failed health check during borrow" now expects
  `ConnectionFailed`, because it had pinned the misattributed reason while its
  eviction assertions are unchanged.
- **PostgreSQL: a not-null or foreign-key violation is no longer reported as
  `UniqueViolation`.** `sqlstateToError` read the SQLSTATE condition at offset 2,
  which is `5` for the whole `235xx` family, so `23502` (not-null) and `23503`
  (foreign-key) both matched the unique-violation arm. A consumer branching on
  `ForeignKeyViolation` — or using `UniqueViolation` for an upsert fallback —
  took the wrong branch on PostgreSQL. Found by the cross-dialect matrix's new
  foreign-key case, which pins the same answer on all three dialects; the
  condition is read at offset 3/4 now, and shorter-than-5-character codes are
  guarded instead of read past their end.

### Notes
- Three test-local cleanup orders were also wrong (children must drop before
  parents): MySQL's missing-junction test produced two errno-3730 errors per
  run and PostgreSQL's produced "other objects depend on it", both swallowed by
  `catch {}`; a third PG block survived only on `CASCADE`. All are fixed, which
  is what let the matrix case assert one answer everywhere.
- `SQLiteDriver.openWithOptions(allocator, path, .{ .enforce_foreign_keys = false })`
  is the supported opt-out for a database that already holds dangling references.

## [0.69.0] - 2026-09-21

### Added
- **A cross-dialect matrix, and the first divergence it found**
  (`tests/integration/dialect_matrix.zig`). Every other integration file is
  self-consistent — each assertion is checked against the server that file talks
  to — which is how the same class of defect shipped over and over: a call whose
  answer depended on which server was behind it, noticed only when a consumer
  reported it. The changed-vs-matched divergence reached four call sites; SQLite
  coercing where MySQL answers null turned one column-order bug into silent wrong
  values on one dialect and `TypeMismatch` on the other; three MariaDB-vs-MySQL
  differences each turned a tag red.

  The matrix runs one logical operation on every available dialect and asserts
  the observables agree — **semantic** answers only (the returned `bool`, the
  count an API reports, the rows and values that come back), never the metadata
  where dialects differ by design. Eleven cases, each drawn from a defect this
  repo actually shipped, plus a **documented exclusion list** so a reader can
  tell "we do not compare this" from "we forgot". A case with fewer than two
  dialects available skips rather than passing quietly, and a divergence names
  the answers that disagree.

- **`docs/OPEN_ITEMS.md`** — what is still open, in one place, with its evidence.
  `CHANGELOG.md` is history and says so; reading "what is open right now" out of
  it meant diffing accumulated notes against every later release. This is that
  diff, kept current. It also separates the three kinds: what needs a decision,
  what has a known shape, and the structural gaps.

### Fixed
- **`DeleteBuilder.Restore(id)` on a live row answered differently per dialect** —
  found by the new matrix on its first run. The statement matched the live row and
  changed nothing, so SQLite and PostgreSQL counted it and answered `true` while
  MySQL's changed-rows count answered `false`: one call, two meanings, and
  **neither** the documented one ("returns true when a row was restored"). It is
  now scoped to `deleted_at IS NOT NULL`, as `execSoftDelete` is scoped to
  `IS NULL`, so a live row is not restored and answers `false` on all three. The
  already-trashed row and a missing id answer what they always did.

- **A bulk insert whose rows declare different fields wrote to the wrong
  columns.** The statement carries one column list — the first row's — while every
  row's values were flattened in that row's own order, so a row with fewer fields
  left the tail of its values bound as real values (the allocator's `0xaa` fill
  under `std.testing.allocator`) and a row with more ran past the buffer.
  `MultiInsert`'s length assertion held in both cases, because the buffer is sized
  from the column list rather than from what the rows set. Every row is now
  compared with the first **by position** before any statement runs:
  `error.InconsistentRowFields`, with the row index in a warning, and nothing
  written. Rows holding the same fields in another order are rejected too — a set
  comparison would call those consistent and bind them just as wrongly. The same
  check subsumes a divide-by-zero: a leading empty row left only *trailing*
  empties trimmed, so the column list came from an empty row.

- **A MySQL uuid primary key the caller never set is `error.MissingPrimaryKey`**
  instead of an entity keyed by `""`. MySQL has no `RETURNING`, so the caller's
  value is the only source of a `CHAR(36)` key — the library generates no uuid and
  the server fills none in — and the entity's key stayed at a value that names no
  row while looking like one. Decided **before** the statement, so no key-less row
  is written (unlike `error.MissingLastInsertId`, which can only be known
  afterwards). The upsert path resolves its conflict target through the same check.

- **`CrudService.get` leaked the strings it had already duplicated** when a later
  `dupe` failed: `ownedCopy` now tears down by count, the shape
  `ShardedEnv.open` uses.

- **`requeueStale`'s staleness cutoff is explicit** (`staleCutoffMs`). The report
  that prompted this said the old code saturated to `0` and thereby reversed the
  meaning; measuring it showed otherwise, and the code follows the measurement:
  Zig's signed `-|` saturates to `minInt`, not `0`, and `now_ms -| maxInt` does not
  saturate at all, so the old value was already "far past". What was worth fixing
  is that it *relied* on saturating arithmetic to land there — the cutoff is now
  `minInt` for an unrepresentable threshold, stays monotonic across the overflow
  point, and never lands on `0`, which reads as "claimed before 1970" and would
  reclaim negative-stamped rows under a threshold nothing can be older than.
  `older_than_secs <= 0` remains the way to ask for "reclaim every processing row".

- **The `migrate` example leaked eight allocations on every MySQL run** — the four
  parsed DSN strings and the four sentinels handed to `MySQLDriver.connect`. Both
  now live in an arena that ends with the connect call, the shape
  `examples/check_sql` already used; the example's output is unchanged.

### Notes
- **Two `SaveError` members were added** (`InconsistentRowFields`,
  `MissingPrimaryKey`), which is incompatible with exhaustive switches over the
  create error sets. The in-tree compile-time error-set pins were updated; no
  switch on the create path was exhaustive.
- **`docs/OPEN_ITEMS.md` is the entry point for "what is left"** — it carries the
  pool health-check decision, the junction-name collision, SQLite's unenforced
  foreign keys, the unassertable log text, and the modules the audit method has
  not reached.

## [0.68.0] - 2026-09-20

### Fixed
- **An eager-loaded target is projected in field order, not in the table's column
  order.** The neighbour query selected `<target>.*`, whose order is the *table's*
  physical column order, while the result set is scanned **positionally**. Those
  two agree only on a database whose tables were created from the current schema —
  and `ALTER TABLE … ADD COLUMN`, which is how `migrateSchema` adds a field to an
  existing table, **appends the column**. So on any long-migrated database every
  eager-loaded target read its values into the wrong fields.

  Reported against a live MySQL cart with `WithEdge("product")`: every cart read
  returned 500 with `error.TypeMismatch`, while the same entity and code on a
  freshly-created SQLite database were fine. The SELECT list is now the target's
  columns in **field order**, taken from the same `TypeInfo` the scanner walks
  (`Step.to_columns`, filled by `buildEdgeStep`), so the projection and the scan
  cannot disagree. `Step.to_columns` has no default only in the sense that
  `buildEdgeStep` always fills it; a Step built by hand falls back to `*` and the
  field documents why.

  The two dialects show the same defect differently, and both are pinned by a
  test: MySQL's binary protocol makes the getter answer `null`, so the scan fails
  with `error.TypeMismatch`; SQLite coerces (an integer field reading `'widget'`
  gets `0`), so it returns **wrong values silently**.

### Added
- **`explainScanFailure` names the column for a misaligned projection**, and the
  eager-load target scan now calls it at all — it previously had no diagnostic,
  which is why the report above arrived as "no output" and had to be narrowed by
  hand through eight experiments. The new message reads, for the cart case:

  `zent: scanning table 'mt_target' failed: column 2 is 'label' with value
  'widget', which field 'app_id' (i64) cannot hold — the projection does not line
  up with the schema's field order (an eager-loaded target is scanned positionally,
  so its SELECT list must be the target's columns in field order)`

- `sql_scan.scanColumn` is public, so a caller can replay a scan field by field the
  way that diagnostic does.

## [0.67.0] - 2026-09-15

### Changed
- **BREAKING: an insert whose driver reports no `last_insert_id` is now
  `error.MissingLastInsertId` instead of a key of `0`, and the MySQL bulk path
  no longer invents a run of ids.** `CreateBuilder.Save` wrote `0` into the
  entity's primary key when the driver had no id to give
  (`res.last_insert_id orelse 0`), and `BulkInsertBuilder.Save` / `SaveOrUpdate`
  derived `base + i` from a single statement's `last_insert_id`. A `0` cannot be
  told apart from a real key — the caller holds an entity that looks like a row
  that exists — and the derived run is wrong as soon as a chunk contains an
  `ON DUPLICATE KEY UPDATE` that *updates* a row, because an updated row consumes
  no `AUTO_INCREMENT` value while the statement still reports its first generated
  one. Measured on MySQL 9.3: a three-row ODKU whose first row collided reported
  `last_insert_id = 2` for true ids `[1, 2, 3]`, so every derived id was wrong and
  the last named **no row at all**. The in-tree MySQL driver always answers
  `Some`, so this was a contract gap rather than a live failure on the MVP path.

  **Migration:** `SaveError` grew a member, so **every exhaustive `switch` over
  the `Save`/`SaveOrUpdate` error set must handle
  `error.MissingLastInsertId`** — a compile error, not a silent one. Callers that
  read a `0` key as "the database did not tell us" now get the error; the row
  *was* written, only its key is unknown.

- **BREAKING: the MySQL bulk insert/upsert path sends one statement per row.**
  SQLite and PostgreSQL keep one multi-row statement per chunk (with
  `RETURNING`); MySQL now sends one per row so each id is the one the driver
  reported for that row. The emitted `id=LAST_INSERT_ID(id)` — already generated —
  is what makes an updated row answer its existing id, so
  `BulkInsert.SaveOrUpdate` returns the rows' real keys, collisions included. Cost:
  one round trip per row on MySQL (`chunkRows` still bounds the batch, though a
  one-row statement never reaches the bind-parameter limit), and a mid-chunk
  failure leaves the rows before it written where the single multi-row statement
  was atomic. A driver that reports no id makes the call
  `error.MissingLastInsertId` rather than a fabricated run.

### Fixed
- **A soft delete no longer re-trashes a row that is already in the trash.** Both
  soft-delete statements (`Delete().Exec()` and `BulkDelete().Exec()`) emitted
  `UPDATE <t> SET deleted_at = <now> WHERE <preds>`, so a second call matched the
  trashed row, pushed `deleted_at` forward — losing **when** the row was really
  trashed — and counted it again, where a hard-deleting entity answers `0` for the
  same call because there is no row left to delete. That asymmetry is what Z34 was
  about, so this closes the half its verification had recorded as "reported, not
  fixed". Both paths now add `AND deleted_at IS NULL`, the condition the edge-write
  helpers already used for the same reason. It is applied to the statement rather
  than to the predicate groups, so `error.NoPredicate` still refuses a call that
  constrains nothing, and a row matched by two ORed bulk groups is no longer
  counted twice.

  **Behaviour change, single-row path:** `Delete().Exec()` on an
  already-soft-deleted row now answers **0 instead of 1**, so `ExecOne()` raises
  `error.NotFound` and a `setVersion` caller gets `error.OptimisticLockConflict`
  where a repeat delete used to "succeed". Checked before changing it: no test,
  example or bench pinned the old behaviour, and `0` is what the hard path answers
  for a row that is gone. Live rows are unchanged.

### Notes
- **The bulk insert API does not validate that every row supplies the same fields
  in the same order, and does not fail when they differ.** Reported while
  verifying the above, not fixed — it writes values into the wrong columns and
  reads uninitialised memory: with row 1 setting `(name, age)` and row 2 setting
  only `age`, row 2's statement is still `INSERT INTO user (name, age) VALUES
  (?, ?)`, its `age` lands in the `name` column, and the second argument is the
  testing allocator's `0xAA` fill. The column list comes from the first row and
  the values are flattened per row, so `MultiInsert`'s length assert holds
  vacuously. A public-API data-corruption surface that needs its own decision
  (a named error, or a per-row column list).
- A MySQL text (uuid) primary key the caller did not set still leaves the entity's
  key empty — the same "unknown as a value" family, in the one branch this change
  deliberately did not touch.

## [0.66.0] - 2026-09-15

### Changed
- **BREAKING (security): an empty `dept_ids` list on a `.dept_custom` /
  `.dept_and_child` data scope now denies instead of widening** (Z33, reported by
  a consumer). It left the filter rule's predicate `null`, and `null` is how this
  module spells "no restriction" — so a request carrying no departments read
  **every** row, while the adjacent branch (over `max_dept_ids`, differing only in
  length) denied. The module contradicted its own `deny_pred` comment, which says
  in as many words that a scope which cannot be built must never come out looking
  like `.all`.

  An empty list is now a "cannot be built" like the over-long one: it
  materializes the always-false `1 = 0` and warns why. **`.all` is untouched** and
  remains the way to say "no restriction", which is why the empty list has no
  information to lose. **Migration:** code that meant "unrestricted" passes
  `.all`; code that meant a real scope passes the real department ids. This bites
  on reads and on the `WHERE` of scoped updates/deletes; creates are unaffected
  (they are gated by the policy *decision*, not the filter predicate).

  Amplification found while checking call sites: **`.dept_and_child` is a synonym
  for `.dept_custom`** — same switch arm — and never reads `self_dept_id`, which
  only `.dept_only` does. A caller using it with `self_dept_id` alone therefore
  *always* passed an empty list, which is exactly the path that used to become a
  full-table read.

- **BREAKING: `BulkDelete().Exec()` with no predicate is now
  `error.NoPredicate`** (Z34, same consumer). It did one of two things depending on
  the entity's schema rather than on the call: a soft-deleting entity silently did
  nothing and returned `0` — which a caller reads as "no rows matched" — while a
  hard-deleting entity deleted the **whole table**. `BulkDeleteBuilder.query` /
  `takeQuery` now refuse a call that constrains no rows, the rule v0.45.0 applied
  to a `SET`-less `UPDATE` (`error.NoFieldsToUpdate`): the shape is named rather
  than resolved in either direction, because which reading a caller got depended on
  someone else's schema. The two duplicated implementations were merged into one
  `writeStatement` — the drift between those copies is the defect class this is
  about.

  **Migration** for callers who used it to clear a table: say so with
  `.Where(&.{sql.Raw("1 = 1")})` (renders `DELETE FROM t WHERE (1 = 1)`), or use
  raw SQL. A scoped delete with no caller `Where` still works when an interceptor
  or a privacy policy supplies the predicate, because the check runs after both.
  The two dead guards (`groups.items.len == 0`, unreachable because `init` always
  appends a group) are gone, so the code no longer looks guarded where it was not.

- **A predicate group with no predicate is skipped instead of rendering a dangling
  `OR`.** A `Next()` before the first `Where` — what a `Next(); Where(…);` loop
  produces — used to emit `DELETE FROM t WHERE  OR "id" = ?`, which is not SQL.
  The soft-delete path already skipped such a group; now both paths delete the
  same rows.

### Fixed
- **The bulk soft-delete path applies the privacy policy's row filters.** It
  checked `decision == .deny` and then dropped `result.getFilters()`, while the
  bulk **hard** delete and the single-row `DeleteBuilder.execSoftDelete` both
  append them — so a soft-deleting entity whose policy scopes rows by a filter
  could **soft-delete rows outside that scope**. Found while verifying Z34;
  falsified by dropping the filters again, which turns a scoped delete of 2 rows
  into one of 3.

## [0.65.0] - 2026-09-15

### Added
- **`check_sql`: the Z28 CLI entry point for raw SQL** (`examples/check_sql`,
  installed as `zig-out/bin/check_sql`, `zig build run-check-sql`). Z28's last
  open item: a consumer with ~476 hand-written call sites asked for a way to
  validate a statement *before* it runs, and the library half shipped in v0.58.0
  (`checkStatement`, prepare and discard) — what was missing was the thing that
  can sit in a pre-commit hook or a CI step.

  It reads `.sql` files and/or `--sql` text, splits each input into single
  statements and runs every one through `checkStatement`. The splitter is real
  rather than advertised: a semicolon inside `'a;b'`, `"ident;ifier"`,
  `` `backtick` ``, a `-- line` / `/* block */` comment (nested, PostgreSQL's
  rule) or a `$tag$ … $tag$` body does not split, each statement reports the line
  it starts on, and the limits (no `#` comments, no backslash escapes, an
  unterminated quote swallows the rest into one statement) are stated in `--help`
  and in the module doc rather than papered over.

  Exit **0** when everything prepared cleanly or could not be judged, **1** when
  a statement failed, **2** when the run itself could not happen — including "no
  statement found", so an empty glob cannot look green. `not_checkable` is
  counted in its own bucket and never as a failure: it is a limit of the prepare
  channel, not a defect in the statement, which is the distinction v0.58 drew and
  the reason this can gate a build. `--dsn` takes `sqlite:<path>`,
  `postgres://…`, a libpq keyword/value conninfo (the shape `PG_DSN` has in CI)
  and `mysql://…`, defaulting to `$ZENT_DSN` then `sqlite::memory:`.

- **`checkSchema` compares a present M2M junction table's shape**, not only its
  existence. `missing_junction_table` answers "is the relation there"; a relation
  of the right name with the **wrong shape** stayed silent even though it breaks
  the same queries — a missing `*_id` column fails every read over the edge with
  `no such column`, and a table with nothing keying the pair accepts the same link
  twice, so the relation query answers with the same neighbour twice.

  A present junction is compared against the shape `junctionTableForEdge` derives
  — the same definition `migrateSchema` creates it from and `buildEdgeStep` reads
  it with, so the checked shape is not a second opinion — on exactly three things:

  - the two columns, as `.missing_column` — read-breaking, like any other missing
    column;
  - the pair's uniqueness, as the new **`.junction_pair_uniqueness`** — a *write*
    constraint, so `breaksReads()` is **`false`** and `read_breaking_only` does not
    block a deploy over it. `UNIQUE (b_id, a_id)` satisfies it, since the two
    orders forbid the same duplicate pairs; a wider `UNIQUE (a, b, c)` does not;
    and a *unique* index whose key list cannot be read (an expression key, a
    prefix, a partial index) suppresses the report rather than guessing — the rule
    `unique_constraint` already follows;
  - the two foreign keys, as `.missing_foreign_key`, by shape like every other.

  A junction whose name a **view** carries is compared on its columns alone,
  because a view can carry neither a primary key nor a foreign key. Column
  **types**, `NOT NULL` and extra columns are deliberately not compared, and
  `migrateSchema` still never reshapes a junction table.

### Fixed
- **EntQL rejects an expression the parser does not consume entirely.**
  `entql.parse` is a prefix parser and never checked that the input ran out, so
  `age > 1 age < 5`, `name = "alice" zzz` and `status IN ("a","b") junk` all came
  back as a tree for the **prefix alone** — indistinguishable from a full parse.
  Through `QueryBuilder.WhereEntQL` that is a filter with **fewer conditions than
  was written**, i.e. more rows returned: the fail-open shape this audit method
  keeps turning up, in the one place where the input is user data. It now requires
  EOF and answers `error.UnexpectedToken`, a name the error set already carried
  and nobody constructed. Trailing whitespace still parses.

  The failure paths also leaked everything they had built — `a IN (1, 2) OR`,
  `has(cars, price > 5` and `name CONTAINS 'x' AND` left the half-built tree, the
  `IN` value list and the `LIKE` pattern allocated, so a malformed filter string
  leaked on every call. Eleven `errdefer` now cover them.

- **`graph.neighbors.appendSetNeighbors{,Filtered}` reject an empty
  `parent_ids`** with `error.EmptyParentIds` instead of emitting a statement with
  a bare `WHERE ` — measured as `SELECT "car".*, "owner_id" AS __fk FROM "car"
  WHERE `, which SQLite rejects with `near ";": syntax error`. Both in-tree callers
  already short-circuit an empty page, so nothing hit it; the guard keeps the next
  caller from inheriting a prepare error from deep in the driver. An error rather
  than an assert, because in `ReleaseFast` an assert is UB and the bare `WHERE`
  would come back.

- **The logger no longer reports a row count the driver never obtained as `0`.**
  `LogContext` carried only `rows_affected`, so the "the driver has no count" case
  that `Result.rows_affected_known` exists for (v0.63.0) still reached the log line
  as a real `0` — the same "matched nothing" claim the drivers had stopped making.
  `LogContext` now carries the flag (additive, default `true`), the renderer prints
  `?` for an unknown count, and the call sites that have no count to give forward
  it: `QueryBuilder.Iterate`, which logs a stream it has not read, marks its `0`
  unknown, and the three `UpdateBuilder`/`DeleteBuilder` `onExec` sites forward
  `Result.rows_affected_known`.

### Notes
- **The log text itself is not capturable in tests** (this repo has no `logFn`), so
  that fix is pinned at the renderer and at the `LogContext` each callback
  receives — stated rather than dressed up as an end-to-end assertion.
- **`crud_helpers.saveOrUpdate` keeps its exists-then-create window**, now
  documented on it and on `batchSaveOrUpdate`: two writers can both read "no match"
  and both insert. The helper receives opaque predicates, so it cannot name a
  conflict target for an upsert, and the `.created`/`.updated` split that
  `batchSaveOrUpdate` counts on has no upsert equivalent. With a unique index over
  the predicate's columns the loser gets `error.UniqueViolation`; without one both
  rows remain.
- **`create.zig`'s two insert log sites still report a hardcoded
  `rows_affected = 1`** (reported, not fixed): on the RETURNING path an ignored
  `SaveIgnore` logged 1 while zero rows were written, and on the MySQL path the
  server's count can be 2 (an ODKU update) or 0 (ignored).
- **`create.zig`'s `last_insert_id orelse 0`** writes `0` into an entity's key and
  fabricates a contiguous id run in the batch path — reachable only through a
  driver that returns `null` (the in-tree MySQL driver always answers `Some`), and
  fixing it changes `SaveError`, so it is reported rather than changed.
- **`BulkDelete().Exec()` with no predicate is a silent no-op on a soft-deleting
  entity and a full-table delete on a hard-deleting one** — the same call, two
  semantics. Needs a decision rather than a patch.
- **`examples/migrate` leaks eight allocations on every MySQL run** (it never frees
  the parsed DSN parts). Reported, not fixed; the new CLI does it correctly.

## [0.64.1] - 2026-09-15

### Fixed
- **`crud_helpers.increment` reports rows *matched*, not rows *changed*.**
  `SET hits = hits + 0` changes nothing, so MySQL counted 0 while SQLite's
  `changes()` and PostgreSQL's `UPDATE 1` tag both counted the matched row
  (measured on all three) — and a caller reading 0 as "no such row" took the
  wrong branch. The zero path now re-checks with the same count query
  `crud_helpers.update` uses, so the answer is the matched count on every
  dialect. A non-zero delta changes the value and never reaches that path.

  `crud_helpers.batchSaveOrUpdate` needed no change: it accumulates the result of
  `saveOrUpdate`, which goes through `update` — so the v0.64.0 fix to that
  function already corrected its `updated_count` on MySQL.

## [0.64.0] - 2026-09-15

### Added
- **Concurrency invariants for the prepared-statement cache and the outbox.**
  The pool has had stress tests since v0.61, and they are the reason the two
  fixes before them hold up; the two other components actually driven from
  several threads had none. Same method — invariants, not a schedule, because a
  flaky stress test is worse than none.

  - the **cache**: concurrent take/put against eviction never recycles or loses a
    handle (a canary is re-read while the handle is out), and the bookkeeping is
    self-consistent after the storm;
  - the **outbox**: a nested dispatcher on one connection and concurrent
    dispatchers on separate ones, asserting the guarantee the implementation
    actually makes — **a row is claimed exactly once, never by two dispatchers** —
    rather than a stronger one it does not.

  Verified by running the binary ten times: 10/10 stable.

- `sql_sqlite.RecursiveMutex` is now public, with the reason in its doc comment:
  the same lock has to guard anything fronting one SQLite connection — a `Driver`
  wrapper fanning out to a shared handle, or the cache driven directly — and
  re-implementing it at a second site is how two locks that must be the same
  become two locks.

### Fixed
- **`crud.update` no longer answers `false` for an idempotent PUT on MySQL.**
  MySQL reports *changed* rows (`CLIENT_FOUND_ROWS` is off), so writing a row
  back unchanged counted `0` and the `!bool` read that as "missing" — a 404
  upstream — while SQLite and PostgreSQL, which report matched rows, answered
  `true`. The zero path now re-checks existence under the same `(tenant, id)`
  predicates, the shape `crud_helpers.updateWithVersion` already used, so `false`
  means "no such row" on all three dialects. The extra query runs only when the
  `UPDATE` reports 0.

  `crud_helpers.update` returns rows **matched** rather than rows **changed** for
  the same reason, so an idempotent update answers `1` on MySQL as it already did
  elsewhere.

- **`crud_helpers.cursorPage` rejects a non-integer `cursor_col`** with
  `error.InvalidCursorColumn`. It validated only that the name existed, so an
  integer cursor bound against a text column **filtered nothing** (measured: 5
  rows returned with `after=3`) and the page could come back with `has_more`
  true beside a null `next_cursor` — a silent truncation with no error at all.
  Checked before tightening: no caller in the tree, the examples or the
  integration tests uses a non-integer cursor column, so this rejects only calls
  that were already wrong.

- **`migrateSchemaWithOptions` with `dry_run: true` previews the migration that
  would actually run.** It printed the DDL for a *fresh* database — every
  `CREATE TABLE`/`VIEW`/`INDEX`, no introspection — so the statements an
  incremental migration really executes (`ALTER TABLE … ADD COLUMN`,
  `DROP COLUMN`, `ALTER TYPE`, `SET`/`DROP NOT NULL`) never appeared. A consumer
  could read the preview, see only `CREATE` statements, approve it, and have the
  real run drop a column.

  One planner now produces the statement list and **both paths use it** — the
  real one executes it inside the transaction, the dry run prints it — so the two
  sets cannot drift. Same introspection, same migration-history snapshot, same
  opt-in gates, same MySQL BLOB/TEXT fail-closed diagnostics, and the dry run
  still executes nothing. The core assertion is that a dry-run plan equals the
  statements a real migration records, observed through a wrapper driver that
  logs every `exec`.

  One consequence worth naming: because the plan is built before any `exec`, a
  generation failure (the MySQL TEXT guard) aborts *before* the first statement
  instead of partway through — and on MySQL, where DDL autocommits, the old
  interleaved flow left the already-executed statements behind.

- **`ShardRouter.init` rejects `shard_count == 0`** with
  `error.InvalidShardCount`; a zero-shard router previously reached `route`'s
  `hash % shard_count` and panicked in Debug/ReleaseSafe (reproduced: `panic:
  division by zero`) or hit undefined behaviour in ReleaseFast. Fixed at
  construction rather than at the division, because `route` returns a plain
  `usize` and the whole `clientForTenant`/`shardOf`/`moveTenant` chain is built on
  "routing always succeeds" — making it fallible would have infected every
  caller. `ShardSet.clientAt` asserts its index for the same reason.

- **`ShardedEnv.open` closes and destroys the drivers of already-opened shards**
  when a later shard fails to open. The per-iteration `errdefer` covered only the
  failing iteration, so every earlier shard's driver leaked (falsified: the
  testing allocator reports a leaked 33408-byte driver block).

## [0.63.1] - 2026-09-15

## [0.63.0] - 2026-09-15

### Added
- **`driver.Result.rows_affected_known`** — a non-breaking additional field,
  defaulting to `true`, saying whether `rows_affected` is a count the driver
  actually obtained. `rows_affected` is a `usize` and so cannot express
  "unknown", which made a statement that reports no count and a driver that could
  not read one both arrive as `0` — indistinguishable from "matched no rows",
  which the optimistic-lock check and the `NotFound` paths read at face value.
  The default is what keeps it non-breaking: every in-tree construction compiles
  and keeps its meaning unchanged.

  The three dialects now answer honestly, and the differences are left visible:

  | Statement | SQLite | PostgreSQL | MySQL |
  |---|---|---|---|
  | `INSERT`/`UPDATE`/`DELETE` | known | known | known |
  | `SELECT` via `exec` | **unknown** | known (rows returned) | known (unprepared) / **unknown** (prepared) |
  | DDL, `BEGIN`/`COMMIT`, `SET` | **unknown** | **unknown** | known (`0`) |

### Changed
- **Four in-tree decision points now read the flag:** the three optimistic-lock
  checks (`UpdateBuilder.Save`, `execSoftDelete`, `execHardDelete`) and
  `DeleteBuilder.Restore`. `UPDATE`/`DELETE` counts are obtained on all three
  dialects, so **no existing behaviour moves** — pinned by the existing
  three-dialect optimistic-lock tests plus a new mock-driver test that drives both
  sides of the guard.

- **Consumers should start checking the flag.** `rows_affected == 0` asks "did the
  driver count zero rows?"; if the question is "did the statement match nothing?",
  read `rows_affected_known and rows_affected == 0`.

### Fixed
- **A driver step failure is no longer reported as a short page.**
  `Rows.next()` returns `null` both when the scan finished and when it broke;
  `nextError()` is the only way to tell, and three bulk readers never asked:
  `crud_helpers.queryRows` and `queryRowsIn` returned an **empty page as a
  successful result**, and `outbox.claim` returned **half a batch as the rows it
  had reserved** — which the dispatcher then treated as all of them. The rest of
  the tree (`codegen`, `scan.zig`, `schema`) already asked; these three were the
  miss.

- **A data-scope policy that cannot be built now denies instead of widening.**
  This one is a **security bug**. `privacy/data_scope` left its predicate `null`
  when it could not build one — a `dept_ids` list longer than `max_dept_ids`, or a
  `PrivacyContext` whose `.extra` carries no filter — and a `null` predicate is how
  a filter rule says *"not applicable"*, so the policy layer read "cannot scope" as
  "no scope" and the query ran over **every row**. A context set up with
  `withContext(.{ .user_id = 1 })` and no filter was therefore wide open. Both
  cases now materialize an always-false predicate (`1 = 0`) and log a warning,
  following the precedent already in `runtime/privacy.zig` for a filter array that
  overflows.

- **SQLite no longer reports the previous statement's row count.** `exec` on a
  `SELECT`, a `PRAGMA`, or a DDL statement returned `sqlite3_changes` — the
  *previous* DML's count. The predicate is a conjunction, because a probe showed
  `sqlite3_stmt_readonly` alone is not enough: it reports `0` for
  `CREATE`/`ALTER`/`DROP`/`ANALYZE`/`VACUUM` and for a `PRAGMA` write, none of
  which touch the counter. Requiring `SQLITE_DONE` also fixes a bug found in
  passing: a DML with `RETURNING` ran, inserted its row, and still reported the
  previous count, because SQLite settles the counter only at completion. Without
  that the new field would have lied, which is worse than not having it.

- **MySQL maps the `(my_ulonglong)-1` sentinel to `0` plus unknown** instead of
  storing `18446744073709551615`, and **PostgreSQL reports the empty `PQcmdTuples`
  tag as unknown** (that is what libpq returns for DDL, `BEGIN`/`COMMIT`, `SET`,
  `VACUUM`, `ANALYZE`, `TRUNCATE`).

### Notes
- **`outbox.dispatch` and `crud_helpers.withTx` no longer destroy the reason.**
  A failed publish logs the row id, event, attempt count and the publisher's error
  name — a batch where *every* publish failed looked exactly like an empty queue —
  and a failed rollback after a failed callback is logged. Neither changes a
  return value, so both are declared **unfalsifiable rather than claimed**: this
  repo has no `logFn` to capture, and no assertion can pin them.
- **Nine further findings reported, not fixed**, each with its blast radius
  (`docs/ISSUES_FROM_ZAPI.md`-adjacent detail in the lane's audit table):
  `crud.update`'s `!bool` **reverses meaning on MySQL** (it reports *changed*, not
  *matched* rows, so an idempotent PUT returns `false` → a 404); `cursorPage`
  silently truncates when the cursor column is not an integer (measured: 5 rows
  returned with `after=3`, and `has_more=true` beside `next_cursor=null`);
  `ShardRouter.route` divides by zero at `shard_count == 0`; `ShardedEnv.open`
  leaks the drivers opened before a failure; `requeueStale`'s age overflow
  was claimed to saturate in the wrong direction — measured in v0.69.0 and it did
  not, see that release; `outbox.nowMs` falls back to `0` (unreachable);
  `crud.ownedCopy` has no `errdefer`; `ShardSet.clientAt` is unchecked;
  `saveOrUpdate`'s exists-then-create is a TOCTOU window.

## [0.62.0] - 2026-09-15

### Added
- **`checkSchema` now checks M2M junction tables**
  (`SchemaDrift.Kind.missing_junction_table`) — the last declared surface nothing
  looked at. An M2M edge implies a junction table (`junctionTableForEdge`), and a
  junction table is not a `TypeInfo`, so the entity loop walked past it: an edge
  whose junction was never created, or was dropped out of band, kept
  `assertSchema` green while every query over that edge failed with
  `no such table`. Same silent class as `missing_view`, one scope over;
  `migrateSchema` already created these tables, only the report was missing.

  The drift names the junction in `table`, leaves `column` empty (no column
  semantics), and puts the edge plus the columns a hand-created table needs in
  `index_detail`. `breaksReads()` is **`true`** — the relation query errors
  outright rather than returning fewer rows, so `read_breaking_only` blocks a
  deploy on it, like `missing_table` and `missing_view`.

  Existence uses the same `getExistingColumns` probe as `missing_view`. Only
  `relation == .m2m` edges with no `Through` need a junction: a `Through` edge
  uses the edge schema's own table (checked as an entity), and O2M/O2O have none
  (their FK is `missing_foreign_key`'s business). Both sides of a symmetric M2M
  derive the same name, so a seen-list collapses the pair into one report.

### Fixed
- **SQLite read a failed query as a short or empty page.** `SQLiteRows.next()`
  handled `SQLITE_BUSY`, `SQLITE_LOCKED` and `SQLITE_CONSTRAINT` and left
  `next_error` at its null default for **every other** step failure —
  `SQLITE_FULL`, `SQLITE_IOERR`, `SQLITE_MISMATCH`, `SQLITE_TOOBIG`,
  `SQLITE_INTERRUPT`. `nextError() == null` is how every consumer distinguishes
  "finished" from "broke", so a failure came back as "no more rows": a partial
  page, or `error.NotFound` for a single-row read. Those failures now report
  `error.ExecFailed`; the lock/constraint classification is unchanged.

- **PostgreSQL's affected-row count was `parseInt(...) catch 0`.** Two different
  situations collapsed into `0`: a command tag that reports no row count
  (PostgreSQL returns `""` for DDL, `BEGIN`/`COMMIT`, `SET`, …), where `0` is
  correct, and a tag that does not parse, where `0` is indistinguishable from "a
  statement that matched no rows" — which consumers read as
  `OptimisticLockConflict` or `error.NotFound`. `rowCountFromCommandTag` keeps
  `""` as `0` and, for anything else, warns with the raw tag and fails with
  `error.DriverFailed`.

  Probing real libpq (every statement class through `PQexec`, `PQexecParams` and
  the prepared path) showed the malformed case is **not reachable today** — which
  is the point: `catch 0` made it unfalsifiable and hid a real distinction.
  Treating `""` as malformed instead would have broken every DDL through `exec`
  (52 integration tests), and that is what pins the two cases apart.

### Notes
- **Audit result, so the negative half is recorded too.** Eight further
  `catch null` / `catch 0` sites were examined and judged benign with their
  reasoning: the `?i64`/`?f64` getters and `last_insert_id` answer `null`, which
  is the legal "not knowable" (and what the strict scanner turns into
  `TypeMismatch`); `scan.zig`'s lenient defaults are its documented contract;
  `classify`'s `else => .bug` is a conservative answer about an *unknown* error,
  not a value for a known one.
- **Three further "a value that cannot be told apart" findings, reported not
  fixed** — all three are consequences of `driver.Result.rows_affected: usize`
  not being able to express "the driver does not know":
  - `sqlite3_changes` is stale after a non-DML, so `exec("SELECT …")` returns the
    *previous* DML's count while PostgreSQL and MySQL report the select's rows —
    the three drivers disagree, and a `rows_affected == 0` consumer gets "found"
    from a `SELECT`.
  - `mysql_affected_rows` returns `(my_ulonglong)-1` on error and `@intCast` to
    `usize` turns it into `18446744073709551615` rather than failing. Unreachable
    today (every `CR_*` failure is checked first), same family.
  - `getBool` turns any unrecognised text into a definite boolean where `null`
    (→ `error.TypeMismatch`) would be honest. Correct for each dialect's own wire
    format; only misfires when a non-boolean column is read into a bool field.
- **A junction-table name colliding with a declared entity table is not
  detected.** `junctionTableForEdge` derives `<a>_<b>`, so an entity whose table
  is literally that collides, and `CREATE TABLE IF NOT EXISTS` silently keeps
  whichever ran first. Reported, not fixed.
- **Only the existence of a junction table is compared**, not its shape
  (columns, PK, FKs, pair-uniqueness); and the check costs one extra
  `getExistingColumns` per distinct junction table.

## [0.61.0] - 2026-09-15

### Added
- **`checkSchema` now reports a declared view the database does not have**
  (`SchemaDrift.Kind.missing_view`). Views were the one declared shape it never
  looked at, so a view that was never created — or was dropped out of band —
  produced a green `assertSchema` while `SELECT … FROM the_view` failed. That is
  the same silent failure as a missing table, one scope up.

  The check asks one question, *is there a relation of this name at all?* (a
  table counts as well as a view), reusing the `getExistingColumns` probe
  `migrateSchema` already uses to re-create a dropped view rather than adding a
  second existence check. `breaksReads()` is **`true`** for it — a missing view
  makes the read fail outright, it does not merely change shape — so
  `DriftStrictness.read_breaking_only` blocks a deploy on it, exactly as it does
  for `missing_table`.

- **`getExistingViews` / `freeExistingViews` / `ExistingView`** — read the views
  a database holds, from each dialect's catalog (`pg_views`,
  `information_schema.views`, `sqlite_master`), with the view name **bound** on
  all three (`$1` / `?` / `?`). `ExistingView.definition` is the definition *as
  the database stores it*.

- **Connection-pool stress tests** (`tests` in `src/sql/pool.zig`). The pool is
  where this project's serious defects have been — an entry whose address moved
  while borrowed (the raw-pointer `available` list, which a `swapRemove` plus a
  fresh `addOne` could alias into a use-after-free), and a `release` that pooled
  a connection it had failed to roll back. Both were found by report or by
  audit, not by a test, because no test asserted what the pool must *never* do
  under concurrency. Three tests now do, with invariants rather than a schedule
  (a flaky stress test is worse than none):

  - a connection is never lent to two borrowers (pointer-keyed registry + a
    holder slot inside the driver);
  - a borrowed connection is still its own entry after a storm of create/close
    churn (a canary re-read while the borrow is live);
  - connections really are closed while others are lent out (a reaper thread
    drives `pingIdleConnections`/`reapIdleConnections` against the borrow-path
    health check and lifetime eviction);
  - `stats()` drains to `total == available`, `in_use == 0`, `waiters == 0`;
  - the simultaneous-borrow peak never exceeds `max_connections`;
  - every parked waiter is woken.

  They run on `std.testing.allocator` — its `SafeAllocator` is thread-safe in
  this Zig version, so leak detection stays on, which is how a leaked registry
  in the first draft was caught. Ten consecutive runs, no jitter.

### Fixed
- **PostgreSQL could not create a declared view at all.** `createViewSQLAlloc`
  emitted `CREATE VIEW IF NOT EXISTS` for every dialect, and **PostgreSQL has no
  `IF NOT EXISTS` for `CREATE VIEW`** — it answers `42601 syntax error at or
  near "NOT"`. A schema declaring a view entity therefore failed
  `migrateSchema` *and* `createAllTables` outright, and had since views were
  added (v0.30-era). SQLite is the mirror image and rejects `OR REPLACE`
  (`near "OR": syntax error`), so one clause cannot serve both:

  | Dialect | Emitted | A changed `view_sql` |
  |---|---|---|
  | PostgreSQL, MySQL/MariaDB | `CREATE OR REPLACE VIEW` | **now takes effect** on the next `migrateSchema` (PostgreSQL allows columns to be appended, not reordered or retyped) |
  | SQLite | `CREATE VIEW IF NOT EXISTS` | still does not take effect — SQLite has no in-place replace |

  This is a behaviour change, not only a fix: on PostgreSQL and MySQL a
  migration now converges an existing view's definition where it previously did
  nothing. The definition is still never *compared* (see below), so a converged
  view is not reported either way — `migrateSchema` acting is not this check
  observing. The view clause is pinned per dialect by a unit test, and the
  PostgreSQL integration test now creates its view through the real migration
  path, which is the assertion that failed with `syntax error at or near "NOT"`
  before this change.

### Notes
- **The view definition is deliberately not compared.** PostgreSQL stores a
  rewritten query (`WHERE status = 'active'` becomes
  `((status)::text = 'active'::text)`), MySQL and MariaDB their own
  normalizations, and SQLite the original text under zent's own clause — a
  string comparison against `view_sql` would report every view in every database
  and block every deploy. A caller that wants to compare can read
  `getExistingViews` and normalize per dialect.
- **`checkSchema` still does not see M2M junction tables.** A missing junction
  table is not reported; relation queries against it fail. Same silent-failure
  class as `missing_view`, not yet covered.
- **A pool behaviour worth a decision, found by the stress tests:** with
  `health_check_on_borrow = true` and a wait budget, a health check that fails
  on a *newly created* connection parks the borrower until the budget expires
  even though the pool could open another — and if no other thread holds a
  connection, nothing can signal it, so the caller waits out `max_wait_ms`
  instead of failing fast on the connection error. Reported, not changed.

## [0.60.1] - 2026-09-15

### Fixed
- **A connection whose leaked transaction cannot be rolled back is dropped
  instead of pooled.** `ConnPool.release` rolls back a connection that comes
  back with an active transaction, and it discarded the result of that
  `ROLLBACK` (`catch {}`) while unconditionally clearing MySQL's `in_tx` flag.
  A rollback that **fails** leaves the connection possibly still inside that
  transaction, so the next borrower would run its statements inside someone
  else's — the silent-state-divergence shape this pool has been bitten by
  before, one level down. The connection is now closed and the pool signalling
  instead, and `in_tx` is cleared only after a rollback that actually worked.

  The successful-rollback case already had a test (`ConnPool rolls back leaked
  transaction on release`); the failing one did not, which is why the error was
  swallowed rather than acted on. The new test drives a connection that reports
  `inTransaction()` and fails its `ROLLBACK`, and asserts the pool holds nothing
  afterwards rather than lending the dirty connection on. Falsified by restoring
  the `catch {}` — the close never happens and the test fails on it.

## [0.60.0] - 2026-09-15

### Added
- **`checkSchema` / `assertSchema` now cover column-level `UNIQUE` and foreign
  keys** — the last two declarations that only ever reached a table inside
  `CREATE TABLE`, so a table built before the field was declared `Unique()`, or
  that never had the edge, keeps neither and **nothing reported it**. A
  column-level `UNIQUE` is not a named index, so neither `index_columns` nor
  `index_uniqueness` could see it, and there was no foreign-key introspection at
  all.

  - **`SchemaDrift.Kind.unique_constraint`** — a field declared `Unique()` with
    no unique index forcing that column **alone**. A composite
    `UNIQUE (a, b)` does **not** satisfy `a`: two rows may share it, which is the
    whole point of the constraint being declared. An index that is not unique
    never suppresses the report (it cannot be the constraint either way).
    A table carrying a **unique index whose key list cannot be read**
    (`lower(email)`, `email(10)`, a partial index, a non-btree access method) is
    **skipped rather than guessed at** — each of those does constrain the
    column, so reporting would be a guess, and a false report blocks a deploy.
    A non-unique unreadable index does not suppress anything, which keeps the
    check useful on real schemas.
  - **`SchemaDrift.Kind.missing_foreign_key`** — a foreign key the schema
    declares and the database does not have, compared **by shape** (ordered
    local columns, target table, target columns) and **never by name**:
    PostgreSQL generates one (`t_col_fkey`), MySQL generates one
    (`t_ibfk_1`), SQLite keeps none, and `migrateSchema`'s own `FOREIGN KEY (…)`
    clause names nothing — so a name comparison would report every constraint in
    every database. `ON DELETE` / `ON UPDATE` are **not** compared. A constraint
    the database has and the schema does not is deliberately **not** reported:
    it can only reject writes the schema never promised, and reporting it would
    turn "someone added the protection by hand" into a red gate.
  - Both kinds answer `false` from `SchemaDrift.breaksReads()` — a write
    constraint does not break reads — so `DriftStrictness.read_breaking_only`
    never fails a deploy over them. Only `.any` does.

- **`sql_schema.getExistingForeignKeys` / `freeExistingForeignKeys` /
  `ExistingForeignKey`** — foreign-key introspection for all three dialects,
  from structured catalogs rather than parsed DDL: PostgreSQL
  `pg_constraint` + `pg_attribute` (`conkey`/`confkey` paired positionally
  through `generate_subscripts`, so composite keys are exact and
  `constraint_column_usage`'s cartesian product is avoided), MySQL/MariaDB
  `information_schema.key_column_usage` (`referenced_table_name IS NOT NULL`),
  and SQLite `PRAGMA foreign_key_list` — which takes the same table-name guard
  as the existing pragmas and has the same caveat: it returns an **empty set**
  for a table that does not exist, so the caller establishes existence first.
  `ExistingForeignKey.ref_columns_comparable` is `false` for SQLite's
  `REFERENCES t` short form, where the target columns are not stated; an
  unreadable target column list is treated as *not* a difference, so it cannot
  produce a false drift.

## [0.59.0] - 2026-09-15

### Added
- **`SchemaDrift.Kind.index_uniqueness`** (Z31 follow-up). `ExistingIndex.unique`
  was read on all three dialects and never compared, so an index the schema
  declares `Unique()` that the database holds **without** `UNIQUE` was silent —
  the application believed the constraint was enforced while duplicate rows
  landed. `checkSchema` / `assertSchema` now report it in both directions, with
  the difference in one sentence (`schema declares UNIQUE, database index is not
  unique`).

  It is a **separate kind from `.index_columns`** on purpose. A key list can be
  an expression, a prefix, a `WHERE` or a non-btree access method, and is
  skipped unless it can be read reliably; `unique` is a plain boolean in every
  catalog and always is. Coupling them would either silence this drift for the
  hardest-to-read indexes or produce a key-list verdict that was never
  established. `breaksReads()` is `false` (a wrong uniqueness breaks *writes*,
  not reads), so `read_breaking_only` never fails on it; `.any` does.

### Changed
- **BREAKING: `driver.Error` gained `ParamCountMismatch`.** Error sets are not
  extensible, so a `switch` over `driver.Error` with no `else` stops compiling.
  The one in-tree exhaustive switch (`migrate.zig`) was updated in the same
  commit.

- **BREAKING (MySQL): a bind list of the wrong length is now
  `error.ParamCountMismatch`, not `error.QueryFailed`.** MySQL already refused
  it; the specific error was being folded into the generic one, so a caller
  could not tell "my argument list is wrong" from "the query failed".
  `driver.classify` reports it as `.client` (the caller's own mistake, and
  retrying cannot help) instead of falling through to `.bug`.

- **SQLite no longer tolerates a wrong argument count.** `bindArgs` discarded
  every `sqlite3_bind_*` return code: surplus bindings came back
  `SQLITE_RANGE` and were dropped, and missing ones stayed unbound, which SQLite
  reads as **NULL**. The statement therefore ran and answered a *different*
  question — a raw query one argument short returned an empty page instead of an
  error, which is the "endpoint returned empty for months" failure mode. The
  statement's parameter count is now compared with the argument list (the same
  rule `checkStatement` already applied), and a failing bind reports
  `error.BindFailed` rather than being ignored.

  Two boundaries, stated rather than hidden: an explicit `?NNN` with a gap
  reports the *highest* slot number, so a list sized to the number of used
  parameters is rejected (the builder only emits `?`); and **PostgreSQL does not
  participate** — libpq answers from its own Bind path, which this driver
  surfaces as `error.DriverFailed`. Unifying PG is a separate pass.

- **MySQL's statement-level diagnostics log at `warn`, not `err`.** An `err`
  line makes the Zig test runner fail the test that exercises the path, so the
  message `mysql: expected N params, got M` was untestable. The caller still
  receives the error; the log is context, not the signal.

### Fixed
- **MySQL: `ALTER TABLE … ADD COLUMN` fails closed on a BLOB/TEXT `DEFAULT`,
  like `CREATE TABLE` already did.** The v0.58.0 guards covered
  `createTableSQLAlloc` and `createIndexSQLForTableAlloc`, but the ALTER path is
  reached exactly when the table **already exists** — the case where no
  `CREATE TABLE` is generated — so `ALTER TABLE t ADD COLUMN body TEXT DEFAULT
  'x'` still arrived as a bare errno 1101 in a warning. It now goes through the
  same `findMySqlTextRestriction` classification and returns
  `error.MySQLTextColumnCannotHaveDefault`, naming the table, the column, the
  dialect type and the way out (`field.String` is `VARCHAR(255)` on MySQL).
  PostgreSQL and SQLite are unchanged, as is a TEXT column added without a
  default.

  The check is handed exactly what the statement emits: `unique` and
  `primary_key` are **cleared**, because the ALTER writes neither — retaining
  them would refuse SQL the server accepts, for a constraint this statement does
  not introduce.

  Note the guard is **stricter than MariaDB requires**: MariaDB ≥ 10.2.1 does
  accept a `DEFAULT` on `TEXT`/`BLOB`, but the DDL layer cannot tell the two
  servers apart without a connection, so it applies MySQL's rule to both. A
  MariaDB user who needs a default on a `Text` column must therefore drop to a
  hand-written migration, or declare the field `field.String` (which is the
  only type that could be indexed anyway). This conservatism is inherited from
  v0.58.0's CREATE-side guard, not new here.

- **PostgreSQL introspection binds the table name instead of interpolating
  it.** `getExistingColumns` and the index query pasted the name into a string
  literal (`WHERE table_name = '…'`), so a name carrying a quote either broke
  the statement or turned the rest of it into more predicate; both now bind
  `$1`, as the MySQL branch already bound `?`. SQLite cannot bind a `PRAGMA`
  argument (`PRAGMA table_info(?)` is a parse error), so it **validates**
  instead: a name containing `'`, `"`, `` ` `` or NUL returns the new named
  error `error.InvalidTableName` (logged with the pragma and the name) rather
  than emitting a statement it would break. Spaces and non-ASCII names are
  unaffected.

## [0.58.1] - 2026-09-15

### Fixed
- **MySQL prefix indexes are no longer treated as comparable** in index
  introspection. `getMySQLIndexes` read `column_name` and marked an index
  not-comparable only when that was NULL (a functional index) — the doc comment
  asserted that was the only case, "since MySQL has no partial indexes". That
  missed `KEY (c(10))`: a **prefix index** does constrain the column, so its key
  list read as a match for a schema index over the full column, and
  `SchemaDrift.Kind.index_columns` stayed silent about a real difference.
  `sub_part` is now selected and a non-NULL value marks the index not
  comparable. Falsified by ignoring `sub_part` again, which fails
  `getExistingIndexes reads the key columns in order`.

- **Two new MySQL integration tests no longer pin MySQL-only behaviour.**
  CI's service is MariaDB 10.11 while a development machine usually has MySQL
  8/9, and both tests passed locally while failing the v0.58.0 tag's CI job:

  - `getExistingIndexes reads the key columns in order` created a functional
    index (`(lower(c))`) to be the not-comparable case. MySQL 8.0.13+ only —
    MariaDB has no functional indexes and rejects the syntax (errno 1064). The
    portable case is now a **prefix** index, which both servers accept, and the
    functional index is created on MySQL alone.
  - `a statement the prepared protocol rejects is not_checkable, not failed`
    asserted MySQL's errno 1295 for `BEGIN`. MariaDB's
    `mysql_stmt_prepare("BEGIN")` succeeds, so it now asserts the invariant that
    holds on both — a valid statement is never reported as `failed` — and then
    the server-specific answer on each branch (`ok` on MariaDB, `not_checkable`
    with errno 1295 on MySQL).

  `AGENTS.md` now records the two-server reality with all three escapes, since
  this is the third release to ship a red tag from an assertion that only held
  on one of them.

## [0.58.0] - 2026-09-15

### Added
- **`zent.sql_statement.checkStatement`** (Z28). Raw SQL had no way to be
  validated before it ran, so a consumer with ~476 hand-written call sites kept
  its own audit scripts to answer "will this even run". The statement is
  **prepared and discarded** — nothing is executed, so a checked `INSERT`,
  `UPDATE` or `DELETE` touches no rows (one test per dialect proves it). It
  returns a `StatementDiagnosis` that separates a syntax error, a missing table,
  a missing column, a parameter-list mismatch and a clean statement, and it
  carries the driver's own text (`message`, `native_code`, PostgreSQL's
  `sqlstate`) instead of leaving the caller to reverse-engineer an errno.
  `freeStatementDiagnosis` releases it.

  The dialects do not see the same things at prepare time, and the diagnosis
  says so rather than flattening them: SQLite reports every prepare failure as
  `SQLITE_ERROR`, so its label comes from the message and is flagged
  `problem_heuristic`; PostgreSQL's `25P02`/`0A000` and MySQL's errno `1295`
  (`BEGIN`, `LOCK TABLES`) are `not_checkable` — a statement the prepare channel
  cannot judge, not a broken one — and a driver with no prepare channel answers
  the same way instead of erroring, so a bulk audit does not stop halfway.
  Constraint violations are out of reach for all three, because they happen at
  execution. `driver.Driver.VTable.prepareCheck` is the optional driver-side
  capability behind it; `ConnPool` forwards it, so a pooled driver answers
  instead of degrading to `not_checkable`.

- **`codegen.beginTxCtx` / `codegen.beginTxFromDriverCtx`** (Z24, the codegen
  half). The pool learned to bound waiting for a connection by the caller's
  deadline, and `driver.Driver` gained `beginTxCtx`, but the layer consumers
  actually use had no context entry — a request budget could only be applied by
  dropping to `pool.asDriver().beginTxCtx(&ctx)`. Pure addition: `beginTx` and
  `beginTxFromDriver` keep their signatures and now delegate with a null
  context, and the explicit null branch still calls `Driver.beginTx` rather than
  `Driver.beginTxCtx(null)`, so a third-party driver with that hook sees exactly
  the calls it saw before.

- **`ExistingIndex.columns` / `ExistingIndex.columns_comparable`** (Z31). Index
  introspection now reads the key columns on all three dialects — MySQL
  `information_schema.statistics`, PostgreSQL **`pg_index` + `pg_attribute`**
  (not `indexdef` text), SQLite `PRAGMA index_info`.

- **`SchemaDrift.Kind.index_columns`** (Z31). A declared index the database has
  under the same name with a different, ordered key list is now reported, with a
  `schema wants (a, b), database has (a)` detail. It is reported **only when the
  database's key list is reliably readable**: expression keys, partial indexes,
  non-btree access methods, invalid indexes and `INCLUDE` columns are skipped
  rather than guessed. The reasoning is that a false drift blocks a deploy while
  a missed one is a warning nobody reads, so the comparison errs towards
  silence. `breaksReads()` is `false` for this kind — `read_breaking_only` never
  fails on it; only `.any` does.

- `sql_schema.findMySqlTextRestriction` / `MySqlTextRestriction` /
  `MySqlTextError` and `sql_schema.createIndexSQLForTableAlloc`: the MySQL
  BLOB/TEXT/JSON restrictions are a pure, dialect-gated check callable before
  any DDL is generated.

### Fixed
- **MySQL: a `field.Text` (or `.Json`/`.Other`/`.Bytes`) column declared
  `Unique()`, `Default()` or a primary key, or used as an index column, now
  fails with a named error instead of a raw server error.** Those types stay
  `TEXT` on MySQL (only `String`/`Enum` became `VARCHAR(255)`), so MySQL's
  errno 1170 and 1101 apply to them. DDL generation fails closed with
  `error.MySQLTextColumnCannotBeIndexed` or
  `error.MySQLTextColumnCannotHaveDefault`, logging the table, the column, the
  dialect type and the way out (use `field.String`, or drop the constraint) —
  where before `CREATE TABLE`/`CREATE INDEX` surfaced a bare
  `error.MySQLExecFailed` and one errno in a warning. A key-length prefix is
  deliberately **not** used: for `UNIQUE` it would constrain only the first N
  characters.

## [0.57.0] - 2026-09-15

### Changed
- **BREAKING for MySQL schemas: `field.String` and `field.Enum` map to
  `VARCHAR(255)` instead of `TEXT`.** MySQL refuses the three things a string
  column is normally asked to do when that column is `TEXT`:

  | Declaration | Emitted DDL | MySQL result |
  |---|---|---|
  | `field.String("email").Unique()` | `` `email` TEXT NOT NULL UNIQUE `` | `ERROR 1170` — no key length |
  | `field.String("status").Default("new")` | `` `status` TEXT DEFAULT 'new' `` | `ERROR 1101` — no DEFAULT on TEXT |
  | an index over a `String` column | `` CREATE INDEX … (`status`) `` | `ERROR 1170` — no key length |

  All three are **hard failures of table creation**, so a MySQL schema using any
  of them could not be built at all. `VARCHAR(255)` is indexable, `UNIQUE`-able
  and defaultable, and 255 is the length ent uses. A key-length prefix
  (`email(255)`) was deliberately **not** used to keep TEXT: for `UNIQUE` it
  would silently constrain only the first 255 characters, so two distinct values
  sharing a 255-character prefix would collide and the constraint would no longer
  mean what the schema says.

  This mirrors the existing MySQL special cases for `.uuid` (`CHAR(36)`, for the
  same errno 1170) and `.decimal` (`DECIMAL(38,10)`); the project had already hit
  this class of problem on UUID primary keys and fixed only that case.

  `field.Text`, `field.JSON` and `field.Other` keep `TEXT` — the restriction is
  MySQL's own and lands on a deliberately unbounded column (ent behaves the same
  way; a `Text` column still cannot be `UNIQUE`, indexed without a key length, or
  defaulted on MySQL). PostgreSQL and SQLite are **unchanged**: both still map to
  `TEXT`.

  **MySQL consumers must convert existing columns by hand.** A table created
  before this release holds `TEXT` where the schema now says `VARCHAR(255)`:
  `sql_schema.checkSchema` reports each such column as `type_mismatch`
  (`normalizeSqlType` strips the `(255)`, so it compares `text` against
  `varchar`), and `migrateSchemaWithOptions(.{ .allow_data_loss = true })` fails
  closed with `error.MySQLTypeChangeUnsafe`, because MySQL's `MODIFY COLUMN`
  replaces the whole definition and can silently strip `NOT NULL` / `DEFAULT` /
  `UNIQUE`. `migrateSchema` **without** that flag performs no type change and
  keeps working, so nothing breaks unbidden — the drift is reported, not applied.
  Convert explicitly, restating every attribute:

  ```sql
  ALTER TABLE t MODIFY col VARCHAR(255) NOT NULL DEFAULT 'new';
  ```

  **Check the length first.** `VARCHAR(255)` is 255 *characters* under
  `utf8mb4`, and `field.String` is unbounded in the API — so a value longer than
  255 characters that PostgreSQL and SQLite accept is an error on MySQL under a
  strict `sql_mode` (the default) or a silent truncation under a permissive one.
  Run `SELECT MAX(CHAR_LENGTH(col)) FROM t` before converting. A column that
  legitimately holds more than 255 characters stays `TEXT` — use `field.Text` and
  accept that MySQL will not let it be unique, prefix-free indexed, or defaulted.
  `docs/UPGRADING.md` §12 and `docs/BEST_PRACTICES.md` carry the same note.

## [0.56.1] - 2026-09-15

### Fixed
- **The new nullability test no longer pins MySQL's rendering of
  `column_default`.** CI runs MariaDB 10.11 while the development machine has
  MySQL 9.3, and the two disagree about
  `information_schema.columns.column_default` for a string default: MariaDB
  returns the literal expression text (`'kept'`), MySQL 8+ strips the quoting
  (`kept`). The test compared against the unquoted form, so it passed locally and
  failed on CI's MariaDB job — the v0.56.0 tag was published with that job red.
  The vendor's quoting convention is not what the test is about; it asserts that
  the DEFAULT survived a refused migration, so it now compares the content with
  one layer of quotes removed. Test-only: the library only `SELECT`s
  `column_default` and never parses it (`ExistingColumn` carries name, type and
  nullability), so no caller behaviour was ever affected.

## [0.56.0] - 2026-09-15

### Added
- **Arena scanning: the caller's arena owns the page** (Z27). `All()` hands back
  a `std.array_list.Managed(Entity)` that the caller must dismantle item by item
  (`deinitEntity` per row, then `deinit()`) — 607 call sites in the reporting
  consumer did exactly that by hand, and `managedEntity`/`dupeEntityTo` were used
  zero times, so the four-argument dismantling was the shape that won. The
  arena variants make freeing a single call:

  ```zig
  var arena = std.heap.ArenaAllocator.init(alloc);
  defer arena.deinit();
  const users = try client.user.Query().AllIn(&arena);
  // no per-row deinit, no list deinit — arena.deinit() is the whole release
  ```

  `AllIn` / `FirstIn` / `SaveIn` / `queryRowsIn` return a plain slice, not a
  `Managed` list: a slice has no `deinit`, which is the strongest available
  signal that there is nothing to free by hand. `All()` and `First()` were
  refactored onto the same `readAll`/`readFirst` core, so the two paths cannot
  drift.

  **Ownership rule, and it is a hard one**: a page from an `*In` call is released
  by `arena.deinit()` and by **nothing else**. Calling `deinitEntity`,
  `deinitRow`, `deinitRows` or `freeOwnedStrings` on rows an arena owns is a
  double free. One page, one release mechanism — `docs/ARCHITECTURE.md` and
  `BEST_PRACTICES.md` both carry the rule.

- **Request-level borrow budget** (Z24). `borrowWithTimeout(ms)` /
  `borrowCtx(&ctx)` / `borrowWithBudget(ms, ctx)` take the waiting time as an
  argument, and the effective budget is `min(requested, max_wait_ms)` — so a
  request deadline can no longer be shortened by a pool-configured ceiling, and
  `max_wait_ms` is a hard upper bound rather than a value that the retry/backoff
  path could walk past. A statement or transaction deadline now covers **waiting
  for a connection**, not just running on one: `driverExec`/`driverQuery` merge
  the context before borrowing, and an optional `beginTxCtx` was added to the
  driver vtable and `Driver` (drivers without the hook fall back to `beginTx`).

### Changed
- **`PoolWaitTimeout` is what a spent budget returns** (Z24). `borrow()` used to
  report `PoolExhausted` when the wait ran out and `PoolWaitTimeout` did not
  exist. The two are now distinct — `PoolExhausted` is "the pool is at capacity
  and retrying is pointless", `PoolWaitTimeout` is "time ran out, retrying may
  work" — which also puts the second one in the retryable set for
  `driver.classify`. A caller matching on `PoolExhausted` to detect a timeout
  must add the new error.

- **BREAKING for exhaustive switches: `driver.Error` gained
  `PoolWaitTimeout`.** Error sets are not extensible, so a `switch` over
  `driver.Error` with no `else` stops compiling. The one exhaustive switch in
  the tree (`migrate.zig`) was updated in the same commit.

- **The health check no longer runs under the pool mutex** (Z23). With
  `health_check_on_borrow = true` the `ping` ran while the mutex was held, which
  serialized every borrow behind a network round trip. A borrow now selects a
  candidate under the lock and pings it outside; only a failed ping takes the
  lock again, to close the connection and signal. The cost is that a candidate
  can be handed out stale, which `Selection.fresh` keeps track of so the old
  retry granularity is preserved.

### Fixed
- **JSON scanning returned a slice into the driver's column buffer.** The
  scanner used `std.json`'s default `.alloc_if_needed`, which for a string that
  needs no unescaping returns a slice of the **input** — the driver's row buffer,
  freed by `rows.deinit()`. A JSON column read into an owned string dangled, and
  the next statement to reuse that buffer overwrote it (observed as
  `expected "dark", found "ena_"`, the tail of another query's SQL text). Now
  `.alloc_always`, so the result is always owned by the caller's allocator.

- **`migrateSchema` can converge nullability, opt-in** (Z31). The gap the
  previous release documented rather than fixed: an added `NOT NULL` column
  arrived nullable and an existing column's nullability was never altered, so a
  deployment could run migrations forever and stay in the drift
  `check_nullability` warns about. `MigrateOptions.allow_nullability_change`
  (default `false`) adds the two halves:

  - an **added** column the schema declares `NOT NULL` is emitted with
    `NOT NULL DEFAULT …` — the field's own default, or the audit-timestamp one;
    a non-optional field with neither fails the migration with
    `error.NotNullNeedsDefault` rather than guessing the value that backfills
    the rows already present;
  - an **existing** column whose nullability differs is altered
    (`SET NOT NULL` / `DROP NOT NULL` on PostgreSQL).

  Dialect behaviour is not smoothed over: PostgreSQL does both; SQLite has no
  `ALTER COLUMN` at all, so only the added-column half converges and
  `check_nullability` reports the rest; **MySQL fails closed** with
  `error.MySQLNullabilityChangeUnsafe` — `MODIFY COLUMN` replaces the whole
  definition and this layer introspects neither `EXTRA` (so `AUTO_INCREMENT` and
  `ON UPDATE CURRENT_TIMESTAMP` would vanish) nor charset, collation or comment.
  Failing is the honest answer where the rewrite would be lossy; the existing
  type-change path already fails closed for the same reason. Off by default, so
  no existing deployment changes behaviour.

## [0.55.0] - 2026-09-15

### Docs
- **What `migrateSchema` deliberately does not converge** (Z31). Item 8 of the
  report, verified line by line and recorded rather than fixed. Confirmed: an
  `ALTER TABLE … ADD COLUMN` never emits `NOT NULL` (the code comment says why —
  SQLite rejects it without a default), so "add a non-null field to an old table"
  produces exactly the drift `checkNullability` then warns about; an existing
  column's nullability is never modified; `UNIQUE` and foreign keys are not added
  by `ALTER`; a **changed `view_sql` never takes effect** (`CREATE VIEW IF NOT
  EXISTS`, so the definition stays whatever it was); and index comparison is by
  name only, since `ExistingIndex` carries no columns. `BEST_PRACTICES` §5h now
  has a table of all six with the consequence and the manual remedy — "the
  migration ran" was never a guarantee that the shape matches, and nothing said
  so. The fixes themselves (an option-gated `NOT NULL` with a backfill default,
  view replacement, columns on `ExistingIndex`) change migration semantics and
  are left for a pass that can test them against real databases.

## [0.54.0] - 2026-09-15

### Changed
- **BREAKING: `CrudService.create(entity)` is now
  `create(entity, tenant_id)`** (Z30). The write loop copied *every* field from
  the caller's entity, the tenant column included, while the interceptor that
  scopes creates only fills a column it finds **missing** — so an entity whose
  tenant field held the zero value (the default of a freshly built one) beat the
  bound tenant and wrote `0`. Every other method on the service already takes
  `tenant_id`; `create` was the one that read it from data the caller may not
  have set, which contradicted the documented "enforced on every op" claim and
  made the write depend on a value nobody had to provide. The tenant column is
  excluded from the field loop and written from the argument.

  Migration: `svc.create(e)` → `svc.create(e, tenant_id)`. The entity's tenant
  field is now ignored, so a zero value there is harmless.

## [0.53.0] - 2026-09-15

### Added
- **`driver.classify` — the 503/500 question, answered once** (Z29). Three
  unrelated error sets exist in this library (`driver.Error`, `runtime.error`'s
  `DbError`/`DriverError`, and the pool's `PoolClosed`/`PoolExhausted`), and a
  service that has to decide "is this capacity, a lost race, or the caller's
  fault?" had to enumerate them itself:

  ```zig
  switch (zent.sql_driver.classify(err)) {
      .capacity => 503,   // database unavailable, pool at capacity, OOM, timeout
      .transient => retry, // deadlock, serialization failure, lock timeout, tx died
      .client => 400,      // constraint violation, bad data, not found
      .bug => 500,         // bind/prepare failure, protocol error, driver bug
  }
  ```

  `isRetryable` now covers `PoolExhausted`, `PoolClosed`, `PingFailed`, `TxFailed`
  and `OptimisticLockConflict` as well as the four it had — `PoolExhausted` is
  exactly the error a consumer needs this answer for, and it was reported as not
  retryable. It is deliberately **not** `classify(…) == .capacity or .transient`:
  `OutOfMemory` and `QueryTimeout` are capacity for a status code while retrying
  them makes things worse, and the existing test that asserts
  `!isRetryable(OutOfMemory)` is right.

- **`ConnPool.stats()`** (Z29). A snapshot under the mutex — `total`, `in_use`,
  `available`, `waiters`, `exhausted_total`, `closed` — for a metrics scrape or a
  health endpoint. The pool tracks what a dashboard wants; the shipping example
  read the internal lists *without* the mutex to print a pool size, which is a
  data race and now impossible to copy by accident.

## [0.52.0] - 2026-09-15

### Added
- **`sql_schema.checkSchema` / `assertSchema`, and the introspection behind
  them, are public** (Z28). `migrateSchema` needs to know what the database
  currently has, and it already did: `getExistingColumns` (all three dialects,
  including `is_nullable` and SQLite's PK flag) and `getExistingIndexes`. They
  were private, so consumers re-implemented the same `information_schema`
  queries in three separate audit scripts. They are exported now, and the
  comparison that was only made for NULL is a full report:

  ```zig
  const drifts = try sql_schema.checkSchema(alloc, drv.asDriver(), infos);
  // .missing_table | .missing_column | .extra_column | .type_mismatch | .nullability
  ```

  `SchemaDrift.breaksReads()` marks the kinds that make a *read* fail — a missing
  table or column (the failure mode behind an endpoint quietly returning an empty
  list for months), and a column the database makes nullable where the schema
  declares it non-optional. `assertSchema` is the gate form, with the same
  `.read_breaking_only` / `.any` split as `assertNullability`. `checkNullability`
  is now a projection of the same traversal rather than its own loop, so the two
  cannot disagree.

  Type comparison is text-based and best-effort (`normalizeSqlType`, the same
  helper the ALTER TYPE path uses), and foreign keys and primary keys are **not**
  compared — PG/MySQL introspection does not read them yet.

  One bug found while testing it, worth naming because it is the kind this
  repository keeps hitting: `extra_column` borrowed the column name from the
  introspection list, which is freed before the caller sees the result — a
  use-after-free that showed up as a garbage name. Those entries own their name
  now (`SchemaDrift.column_owned`), and `freeSchemaDrift` frees exactly those.

## [0.51.0] - 2026-09-15

### Fixed
- **`error.PoolExhausted` now means capacity, and nothing else** (Z24).
  `tryBorrowNoLock` folds every reason it cannot produce a connection into
  `null` — a refused connection, bad credentials, an OOM, a failed health check —
  and `borrow` reported the constant `PoolExhausted` for all of them. A consumer
  mapping that to 503 (as the reporting one does) therefore retried a
  configuration fault indefinitely, which is the "just moving the 500" their
  120-concurrent measurement describes.

  The pool now remembers *why* the last attempt produced nothing and returns
  that: `ConnectionFailed`, `PingFailed`, `OutOfMemory`, `DriverFailed` and
  `PoolClosed` stay distinguishable, everything else folds back into
  `PoolExhausted` so `borrow`'s error set stays bounded
  (`asDriver()`'s explicit sets depend on it). `Metrics.onError` receives the
  real error instead of a constant, and the give-up path logs a `warn` — the
  pool had **no** log statement at all before this.

  Not included: a request-level borrow budget (`borrowWithTimeout`/`borrowCtx`)
  and threading a context through `VTable.beginTx`. Those change the driver
  interface and the pool's waiting logic, so they are the next slice rather than
  a ride-along.

## [0.50.0] - 2026-09-15

### Fixed
- **`Has{Edge}()`, `NotHas{Edge}()` and `Has{Edge}With(…)` are satisfied
  correctly again — a soft-deleted neighbor no longer counts** (Z25). They are
  `EXISTS` subqueries over the target table, and they ignored its soft-delete
  scope, so a trashed row satisfied an existence filter. That is the same leak
  the eager-loading path closed in v0.35, in the one place that went around it;
  ent scopes `Has*` the same way this now does. The M2M branch qualifies the
  column (`t."deleted_at"`), since its subquery joins the junction table.

  The reason it was only half-fixed at first is worth recording: the `EXISTS`
  body existed **twice** — once in `graph_neighbors.appendHasNeighborsWith` and
  once inline in `sql/builder.zig`'s `.has_neighbors_with` prong — and the
  predicate used the inline copy, so a change to the graph helper had no effect
  on it. The prong now delegates, so there is one implementation. Threading that
  call back through `Predicate.appendTo` also surfaced an inference cycle, which
  is why `appendTo` (and the two helpers) now declare `anyerror` explicitly
  rather than inferring it: `.exists_fn` carries a caller-supplied generator, so
  the set was never this module's to know.

### Docs
- **Which predicates carry a scope, and which cannot.** A bare predicate has no
  runtime context, so `Has{Edge}()`/`NotHas{Edge}()`/`Has{Edge}With(…)` apply the
  target's soft-delete scope but **not** its privacy filters or the interceptor
  chain — a tenant-scoped existence check passes its tenant predicate through
  `Has{Edge}With(…)` explicitly. Likewise `sql.InSelect`,
  `sql.InSubquery`/`ExistsSubquery` render exactly what they are given: the `sql`
  layer has no graph, so the inner table's scope is the caller's to add.
  `BEST_PRACTICES` §3a states both.

## [0.49.0] - 2026-09-15

### Fixed
- **A lost PostgreSQL connection is discarded instead of returned to the pool**
  (Z23). `ConnPool` evicts a released connection whose type has a `dead` field —
  that is how the MySQL driver has always worked — but `PostgresDriver` had no
  such field, so a connection lost to a server restart, a `pg_terminate_backend`
  or an idle-timeout kill went straight back into `available` and kept failing
  for whoever borrowed it next, one request at a time.

  `PostgresDriver` now carries `dead`, marked from `PQstatus` (libpq learns the
  socket is gone when an I/O attempt fails, so the failing call marks it and the
  next borrower fails fast), and every operation checks it before touching the
  connection. Proven against a real server: the test terminates its own backend
  and asserts the flag, then that `exec`/`query`/`beginTx` all fail with
  `ConnectionFailed` without another round trip. Falsified by making `noteError`
  a no-op, which fails that assertion.

### Changed
- **A failed statement is logged at `warn`, not `err`, in all three drivers.**
  The caller receives the error and decides what it means (a constraint
  violation is an expected 4xx, a deadlock is retryable); logging it at error
  level double-reports it into whatever alerts on that, and — concretely — made
  any failure path untestable, because Zig's test runner treats a logged error
  as a test failure. `connect` failures have been `warn` for exactly this reason
  since the beginning; this brings the per-statement path in line. Connection
  setup failures (`sqlite3_open`, `mysql_options`) stay at `err`: those are
  configuration faults, not outcomes.

## [0.48.0] - 2026-09-15

### Fixed
- **A raw predicate containing `OR` could escape an injected scope predicate**
  (Z25). `Where`/`Where-lists` are joined with a bare `" AND "`, so
  `Where(.{sql.Raw("a = 1 OR b = 2")})` plus an interceptor-injected
  `AND app_id = ?` rendered `WHERE a = 1 OR b = 2 AND app_id = ?` — the `AND`
  binds to the second operand, and every row satisfying `a = 1` came back
  whatever its tenant. `.raw` and `.raw_args` are now rendered inside
  parentheses, so a fragment is always one operand. Proven with rows: a test
  seeds a foreign tenant's row that satisfies the `OR`, and removing the
  parentheses makes it fail with `expected 1, found 2`. Two pinned SQL-text
  expectations changed accordingly (one gains the necessary pair, one gains a
  redundant pair around a fragment that already had its own).

### Added
- **`sql_schema.assertNullability` — the drift check as a gate** (Z26). The
  automatic report inside `migrateSchema` cannot reach a consumer whose DDL is a
  set of `.sql` files and never calls `migrateSchema` — which is exactly the
  consumer that reported needing it, with 70 drifted columns in hand. It now has
  a callable form that fails rather than logs:

  ```zig
  try zent.sql_schema.assertNullability(alloc, drv.asDriver(), infos, .read_breaking_only);
  ```

  `.read_breaking_only` refuses only the direction that breaks reads (database
  allows NULL, schema does not); `.any` refuses every difference, and a benign
  disagreement (schema optional, column NOT NULL) is what tells the two apart —
  pinned by a test, since a gate that blocks a deploy needs its boundary stated.

## [0.47.0] - 2026-09-14

### Added
- **`scope.Options.arg_index` and `.marker`, and `sql.Builder.arg_base`**
  (Z22/T1). A `zent.scope` fragment rendered its placeholders from `$1`
  regardless of the statement it was spliced into. On PostgreSQL that is not a
  syntax error but a **wrong query**: a head binding `$1` plus a fragment
  binding `$1` makes both predicates share one parameter, so the tenant value is
  bound to whatever the head's first argument was — and the caller sees another
  tenant's rows with no error at all. `arg_index` (default `1`, i.e. today's
  behaviour) says where the fragment's numbering starts:
  `head_arg_count + 1` for a head that binds anything. `.marker = .question`
  renders `?` placeholders regardless of dialect, for a caller that renumbers
  the statement itself. `0` is `error.InvalidArgIndex` rather than a silent
  underflow. `sql.Builder.arg_base` defaults to 0, so every existing output is
  byte-identical. Covered by a PostgreSQL integration test that asserts the
  *rows* (two tenants sharing an `amount`), and by unit tests for the shift, the
  marker and the `?`-dialect no-op; falsified by dropping `arg_index`, which
  renders `$1`.

### Fixed
- **`field.Nillable()` now means what it says** (Z21/T2). It set only
  `f.nillable`, while ten places decide nullability and several looked at
  `f.optional` alone — so `field.Int("x").Nillable()` produced a **nullable
  column with a non-optional Zig field**: a NULL failed to scan with
  `error.TypeMismatch`, and `setFieldValue("x", null)` did not compile. The
  library's own guidance (`BEST_PRACTICES`, and the scan diagnostic added in
  v0.46.0) recommends `Optional()/Nillable()`, which made this a trap rather
  than a corner. `Nillable()` now sets both flags, matching ent, which fixes all
  ten sites at once and cannot make an existing column NOT NULL
  (`not_null = !optional and !nillable` is unchanged). It had **zero** call
  sites in the repository, so nothing could break; the new nullability-matrix
  test is now its first user.

### Docs
- The `zent.scope` example showed a `$N` fragment appended to a `?` head, which
  cannot work on PostgreSQL — the driver passes SQL through to `PQprepare`
  untranslated. Both examples (module doc and `BEST_PRACTICES` §5) now use the
  dialect's placeholders and state the two contracts the API relies on: the
  caller's arguments come first and `scope.args` after them, and the head's own
  numbering is the caller's to get right.

## [0.46.0] - 2026-09-14

### Added
- **`sql_schema.checkNullability`: the schema and the database, compared on
  NULL.** `migrateSchema` adds what is missing but never touches an existing
  column's nullability, so a database that predates the schema (a ported app,
  hand-managed DDL) can disagree silently — until a read hits a NULL and fails
  with `error.TypeMismatch`. The check returns every differing column, with
  `NullabilityDrift.breaksReads()` marking the direction that hurts (database
  allows NULL, schema declares a non-optional field). `migrateSchema` runs it at
  the end — the moment the two are known to meet — as **one** summary line at
  `warn` with per-column detail at `debug`, because a legacy database can
  disagree about hundreds of columns. `MigrateOptions.check_nullability`
  (default `true`) disables it. The introspection already read `not_null` for
  all three dialects; it had simply never been compared.

### Changed
- **A bare `null` literal is accepted for optional fields.**
  `setFieldValue("body", null)` now works; `@as(?[]const u8, null)` still does.
  It was a compile error — *"expected ?[]const u8, got @TypeOf(null)"* — which
  reads as "null is not supported" and is what a consumer reported as
  "`Optional` does not resolve NULL". A bare `null` for a **non-optional** field
  stays a compile error.

### Fixed
- **A scan failure now names the table and the column.** `error.TypeMismatch`
  carried no context at all, in a library whose central hazard is exactly this
  (the database allowing NULL where the schema does not). The diagnosis runs
  **only on the failure path** — a successful read pays nothing — and says which
  column is NULL against a non-optional field, or reports that no NULL was found
  so the value itself does not fit. Logged at `warn`, not `err`: the error is
  already returned to the caller, and Zig's test runner treats a logged error as
  a test failure, which would make the diagnostic untestable.

## [0.45.0] - 2026-09-12

### Fixed
- **An edge-only update works, and an empty update says why (Z19).** With no
  `setFieldValue` and only an edge write registered, `Save()` emitted
  `UPDATE t WHERE …` — no `SET` clause — and the database rejected it with a
  prepare error that named nothing (`near "WHERE": syntax error`). Every
  existing edge-write test worked around it by pairing the edge call with an
  unrelated `setFieldValue`, so the habit was everywhere and the reason nowhere.

  Now:
  - no `SET` field **with** edge actions → the statement touches the matched
    rows with a primary-key self-assignment. One statement, hooks still fire,
    and `rows_affected` keeps meaning "rows the predicate matched" — the reading
    every edge-write test already assumes. (MySQL still reports *changed* rows,
    the documented caveat for any no-op update.)
  - no `SET` field **and** no edge action → `error.NoFieldsToUpdate`, naming the
    cause instead of quoting the database.

  The check runs after `fillAuditUser` and the `updated_at`/version maintenance,
  so an entity that contributes a column there is not mistaken for empty.
  Falsified by dropping the self-assignment, which restores the original syntax
  error in the test.

## [0.44.0] - 2026-09-12

### Added
- **Edge writes work on `From` edges (Z15).** `SetEdgeIDs` and `ClearEdge`
  rejected every edge whose FK lives on the row being updated, so the same
  intent needed a different spelling depending on which side of the relation
  owned the column (`setFieldValue("owner_id", …)`). They now accept `From`
  m2o/o2o edges, and the write goes into the UPDATE's **own** `SET` clause
  rather than becoming a second statement against the target table: one
  statement, one predicate, one transaction, and the interceptor/privacy scope
  covers it like any other column. `error.TooManyEdgeTargets` (returned by the
  call, not by `Save`) rejects more than one id, since a `From` edge points at a
  single row; clearing needs a nullable FK, which `ClearEdge` rejects at
  compile time and `SetEdgeIDs(…, &.{})` at runtime
  (`error.EdgeNotDetachable`). Covered on SQLite, PostgreSQL and MySQL in the
  existing edge-write tests, including re-point, clear and rejection —
  falsified by making the branch a no-op. `AddEdgeIDs`/`RemoveEdgeIDs` stay
  M2M-only, and their compile errors now point at `SetEdgeIDs` for
  single-target edges.

## [0.43.0] - 2026-09-12

### Fixed
- **`setFieldValue`'s accepted set is decided in one place (Z18).** The contract
  lived in three — `canSetField` (the check), `toSqlValue` (the conversion) and
  a doc table — and the first two existed twice, once in `create.zig` and once
  in `update_delete.zig`, where they had drifted apart in both implementation
  and accepted set. All of it is now `src/codegen/field_value.zig`:
  `accepts(Expected, Actual)` decides, `toSqlValue` converts, and the module's
  tests check both directions — including the shapes that must be **rejected**,
  which no doc table can do.

  With one place to fix, the broken shape is gone rather than documented: a
  `[N]u8` **array value** is no longer accepted. Converting one would have to
  return a pointer into the callee's own by-value parameter, so it could never
  have worked; it previously passed the type check and then failed inside
  `toSqlValue` with a message naming neither the field nor the function. Now it
  fails at the check ("expected `[]const u8`, got `[4]u8`"), and `toSqlValue`
  carries an explicit branch telling the caller to pass a slice or a literal.

## [0.42.0] - 2026-09-12

### Changed
- **The `anytype` contract is now written down and tested, starting with the
  two most-used parameters.** `Where(predicates)` existed as five copies of the
  same `switch`, and the copies had already drifted from the contract they were
  supposed to enforce: the `@compileError` listed four accepted shapes and
  omitted every pointer form, and the doc comments said nothing at all. All
  four builders now delegate to one `sql.appendPredicates`, whose doc carries
  the shape table and whose test exercises all seven shapes on every builder —
  including the pointer forms, which had no coverage anywhere. A pointer *to* a
  slice is documented as **not** a shape: `for` over the pointer is not
  indexable, so it never compiled, and saying so is better than implying it.

- **`setFieldValue`'s accepted values are documented** (the table is on the
  builder methods) and pinned by a test that exercises every row. Writing it
  exposed two smaller things: no test in `zig build test` had ever set a
  **float** field (only an example compiled one), and **`std.json.Value` was
  accepted by the create path but not by update/bulk** — an accident of the
  copy, now consistent.

### Fixed
- **Removed an unreachable `Enum` tag validation.** It compared the runtime
  `value` inside a `comptime` block, so it could never fire; reaching it turned
  a `[N]u8` argument into `unable to resolve comptime value` instead of a useful
  error. The docs now state that the tag text is passed through unvalidated
  (recorded with the remaining `canSetField`/`toSqlValue` disagreement as Z18).

## [0.41.1] - 2026-09-12

### Fixed
- **`crud_helpers.deinitRows` accepts a pointer again (compile-blocking
  regression in v0.40.0).** Z17 turned the wrapper's body into
  `var list = rows; deinitEntityList(…, &list)`, which only type-checks when
  `rows` is a value. Every caller passing `&rows` — the shape a consumer layer
  forwards — stopped compiling:

      src/crud_helpers.zig:864:46: error: expected type 'T', found '*T'

  `rows: anytype` always accepted both shapes, so narrowing it to one was a
  silent breaking change; the release note claiming it "keeps its by-value
  signature" was wrong. The wrapper now normalises at comptime: a mutable
  pointer is handed through (so the caller's list comes back empty and
  reusable), a value or a `*const` is freed through a mutable copy. The
  regression test covers all three shapes, and reverting the fix reproduces
  the consumer's error verbatim.

## [0.41.0] - 2026-09-12

### Docs
- **Which raw paths are scoped, and which are not.** `crud_helpers.queryRows`
  is a mapper over `driver.query` and runs your statement as written — the same
  bypass class as the raw path `zent.scope` was added for, one layer up in the
  library's own convenience API. Its doc now says so and shows the composition,
  `BEST_PRACTICES` §5 gained a table of every raw path with what each needs,
  and an integration test performs the composition end to end (unscoped
  statement → 3 tenants' rows, scoped → 1) so the claim is checkable rather
  than asserted. Two paths were audited and found already safe: `PreparedCache`
  keys on the final SQL text with a byte comparison (per-tenant statements can
  never be shared), and `explainSql` only wraps a statement in `EXPLAIN` —
  `Format` has no `ANALYZE`, so it never executes one.

## [0.40.0] - 2026-09-12

### Added
- **One-call entity release: `deinitRows` / `deinitRow` / `deinitEdgeRows`.**
  Freeing a page took `deinitEntity(infos, info, &e, alloc)` per item plus
  `list.deinit()`; the ergonomic helper that existed (`managedEntity`) was never
  reachable from a query, so consumers kept writing the long form — 607
  hand-written calls against zero uses of the helper in the reporting
  codebase (Z17). Now:

  ```zig
  var rows = try q.All();
  defer q.deinitRows(&rows);              // page + list, one line
  defer client.user.deinitRows(&rows);    // same, when the builder is gone
  defer client.user.deinitRow(&e);        // a single First()/Save() result
  defer client.user.deinitEdgeRows("cars", &rows);  // a QueryEdge page
  ```

  All four delegate to one implementation
  (`codegen.entity.deinitEntityList`), which the pre-existing
  `crud_helpers.deinitRows(infos, info, rows, alloc)` now also uses. The list
  is left empty and reusable, so a second call is a no-op instead of a
  double-free. `deinitEdgeRows` exists because a `QueryEdge` page holds the
  *target* entity: it resolves that target's `TypeInfo` from the edge name, so
  the caller does not have to hold it.

## [0.39.2] - 2026-09-12

### Fixed
- **Duplicate version heading in the previous CHANGELOG.** v0.39.1 declared
  `## [0.39.1]` twice — an empty one (the promoted `[Unreleased]`) above the
  real one — because the release section had been hand-written before
  `release.sh` ran, and the script promotes `[Unreleased]` itself. Merged, and
  `check-version.sh` now fails on a version declared twice or when the first
  CHANGELOG section is not the package version, so the mistake cannot ship
  again. `docs/RELEASING.md` states the rule. No code changed in this release.

## [0.39.1] - 2026-09-12

### Fixed
- **Dead-code gate is clean again.** Routing the 16 edge-target lookups in
  v0.39.0 through `graph.edgeTargetInfo` orphaned four private `findTypeInfo`
  copies, which the CI dead-code gate flagged as new dead declarations —
  v0.39.0's tag therefore points at a commit whose CI is red. They are
  deleted in this release; the library behaves identically (nothing called
  them). Cut as a patch rather than moving the published tag.

## [0.39.0] - 2026-09-12

### Added
- **`zent.scope`: the read contract for raw SQL.** Raw statements bypassed
  privacy and the interceptor chain entirely, because an injected predicate
  needs a builder-provided `QueryView` sink and there was no way to ask "what
  may this table show?" from outside one — so tenant scoping was silently
  skipped on every hand-written query. `zent.scope.forClient(infos, table,
  &client.entity, opts)` renders the *same* contract the fluent path uses
  (`appendTargetScopePreds`: soft-delete → privacy → interceptors) into a
  fragment, and `withClause` / `writeClause` splice it into a statement you
  wrote by hand. `table` is comptime, so a typo is a compile error rather than
  an unscoped query; `.alias` qualifies every injected predicate so a JOIN
  cannot make it ambiguous; a policy-bearing table without a `privacy_ctx`
  returns `error.PrivacyDenied` instead of an unscoped fragment. Covered by an
  end-to-end test that contrasts the unscoped statement (3 rows) with the
  scoped one (1 row, and only the calling tenant's).

- **`queryAllLenient` / `queryOneLenient`.** The v0.38 lenient scanners were
  only reachable at the component layer; `queryAll`/`queryOne` called
  `scanRowNamed` (strict), so callers needing the absent-value contract fell
  back to hand-rolled `rows.next()` loops.

- **`<col>Like`, the honest name for `<col>Contains`.** Same predicate, same
  rendering; `Contains` did not wrap the value and did not say so. `Contains`
  stays as an alias, so nothing breaks.

- **`zent.version`,** mirroring `build.zig.zon`. A consumer that pinned a
  dependency by tag was verifying its checkout's HEAD against the tag commit,
  which raises a false alarm as soon as a docs commit follows the release.
  Comparing `zent.version` decouples the check from git; `check-version.sh`
  gates the mirror and the bump/release scripts update both.

- **The qualification of injected predicates moved into one helper**
  (`sql.appendQualifiedPred`), shared by the eager loader and `zent.scope`.
  Two behaviours changed with it: soft-delete predicates are now qualified
  too (a source and target that are both soft-deletable own `deleted_at` on
  each side of an m2o join, so a bare one was ambiguous in exactly the way the
  tenant column was), and the helper is the only place that knows how to
  rewrite a predicate's column.

### Fixed
- **Out-of-bounds read in positional scanning.** `scanRow*` indexed the row
  by field order with no `columnCount()` check, and the drivers do not all
  bounds-check — MySQL reads its `null_indicators` array by index and libpq
  indexes a null array, so a DTO with more fields than the result set read
  past the end of the row. Both families now fail with
  `error.ColumnCountMismatch`; trailing extra columns stay legal (`target.*`
  projections append a computed `__fk`). Reverting the guard makes the new
  test die with `index out of bounds: index 2, len 2`.

- **Invalid free of a string default.** The lenient scanners wrote a declared
  default (a comptime literal such as `"0.00"`) straight into the field, and
  `freeDto` frees every string field — so a caller's cleanup freed a literal.
  String defaults now come back owned, and `freeDto` length-guards so a
  default that never allocated is harmless. Reverting the copy aborts the new
  test inside the testing allocator's invalid-free detection.

- **Lenient scanning aborted on a value that did not fit.** A column the
  field cannot hold (DECIMAL text into an int — the common case in a
  PHP-style port) returned `error.TypeMismatch` instead of falling back to the
  default. Lenient mode now treats it like NULL, while the structural check
  above and the strict scanners are unchanged: a wrong projection still fails,
  only an absent value is tolerated. The trade-off is documented — lenient can
  mask a wrong column mapping by design.

- **A cross-graph edge now says what is wrong.** `TypeInfo not found: Payment`
  became: *"edge 'payment' on 'Order' targets 'Payment', which is not in this
  graph. Edges resolve only within a single graph (§8a): add the target schema
  to the graph you pass to buildGraph, or read it through the raw driver with
  zent.scope."* All 16 edge-target resolutions go through
  `graph.edgeTargetInfo`. The limitation itself is unchanged (Z16): it is now
  visible at the call site instead of inferred from a bare type name.

## [0.38.0] - 2026-09-12

### Changed
- **BREAKING: `queryTargets` / `queryTargetsByValue` are now fail-closed, like
  `WithEdge`.** The two bulk neighbour readers disagreed on tenant isolation:
  `WithEdge` scoped eager-loaded targets (soft-delete → privacy →
  interceptors), while `queryTargets`/`queryTargetsByValue`/`QueryEdge` applied
  soft-delete only and documented the gap as a "known boundary". The target
  read contract now lives in one place
  (`codegen.query.appendTargetScopePreds`) and both readers call it, so the
  posture cannot drift again. `EntityClient.QueryEdge` forwards the client's
  `privacy_ctx`/`interceptors` and keeps its signature; the two free functions
  gained the arguments, and the previous soft-delete-only behaviour is
  preserved under the explicit names
  `queryTargetsUnscoped`/`queryTargetsByValueUnscoped`. A policy-bearing target
  now returns `error.PrivacyDenied` from a context-less traversal instead of
  silently skipping the policy. Migration steps in `UPGRADING.md` §11.

### Added
- **NULL-tolerant row scanning.** Every scanner was strict: a NULL in a
  non-optional field is `error.TypeMismatch`, which is the right default for
  entity reads (a NULL in a non-nullable schema column means the row does not
  match the schema). It is the wrong contract for ad-hoc queries and DTOs —
  `LEFT JOIN`ed lookups, aggregate outputs, tables where an absent value is
  ordinary — and callers were hand-rolling scanners to get the other
  behaviour. `scanRowLenient[WithArena]`, `scanRowNamedLenient[WithArena]`,
  `scanRowNamedLenientMapped[WithArena]` add the second contract: a NULL (or
  an absent column, for the named variants) leaves the field at its default —
  the declared Zig default when the field has one, else zero, `null` for
  optionals, `.null` for `std.json.Value`. The strict scanners are untouched;
  the named scanners now share one implementation with their lenient twins.

- **Regression coverage for the JOIN-shaped eager loads.** The qualification
  fix above shipped with only an `o2m` regression test, whose neighbour query
  joins nothing — so it could not have caught the bug. The same scenario is
  now covered for `m2o` (joins the source) and `m2m` (joins the junction) with
  the tenant column on both sides, on SQLite, PostgreSQL and MySQL. Reverting
  the qualification makes all three fail with the dialect's own ambiguity
  error, which pins the fix end to end.

### Fixed
- **Eager-loaded targets: interceptor predicates are now qualified with the
  target table.** v0.35 started running the interceptor chain on eager-loaded
  targets (a security fix — otherwise cross-tenant rows leak through edges).
  The injected `whereEq("app_id", …)` was rendered as a bare column, so any
  `m2o`/`m2m` neighbour query — which `INNER JOIN`s the source (or junction)
  table — failed to prepare with "Column 'app_id' in where clause is
  ambiguous" whenever both sides owned the column. `appendSetNeighborsFiltered`
  now emits `target.col` for the EQ predicates the interceptor emits, which is
  also what the predicate intends: scope the loaded target rows. Predicates
  that already carry a qualifier are untouched. Regression test added
  (`appendSetNeighborsFiltered qualifies interceptor EQ with the target table`).

- **Interceptor `whereEq` is idempotent, and never suppresses a differing
  value.** The interceptor sinks appended unconditionally, so a query that
  already constrained the tenant column emitted `AND app_id = ? AND app_id = ?`
  — redundant parameters and, more importantly, a sign that injection ignored
  what the query already said. Injection now skips only when the **(column,
  value) pair** is already present. Deduping on the column alone would have
  been worse than the bug: a caller-supplied predicate for the tenant column
  would then suppress the interceptor's value, turning "add a predicate" into a
  way to escape tenant scoping. Covered by a unit test that asserts the
  identical pair collapses while a differing value is kept. Applies to the
  query, update and delete builders, and (as of this release) to the bulk
  update/delete builders too — the bulk delete sink dedupes per ORed group,
  so the injected scope still lands in every branch.

- **Interceptor `whereEq` sink audit.** All eight sinks now go through the
  same `appendEqUnlessPresent` helper. The two create-path sinks
  (`CreateBuilder`/`BulkInsertBuilder`) are deliberately *not* dedupe sites:
  they fill omitted columns rather than adding predicates, and they keep the
  existing "an explicitly set field wins" rule, which is the documented
  contract of `fillAuditUser` too. That makes create-time injection a default
  filler, **not** an enforcement point — see the note in `BEST_PRACTICES`
  §5d. Enforcement on writes belongs in a privacy policy (`Deny`), which the
  caller cannot override.

- **`stmt_prepare` failures log the statement.** The MySQL driver reported
  only `errno`/message on a failed prepare, leaving the offending SQL
  invisible (the query never reaches the success-path query log). It now also
  emits the statement at `debug` level.

### Docs
- Corrected the `Contains` row in the predicate catalogue (`BEST_PRACTICES`
  §3a): it binds the value verbatim (`col LIKE ?`) and does **not** add `%`,
  unlike `ContainsEscaped`, `HasPrefix`, `HasSuffix` and `ContainsFold`. The
  old wording described `ContainsEscaped` and would have led callers to write
  an exact match where they meant a substring search. A test now pins both
  renderings, and `ISSUES_FROM_ZAPI.md` records the naming question (Z14).
- Recorded two deliberately deferred design items in `ISSUES_FROM_ZAPI.md`
  rather than leaving them in a chat thread: **Z15** (edge writes are
  unavailable on `From` edges — same intent, different spelling per side) and
  **Z16** (multi-graph is a documented discipline, not a first-class type, so
  a cross-graph `WithEdge` fails at runtime). Both carry evidence, impact and
  an acceptance criterion for whoever picks them up.

## [0.37.0] - 2026-09-12

### Added
- **Blocking, timeout-bounded connection waits.** `Options.max_wait_ms` is no
  longer dead configuration: when it is non-zero and no connection can be
  handed out or opened, `borrow` waits on the pool condition variable (woken
  by `release`) instead of sleeping between retries, and gives up with
  `error.PoolExhausted` once the budget — measured from the start of the call
  — is spent. After the wait is exhausted the call still falls back to the
  existing `max_retries` + `retry_backoff_ms` path, so `max_wait_ms = 0` (the
  default) keeps the previous non-blocking semantics exactly. Waiting is
  **best-effort fair, not strict FIFO**: each waiter holds a ticket and defers
  to an older ticket that is still waiting, but a descheduled, timed-out, or
  unticketed waiter never blocks another borrower indefinitely.
  `Metrics.onWait` now fires (at most once per `borrow`, outside the mutex) and
  `Metrics.onBorrow` reports the real wait time. `reapIdleConnections` and
  `pingIdleConnections` also wake waiters when they drop connections, since
  that frees room below `max_connections`.

### Changed
- **`ConnPool.deinit`'s caller contract now names blocked borrowers.** The
  caller must ensure no other thread is inside `borrow`/`release`/`asDriver`
  when `deinit` runs — explicitly including a thread blocked waiting for a
  connection. A woken waiter observes `closed` and returns
  `error.PoolClosed`, but that requires the pool mutex and the owned `Io` to
  still be alive, and `deinit` destroys both immediately after releasing the
  mutex; using `deinit` to interrupt blocked borrowers is undefined behavior.

### Fixed
- **Nested eager loading issues one query per level instead of one per
  parent.** `WithEdge("posts.comments")` recursed once per parent entity, so
  the second level cost N queries (N+1). Every level-1 target now goes into a
  single pointer list and the next level runs as one query. The parents are
  addressed by pointer, not copied, because the loaded slices are written back
  into those very elements. Measured, not assumed: a driver decorator counts
  statements, and a three-owner two-level load asserts exactly 3 queries —
  restoring the per-parent recursion makes it 5.

### Docs
- `BEST_PRACTICES` §5f (connection pool: `max_wait_ms`, health-check and
  callback locking, the quiescence `deinit` requires) and §5g (eager loading:
  one query per level, parent chunking, the target read contract, and that
  `queryTargets` is soft-delete-only and not tenant-scoped). `ARCHITECTURE`
  now states the interceptor-chain ownership rule and the parked-borrower
  requirement, and `UPGRADING` §10 lists the concrete steps for adopting
  v0.36 (outbox `claimed_at` migration, `createAllTables` allocator argument,
  migrations locking by default, `max_wait_ms` meaning).
## [0.36.0] - 2026-09-11

### Added
- **BulkInsert chunks rows around the bound-parameter limit.** `BulkInsert.Save`
  emitted a single multi-row INSERT, so a batch large enough to exceed the
  driver's parameter budget (SQLite's `SQLITE_MAX_VARIABLE_NUMBER` is 999 on
  builds older than 3.32) failed outright. Rows are now inserted in chunks
  sized from the dialect limit, and each chunk's ids are accumulated so the
  caller still receives one id per row. `chunkRows(n)` overrides the derived
  budget when a caller wants to bound statement size (e.g. MySQL
  `max_allowed_packet`) or to pin chunk boundaries.
- **`queryTargetsByValue` for UUID/textual primary keys.** `QueryEdge`'s
  traversal helper only accepted `[]const i64` parents, so entities keyed by
  a `field.UUID("id")` string PK could not traverse edges at all. The new
  `codegen.client.queryTargetsByValue(infos, source, edge, parent_ids:
  []const sql.Value, …)` takes any PK type (`.int` or `.string`), and
  `queryTargets` keeps its signature as an integer-only wrapper that
  delegates to it. Same semantics — empty-list short-circuit, dialect
  placeholders, target soft-delete scope, caller-owned result.
- **`StorageKey`: map a Zig field onto a differently-named SQL column.**
  `field.String("userName").StorageKey("user_name")` decouples the field name
  used by the fluent API (`setFieldValue("userName", …)`, typed predicates,
  `Select`/`OrderBy`/`GroupBy`, interceptor `whereEq`) from the physical
  column emitted in DDL, `INSERT`/`UPDATE`/`SET`, `WHERE`/`ORDER BY`/
  `GROUP BY`, indexes, and cursor pagination — the mapping needed to adopt
  zent on an existing schema. `FieldInfo` now carries `column_name` alongside
  `name`, and `codegen.graph.columnName(info, field)` resolves a field name
  to its column. Schemas that never call `StorageKey` are unchanged
  (column name == field name).
- **Outbox stale-claim recovery.** The claim-based dispatcher added in 0.35.0
  could strand a row in `processing` forever if a dispatcher died after
  claiming it. `OutboxMessage` now has a nullable `claimed_at` column (epoch
  ms) that `claim` writes in the same statement that flips the row to
  `processing`, and the new `OutboxOps.requeueStale(allocator, client,
  older_than_secs)` returns `processing` rows whose claim is older than the
  threshold — a NULL `claimed_at` counts as stale, and `older_than_secs <= 0`
  reclaims every `processing` row — to `pending` with `claimed_at` cleared.
  `markPublished` / `markFailed` / `requeue` also clear `claimed_at`. Call
  `requeueStale` from a periodic sweeper (a threshold several times the
  longest publish). **This adds a column, so existing deployments need one
  schema migration** (`migrateSchema` adds it automatically; downgrades must
  drop it manually).
- **Migration locking and checksum verification.** `MigrateOptions.lock_timeout_ms`
  (default 10 s, `0` disables) takes an advisory lock for the whole migration:
  `pg_advisory_lock` on PostgreSQL and `GET_LOCK`/`RELEASE_LOCK` on MySQL, so
  several instances starting at once no longer race on the existence/absence
  checks. A lock that cannot be taken and a timeout both surface as
  `error.MigrationLockTimeout`; if the lock statement is unsupported or
  denied, the migration warns and continues rather than failing. SQLite relies
  on its single-writer transaction instead. Already-applied file migrations
  now have their recorded checksum compared against the file on disk
  (`error.MigrationChecksumMismatch`), so an edited migration is caught
  instead of silently skipped. The history table's `checksum` column may be
  NULL (schema-diff migrations and rows predating verification), which is
  treated as "not recorded" rather than a mismatch.
- **MySQL TLS material (CA, client certificate/key, cipher).** The MySQL
  driver previously called `mysql_ssl_set` with every argument NULL, so
  `verify_ca` enabled certificate verification with no CA to verify against
  and mutual TLS was impossible. `MySQLDriver.SslConfig` (`mode` plus `ca`,
  `capath`, `cert`, `key`, `cipher` PEM paths) is now threaded through the new
  `connectOptsSsl` / `connectOptsSslSocket` entry points; the existing
  `connect` / `connectOpts` / `connectOptsSocket` keep their signatures and
  delegate with `SslConfig{ .mode = ... }`. `verify_ca` only verifies when a
  `ca` (or `capath`) is supplied, and `REQUIRE X509` needs both `cert` and
  `key`. Integration coverage (skipped unless `MYSQL_SSL_CA` is set, with
  `MYSQL_SSL_CERT` / `MYSQL_SSL_KEY` for mTLS) asserts an actual TLS session
  via `Ssl_cipher`, that a wrong CA is rejected, and that a client
  certificate satisfies `REQUIRE X509` while its absence does not.

### Fixed
- **A UUID primary key is no longer rewritten to an integer.** `TableDef`
  marked *every* id column as auto-increment, so PostgreSQL replaced the
  declared type with `SERIAL` — a `field.UUID("id")` primary key silently came
  out as `integer` — and MySQL appended `AUTO_INCREMENT` to a `TEXT` column,
  failing `CREATE TABLE` with errno 1170. Auto-increment now applies only to
  integer ids, and MySQL maps `uuid` to `CHAR(36)` instead of `TEXT`, which
  cannot be indexed without a key length. Covered by a per-dialect test that
  runs the library's own `createAllTables` (asserting the emitted column type
  on PostgreSQL and MySQL) and round-trips a UUID-keyed row.
- **Interceptor chains survive a `Client` move.** `Client` held its interceptor
  chain **by value** while every entity sub-client stored a pointer into that
  field, so any move of the `Client` value — `makeClient`'s return, the
  helpers storing it, `withContext`, a tx client — left those pointers
  dangling and the next query touched freed memory. The chain is now lazily
  heap-allocated on first `UseInterceptor`, so a move relocates a pointer, not
  the chain. `Client.owns_interceptors` distinguishes an owned chain from one
  borrowed via `withInterceptors`, and `DeinitClient` frees only the former;
  call it once, on the value that registered. `StoreEnv`/`PooledEnv`/
  `ShardedEnv` deinit the client they created, which previously leaked any
  registered chain.
- **Global hook registry can be released.** `registerGlobal` took a
  caller-owned pointer with no way to unregister, so a chain that went out of
  scope left the registry dangling into freed memory. `unregisterGlobal(chain)`
  clears it only when that chain is the registered one.

## [0.35.0] - 2026-09-11

### Added
- **Typed predicates for IN / NULL / prefix / suffix / case-insensitive.**
  Every field gains `In`, `NotIn`, `IsNull`, `NotNil`; `string`/`text` fields
  gain `HasPrefix`, `HasSuffix`, `ContainsFold`, `EQFold`; every edge gains
  `NotHas<Edge>`. The LIKE variants reuse the escaped-literal renderer, so
  user input stays literal (wildcards escaped) with no injection surface and
  no pre-escaped allocation. `Has<Edge>With` already accepted the target
  entity's typed predicates; that is now covered by a test. Catalogue in
  `BEST_PRACTICES` §3a.
- **Edge writes on `UpdateBuilder`.** Association maintenance no longer needs
  hand-written junction SQL: `AddEdgeIDs(edge, ids)` (idempotent),
  `RemoveEdgeIDs(edge, ids)`, `SetEdgeIDs(edge, ids)` (replace, detaching the
  previous owner first) and `ClearEdge(edge)`. M2M edges write the junction
  table; `To` o2m/o2o edges move the FK in the target table. Wrong edge kinds
  fail at compile time with an actionable message, and non-nullable FKs are
  rejected for detach operations. The statements are scoped by a subquery over
  the same predicate set as the parent UPDATE, so they inherit its privacy /
  interceptor scoping — wrap the update in `beginTx` for atomicity.
- **Outbox claim-based dispatch.** New `Outbox.claim(allocator, client, limit)`
  atomically moves a batch of rows from `pending` to the new `processing`
  status and returns them, and `dispatch` now goes through it. PostgreSQL and
  SQLite claim in a single `UPDATE … RETURNING` (PostgreSQL adds
  `FOR UPDATE SKIP LOCKED`); MySQL runs `SELECT … FOR UPDATE SKIP LOCKED` plus
  the `UPDATE` inside one transaction. Because the rows are reserved before
  publishing, concurrent dispatchers no longer fetch and publish the same
  rows. `processing` is a plain string value, so no migration/DDL change is
  needed. Rows left in `processing` by a crash are **not** reaped
  automatically (no recovery API is provided); requeue stale rows out of band.
  `pending` remains as a non-claiming read path.

### Fixed
- **Eager loading generated invalid SQL past the parameter limit.**
  `writeInClauseChunked` emitted `col IN (a, b) OR (c, d)` — a bare row value
  as an OR operand, which PostgreSQL rejects and SQLite reports as
  "row value misused". Any `WithEdge` load over 500 parents failed. Each chunk
  now repeats `col IN (...)`.
- **Eager-loaded targets bypassed the read contract of a normal query.** They
  were fetched with no soft-delete filter, no privacy policy/row filters and
  no interceptor chain — a cross-tenant leak wherever interceptors inject the
  tenant, plus soft-deleted children appearing in results. The target contract
  (soft-delete → privacy → interceptors) is now applied inside the neighbour
  `WHERE`, before any per-parent window ranking, so a filtered row cannot
  consume a per-parent `LIMIT` slot.
- **`QueryEdge` traversal emitted dialect-invalid SQL.** `queryTargets`
  hand-concatenated `?` placeholders, double-quoted identifiers and literal
  `"id"` / `{table}_id` key and junction columns — wrong on PostgreSQL and
  MySQL, and wrong on SQLite whenever the primary key or junction column was
  named differently. It now renders through the same generator as eager
  loading (`buildEdgeStep` + `appendSetNeighborsFiltered`) and applies the
  target's soft-delete scope. The helper still takes no
  privacy_ctx/interceptors — documented on the function; use `WithEdge` when
  you need tenant scoping.
- **PostgreSQL and MySQL issued an extra `SET` per statement.** Both drivers
  ran the timeout reset unconditionally in a `defer`, even when the statement
  carried no deadline (MySQL performed no SET at all in that case, so the
  reset was pure overhead). They now track the timeout in effect per
  connection and only send `SET` when the desired value differs:
  deadline-free statements cost zero extra round-trips, and statements with a
  deadline lose the trailing reset.
- **Concurrency failures could not be told apart.** PostgreSQL 40001/40P01,
  MySQL 1205/1213 and SQLite BUSY/LOCKED all collapsed into generic failure
  errors, so callers could not know what was worth retrying. They now map to
  `SerializationFailure` / `DeadlockDetected` / `LockTimeout`,
  `driver.isRetryable` classifies transient errors, and `driver.retryTx`
  replays a whole transaction with exponential backoff (`Tx.deinit` exactly
  once per attempt).
- **MySQL no-arg `exec` left its result set pending.** A `SELECT` issued
  through exec made the NEXT command fail with errno 2014 "Commands out of
  sync". The result set is now consumed and freed (a no-op for
  INSERT/UPDATE/DDL).
- **Quoted identifiers did not escape their own quote character.** A name
  containing `"` (or a backtick on MySQL) closed the identifier early —
  reachable from request input via ORDER BY column names. `Builder.ident`,
  `Dialect.quoteIdent` and `quoteIdentToBuffer` now double embedded quotes per
  the SQL standard.
- **Migrations hardcoded `std.heap.page_allocator`.** `createTables`,
  `createAllTables` and `Client.createAllTables` now take an allocator and
  thread it through the `*Alloc` SQL builders, so allocate/free always pair on
  the same allocator and those paths are leak-checked under
  `std.testing.allocator`.
- **Connection-pool release wrote to a freed entry on the OOM path.**
  `release` closed the entry in a `catch` and then still assigned
  `entry.idle_since`; closing destroys the entry, so that was a
  use-after-free write.
- **Connection-pool metrics callbacks run outside the mutex.** `borrow` and
  `release` now invoke `Metrics.onBorrow` / `Metrics.onRelease` after
  unlocking, so a callback that re-enters the pool (reads pool state, borrows
  a connection, logs through the pool) no longer self-deadlocks. The borrow
  path's health check still runs inside the mutex, so
  `health_check_on_borrow` serializes concurrent borrows — a known limitation,
  now documented on `Options.Metrics`.
- **Privacy policies fail closed past their filter capacity.** A policy whose
  rules produced more than the inline limit (8) row-level filters hit a
  `std.debug.assert` — a process abort under ReleaseSafe, and a silently
  dropped filter (widened result set for a security policy) in builds without
  assertions. The overflow now denies the operation and logs why.
- **`monotonicNs` no longer traps.** A failing `clock_gettime(CLOCK_MONOTONIC)`
  hit `unreachable`, which is undefined behaviour in ReleaseFast and an abort
  under ReleaseSafe. It now degrades to the wall clock with a warning and
  reports 0 only if both clocks fail.

### Docs
- Documented the predicate catalogue (`BEST_PRACTICES` §3a) and the new edge
  writes (§5e), including a cross-dialect note that MySQL's
  `rows_affected` counts *changed* rows while SQLite/PostgreSQL count
  *matched* rows.

## [0.34.0] - 2026-09-07

### Added
- **Parameterized raw predicates.** `sql.RawArgs(sql_text, args)` renders a
  raw SQL fragment whose `?` markers are rebound to dialect placeholders in
  order (`$N` on PostgreSQL), composing with typed predicates via
  `sql.And`/`sql.Or`. A marker/argument count mismatch fails with
  `error.RawArgCountMismatch` instead of emitting malformed SQL. Covers
  fragments typed predicates cannot express (`BETWEEN`, `IN (…)`, function
  calls) without string-concatenating values.
- **Aggregate query helpers** on `QueryBuilder`:
  - `SumOrZero("col")` — `COALESCE(SUM("col"), 0)`, returns `0` on empty
    sets instead of `NULL`.
  - `AggregateOne("COUNT(DISTINCT name)")` — single-value aggregates as a
    typed `sql.Value` (`null`/`int`/`float`/owned `string`).
  - `AggregateText("SUM(\"amount\")")` — aggregate read back as exact
    decimal text (`?[]u8`, caller frees) for money columns where `f64`
    rounding is unacceptable.
  - `AggregateBy("SUM(\"amount\")", "status")` — raw aggregate grouped by a
    schema field, honoring `Where` predicates, soft-delete filtering and
    `Having`; returns `Managed(GroupMetric)` released with
    `freeGroupMetrics`. Appends to an existing `GroupBy` column list.
- **Upsert custom update expressions.** `SaveOrUpdateOnWith(conflict_cols, exprs)`
  takes per-column `UpsertSetExpr{ .column, .expr }` templates rendered on the
  duplicate-key path, e.g. `{t:receive_num} + 1` for counter increments
  (`{t:col}` = table-qualified column, `{x:col}` = `EXCLUDED."col"` on
  PostgreSQL/SQLite, `VALUES(\`col\`)` on MySQL). Placeholder columns are
  validated to `[A-Za-z0-9_]`; other columns keep the default
  `EXCLUDED`/`VALUES()` assignment. On SQLite, supplying expressions switches
  from `INSERT OR REPLACE` (delete+insert, breaks FK/ROWID invariants) to
  `INSERT … ON CONFLICT … DO UPDATE`.
- **Raw-query DTO scanning.** `sql_scan.queryAll(T, allocator, driver, sql, args)`
  / `sql_scan.queryOne(...)` run a raw driver query and scan rows into any
  DTO struct by column name (`scanRowNamed` semantics — unselected fields
  keep zero values); `sql_scan.freeDto(T, allocator, &item)` releases the
  string fields duplicated at scan time. Failed mid-scan calls free the
  already-collected items (errdefer), keeping `zig build test` leak-clean.
  This replaces hand-written `rows.next()` + per-column `getInt`/`getText`
  loops in consumer persistence code.
- **Row-lock variants.** `Selector.forUpdateWith` / `QueryBuilder.ForUpdateWith`
  accept `LockOpts{ .of, .skip_locked, .nowait }`: `FOR UPDATE OF "table"`
  scopes the lock to one table on PostgreSQL; `SKIP LOCKED` / `NOWAIT`
  (PostgreSQL 9.5+, MySQL 8+) skip or fail on locked rows instead of
  blocking — the queue-drain pattern for worker pools. Unsupported clauses
  degrade per dialect: `OF` is PostgreSQL-only, lock modifiers are omitted on
  SQLite (no row locks).

## [0.33.0] - 2026-09-03

### Added
- **Create / BulkInsert interceptors.** `UseInterceptor` now runs on
  `Create` and `BulkInsert` as well as Query/Update/Delete. `whereEq` on
  create fills an omitted column (if-missing); an explicit value is kept.
  Tables without the field still return `UnknownField`. Hooks still fire
  after injection so they see the filled values.

## [0.32.2] - 2026-08-31

### Fixed
- **Connection pool use-after-free.** `ConnPool` stored entries by value in
  `all` and kept raw pointers into that array in `available`; `closeConnection`
  used `swapRemove`, which moved the tail entry into the removed slot. A
  still-borrowed entry at the tail could then be aliased when a later
  `addOne` reused that slot, so a borrowed `*D` could point at a recycled or
  freed connection and a health-check `ping()` would dereference poisoned
  memory (segfault after idle eviction). Entries are now individually
  heap-allocated (`*PooledEntry`) with stable addresses; removal is by pointer
  identity from both lists. Regression test added.
- **MySQL upsert for non-integer primary keys.** `LAST_INSERT_ID(pk)` coerces
  a string/varchar PK to an integer, raising MySQL errno 1292 on the
  duplicate-key UPDATE path. Integer PKs keep the id-preserving
  `LAST_INSERT_ID` form; string/UUID PKs now fall back to `VALUES(pk)`.

### Tests
- Multi-threaded pool tests use a thread-safe allocator
  (`std.heap.page_allocator`); sharing the single-threaded
  `std.testing.allocator` across spawned threads was UB and the source of
  intermittent `failed command` crashes in CI.
- Benchmark regression canary compares against `HEAD~1` instead of
  `github.event.before`, which can point at a dangling SHA after a
  force-push/amend.

## [0.32.1] - 2026-08-27

### Added
- `examples/interceptor` — multi-tenant query-rewriting demo: a runtime tenant
  id in the interceptor `ctx` transparently scopes `Query`/`Update`/`Delete`
  via `view.whereEq("tenant_id", …)`; wired as `zig build run-interceptor`.
- Eager-loading and upsert benchmarks (`bench/eager.zig`, `bench/upsert.zig`):
  `eager/with_edge_o2m`, `upsert/save_or_update`, `upsert/save_or_update_on`,
  each against in-memory SQLite with a one-shot correctness check.

### Fixed
- CI is green again on every push. Four independent failures (all pre-existing
  at v0.32.0) are fixed: (1) connect-failure logs are `warn` instead of `err`
  so the skip path no longer fails Zig's test runner; (2) the `integration-db`
  job connects to MariaDB over TCP (`127.0.0.1`) instead of the unix socket;
  (3) the dead-code job pins zigmodu v0.15.32, which builds under the pinned
  Zig on Linux; (4) the benchmark canary is now a same-runner A/B against the
  parent commit instead of a machine-relative absolute baseline.
- Remove an unused `Value` import in `src/sql/diagnostics.zig` that the newer
  zmodu dead-code pass flags; shrink the dead-code baseline.

## [0.32.0] - 2026-08-27

### Added
- **Interceptor framework** (`src/runtime/intercept.zig`) — ent-style runtime
  query interception. `UseInterceptor(infos, &client, i)` registers an
  `Interceptor` on the client; every query/update/delete runs the chain after
  privacy checks and before execution, and each interceptor receives a
  type-erased `QueryView` whose `whereEq(field, value)` ANDs an equality
  predicate into the statement (multi-tenant `tenant_id` injection, audit
  filters). Chain pointer propagates to all five builders and `TxClient`;
  release with `DeinitClient`. Errors converge to `error.InterceptFailed`.
  Docs: `BEST_PRACTICES.md` §5d.
- PreparedCache benchmarks (`bench/cache.zig`): hot hit, cold-tail hit,
  take+return, evict churn — the byte-compare lookup path costs ~27ns hot /
  ~160ns cold tail.

### Fixed
- PreparedCache no longer keys statements by `(Wyhash, length)` alone — a
  hash collision could have handed back a statement prepared for different
  SQL. Entries store the SQL text inline (byte-compared on lookup; SQL
  longer than 2048 bytes bypasses the cache), and take/return is now
  slot-based: a taken (in-use) statement is invisible to lookups and
  eviction, and a slot invalidated by DDL `evictAll` releases the handle on
  return instead of re-caching stale SQL. Also fixes LRU order drift in the
  old `returnStmtByHash` evict branch.

### Tests
- Three-dialect integration alignment: optimistic locking (4), migrateSchema
  drop-column + dry-run, WhereIn chunking, privacy owner_id filter,
  BulkInsert id derivation (RETURNING on PG, `last_insert_id` fallback on
  MySQL), file-based migrations, cascade delete, stream iterator, and
  beginTx hook/privacy propagation now run on PostgreSQL and MySQL too
  (PG 18→31, MySQL 19→32 tests; suite total 116).

### Docs
- ISSUES_FROM_ZAPI body statuses synced (Z2/Z4/Z6/Z7 were fixed in v0.30.0);
  README comparison tables updated: migration is diff-based, PG/MySQL
  drivers are no longer "basic/placeholder".

## [0.31.0] - 2026-08-26

### Added
- `WithEdgeOptions(path, .{ .join = .inner, ... })` — eager edge loading with
  a schema-aware EXISTS inner-join filter in SQL, so `Limit` applies after
  the edge filter (no limit skew). `WithEdgeOpts` / `EdgeJoinKind` /
  `EdgeLimitMode` exported via `zent.codegen` (Z10).
- `field.Decimal(name)` — exact money columns: PG `NUMERIC`, MySQL
  `DECIMAL(38,10)` (explicit precision), SQLite `TEXT`; scans to owned
  `[]const u8`, never silently truncated to f64 (Z11).
- Fluent SELECT/ORDER BY expressions: `sql.SelectExpr(expr, alias)` with
  quoted aliases on all dialects, `sql.OrderExprSql(expr, desc)`,
  `Selector.addColumn`, `Driver.queryOwned`, and `Row.columnIndex(name)`
  for alias-based DTO mapping (Z5).
- `codegen.ManagedEntity` / `managedEntity` bind the owning allocator to an
  entity so teardown can't pick the wrong allocator; `codegen.dupeEntityTo`
  deep-copies fields, typed JSON structs and two edge levels into a caller
  arena for request-scoped HTTP handlers (Z8).
- `codegen.beginTxFromDriver(infos, driver, alloc)` — open a typed `TxClient`
  straight from a shared `Driver`/`pool.asDriver()` without a root `Client`;
  re-entrant calls degrade to a savepoint (Z9).
- Comptime graph stress tests: a single `buildGraph` compiles 400 minimal,
  400 realistic 8-field, and 300 hub-and-spoke edged schemas under the
  default 1M eval-branch quota (Z3).

### Documentation
- `UPGRADING.md` §7a: measured large-schema limits + safe-split guidance (Z3).
- `BEST_PRACTICES.md`: §5b SELECT expressions, §5c fluent complex UPDATE
  expressions (`setExprArgs` with `GREATEST`-style clamps; multi-table UPDATE
  stays raw), §2 rule 5 allocator-safe teardown helpers, §8a Driver-first
  transactions (Z5/Z8/Z9/Z12).

## [0.30.0] - 2026-08-26

### Added
- `SaveOrUpdateOn(conflict_columns)` on `CreateBuilder`/`BulkInsertBuilder` —
  business-key upserts with explicit conflict targets (PG/SQLite
  `ON CONFLICT (cols) DO UPDATE`, MySQL ODKU) (Z2).
- `SaveIgnore()` — conflict-do-nothing inserts: MySQL `INSERT IGNORE`,
  PG `ON CONFLICT DO NOTHING`, SQLite `INSERT OR IGNORE` (Z4).
- `Row.tryGetBool/tryGetInt/tryGetFloat/tryGetText/tryGetBlob` —
  error-union getters returning `error.NullColumn` on NULL (Z6).
- `crud_helpers.freeOwnedStrings` helper (zapi escape-ledger support).

### Fixed
- MySQL `ContainsEscaped` now uses `!` as the ESCAPE character (`\` is
  MySQL's string escape and corrupts LIKE patterns) (Z1).

### Documentation
- `BEST_PRACTICES.md`: upsert section (§5a), multi-graph strategy (§8a),
  escape-ledger template with "min zent version" column (Z7/Z13).
- `docs/ISSUES_FROM_ZAPI.md`: consumer issue tracker from the zapi port.

## [0.29.8] - 2026-08-13

### Internal
- CI: add a `benchmark-regression` canary job (`scripts/bench-compare.sh` +
  `scripts/benchmark-baseline.txt`) that fails on >100% `ns/op` regressions;
  loosen the threshold locally with `BENCH_REGRESSION_THRESHOLD_PCT`.
- Docs: add `SECURITY.md`, `CODE_OF_CONDUCT.md`, and issue/PR templates; sync
  `README_CN` consumer wiring to the git dependency and fix stale
  `AGENTS.md`/`CONTRIBUTING.md` references (version, repo URL, dev.md).
- Tests: cover outbox `max_attempts` exhaustion + oldest-first ordering,
  shard negative-tenant routing + shard-count mismatch, and MySQL
  `errnoToError`/`toDriverError` mapping.

## [0.29.7] - 2026-08-11

### Added
- Zent Builders (`QueryBuilder`, `UpdateBuilder`, `DeleteBuilder`) `Where` method now natively accepts dynamic predicate slices (`[]sql.Predicate` / `[]const sql.Predicate`), single `sql.Predicate` values, and pointers to tuples `&.{ ... }`. This enables `crud_helpers` (like `paginatedWithOptions`, `all`, `first`, `scoped`, etc.) to handle optional/dynamic query filters seamlessly.

## [0.29.6] - 2026-08-11

### Added
- `zent.crud_helpers`: Enhanced business query and mutation helpers:
  - `paginatedWithOptions`: Sorting (`ASC`/`DESC`) with automatic column whitelist validation against entity schema fields (`error.InvalidSortColumn`).
  - `latest`: Fetch newest single entity matching predicates with column whitelist validation.
  - `withTx`: Transaction callback wrapper with automatic commit on success, rollback on error, and guaranteed single `deinit()` cleanup.
  - `increment`: Atomic field increment / decrement helper.
  - `scoped` / `scopedBy` / `scopedFirst` / `scopedFirstBy`: Multi-tenant query scope helpers enforcing tenant ID isolation (`error.InvalidTenantColumn`).
  - `cursorPage`: Keyset cursor-based pagination helper (`CursorResult`) supporting `after`/`before` and `has_more` without `OFFSET` overhead.
  - `updateWithVersion`: Optimistic concurrency locking update helper returning `error.OptimisticLockConflict` on version mismatches.
  - `batchSaveOrUpdate`: Batch upsert helper matching on business key fields (`error.InvalidMatchColumn`).

## [0.29.5] - 2026-08-11

### Added
- `createTableSQLAlloc`, `createIndexSQLAlloc`, and `createViewSQLAlloc` in `sql/schema/migrate.zig` allowing explicit allocator propagation without OOM crash assumptions.
- `zent.graph.mermaid.toMermaid`: Generate Mermaid.js `erDiagram` markdown strings directly from `comptime` Schema definitions.
- `zent.sql_diagnostics.SqlDiagnostic`: Rich diagnostic context struct for formatting detailed database execution errors (SQL, bound args, table name, DB native error codes).
- `zent.graph.doc_exporter.toMarkdownDoc`: Export complete Markdown Data Dictionaries (fields, types, constraints, and edge relations) from `comptime` Schema definitions.
- `zent.entql.parseOrder`: Parse `ORDER BY` clause strings into typed `sql.Order` terms.
- `zent.sql_scan`: Added native `.enum` type scan support (supporting both integer tag values and string tag names across drivers).
- `zent.sql_pool`: Added proactive idle connection reaping (`reapIdleConnections`) and active health pinging (`pingIdleConnections`) to `ConnPool`.
- `zent.crud_helpers`: High-level business CRUD sugar functions including `get` (by ID), `findByIds`, `exists`, `findOrStore`, `saveOrUpdate` (with `SaveOrUpdateResult`), `paginated` (with `PageResult`), and `batchCreate`.

### Fixed
- `Meta(info).FieldID` in `codegen/meta.zig` now uses `info.pk_field` instead of hardcoding `"id"`, enabling correct primary-key field metadata queries on schemas with custom PKs.

## [0.29.4] - 2026-08-10

### Added
- `Schema` accepts a `table_name` override to map onto pre-existing
  physical tables (defaults to `toSnakeCase(name)`), and a `pk` override
  for tables whose primary key is not `"id"` (the schema must declare a
  field with that name). The custom `pk_field` propagates through graph
  resolution, CREATE (RETURNING/upsert/keyset cursor), and edge lookups.
- `@setEvalBranchQuota` raised to 1M so large schema graphs (174 tables)
  compile.

### Fixed
- `addEdgeFields` no longer injects a duplicate FK column when the From
  edge's `field_name` is already declared in the schema, and now honors
  `edge.field_name` (upstream issue #2). `buildEdgeStep` uses the real
  primary key instead of hardcoded `"id"`, fixing edge eager-load on
  tables with custom PKs (e.g. `upload_file.file_id`).
- Connection pool: rows now hold their borrowed connection until
  `deinit()`, fixing a concurrent use-after-free where another thread
  could reuse the connection (evicting prepared statements) while a
  caller was still iterating rows. Dead connections are closed and
  discarded instead of returning to the pool.

### Changed
- `Query.Sum` now returns `f64` (instead of `i64`) so numeric SUM works
  for both int and float columns, parsed via the text representation.
  Callers that typed the result as `i64` must switch to `f64`.

## [0.29.3] - 2026-08-07

### Fixed
- `QueryBuilder.WhereIn` now compiles on Zig 0.17: it appended to
  `std.array_list.Managed` with an explicit allocator argument, but 0.17's
  `Managed.append` takes only the item (only `ArrayListUnmanaged.append`
  takes an allocator). The function had no callers, so lazy compilation
  hid the breakage; new integration coverage exercises single/multi/>500
  chunk (OR-joined) and empty-value paths.
- Boolean columns scan correctly on Postgres/MySQL: `scanColumn(.bool)`
  decoded via `getInt` (base-10 parse), but Postgres `BOOLEAN` comes back
  as `"t"`/`"f"` over the wire, so every query touching a bool column
  failed with `error.TypeMismatch` (MySQL only worked because its TINYINT
  renders as `"0"`/`"1"`). Scanning now routes through the drivers'
  `getBool`; Postgres + MySQL integration tests cover real bool
  round-trips.

### Docs
- `All()` / `paged()` doc comments spell out their different return
  shapes and ownership (`std.array_list.Managed(Entity)` vs
  `PagedResult` with nested `.items.items`).

## [0.29.2] - 2026-08-07

### Fixed
- Migration version hashing (`computeMigrationVersion`) now runs at runtime
  instead of comptime. The migrate loop is `inline for (infos)`, so the old
  comptime version instantiated a hash loop for every table × operation and
  could blow the eval branch quota as schema table counts grew; the version
  numbers themselves are unchanged (FNV-1a is deterministic), so applied
  migration records remain valid.

## [0.29.1] - 2026-08-06

### Fixed
- `applyServerTimeout`'s expected `max_execution_time` probe failure on
  MariaDB (errno 1193) is no longer logged as an error — previously every
  MariaDB integration test logged an error and `zig build test-integration`
  exited non-zero even though all tests passed.

### CI
- Zig toolchain pinned to `0.17.0-dev.1567+f0354179a` (matches the local
  dev toolchain).
- Dead-code baseline builds zigmodu v0.15.10 (v0.15.5 failed to build on
  the current zig); baseline re-generated (still 24 declarations).
- Consumer dependency examples use `git+https` refs instead of tarballs.

## [0.29.0] - 2026-08-06

### Added
- Constraint error taxonomy: `UniqueViolation` / `NotNullViolation` /
  `ForeignKeyViolation` across all three drivers — duplicate keys and NOT
  NULL violations no longer surface as `error.NotFound` (SQLite INSERT...
  RETURNING previously swallowed the step error).
- `field.JSONValue(name)`: untyped JSON document fields backed by
  `std.json.Value` (specs, config blobs), with full create/scan/arena
  ownership support.
- `QueryBuilder.WhereEntQL` supports `has(edge)` / `not_has(edge)` /
  `has(edge, expr)` lowered to schema-aware EXISTS subqueries.
- Privacy `OnCreate` / `OnUpdate` / `OnDelete` / `OnQuery` are now
  operation-scoped (the codegen layer sets `PrivacyContext.op` per op).
- `examples/advanced`: composite UNIQUE index, paged listing with total,
  sensitive-field masking and the transactional outbox (`run-advanced`).
- `docs/UPGRADING.md`: v0.12 → v0.28+ migration guide.
- 30-table codegen stress test; benchmark assertions; cross-driver
  (Postgres/MySQL) JSONValue + WhereEntQL integration tests.

### Changed
- `field.Time` maps to **BIGINT epoch seconds on every dialect** (was
  TIMESTAMPTZ on Postgres) so the column type agrees with the bigint audit
  default — this fixes CREATE TABLE failing on Postgres for TimeMixin
  schemas, and is a breaking change for existing PG tables.
- addEdgeFields uses a precomputed incoming-edge table (comptime cost drops
  from O(n²·e·(e+f)) to O(n²·e + T·(e+f))).
- `SKIP_PG` centralized in `connect()` (mirrors `SKIP_MYSQL`).
- `shard.route()` uses `@bitCast` for negative tenant ids (no panic/UB);
  the global hook registry is an atomic pointer.

### Fixed
- Silent error drops logged: 14 after-hook sites, audit-column OOM,
  Tx/Savepoint rollback, mysql_options failures (SSL enforcement now
  hard-fails instead of silently downgrading).
- JSON ownership unified across create/scan/eager-load paths (per-entity
  arena); `toMaskedJson` skips the injected json_arena defensively.
- `withTimeout` on Postgres actually interrupts queries (defer was scoped to
  an if block); PG auto-increment ids emit SERIAL/BIGSERIAL.
- MySQL preferred SSL falls back to plaintext; statement timeouts apply to
  SELECTs.
- README/README_CN/RELEASING dependency examples use `git+https` refs
  (tarball hashes are unstable on 0.17-dev).
- Examples build on current dev zig (`.edges` recursion, `hash.crc`,
  `QueryIterator.select_cols`).

## [0.28.0] - 2026-08-06

### Added
- EntQL `has(edge)` / `not_has(edge)` / `has(edge, expr)` — the parser now
  accepts them and `QueryBuilder.WhereEntQL()` lowers them to schema-aware
  EXISTS subqueries (previously a compile error).
- Privacy operation-level policies are real: `OnCreate` / `OnUpdate` /
  `OnDelete` / `OnQuery` deny only their own operation (the codegen layer
  sets `PrivacyContext.op` per operation).
- Codegen scale regression protection: a 30-table x 8-field stress test
  (edges/indexes/JSON) compiles and runs a CRUD smoke.
- Benchmarks now assert result correctness (generated SQL, scanned values,
  borrowed connection) and fail loudly instead of print-and-continue.

### Changed
- JSON field ownership unified across create and scan paths: query results
  (including eager-loaded edges) parse JSON into a per-entity arena that
  `deinitEntity` releases — no more caller-owned JSON on the scan path.
- `@setEvalBranchQuota` raised for codegen generation (predicates,
  migrations, graph lowering) so 20+ table schemas compile.

### Fixed
- `zig build` was red on both CI and current dev zig: eager-load recursion
  into the terminal PlainFields type, `std.hash.crc` API drift, and
  `QueryIterator` losing `select_cols` (column projection) are fixed.
- PostgreSQL `withTimeout` actually interrupts queries — a `defer` scoped to
  an `if` block reset `statement_timeout` before the query ran; PG
  `createAllTables` also emits `SERIAL`/`BIGSERIAL` ids now.
- MySQL preferred SSL mode falls back to plaintext instead of enforcing TLS;
  server-side statement timeouts apply to SELECTs; 14 silent `catch {}`
  error drops (after-hooks, audit fields, Tx/Savepoint rollback,
  mysql_options) now log.
- CI/test infra: PG/MySQL integration tests are optional (compile without
  libpq/libmariadb headers), `SKIP_MYSQL` matches `SKIP_PG`, and
  check-version scripts work on macOS (`git tag --sort=-v:refname`).
- README (en/zh) example compiles and runs; AGENTS.md / ARCHITECTURE.md
  synced with the actual API.

## [0.27.0] - 2026-08-04

### Added
- Public root export of `codegen.toMaskedJson` — the sensitive-field JSON
  masking helper is now reachable as `zent.codegen.toMaskedJson(...)` so
  consumers no longer need to reach into internal file paths.

### Fixed
- Optional fields (`field.*.Optional()`) now work across create / get /
  update / bulk paths: `setFieldValue` accepts bare values for optional
  fields, SQL binding handles null, validators skip null, and `ownedCopy`
  duplicates `?[]const u8` correctly (no dangling strings on read).

## [0.26.0] - 2026-08-04

### Added
- Column projection: `QueryBuilder.Select(cols)` restricts the query to a
  column subset (skips large text/blob fields); rows scan by name
  (`scanRowNamed`) and unselected fields keep zero values (read-only).
- Bulk soft delete: `BulkDelete` on `soft_delete` entities updates
  `deleted_at` per WHERE group (OR semantics) instead of compile-erroring.
- `field.Custom(pattern)` validator lands as wildcard matching (`*` any
  sequence, `?` one char).

### Fixed
- Dangling-pointer bug in pointer-based `And`/`Or` predicate trees
  (`WhereIn` stored pointers to expired stack locals). New value-semantics
  `or_in` predicate (`col IN (…) OR col IN (…)`) with chunks owned by the
  query builder.

## [0.25.0] - 2026-08-04

### Added
- `AuditMixin` (`created_by` / `updated_by`): Create/Update auto-fill from
  `PrivacyContext.user_id` unless set explicitly — audit trail for who
  created/changed a row.
- Built-in validators: `NotEmpty`, `Length(min, max)`, `Email`, `Phone`
  (lightweight checks in `validateSqlValue`, run automatically on
  Create/Update).
- Soft-delete restore: `DeleteBuilder.Restore(id)` clears `deleted_at`
  (compile error on non-soft-delete entities).

## [0.24.0] - 2026-08-04

### Added
- Nested transactions via savepoints: `Driver.beginSavepoint` (SQLite /
  Postgres / MySQL, pool-forwarded) and `codegen.beginTx` degrading to
  `SAVEPOINT` when already inside a transaction — re-entrant service
  orchestration with inner rollback/commit semantics.
- After-commit hook: `TxClient.afterCommit(ctx, fn)` fires once after a
  successful commit (cache invalidation, indexing, notifications).
- Distributed ids: `core.id.uuidv4() / uuidv7(now_ms) / format()` with a
  statically-held CSPRNG; uuid primary keys support Create/Save, query by
  id, CursorAfter, and eager edge loading (compile-time map selection).
- Sensitive-field JSON masking: `codegen.entity.toMaskedJson` emits
  sensitive fields as `"***"` (APIs must use it instead of serializing raw
  entities — @Struct has no decls slot for jsonStringify).
- Transaction-scoped event collection: `TxClient.enqueueEvent` /
  `takePendingEvents` (typically from the after-commit hook) for
  outbox/audit/notifications.
- Update-path sensitive log masking (create already masked; update/query
  were leaking secrets into exec logs).
- Chunked `IN` clauses: `sql.InChunked`, `QueryBuilder.WhereIn`, and
  chunked eager-load parent ids (SQLite ~999 parameter cap).
- `CrudService.insertMany` / `upsertMany` batch writes.

## [0.23.0] - 2026-08-03

### Added
- Composite keyset pagination: `CursorKeyset(col, value, id, desc)` generates
  `WHERE (col > ?) OR (col = ? AND id > ?) ORDER BY col, id` — ties on the
  cursor column (e.g. duplicate feed timestamps) no longer drop rows between
  pages.
- Eager-loaded edge filtering: `Edge.WhereRaw(fragment, args)` filters which
  neighbors load (e.g. only visible comments); filters apply before
  order/limit so limits rank filtered rows.

### Changed
- `sql.Value` moved to `src/sql/value.zig` (re-exported by the builder) so
  `core/edge` and `graph/step` can reference it without a builder↔step import
  cycle.

## [0.22.0] - 2026-08-03

### Added
- Audit timestamps auto-maintained: `created_at` / `updated_at` (`.time`)
  columns get a dialect-aware epoch `DEFAULT` (`(unixepoch())` /
  `EXTRACT(EPOCH FROM now())::bigint` / `UNIX_TIMESTAMP()`) — matching zent's
  i64 Time storage; `UpdateBuilder` auto-refreshes `updated_at` unless the
  caller sets it explicitly.
- Eager-loaded edge lists can be ordered and capped:
  `edge.To(...).OrderBy("created_at").Desc().Limit(10)` — per-parent `LIMIT`
  uses `ROW_NUMBER() OVER (PARTITION BY fk …)` for O2M/O2O (other relations
  reject limits with `UnsupportedEdgeLimit`).

### Fixed
- `Edge.Field(fk)` was ignored for `To` edges — FK column names were
  hardcoded to `source_table_id` in both `graph.addEdgeFields` and
  `tableFromTypeInfoCrossRef`, so explicit FK bindings never took effect.

## [0.21.0] - 2026-08-03

### Added
- Atomic expression parameters: `sql.UpdateBuilder.setExprArgs` and the
  generated `UpdateBuilder.setExprArgs(field, expr, args)` — `?` placeholders
  in SET expressions are rewritten dialect-aware and bound in SQL order
  (SET args precede WHERE args). Enables oversell-safe stock decrement:
  `SET stock = stock - ? WHERE id = ? AND stock >= ?`, with
  `rows_affected == 0` meaning insufficient stock.
- Two-level nested eager loading: `QueryBuilder.WithEdge("posts.comments")`
  preloads two levels (one IN neighbor query per level). `LightEntity` now
  carries one shallow edges level (terminal targets are plain fields; deeper
  paths are compile errors), and `deinitEntity` recursively frees nested edge
  slices.

### Fixed
- Global-hook registry test left a dangling chain pointer that crashed later
  Create/Save tests.

## [0.20.0] - 2026-08-03

### Added
- `helpers` module — official environment assemblers lifted from the ZigModu
  example into the framework: `StoreEnv` (single store + `driver()` accessor),
  `PooledEnv` (thread-safe `sql_pool`-backed client), `ShardedEnv`
  (per-shard driver/client + `ShardSet` routing), `TestEnv` (isolated
  in-memory store with `reset()`).
- `sql_pool.ConnPool`: `connect` is now optional and a `connectCtx` factory
  pair was added, so pools can open connections with runtime configuration
  (e.g. a file path) without globals.
- `shard.ShardRouter.moveTenant` / `ShardSet.rebalance` — idempotent tenant
  rebalance (no-op when already routed to the target shard).

## [0.19.0] - 2026-08-03

### Added
- `crud.CrudService(infos, info, tenant_col)` — generic list/get/create/
  update/delete over the generated client with tenant scoping and a
  `CrudEvent{created,updated,deleted}` listener (schema-as-code answer to
  zmsaas' sqlx CrudService).
- `privacy.data_scope` — DataScopeFilter + Policy mapping the
  all/self_/dept_only/dept_and_child/dept_custom scopes onto zent policies;
  the scope predicate is injected at the SQL layer per query.
- `outbox.Outbox(infos, outbox_info)` — transactional outbox: enqueue inside
  `tx.client` (atomic with the business write), dispatch with
  at-least-once semantics, requeue-with-attempts until max_attempts.
- `shard.ShardSet(infos)` + `ShardRouter` — tenant → shard routing with an
  explicit map and stable hash fallback over one generated Client per shard.

### Fixed
- `CrudService.get` freed scan rows with the caller's allocator instead of
  the client allocator (mismatched-free UB + per-call leak when the caller
  passes a request arena); regression test added.
- Dormant `graph/neighbors` tests revived; predicate rendering now splits
  dotted columns (`group.name` → `"group"."name"` instead of `"group.name"`).

## [0.18.0] - 2026-08-03

### Added
- `QueryBuilder.paged(page, page_size) → PagedResult{items,total}` — one
  count + one limit/offset fetch, unified deinit.
- `QueryBuilder.CountBy(col) → GroupCount{key,count}[]` — single GROUP BY
  aggregate helper.
- `sql.ContainsEscaped` + generated `{col}ContainsEscaped` predicate —
  render-time escaping of `%`/`_`/escape char.
- `BulkInsertBuilder.SaveOrUpdate` — bulk upsert (`ON CONFLICT DO UPDATE` /
  `ON DUPLICATE KEY UPDATE`), one id per row via RETURNING or
  last_insert_id.

### Fixed
- Package version synced to release tags (0.12.1 → 0.18.0); release
  toolchain (`scripts/check-version.sh` / `bump-version.sh` / `release.sh`)
  added so tag/version drift can't recur.

## [0.17.0]

### Fixed
- MySQL real upsert (schema + codegen review feedback).

Older releases: see `git tag` history.
