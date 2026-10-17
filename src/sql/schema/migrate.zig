const std = @import("std");
const field_mod = @import("../../core/field.zig");
const TypeInfo = @import("../../codegen/graph.zig").TypeInfo;
const FieldInfo = @import("../../codegen/graph.zig").FieldInfo;
const EdgeInfo = @import("../../codegen/graph.zig").EdgeInfo;
const IndexInfo = @import("../../codegen/graph.zig").IndexInfo;
const Dialect = @import("../dialect.zig").Dialect;
const sql_driver = @import("../driver.zig");
const Value = @import("../builder.zig").Value;
const zent_log = @import("../../runtime/log.zig");
const walltime = @import("../walltime.zig");
const dialect_expr = @import("../dialect_expr.zig");

/// Transaction safety by backend
///
/// SQLite and PostgreSQL support transactional DDL — a `CREATE TABLE`,
/// `ALTER TABLE`, or `CREATE INDEX` issued inside a `BEGIN`/`COMMIT` block
/// is fully atomic and can be rolled back.
///
/// MySQL does NOT support transactional DDL. `CREATE TABLE`, `ALTER TABLE`,
/// `CREATE INDEX`, and similar statements implicitly commit any active
/// transaction before executing. Therefore, on MySQL the transaction wrapping
/// in `migrateSchema` only guarantees atomicity for history-table writes
/// (`zent_schema_migrations` INSERTs). Schema changes on MySQL are applied
/// immediately and cannot be rolled back by this layer.
///
/// This is a known, documented limitation of MySQL — do not attempt to make
/// DDL transactional on MySQL; the guarantee is best-effort per backend.
/// Current Unix timestamp in seconds, from the one wall clock the library
/// keeps (`zent.walltime`); `applied_at` is informational and not used by
/// migration logic.
fn unixTimestamp() i64 {
    return walltime.nowSecs();
}

/// Version scheme for migration operations.
///
/// The version is derived from the bytes of the key using a
/// linear congruential hash. The 31-bit mask keeps it positive and
/// within MySQL's signed INTEGER range (32-bit).
fn computeMigrationVersion(table: []const u8, op: []const u8, target: []const u8) i64 {
    // Runtime FNV-1a-style hash — deterministic, so version numbers are
    // identical to the previous comptime version (applied records stay
    // valid). Keeping this out of comptime avoids per-table/per-op codegen
    // explosion: the whole migrate loop is `inline for (infos)`, so a
    // comptime version instantiated a hash loop for every table × op and
    // blew the fmt eval branch quota at ~25 tables.
    var h: u64 = 14_695_981_039_346_656_037;
    for (table) |b| {
        h ^= b;
        h *%= 1_099_511_628_211;
    }
    h ^= ':';
    for (op) |b| {
        h ^= b;
        h *%= 1_099_511_628_211;
    }
    h ^= ':';
    for (target) |b| {
        h ^= b;
        h *%= 1_099_511_628_211;
    }
    return @as(i64, @intCast(h & 0x7FFF_FFFF));
}

/// Options controlling migration behavior.
pub const MigrateOptions = struct {
    /// If true, don't execute any SQL — only print what would be done.
    dry_run: bool = false,

    /// If true, columns that exist in the database but NOT in the schema
    /// will be dropped. When false (default), extra columns are silently kept.
    drop_columns: bool = false,

    /// If true, column type changes (ALTER TYPE / MODIFY COLUMN) are applied
    /// even when they may cause data loss. When false (default), type mismatches
    /// are silently ignored.
    allow_data_loss: bool = false,

    /// If true, the migration also converges **nullability** instead of only
    /// adding what is missing:
    ///
    ///   - An **added** column the schema declares NOT NULL is emitted
    ///     `NOT NULL DEFAULT …`, so it does not arrive nullable and become the
    ///     drift `check_nullability` warns about one statement later. The
    ///     default is the field's own (or the audit-timestamp one); a
    ///     non-optional field with neither fails the migration with
    ///     `error.NotNullNeedsDefault`, because the value that fills the rows
    ///     already in the table is the caller's decision, not this layer's.
    ///   - An **existing** column whose nullability differs from the schema is
    ///     altered (`SET NOT NULL` / `DROP NOT NULL`). `SET NOT NULL` fails on
    ///     rows that already hold a NULL, so this is opt-in, next to
    ///     `drop_columns` / `allow_data_loss`.
    ///
    /// Dialects differ, and the differences are not hidden: PostgreSQL does
    /// both; SQLite has no `ALTER COLUMN` at all, so only the added-column half
    /// converges there and an existing column stays as it is (`check_nullability`
    /// reports it); MySQL fails closed with `error.MySQLNullabilityChangeUnsafe`,
    /// because `MODIFY COLUMN` replaces the whole column definition and this
    /// layer does not introspect enough to reproduce it — the same reason its
    /// type changes fail closed.
    ///
    /// False by default: an existing deployment keeps the behaviour it has, and
    /// turning this on is a statement that `SET NOT NULL` may be attempted
    /// against live data.
    allow_nullability_change: bool = false,

    /// If true, a **foreign key** the schema declares and the database does not
    /// have is added to the table that already exists — the repair for
    /// `SchemaDrift.Kind.missing_foreign_key`, which the default path only
    /// reports.
    ///
    /// A `FOREIGN KEY` is inline in `CREATE TABLE`, so a table created before the
    /// edge existed never gets the constraint and every dangling reference the
    /// application expects the database to reject is accepted. This option emits
    /// the `ALTER TABLE … ADD CONSTRAINT … FOREIGN KEY` that closes the gap, and
    /// the statement is **not** conditional: when the table already holds rows
    /// that violate the key the migration fails with the driver's own
    /// foreign-key error rather than quietly leaving the constraint out. That is
    /// why it is opt-in, next to `drop_columns` / `allow_data_loss` / the
    /// nullability convergence: it is a decision about the data already in the
    /// table. False by default, so an existing deployment keeps the behaviour it
    /// has and the drift stays a report.
    ///
    /// The name it gives the constraint is deterministic — `fk_<table>_<column>`,
    /// with the columns joined by `_` for a composite key, the
    /// `uq_<table>_<column>` shape `planUniqueColumnIndex` already uses. The
    /// *comparison* stays by shape (`foreignKeyPresent`), so a database that has
    /// the key under a name of its own (`t_col_fkey`, `t_ibfk_1`, or SQLite's
    /// nothing) is not touched, and neither is a key the schema does not declare.
    /// `ON DELETE` / `ON UPDATE` are emitted from the declaration, because a
    /// repaired key that defaulted to `NO ACTION` would behave differently from
    /// the one `CREATE TABLE` writes while `checkSchema` stayed silent — it does
    /// not compare them.
    ///
    /// Dialects, and the differences are not hidden:
    ///
    ///   - **MySQL** emits the `ADD CONSTRAINT … FOREIGN KEY` directly. InnoDB
    ///     validates the rows already in the table as part of it, so an orphan
    ///     fails the migration with `error.ForeignKeyViolation`.
    ///   - **PostgreSQL** emits it `NOT VALID` and then
    ///     `ALTER TABLE … VALIDATE CONSTRAINT` as a second statement of the same
    ///     plan: the add is a catalog update under a short lock, the scan is the
    ///     validation, and a violating row fails *there*, with an error that
    ///     names the constraint. The migration's own transaction means that
    ///     failure rolls both statements back — nothing half-added is left
    ///     behind. (A caller that executes the two planned statements itself has
    ///     the re-entrant state instead: a failed `VALIDATE` leaves the
    ///     constraint present but not validated, and since `foreignKeyPresent`
    ///     compares by shape, a later run sees it as present and plans nothing.
    ///     Validity is not part of that comparison, here or in `checkSchema`.)
    ///   - **SQLite** is a **no-op** — see `planMissingForeignKeys`. It has no
    ///     `ALTER TABLE ADD CONSTRAINT`, so the drift keeps being reported there
    ///     and nothing is emitted; a SQLite run is otherwise byte-identical to
    ///     the default.
    add_missing_foreign_keys: bool = false,

    /// How long to wait for the cross-process migration lock before giving up
    /// with `error.MigrationLockTimeout`. `0` disables locking entirely.
    /// SQLite ignores this (single-writer database, see `lockMigration`).
    lock_timeout_ms: u32 = 10_000,

    /// After migrating, compare every column's **nullability** between the
    /// schema and the live database and log a warning per difference
    /// (`checkNullability` is the same check, callable directly).
    ///
    /// Migrations only add what is missing; a column that already exists with
    /// different nullability is left alone — silently, until a read fails with
    /// `error.TypeMismatch` on a NULL the schema did not expect. This is the
    /// moment the two are known to meet, so the mismatch is reported here.
    check_nullability: bool = true,
};

/// A column whose nullability differs between the schema and the database.
pub const NullabilityDrift = struct {
    /// Table and column names, borrowed from `infos` (no ownership).
    table: []const u8,
    column: []const u8,
    schema_optional: bool,
    db_nullable: bool,

    /// The direction that breaks reads: the database allows NULL where the
    /// schema declares a non-optional field, so a scan fails at runtime with
    /// `error.TypeMismatch` and no hint about which column.
    pub fn breaksReads(self: NullabilityDrift) bool {
        return !self.schema_optional and self.db_nullable;
    }
};

/// What the database and the schema disagree about.
pub const SchemaDrift = struct {
    table: []const u8,
    /// Empty for `missing_table` and `missing_view`.
    column: []const u8 = "",
    kind: Kind,
    /// For `.nullability`: the schema's view, and the database's.
    schema_optional: bool = false,
    db_nullable: bool = false,
    /// For `.type_mismatch`: the schema's declared type. The database's type is
    /// on the `ExistingColumn` for the same name — one string here rather than
    /// two avoids owning it.
    schema_type: []const u8 = "",
    /// True when `column` was **duplicated** into this entry and must be freed.
    ///
    /// Only `.extra_column` needs it: every other kind names a column that comes
    /// from `infos` (a comptime literal, stable for the program's life), while an
    /// extra column exists only in the database's answer, which is freed before
    /// the drift list reaches the caller — borrowing it there is a
    /// use-after-free that shows up as garbage in the name.
    column_owned: bool = false,

    /// For the `.index_columns` and `.index_uniqueness` kinds: the index name,
    /// borrowed from `infos` (a comptime literal), and a formatted sentence
    /// describing the difference, **owned** — the database's answer is released
    /// before the drift list reaches the caller, so the difference has to be
    /// copied out. Both index kinds allocate it, and `freeSchemaDrift` frees it
    /// for both.
    ///
    /// `.missing_foreign_key` borrows the same field for the same reason (the
    /// shape it names — `(user_id)` → `user (id)` — is built at runtime) and is
    /// freed with the two index kinds; `.unique_constraint` and `.missing_view`
    /// point it at a `const` literal, which must **not** be freed.
    /// `.missing_junction_table` also points it at a comptime literal (the edge
    /// and the junction table name it names are all comptime-known).
    /// `ownsIndexDetail` is the single place that decides which is which. Every
    /// other kind leaves it empty *except* where a junction is the subject: the
    /// edge that put the expectation there is comptime-known, so
    /// `.missing_column` for a junction's own column and
    /// `.junction_pair_uniqueness` carry a comptime sentence built from it
    /// (the same literal, not an allocation — see `ownsIndexDetail`).
    index_name: []const u8 = "",
    index_detail: []const u8 = "",

    pub const Kind = enum {
        missing_table,
        missing_column,
        extra_column,
        type_mismatch,
        nullability,
        /// The schema declares a **view** (`Schema(…, .{ .view = true })`) and
        /// the database has no relation of that name — neither a view nor a
        /// table.
        ///
        /// This is the drift nothing else can see: `checkSchema` used to skip
        /// `is_view` entities entirely, while `migrateSchema` only creates a view
        /// that is missing (see `createViewSQLAlloc` for the clause each dialect
        /// gets), so a view that was never created produced a green check and a
        /// `SELECT` against it failed with "no such table/view" — the same
        /// silent-empty-result failure `missing_table` exists for, which is why
        /// `breaksReads()` is **true** here: the read fails outright, it does not
        /// merely change shape.
        ///
        /// A relation of that name counts whether it is a view or a table. The
        /// check asks "is there anything to read?", and answering it with the
        /// view catalog alone would report a declared name that a table already
        /// serves — the shape `CREATE VIEW IF NOT EXISTS` itself accepts.
        ///
        /// The view's **definition is never compared** — see the doc comment on
        /// `getExistingViews` for why (the database stores a canonical rewrite,
        /// not the text the schema wrote, so the comparison would fire on every
        /// database and block every deploy). A changed `view_sql` therefore
        /// still takes no effect and is still not reported.
        missing_view,
        /// The schema declares an **M2M edge** and the database has no relation
        /// of the junction table that edge needs — neither a table nor a view.
        ///
        /// An M2M edge carries no foreign key column (see `junctionTableForEdge`):
        /// the two sides are joined through a table named after both of them, in
        /// alphabetical order, which `migrateSchema` creates beside the entity
        /// tables. Nothing in this check used to look at it — the loop walks
        /// `infos`, and a junction table is not a `TypeInfo` — so a junction that
        /// was never created, or was dropped out of band, produced a green check
        /// while every query over that edge failed with "no such table" (the same
        /// class as `missing_view`: a *broken read*, not a missed optimisation),
        /// which is why `breaksReads()` is **true** here.
        ///
        /// Only an M2M edge without an explicit edge schema needs one: an edge
        /// with `Through(EdgeSchema)` reads and writes the through entity's own
        /// table, which is a declared entity and is checked as one. O2M and O2O
        /// edges need no junction table at all — their FK is a column of the
        /// entity table, covered by `missing_column` / `missing_foreign_key`.
        ///
        /// `table` is the junction table's name (`user_team`), because that is
        /// the relation the reader has to create; the edge that needs it is named
        /// in `index_detail`. Like `missing_view`, this kind is the relation's
        /// **absence** and nothing else — but a relation that *is* there is not
        /// left unexamined either: the two columns come back as
        /// `.missing_column`, the pair's uniqueness as
        /// `.junction_pair_uniqueness`, and the two foreign keys as
        /// `.missing_foreign_key`. See `checkSchema` for the shape those three
        /// compare and for what they deliberately leave alone.
        ///
        /// The relation is asked about on its own, with no gate on the two entity
        /// tables: a database that has never been migrated reports one of these
        /// beside each `missing_table`, not a silent gap.
        missing_junction_table,
        /// The schema declares an **M2M junction table** whose two columns are
        /// unique *together* — `junctionTableForEdge` gives it
        /// `PRIMARY KEY (a_id, b_id)` — and the database has no unique
        /// constraint forcing that pair.
        ///
        /// The other half of a junction table that *exists*. The columns are
        /// there, so every query over the edge runs and returns rows; what is
        /// missing is the constraint the pair is keyed by, so the same pair can
        /// be written twice and the relation query then answers with the same
        /// neighbour twice. A junction table created before the edge existed, or
        /// hand-created to the shape of some earlier design (a surrogate `id`,
        /// no composite key), is what this catches.
        ///
        /// Not `unique_constraint`, and not `index_uniqueness`:
        ///
        ///   - `unique_constraint` asks the same question about **one** column of
        ///     a declared entity table (`ColumnDef.unique`), and a pair is not a
        ///     column — a composite key does not make either half unique;
        ///   - `index_uniqueness` compares a **named** index the schema declares
        ///     against the database's index *of that name*. A junction's primary
        ///     key has no name on the schema side — SQLite does not even keep one
        ///     — so there is nothing to match on, and the question here is the
        ///     one `unique_constraint` asks for a column: does **anything** force
        ///     these two together?
        ///
        /// An index that is unique and **unreadable** (an expression key, a
        /// prefix, a partial index) suppresses the report for the whole junction,
        /// exactly as it does for `unique_constraint`: such an index may well be
        /// what forces the pair, so the answer is unknown rather than negative. A
        /// unique index over the pair **in the other order** does satisfy it —
        /// `UNIQUE (b, a)` forbids the same duplicates — as does the primary key
        /// `migrateSchema` creates.
        ///
        /// `breaksReads()` is **false**, and the split matters. A junction whose
        /// *column* is missing (`missing_column`) fails every query over the edge
        /// outright; a junction that merely cannot hold two identical pairs still
        /// runs those queries and still answers with the rows the table holds. The
        /// missing constraint changes whether a *write* is rejected, which is the
        /// class `unique_constraint` and `missing_foreign_key` are in: reporting
        /// it through `read_breaking_only` would turn a write constraint into a
        /// blocked deploy, the widening that mode exists to avoid. (The extra rows
        /// a duplicate puts on the page are the duplicate write's doing, not the
        /// read's.)
        junction_pair_uniqueness,
        /// The name `junctionTableForEdge` derives for an M2M edge is **also the
        /// table of a declared entity** — `<a>_<b>` is a name any entity can
        /// take, and the derivation does not know about it.
        ///
        /// Reported instead of the shape questions (`missing_column` and the
        /// rest), because those are its consequences: `migrateSchema` creates
        /// entity tables before junctions and emits `CREATE TABLE IF NOT EXISTS`
        /// for both, so whichever ran first wins and the other surface reads a
        /// table with the wrong columns. There is nothing to repair here — the
        /// two names have to differ — so the report names both surfaces and
        /// stops.
        junction_name_collision,
        /// The schema declares an index the database has under the same name
        /// with a **different key list**. Only reported when the database's
        /// key list could be read reliably (`ExistingIndex.columns_comparable`).
        index_columns,
        /// The schema declares an index the database has under the same name
        /// with a **different uniqueness**. Reported whenever the two exist,
        /// with no comparable/not-comparable escape hatch: `unique` is a plain
        /// boolean in all three catalogs (MySQL `statistics.non_unique`,
        /// PostgreSQL `pg_index.indisunique`, SQLite `PRAGMA index_list`), so
        /// unlike a key list it cannot be an expression, a prefix, a `WHERE`
        /// or an access method — there is nothing to guess at.
        ///
        /// This is the difference that lets rows the application believes are
        /// constrained through. A schema saying `Unique()` over an index the
        /// database built without it looks enforced from the inside and is not,
        /// so duplicates land until something else notices. The reverse
        /// direction (the database is stricter than the schema) makes writes
        /// fail that the schema never promised would, which is loud — reported
        /// for the same reason, since it is the same disagreement.
        index_uniqueness,
        /// The schema declares a **column** UNIQUE (`ColumnDef.unique`, from
        /// `field.String(…).Unique()`) and the database has no constraint that
        /// forces that column, on its own, to be unique.
        ///
        /// This is not `index_uniqueness`, and the two must not be folded
        /// together: that one compares *an index the schema declares* against
        /// the database's index of the same name, while this one asks whether
        /// anything at all enforces the declaration — the column's `UNIQUE` is
        /// inlined into `CREATE TABLE` and is not a named index of the schema,
        /// so nothing else can see it. A duplicate then lands where the
        /// application believed it could not.
        ///
        /// Reported only when the answer is a fact rather than a guess: a
        /// composite `UNIQUE (a, b)` does **not** satisfy `a`, and a table with
        /// an unreadable *unique* index (`lower(email)`, `email(10)`) is skipped
        /// entirely, because such an index does constrain the column and the
        /// check could not tell. See `checkSchema`.
        unique_constraint,
        /// The schema declares a foreign key (`TableDef.foreign_keys`, built
        /// from the entity's own `From` edges and the other entities' `To`
        /// edges) and the database has no foreign key with the same shape.
        ///
        /// `migrateSchema` adds one only when
        /// `MigrateOptions.add_missing_foreign_keys` asks for it — an
        /// `ALTER TABLE ADD CONSTRAINT` against a table that already holds rows
        /// can fail, and the default is deliberately non-destructive — so by
        /// default a table created before the edge existed never gets the
        /// constraint, and every dangling reference the application expects the
        /// database to reject is accepted. SQLite cannot repair it at all (no
        /// `ADD CONSTRAINT`), so there the drift really is report-only.
        ///
        /// Compared **by shape, never by name**: PostgreSQL and MySQL invent the
        /// names (`t_col_fkey`, `t_ibfk_1`) and SQLite keeps none at all. The
        /// repair therefore adds the key under its own deterministic name and
        /// does not care what the database would have called it. `ON DELETE` /
        /// `ON UPDATE` are **not** compared either (see `checkSchema`) — which is
        /// why the added constraint carries the declared actions rather than the
        /// `NO ACTION` a bare `FOREIGN KEY` would default to.
        ///
        /// The reverse direction — a foreign key the database has and the schema
        /// does not — is deliberately **not** reported; see `checkSchema`.
        missing_foreign_key,
    };

    /// Whether this drift makes a *read* fail — the kinds worth blocking a
    /// deploy over, as opposed to cosmetic agreement.
    ///
    /// A missing table, column, **view** or M2M **junction table** fails every
    /// query that mentions it (the failure mode behind "the endpoint quietly
    /// returned an empty list for months"), and a column the database makes
    /// nullable while the schema declares it non-optional fails on the first row
    /// that actually holds a NULL. A view or a junction table whose relation is
    /// absent is grouped with the first of those and not with the constraints
    /// below: `SELECT … FROM the_view` and a query over the M2M edge both do not
    /// return fewer rows, they error outright ("no such table/view") — so
    /// `read_breaking_only` must catch them, exactly as it catches
    /// `missing_table`. An extra column and a type difference do not fail reads
    /// by themselves.
    ///
    /// None of the five constraint kinds does either: a different key list
    /// changes how fast a query runs, a different uniqueness changes whether a
    /// *write* is rejected, a missing column constraint changes whether a
    /// duplicate is rejected, a missing **junction pair** constraint changes
    /// whether the same neighbour can be linked twice, and a missing foreign key
    /// changes whether an orphan is rejected — a read returns the rows it always
    /// returned. So none of them may fail
    /// `DriftStrictness.read_breaking_only`: that mode exists to stop a deploy
    /// that would break reads, and widening it into "every constraint must match"
    /// would convert a performance note, or a write that now fails loudly, into
    /// an outage. They fail only under `.any`.
    ///
    /// A junction is where the split is easiest to get wrong, because one drift
    /// kind is a broken read and the other is not: a junction table missing a
    /// **column** the relation query names is `.missing_column` and is
    /// read-breaking like any other missing column, while a junction that cannot
    /// hold the same pair twice is `.junction_pair_uniqueness` and is not.
    pub fn breaksReads(self: SchemaDrift) bool {
        return switch (self.kind) {
            // A junction name taken by an entity table is read-breaking on the
            // relational surface: the edge's relation query selects the
            // junction's columns from that name. `missing_junction_table` — the
            // same surface — is classified the same way.
            .junction_name_collision,
            .missing_table,
            .missing_column,
            .missing_view,
            .missing_junction_table,
            => true,
            .nullability => !self.schema_optional and self.db_nullable,
            .extra_column,
            .type_mismatch,
            .index_columns,
            .index_uniqueness,
            .unique_constraint,
            .junction_pair_uniqueness,
            .missing_foreign_key,
            => false,
        };
    }
};

/// Every entity, compared against the live database: a missing table, a missing
/// or extra column, a type or nullability difference, a **column** the schema
/// declares UNIQUE with nothing enforcing it, a **foreign key** the schema
/// declares the database does not have, a **view** the schema declares with no
/// relation of that name, an **M2M junction table** an edge needs with no
/// relation of that name, and — for a declared index the database already has
/// under the same name — a different key list or a different uniqueness.
///
/// Returns a caller-owned slice (`freeSchemaDrift`); names and types borrow from
/// `infos` or from comptime literals, so freeing is one call (the details of the
/// two index kinds and of `.missing_foreign_key` are the exceptions, see
/// `SchemaDrift.index_detail`).
/// Primary keys are **not** compared (see `ISSUES_FROM_ZAPI.md` Z28).
///
/// **Views** (`.missing_view`) get exactly one question asked of them: *is there
/// a relation of this name at all?* A view's columns are not compared (a view's
/// shape drift is a different matter — `migrateSchema` cannot `OR REPLACE` a view
/// whose shape changed, and it does not try) and neither is its **SQL**, which
/// would fire on every database: PostgreSQL's `pg_views.definition` is a rewrite
/// of the query (`::text` casts, added parentheses, schema-qualified names) and
/// MySQL/MariaDB and SQLite keep their own text, so comparing it against
/// `view_sql` would report a difference that is not one. The consequence is the
/// one to know: **a changed `view_sql` is still not reported here.** On SQLite
/// it also still takes no effect (`CREATE VIEW IF NOT EXISTS` leaves an existing
/// name alone); on PostgreSQL and MySQL/MariaDB `createViewSQLAlloc` emits
/// `CREATE OR REPLACE VIEW`, so a migration does converge the definition — but
/// that is `migrateSchema` acting, not this check observing, and this check
/// cannot tell you whether it succeeded.
/// A caller that wants to compare definitions can read them with
/// `getExistingViews` and normalize per dialect; that judgement is theirs.
///
/// **M2M junction tables** are asked *two* questions, and the split between them
/// is the same one a view draws and no further. An M2M edge carries no FK column
/// of its own — `migrateSchema` creates a junction table named after both sides
/// (`junctionTableForEdge`) and the relation query reads it — so a junction that
/// was never created, or was dropped out of band, leaves `SELECT` over that edge
/// failing with "no such table" while this check stayed green. That is
/// `.missing_junction_table`, reported when no relation of the derived name
/// exists.
///
/// A relation that **does** exist is not left there, because a junction table of
/// the right name with the wrong shape fails the same query with `no such
/// column` (the failure mode `missing_column` exists for), and one without the
/// composite key `junctionTableForEdge` gives it accepts the same pair twice and
/// answers the relation query with the same neighbour twice. So a present
/// junction table is compared, **against the shape `migrateSchema` creates and
/// `buildEdgeStep` reads**, on exactly three things:
///
///   - its two columns — `.missing_column`, `schema_type` `INTEGER`, and
///     read-breaking like any other missing column;
///   - the pair's uniqueness — `.junction_pair_uniqueness` (`PRIMARY KEY
///     (a_id, b_id)` in the junction's own definition), a *write* constraint and
///     so not read-breaking;
///   - its two foreign keys — `.missing_foreign_key`, by shape like every other
///     foreign key, and reported in that direction only.
///
/// The columns' **type** and **NOT NULL**, and any **extra** column the database
/// carries (a `created_at`, a surrogate `id`), are deliberately not compared.
/// The junction's `INTEGER` is a *derivation* — `junctionTableForEdge` writes it,
/// the consumer never declared it — and neither a wider type nor an extra column
/// changes which relation the query reads, which is what this check is about. A
/// column the query names and the table does not have is the case that fails it,
/// and that is `.missing_column`. **Nothing here repairs**: a junction table is
/// created when it is absent and never reshaped, so these reports are for the
/// consumer to act on, exactly like `.unique_constraint` and
/// `.missing_foreign_key`.
///
/// A junction whose name a **view** carries is compared on its columns alone.
/// `missing_junction_table` accepts any relation of the name, and a view can
/// carry neither a primary key nor a foreign key: asking would report
/// constraints no view could ever have, which is the false report this module's
/// comparisons are written to avoid (`getExistingViews` is the probe, and it
/// answers "is there a view of this name" on all three dialects).
///
/// Only edges that need an implicit junction are looked at: `.relation == .m2m`
/// **and** no `Through`, which is the condition `migrateSchema` creates them
/// under. An explicit edge schema is a declared entity and is checked as one;
/// O2M and O2O edges have no junction table at all (their FK is an entity-table
/// column, which `missing_column` and `missing_foreign_key` cover). The report
/// names the junction table in `table` and the edge that needs it in
/// `index_detail`. Both sides of a symmetric M2M edge produce the same junction
/// table name, and it is reported once.
///
/// The existence answer is `getExistingColumns`, the same relation probe
/// `migrateSchema` uses to re-create a view that was dropped out of band: it
/// answers "does this relation have columns", which is true for a view and for a
/// table on all three dialects (PostgreSQL and MySQL report a view's columns
/// through `information_schema.columns`, SQLite's `PRAGMA table_info` reads
/// them), so one query covers both shapes and no second introspection path is
/// needed. A declared view whose name a **table** already carries is therefore
/// not reported — the relation is readable, which is what the check is about.
///
/// Index comparison is deliberately narrow: only indexes the schema declares
/// **and** the database already has by name are looked at. An index that exists
/// only in the database is `migrateSchema`'s business (it is not drift), and an
/// index the schema has and the database lacks is a missing index — reported by
/// nothing here, because a missing index is a performance note too.
///
/// What *is* compared for such an index is its key list (`.index_columns`) and
/// its uniqueness (`.index_uniqueness`). The two have different reliability:
/// the key list is reported only when the database's answer could be read
/// reliably (`ExistingIndex.columns_comparable`), because it can be an
/// expression, a prefix, a `WHERE`, or an access method; uniqueness is a
/// boolean in every catalog and is reported whenever the two exist. They are
/// separate kinds and separate conditions for exactly that reason — neither may
/// suppress the other.
///
/// The index's **access method and operator class** (`IndexDef.method` /
/// `.opclass`) are deliberately *not* compared — see `IndexDef.method` for the
/// reasoning. A declared `USING hnsw (embedding vector_cosine_ops)` therefore
/// reports nothing here, in either direction: the declaration cannot produce a
/// false `index_columns` drift either, because PostgreSQL's non-btree access
/// methods already fail the `amname == 'btree'` gate that
/// `getPostgresIndexes` sets `columns_comparable` from, so the key list of an
/// hnsw index is never compared against a declaration.
///
/// **Column `UNIQUE`** (`.unique_constraint`) is a third, unrelated question:
/// not "does the index we declare agree with the database's" but "does anything
/// at all force this column to be unique". The declaration is inlined into
/// `CREATE TABLE` and is not one of `info.indexes`, so the index path cannot see
/// it. A column is satisfied when it *is* the primary key (a PK is unique by
/// construction) or when some unique index forces it **alone** — its comparable
/// key list is exactly `[column]`. A composite `UNIQUE (a, b)` does not satisfy
/// `a`, a non-unique index forces nothing, and no index at all forces nothing.
/// The report is suppressed for the whole table while any index with
/// `unique = true` and `columns_comparable = false` exists: `lower(email)` and
/// `email(10)` are both unreadable *and* both do constrain the column, so the
/// answer is unknown rather than negative. An unreadable **non-unique** index
/// does not suppress it — it enforces nothing either way.
///
/// **Foreign keys** (`.missing_foreign_key`) are compared **by shape**: the
/// local column list, the target table, and the target column list must all
/// match some foreign key in the database. Names are not compared — PostgreSQL
/// and MySQL generate them (`t_col_fkey`, `t_ibfk_1`) and SQLite keeps none —
/// and neither are `ON DELETE` / `ON UPDATE`: **the actions are never read**, so
/// a key whose actions differ from the declaration is invisible here.
/// `migrateSchema` only writes actions when it *adds* a key — the repair
/// `MigrateOptions.add_missing_foreign_keys` opts into emits the declared ones —
/// and an existing key it did not add is left with whatever it carries.
/// A foreign key the database has and the schema does not is *not* reported: it
/// can only reject writes the schema never promised, so a table with a
/// hand-added constraint stays green, and `migrateSchema` already ignores
/// database-only indexes for the same reason.
///
/// The point is the class of failure this cannot survive silently: a column the
/// schema believes in but the database does not have makes every query that
/// mentions it fail, and in a handler that swallows errors it looks like "empty
/// result" for months. `migrateSchema` adds what is missing, but a consumer whose
/// DDL lives in `.sql` files never runs it — that consumer calls this.
pub fn checkSchema(
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
    comptime infos: []const TypeInfo,
) ![]SchemaDrift {
    var drifts = std.array_list.Managed(SchemaDrift).init(allocator);
    errdefer {
        // The success path hands the slice to `freeSchemaDrift`; the error path
        // must release exactly the same owned fields for every entry that made
        // it into the list, then the list itself. A bare `deinit` here leaked
        // the `.extra_column` name and every index/FK detail already appended —
        // reached whenever any introspection query below fails after the first
        // append.
        for (drifts.items) |d| freeDriftOwnedFields(allocator, d);
        drifts.deinit();
    }
    const dialect = driver.dialect();

    inline for (infos) |info| {
        if (comptime !info.is_view) {
            const table = comptime tableFromTypeInfoCrossRef(info, infos);
            var existing = try getExistingColumns(allocator, driver, table.name);
            defer freeExistingColumns(allocator, &existing);

            if (existing.items.len == 0) {
                try drifts.append(.{ .table = table.name, .kind = .missing_table });
            } else {
                inline for (table.columns) |col| {
                    if (getExistingColumnByName(existing.items, col.name)) |db_col| {
                        const schema_optional = !col.not_null;
                        const db_nullable = db_nullableOf(db_col);
                        if (schema_optional != db_nullable) {
                            try drifts.append(.{
                                .table = table.name,
                                .column = col.name,
                                .kind = .nullability,
                                .schema_optional = schema_optional,
                                .db_nullable = db_nullable,
                            });
                        }
                        // Type comparison is text-based and best-effort: SQLite
                        // is dynamically typed, and its declared type is all the
                        // metadata there is. `normalizeSqlType` exists for
                        // exactly this comparison, and the ALTER TYPE branch of
                        // the plan runs it through the same
                        // `columnTypesAgree` — one comparison, so a plan
                        // cannot disagree with the drift report it previews.
                        var schema_buf: [128]u8 = undefined;
                        var db_buf: [128]u8 = undefined;
                        if (!try columnTypesAgree(allocator, columnSQLType(col, dialect), db_col, &schema_buf, &db_buf, dialect)) {
                            try drifts.append(.{
                                .table = table.name,
                                .column = col.name,
                                .kind = .type_mismatch,
                                .schema_type = columnSQLType(col, dialect),
                            });
                        }
                    } else {
                        try drifts.append(.{
                            .table = table.name,
                            .column = col.name,
                            .kind = .missing_column,
                            .schema_type = columnSQLType(col, dialect),
                        });
                    }
                }
            }

            // Columns the database has and the schema does not. Reported, never
            // dropped: `migrateSchema`'s `drop_columns` is the destructive path.
            for (existing.items) |db_col| {
                var known = false;
                inline for (table.columns) |col| {
                    if (std.mem.eql(u8, col.name, db_col.name)) known = true;
                }
                if (!known) {
                    try appendOwnedDrift(allocator, &drifts, .{
                        .table = table.name,
                        .column = try allocator.dupe(u8, db_col.name),
                        .kind = .extra_column,
                        .column_owned = true,
                    });
                }
            }

            // Index drift, and only under the conditions that make it a fact
            // rather than a guess:
            //
            //  * the table exists (a missing table is already reported, and an
            //    index it does not have yet is not a difference to describe),
            //  * the schema declares the index (`info.indexes`),
            //  * the database has an index of the same name, and
            //  * for the *key list* only, the database's answer was readable at
            //    all (`ExistingIndex.columns_comparable`, which is where
            //    expression keys, partial indexes, non-btree access methods and
            //    INCLUDE columns are dropped). Uniqueness is a boolean in every
            //    catalog and needs no such gate.
            //
            // Anything else is skipped without a word. A key-list difference is
            // a performance signal; a uniqueness difference is a write
            // constraint the application may believe in and not have. Either
            // way `assertSchema` turns every reported drift into a decision, so
            // a false one is a blocked deploy — strictly worse than a missing
            // warning. That is the reason for the gates, not for silence.
            if (comptime info.indexes.len > 0 or wantsUniqueColumnCheck(table)) {
                if (existing.items.len > 0) {
                    // A PostgreSQL-wire server need not carry PostgreSQL's index
                    // catalogs (HeliosDB Nano has no `pg_am`, so both the full
                    // query and its reduced form are refused). Index comparison
                    // is then *unknown*, not negative — so this table's whole
                    // index/unique half is skipped instead of reporting every
                    // declared index as missing.
                    index_half: {
                        var existing_idxs = getExistingIndexes(allocator, driver, table.name) catch |err| switch (err) {
                            error.IndexCatalogUnavailable => break :index_half,
                            else => return err,
                        };
                        defer freeExistingIndexes(allocator, &existing_idxs);

                        if (comptime info.indexes.len > 0) {
                            inline for (info.indexes) |idx| {
                                if (getExistingIndexByName(existing_idxs.items, idx.name)) |db_idx| {
                                    if (db_idx.columns_comparable and !columnsEqual(db_idx.columns, idx.columns)) {
                                        try appendOwnedDrift(allocator, &drifts, .{
                                            .table = table.name,
                                            .kind = .index_columns,
                                            .index_name = idx.name,
                                            .index_detail = try indexColumnsDetailAlloc(allocator, idx.columns, db_idx.columns),
                                        });
                                    }
                                    // Uniqueness, on its own gate. It is deliberately
                                    // *not* nested in the `columns_comparable` branch
                                    // above: that flag answers "can the key list be
                                    // read", and uniqueness can always be read, so
                                    // coupling the two would drop this drift for
                                    // exactly the indexes a comparison found hardest
                                    // to see (expression keys, partial indexes,
                                    // non-btree access methods). The reverse coupling
                                    // matters too: a difference in uniqueness must
                                    // never make `index_columns` report a key list it
                                    // could not compare.
                                    if (db_idx.unique != idx.unique) {
                                        try appendOwnedDrift(allocator, &drifts, .{
                                            .table = table.name,
                                            .kind = .index_uniqueness,
                                            .index_name = idx.name,
                                            .index_detail = try indexUniquenessDetailAlloc(allocator, idx.unique, db_idx.unique),
                                        });
                                    }
                                }
                            }
                        }

                        // Field-level UNIQUE: the declaration is inlined into
                        // `CREATE TABLE` and is not one of `info.indexes`, so the
                        // loop above cannot see it and a table built before the
                        // field was declared UNIQUE never gets the constraint.
                        //
                        // The whole table is skipped while a unique index is
                        // unreadable: `lower(email)` and `email(10)` both have no
                        // comparable key list *and* both do force the column — so
                        // the answer is unknown, and a report would be a guess. An
                        // unreadable **non**-unique index is not part of that
                        // judgement; it enforces nothing, so it answers nothing.
                        if (comptime wantsUniqueColumnCheck(table)) {
                            const undecidable = hasUnreadableUniqueIndex(existing_idxs.items);
                            inline for (table.columns) |col| {
                                // Three reasons not to look at this column at all:
                                // the declaration already enforces it (the PK is
                                // unique by construction), the database does not
                                // have the column (already reported as
                                // `missing_column`), or an unreadable unique index
                                // makes the answer unknown.
                                //
                                // Written as one condition rather than a chain of
                                // `continue`s: the filter above is comptime-known
                                // and `continue` inside it is comptime control flow
                                // in a runtime block, which 0.17 rejects.
                                if (uniqueColumnChecked(col, table) and
                                    getExistingColumnByName(existing.items, col.name) != null and
                                    !undecidable and
                                    !indexForcesColumnAlone(existing_idxs.items, col.name))
                                {
                                    try drifts.append(.{
                                        .table = table.name,
                                        .column = col.name,
                                        .kind = .unique_constraint,
                                        .index_detail = uniqueColumnDriftDetail,
                                    });
                                }
                            }
                        }
                    }
                }
            }

            // Foreign keys the schema declares and the database does not have.
            // Shape, not name (see `foreignKeyPresent`), and only in that
            // direction: a constraint the database has and the schema does not
            // can only reject writes the schema never promised, so reporting it
            // would turn a table somebody hardened by hand into a red deploy.
            // Foreign keys the schema declares and the database does not have.
            // Shape, not name (see `foreignKeyPresent`), and only in that
            // direction: a constraint the database has and the schema does not
            // can only reject writes the schema never promised, so reporting it
            // would turn a table somebody hardened by hand into a red deploy.
            //
            // A server that cannot answer the read (`ForeignKeyCatalogUnavailable`
            // — no `pg_proc`, so no `generate_subscripts`) has every declared key
            // *left alone* rather than reported missing: the report is what makes
            // the planner emit a second `ADD CONSTRAINT`, and "unknown" is not
            // "absent".
            fk_half: {
                if (comptime table.foreign_keys.len > 0) {
                    if (existing.items.len > 0) {
                        var existing_fks = getExistingForeignKeys(allocator, driver, table.name) catch |err| switch (err) {
                            error.ForeignKeyCatalogUnavailable => break :fk_half,
                            else => return err,
                        };
                        defer freeExistingForeignKeys(allocator, &existing_fks);

                        inline for (table.foreign_keys) |fk| {
                            if (!foreignKeyPresent(existing_fks.items, fk)) {
                                try appendOwnedDrift(allocator, &drifts, .{
                                    .table = table.name,
                                    .column = if (fk.columns.len > 0) fk.columns[0] else "",
                                    .kind = .missing_foreign_key,
                                    .index_detail = try foreignKeyDetailAlloc(allocator, fk),
                                });
                            }
                        }
                    }
                }
            }
        }

        // Views, which is the one declaration whose *absence* nothing here used
        // to see (the entity loop skipped `is_view` entities outright). One
        // question is asked and no more: is there a relation of this name at
        // all? `getExistingColumns` answers it — see the doc comment above for
        // why that probe covers a view and a table alike — and the definition is
        // deliberately not compared.
        if (comptime info.is_view) {
            var view_relation = try getExistingColumns(allocator, driver, info.table_name);
            defer freeExistingColumns(allocator, &view_relation);

            if (view_relation.items.len == 0) {
                try drifts.append(.{
                    .table = info.table_name,
                    .kind = .missing_view,
                    .index_detail = missingViewDriftDetail,
                });
            }
        }
    }

    // M2M junction tables — the other declaration whose *absence* nothing else
    // here sees. A junction table is not a `TypeInfo`, so the loop above walks
    // past it however complete the graph is, yet a query over the edge reads it
    // directly and fails outright when it is not there. The traversal is
    // `migrateSchema`'s own junction loop: every non-view entity, every edge
    // that is M2M **without** an explicit edge schema (`Through` is checked as
    // its own entity, and O2M/O2O carry an FK column instead), and the name
    // `junctionTableForEdge` derives from the two table names.
    //
    // Both sides of a symmetric M2M declare a `To` edge, so the same junction
    // table is visited twice with the same name — `seen_junctions` collapses that
    // into one report, the same way `CREATE TABLE IF NOT EXISTS` collapses the
    // two creations on the migration side.
    var seen_junctions = std.array_list.Managed([]const u8).init(allocator);
    defer seen_junctions.deinit();
    inline for (infos) |info| {
        if (comptime !info.is_view) {
            inline for (info.edges) |e| {
                if (e.relation == .m2m and e.through == null) {
                    const jtable = comptime junctionTableForEdge(e, info, infos);

                    var already_seen = false;
                    for (seen_junctions.items) |seen_name| {
                        if (std.mem.eql(u8, seen_name, jtable.name)) already_seen = true;
                    }
                    // Nested rather than `continue`: a runtime `continue` is
                    // comptime control flow inside the unrolled body, which 0.17
                    // rejects.
                    if (!already_seen) {
                        try seen_junctions.append(jtable.name);

                        // Asked first and unconditionally: the collision is a fact
                        // about the schema, not about the database, and on a
                        // database the entity's table has not reached yet the
                        // shape questions below would report it as merely missing.
                        // The collision is a fact about the schema, not about the
                        // database, so it is asked first and answered alone: on a
                        // database that has not been migrated the shape questions
                        // below would report the same name as merely missing, which
                        // is a different (and repairable) thing.
                        if (comptime junctionNameOwner(infos, jtable)) |owner| {
                            try drifts.append(.{
                                .table = jtable.name,
                                .kind = .junction_name_collision,
                                .index_detail = comptime junctionNameCollisionDetail(info, e, owner, infos),
                            });
                        } else {
                            try appendJunctionRelationDrifts(allocator, driver, &drifts, info, e, jtable, infos);
                        }
                    }
                }
            }
        }
    }
    return drifts.toOwnedSlice();
}

/// Compare a **present** junction table against the shape the M2M edge derives,
/// and append what differs. `existing` is the relation's column list, which the
/// The relation-side report for a junction whose name nothing else took: either
/// no relation of that name exists, or one does and gets the shape questions.
///
/// Split out of `checkSchema` so the collision branch above can answer alone —
/// a runtime `continue` is comptime control flow inside the unrolled edge loop,
/// which 0.17 rejects, and nesting the two halves in one `if` would have the
/// shape questions read as conditional on the collision.
fn appendJunctionRelationDrifts(
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
    drifts: *std.array_list.Managed(SchemaDrift),
    comptime info: TypeInfo,
    comptime edge: EdgeInfo,
    comptime jtable: TableDef,
    comptime all_infos: []const TypeInfo,
) !void {
    var junction_relation = try getExistingColumns(allocator, driver, jtable.name);
    defer freeExistingColumns(allocator, &junction_relation);

    if (junction_relation.items.len == 0) {
        try drifts.append(.{
            .table = jtable.name,
            .kind = .missing_junction_table,
            .index_detail = comptime missingJunctionTableDetail(info, edge, all_infos),
        });
    } else {
        // A relation *is* there, so the shape questions get asked. They are the
        // same three the entity loop asks of a table the schema declares,
        // against the shape `junctionTableForEdge` derives — the definition
        // `migrateSchema` creates the table from and `buildEdgeStep` builds the
        // relation query against.
        try appendJunctionShapeDrifts(allocator, driver, drifts, info, edge, junction_relation.items, all_infos);
    }
}

/// caller has already read (a missing relation is `.missing_junction_table` and
/// never reaches here).
///
/// The three questions, and nothing else — see `checkSchema` for why each is in
/// and what is deliberately out:
///
///   - the relation query names both columns; a column that is not there fails
///     every query over the edge, so it is `.missing_column` and read-breaking;
///   - the junction's `PRIMARY KEY (a_id, b_id)` makes the *pair* unique, so a
///     database with nothing forcing it is `.junction_pair_uniqueness` — the
///     report `unique_constraint` gives a single column, for two;
///   - the two foreign keys are `.missing_foreign_key`, by shape, in the same
///     one direction the entity loop reports them.
///
/// **A relation that is a view is compared on its columns alone.** The existence
/// probe accepts any relation of the junction's name, and a view can carry
/// neither a primary key nor a foreign key: the constraint questions would
/// report something no view could ever have. `getExistingViews` answers "is
/// there a view of this name" on all three dialects, and the cost is one catalog
/// query per junction table — paid only by a schema that has junctions at all.
///
/// There is no cascade short-circuit: a junction table missing a column still
/// gets the uniqueness and foreign-key reports its indexes and constraints
/// answer for. They are three separate facts a hand-fix has to cover, and with
/// `migrateSchema` deliberately not reshaping junction tables, this report is
/// the only place that says what the shape should have been.
fn appendJunctionShapeDrifts(
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
    drifts: *std.array_list.Managed(SchemaDrift),
    comptime info: TypeInfo,
    comptime edge: EdgeInfo,
    existing: []const ExistingColumn,
    comptime all_infos: []const TypeInfo,
) !void {
    const jtable = comptime junctionTableForEdge(edge, info, all_infos);
    const dialect = driver.dialect();

    inline for (jtable.columns) |col| {
        if (getExistingColumnByName(existing, col.name) == null) {
            try drifts.append(.{
                .table = jtable.name,
                .column = col.name,
                .kind = .missing_column,
                .schema_type = columnSQLType(col, dialect),
                .index_detail = comptime missingJunctionColumnDetail(info, edge, col.name, all_infos),
            });
        }
    }

    var views = try getExistingViews(allocator, driver, jtable.name);
    defer freeExistingViews(allocator, &views);
    if (views.items.len > 0) return;

    // Unknown catalog ⇒ unknown uniqueness: return without reporting, the same
    // "unknown rather than negative" answer the unreadable-index hatch gives.
    var existing_idxs = getExistingIndexes(allocator, driver, jtable.name) catch |err| switch (err) {
        error.IndexCatalogUnavailable => return,
        else => return err,
    };
    defer freeExistingIndexes(allocator, &existing_idxs);

    // The same escape hatch the column UNIQUE check uses, for the same reason: a
    // *unique* index whose key list cannot be read (an expression, a prefix, a
    // partial index) may well be what forces this pair, so the answer is unknown
    // rather than negative — and a false report blocks a deploy, while a missed
    // one is a log line nobody reads.
    if (!hasUnreadableUniqueIndex(existing_idxs.items) and
        !indexForcesPairAlone(existing_idxs.items, jtable.columns[0].name, jtable.columns[1].name))
    {
        try drifts.append(.{
            .table = jtable.name,
            .kind = .junction_pair_uniqueness,
            .index_detail = comptime junctionPairUniquenessDetail(info, edge, all_infos),
        });
    }

    // A server whose foreign-key read cannot be answered (`pg_proc` absent, so
    // no `generate_subscripts` — see `getPostgresForeignKeys`) stops here: the
    // pair uniqueness above is decided, and the key half is left to a server
    // that can answer it rather than reported as missing.
    var existing_fks = getExistingForeignKeys(allocator, driver, jtable.name) catch |err| switch (err) {
        error.ForeignKeyCatalogUnavailable => return,
        else => return err,
    };
    defer freeExistingForeignKeys(allocator, &existing_fks);

    inline for (jtable.foreign_keys) |fk| {
        if (!foreignKeyPresent(existing_fks.items, fk)) {
            try appendOwnedDrift(allocator, drifts, .{
                .table = jtable.name,
                .column = if (fk.columns.len > 0) fk.columns[0] else "",
                .kind = .missing_foreign_key,
                .index_detail = try foreignKeyDetailAlloc(allocator, fk),
            });
        }
    }
}

/// True when the table has any column the field-level UNIQUE check must look at
/// (see `uniqueColumnChecked`). Decides whether the index introspection — one
/// query for PostgreSQL and MySQL, two for SQLite — is worth running at all.
fn wantsUniqueColumnCheck(table: TableDef) bool {
    for (table.columns) |col| {
        if (uniqueColumnChecked(col, table)) return true;
    }
    return false;
}

/// True when `col` is a column the schema declares UNIQUE and that the
/// declaration does not already enforce on its own.
///
/// The exception is the primary key: it is unique by construction, so a `UNIQUE`
/// on it says nothing the PK does not. It has to be *the* PK though, not one
/// part of a composite one — `PRIMARY KEY (a, b)` does not make `a` unique, and
/// the schema can express a composite PK (`field.Int("a").Unique()` on two
/// `is_id` fields), which is why the check falls through here rather than
/// assuming `primary_key` implies single-column.
fn uniqueColumnChecked(col: ColumnDef, table: TableDef) bool {
    if (!col.unique) return false;
    if (col.primary_key and table.primary_keys.len <= 1) return false;
    return true;
}

/// True when some index on the table is unique but its key list could not be
/// read — an expression (`lower(email)`), a prefix (`email(10)`), a `WHERE`, a
/// non-btree access method, `INCLUDE` columns. Both example shapes genuinely do
/// force the column, so while one is present "is this column constrained?" has
/// no answer at all and the check must stay silent rather than report a guess.
///
/// A **non**-unique index that cannot be read is deliberately not part of this
/// judgement: whatever it covers, it enforces no uniqueness, so it cannot make
/// the question unanswerable.
fn hasUnreadableUniqueIndex(indexes: []const ExistingIndex) bool {
    for (indexes) |idx| {
        if (idx.unique and !idx.columns_comparable) return true;
    }
    return false;
}

/// Whether some unique index forces exactly `column`, and nothing else, to be
/// unique. A composite `UNIQUE (a, b)` does **not**: two rows may share `a`.
fn indexForcesColumnAlone(indexes: []const ExistingIndex, column: []const u8) bool {
    for (indexes) |idx| {
        if (!idx.unique or !idx.columns_comparable) continue;
        if (idx.columns.len == 1 and std.mem.eql(u8, idx.columns[0], column)) return true;
    }
    return false;
}

/// Whether some unique index forces exactly the pair `a`, `b` — and nothing else
/// — to be unique, which is what a junction table's `PRIMARY KEY (a, b)` asks the
/// database to enforce.
///
/// The **order is not part of the question**: `UNIQUE (a, b)` and `UNIQUE (b, a)`
/// reject the same duplicate pairs, so reading the reversed index as a
/// difference would report a constraint the database does enforce. Anything
/// wider does not satisfy it — a `UNIQUE (a, b, c)` accepts two rows sharing
/// `(a, b)` as soon as `c` differs, which is not the pair the junction is keyed
/// by.
fn indexForcesPairAlone(indexes: []const ExistingIndex, a: []const u8, b: []const u8) bool {
    for (indexes) |idx| {
        if (!idx.unique or !idx.columns_comparable or idx.columns.len != 2) continue;
        if (std.mem.eql(u8, idx.columns[0], a) and std.mem.eql(u8, idx.columns[1], b)) return true;
        if (std.mem.eql(u8, idx.columns[0], b) and std.mem.eql(u8, idx.columns[1], a)) return true;
    }
    return false;
}

/// Whether the database enforces the declared foreign key — compared **by
/// shape**, never by name. An auto-generated name is all PostgreSQL
/// (`t_col_fkey`) and MySQL (`t_ibfk_1`) leave behind, SQLite keeps none at all,
/// and `migrateSchema`'s own `FOREIGN KEY (…)` clause names nothing, so a
/// comparison by name would report every constraint in every database.
///
/// The local column list (ordered) and the target table must both match. The
/// target *columns* must match too, **unless the database did not record any**:
/// SQLite renders `REFERENCES t` with no column list as a NULL `to`, which means
/// the other table's primary key — an unreadable answer is not evidence of a
/// difference, and a false "missing" blocks a deploy. `ON DELETE` / `ON UPDATE`
/// are not compared; see `checkSchema`.
fn foreignKeyPresent(existing: []const ExistingForeignKey, fk: ForeignKeyDef) bool {
    for (existing) |db_fk| {
        if (!columnsEqual(db_fk.columns, fk.columns)) continue;
        // Case-insensitive on the table name alone: SQLite and MySQL compare
        // table names case-insensitively and PostgreSQL folds an unquoted one
        // to lower case, so `Cars` and `cars` are the same table on all three.
        // Column names stay exact, like every other comparison here.
        if (!std.ascii.eqlIgnoreCase(db_fk.ref_table, fk.ref_table)) continue;
        if (db_fk.ref_columns_comparable and !columnsEqual(db_fk.ref_columns, fk.ref_columns)) continue;
        return true;
    }
    return false;
}

/// The `.unique_constraint` report in one sentence. A `const` literal — nothing
/// is allocated for this kind (see `ownsIndexDetail`).
const uniqueColumnDriftDetail = "schema declares the column UNIQUE, database has no unique constraint covering it";

/// The `.missing_view` report in one sentence. A `const` literal — nothing is
/// allocated for this kind (see `ownsIndexDetail`).
///
/// It says the two things the reader has to know and cannot see from the drift
/// kind alone: which statement on the schema side produced the expectation, and
/// the boundary of this check — the definition is never compared, so a stale
/// `view_sql` is invisible *here* even after the view is created.
const missingViewDriftDetail = "schema declares the view, database has no relation of that name; view_sql is never compared, so a stale definition is not reported either";

/// The `.missing_junction_table` report, naming the edge that needs the relation
/// and the relation itself. A **comptime** literal — every part of it comes from
/// `infos` and from `junctionTableForEdge`, both comptime-known, so nothing is
/// allocated for this kind (see `ownsIndexDetail`).
///
/// Names are spelled out because a schema can carry several M2M edges: "a
/// junction table is missing" would send the reader back to the schema to work
/// out which one, and the junction *table* name alone does not say which two
/// entities it joins. The edge is printed in the same alphabetical order the
/// junction table's own name uses, so the sentence reads the same whichever side
/// declares the edge. The expected columns are named for the consumer that
/// creates the table by hand instead of running `migrateSchema`.
///
/// The last clause is the boundary of this check: *this* kind is about the
/// relation's absence, so a relation of that name is not reported here — it is
/// compared on its shape by the reports beside it, which the clause names so the
/// reader does not take the silence for completeness.
fn missingJunctionTableDetail(comptime info: TypeInfo, comptime edge: EdgeInfo, comptime all_infos: []const TypeInfo) []const u8 {
    comptime {
        const source_table = info.table_name;
        const target_table = edgeRefTarget(edge, all_infos).table;
        const a_first = std.mem.lessThan(u8, source_table, target_table);
        const left = if (a_first) source_table else target_table;
        const right = if (a_first) target_table else source_table;
        const jtable = junctionTableForEdge(edge, info, all_infos);

        return "schema declares the M2M edge " ++ left ++ " <-> " ++ right ++
            ", database has no relation named " ++ jtable.name ++
            " (expected columns " ++ jtable.columns[0].name ++ ", " ++ jtable.columns[1].name ++
            "); migrateSchema creates it, and a relation of that name is then compared on its columns, pair uniqueness and foreign keys";
    }
}

/// "schema declares the M2M edge jc_member <-> jc_tag, which joins through
/// jc_member_jc_tag (expected columns jc_member_id, jc_tag_id)" — the clause the
/// two shape reports of a **present** junction share. A comptime literal, like
/// everything it is built from (see `ownsIndexDetail`).
///
/// A junction table is not a `TypeInfo` and its columns are not `field`s, so
/// neither the table nor the column in a report can be found in the consumer's
/// schema. This clause is what does let the reader find the expectation: it names
/// the edge they declared, and the relation and columns `migrateSchema` derives
/// from it.
/// The declared entity whose table *is* this junction's name, if any — the
/// collision `.junction_name_collision` reports.
///
/// Comptime: both the derived junction name and every entity's table name are
/// known at that point, so the question costs nothing at runtime and cannot
/// disagree with what `migrateSchema` will create.
fn junctionNameOwner(comptime infos: []const TypeInfo, comptime jtable: TableDef) ?TypeInfo {
    comptime {
        for (infos) |other| {
            if (std.mem.eql(u8, other.table_name, jtable.name)) return other;
        }
        return null;
    }
}

/// The `.junction_name_collision` report. A comptime literal (see
/// `ownsIndexDetail`), and it names both surfaces: which pair of entities
/// derived the name, and which declared entity answers to it.
fn junctionNameCollisionDetail(comptime info: TypeInfo, comptime edge: EdgeInfo, comptime owner: TypeInfo, comptime all_infos: []const TypeInfo) []const u8 {
    comptime {
        return junctionShapeClause(info, edge, all_infos) ++
            ", but that name is the table of the entity " ++ owner.name ++
            " (schema '" ++ owner.name ++ "'); both are created with IF NOT EXISTS and entities are created first, " ++
            "so the junction's CREATE is a no-op and the relation query reads the other table's columns — " ++
            "give the entity a different table name or rename the edge's target";
    }
}

fn junctionShapeClause(comptime info: TypeInfo, comptime edge: EdgeInfo, comptime all_infos: []const TypeInfo) []const u8 {
    comptime {
        const source_table = info.table_name;
        const target_table = edgeRefTarget(edge, all_infos).table;
        const a_first = std.mem.lessThan(u8, source_table, target_table);
        const left = if (a_first) source_table else target_table;
        const right = if (a_first) target_table else source_table;
        const jtable = junctionTableForEdge(edge, info, all_infos);

        return "schema declares the M2M edge " ++ left ++ " <-> " ++ right ++
            ", which joins through " ++ jtable.name ++
            " (expected columns " ++ jtable.columns[0].name ++ ", " ++ jtable.columns[1].name ++ ")";
    }
}

/// The `.missing_column` report when the column belongs to an **implicit
/// junction table**. A comptime literal (see `ownsIndexDetail`), and the stake in
/// one clause: the relation query names this column, so the database missing it
/// fails every query over the edge rather than returning fewer rows.
fn missingJunctionColumnDetail(comptime info: TypeInfo, comptime edge: EdgeInfo, comptime column: []const u8, comptime all_infos: []const TypeInfo) []const u8 {
    comptime {
        return junctionShapeClause(info, edge, all_infos) ++ "; the relation query names " ++ column;
    }
}

/// The `.junction_pair_uniqueness` report, spelling out what the schema asks for
/// and what goes wrong without it. A comptime literal (see `ownsIndexDetail`).
///
/// The *consequence* is in the sentence because it is the only part a reader
/// cannot get from the drift kind: a duplicate pair is a write the database
/// accepts, and it shows up on the read side as a neighbour returned twice.
fn junctionPairUniquenessDetail(comptime info: TypeInfo, comptime edge: EdgeInfo, comptime all_infos: []const TypeInfo) []const u8 {
    comptime {
        return junctionShapeClause(info, edge, all_infos) ++
            ", whose primary key is that pair; the database has no unique constraint over the two columns, " ++
            "so a duplicate pair is accepted and the relation query then returns the same neighbour twice";
    }
}

/// "schema declares FOREIGN KEY (user_id) REFERENCES user (id), database has
/// none" — **owned** (see `indexColumnsDetailAlloc`).
///
/// The shape is spelled out because a table can carry several foreign keys: a
/// report that only says "a foreign key is missing" sends the reader back to the
/// database to find out which one.
fn foreignKeyDetailAlloc(allocator: std.mem.Allocator, fk: ForeignKeyDef) ![]const u8 {
    var detail = std.array_list.Managed(u8).init(allocator);
    errdefer detail.deinit();

    try detail.appendSlice("schema declares FOREIGN KEY (");
    for (fk.columns, 0..) |col, i| {
        if (i > 0) try detail.appendSlice(", ");
        try detail.appendSlice(col);
    }
    try detail.appendSlice(") REFERENCES ");
    try detail.appendSlice(fk.ref_table);
    try detail.appendSlice(" (");
    for (fk.ref_columns, 0..) |col, i| {
        if (i > 0) try detail.appendSlice(", ");
        try detail.appendSlice(col);
    }
    try detail.appendSlice("), database has none");
    return detail.toOwnedSlice();
}

fn columnsEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |a_col, b_col| {
        if (!std.mem.eql(u8, a_col, b_col)) return false;
    }
    return true;
}

/// "schema wants (a, b), database has (a)" — the difference in one sentence,
/// because a drift report that only says "the columns differ" sends the reader
/// back to the database to find out how.
fn indexColumnsDetailAlloc(allocator: std.mem.Allocator, schema_columns: []const []const u8, db_columns: []const []const u8) ![]const u8 {
    var detail = std.array_list.Managed(u8).init(allocator);
    errdefer detail.deinit();

    try detail.appendSlice("schema wants (");
    for (schema_columns, 0..) |col, i| {
        if (i > 0) try detail.appendSlice(", ");
        try detail.appendSlice(col);
    }
    try detail.appendSlice("), database has (");
    for (db_columns, 0..) |col, i| {
        if (i > 0) try detail.appendSlice(", ");
        try detail.appendSlice(col);
    }
    try detail.appendSlice(")");
    return detail.toOwnedSlice();
}

/// "schema declares UNIQUE, database index is not unique" — the difference in
/// one sentence, and **owned** (see `indexColumnsDetailAlloc`).
///
/// Both directions are spelled out because they are not the same news: the
/// first is a constraint the application believes in and does not have, the
/// second is one it never asked for.
fn indexUniquenessDetailAlloc(allocator: std.mem.Allocator, schema_unique: bool, db_unique: bool) ![]const u8 {
    std.debug.assert(schema_unique != db_unique);
    return allocator.dupe(u8, if (schema_unique)
        "schema declares UNIQUE, database index is not unique"
    else
        "schema declares a non-unique index, database index is UNIQUE");
}

/// Which kinds carry an **allocated** `index_detail`, and so must be freed —
/// the two index kinds, whose sentence describes a difference read from the
/// database, and `.missing_foreign_key`, whose sentence names a shape built at
/// runtime. `.unique_constraint`, `.missing_view` and `.missing_junction_table`
/// point the field at a `const`/comptime literal instead and must not be freed,
/// as do the two junction-shape reports of `.missing_column` and
/// `.junction_pair_uniqueness` (their sentence is built from the comptime edge
/// and junction table — see `missingJunctionColumnDetail`); every other kind
/// leaves it empty.
fn ownsIndexDetail(kind: SchemaDrift.Kind) bool {
    return switch (kind) {
        .index_columns, .index_uniqueness, .missing_foreign_key => true,
        else => false,
    };
}

/// Frees one drift entry's owned fields — the `.extra_column` name
/// (`column_owned`) and the detail the kinds `ownsIndexDetail` names — and
/// nothing else; every other field borrows from `infos` or from comptime
/// literals (see `SchemaDrift.column_owned` / `SchemaDrift.index_detail`).
///
/// The per-item half of `freeSchemaDrift`, kept separate because
/// `checkSchema`'s error path and `appendOwnedDrift` need exactly this half:
/// the classification of "what does this entry own" lives here alone.
fn freeDriftOwnedFields(allocator: std.mem.Allocator, d: SchemaDrift) void {
    if (d.column_owned) allocator.free(d.column);
    if (ownsIndexDetail(d.kind)) allocator.free(d.index_detail);
}

/// Frees the slice, the `.extra_column` names it duplicated, and the detail
/// carried by the kinds `ownsIndexDetail` names.
pub fn freeSchemaDrift(allocator: std.mem.Allocator, drifts: []SchemaDrift) void {
    for (drifts) |d| freeDriftOwnedFields(allocator, d);
    allocator.free(drifts);
}

/// Append one drift entry, releasing its freshly allocated owned fields when
/// the `append` itself fails.
///
/// `try drifts.append(.{ .index_detail = try detailAlloc(…) })` allocates the
/// detail **before** the list grows, and the growth is an allocation that can
/// fail: the entry never reaches `drifts.items`, so the caller's error cleanup
/// — which walks exactly that list — cannot see it and the detail leaks.
/// Routing every append that carries an allocation through here makes the error
/// path own the entry from the moment it exists. What "owned" means is read off
/// the entry itself (`column_owned`, `ownsIndexDetail`), the same rule
/// `freeSchemaDrift` applies, so an entry that owns nothing frees nothing.
/// `appendPlanned` is the same shape for the plan list.
fn appendOwnedDrift(
    allocator: std.mem.Allocator,
    drifts: *std.array_list.Managed(SchemaDrift),
    drift: SchemaDrift,
) !void {
    errdefer freeDriftOwnedFields(allocator, drift);
    try drifts.append(drift);
}

/// Assert that the schema and the database agree, for a startup step or a CI
/// job (`migrateSchema`'s own report never runs for a consumer whose DDL is a
/// set of `.sql` files).
pub fn assertSchema(
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
    comptime infos: []const TypeInfo,
    strictness: DriftStrictness,
) (sql_driver.Error || error{ SchemaDrift, UnsupportedDialect, InvalidTableName, IndexCatalogUnavailable, ForeignKeyCatalogUnavailable })!void {
    const drifts = try checkSchema(allocator, driver, infos);
    defer freeSchemaDrift(allocator, drifts);
    for (drifts) |d| {
        if (strictness == .read_breaking_only and !d.breaksReads()) continue;
        zent_log.warn("zent: schema drift on {s}.{s}: {s}{s}{s}", .{
            d.table,
            if (d.column.len > 0)
                d.column
            else if (d.index_name.len > 0)
                d.index_name
            else if (d.kind == .missing_view)
                "(view)"
                // Both junction kinds: the relation's absence, and the pair nothing
                // keys. `table` carries no column for either, so without this branch
                // the line would read "(table)" for a junction table.
            else if (d.kind == .missing_junction_table or d.kind == .junction_pair_uniqueness)
                "(junction)"
            else
                "(table)",
            @tagName(d.kind),
            if (d.index_detail.len > 0) " — " else "",
            d.index_detail,
        });
        return error.SchemaDrift;
    }
}

/// Compare every column's nullability between `infos` and the live database.
///
/// Returns a caller-owned slice (free with `freeNullabilityDrift`) of the
/// differences; empty means they agree. Columns named in the schema but absent
/// from the database are not reported — that is `migrateSchema`'s job — so this
/// answers exactly one question: *where do the two disagree about NULL?*
pub fn checkNullability(
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
    comptime infos: []const TypeInfo,
) ![]NullabilityDrift {
    // One traversal, two views: `checkSchema` is the implementation, this is the
    // nullability projection of it, kept because that is the shape its callers
    // (and `assertNullability`) already use.
    const drifts = try checkSchema(allocator, driver, infos);
    defer freeSchemaDrift(allocator, drifts);

    var out = std.array_list.Managed(NullabilityDrift).init(allocator);
    errdefer out.deinit();
    for (drifts) |d| {
        if (d.kind != .nullability) continue;
        try out.append(.{
            .table = d.table,
            .column = d.column,
            .schema_optional = d.schema_optional,
            .db_nullable = d.db_nullable,
        });
    }
    return out.toOwnedSlice();
}

/// `db_nullable = NOT not_null`, spelled out because `pk` counts as non-nullable
/// on SQLite even though `PRAGMA table_info` may report otherwise.
fn db_nullableOf(col: ExistingColumn) bool {
    return !col.not_null and !col.pk;
}

pub fn freeNullabilityDrift(allocator: std.mem.Allocator, drifts: []NullabilityDrift) void {
    allocator.free(drifts);
}

/// How much disagreement `assertNullability` refuses to ship.
pub const DriftStrictness = enum {
    /// Only the direction that breaks reads: the database allows NULL where the
    /// schema declares a non-optional field. The other direction makes a NULL
    /// insert fail, which is loud, and blocking a deploy for it is usually not
    /// what you want.
    read_breaking_only,
    /// Any difference at all.
    any,
};

pub const NullabilityError = sql_driver.Error || error{ NullabilityDrift, UnsupportedDialect, InvalidTableName, IndexCatalogUnavailable, ForeignKeyCatalogUnavailable };

/// The same check as `checkNullability`, as a **gate** rather than a side
/// effect: fails with `error.NullabilityDrift` instead of writing a log line.
///
/// This exists because the automatic report inside `migrateSchema` only reaches
/// a consumer that calls `migrateSchema` — one whose DDL is a Flyway-style set
/// of `.sql` files never does, so the check it wants could never fire. Calling
/// this from a startup step or a CI job makes it a decision instead.
///
/// ```zig
/// try zent.sql_schema.assertNullability(allocator, drv.asDriver(), infos, .read_breaking_only);
/// ```
///
/// On failure the drift is also logged (the detail at `debug`), because an error
/// name alone does not say which column.
pub fn assertNullability(
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
    comptime infos: []const TypeInfo,
    strictness: DriftStrictness,
) NullabilityError!void {
    const drifts = try checkNullability(allocator, driver, infos);
    defer freeNullabilityDrift(allocator, drifts);

    var violating: usize = 0;
    for (drifts) |d| {
        if (strictness == .read_breaking_only and !d.breaksReads()) continue;
        violating += 1;
    }
    if (violating == 0) return;
    reportNullabilityDrift(drifts);
    return error.NullabilityDrift;
}

/// Report nullability drift without flooding a startup log.
///
/// One summary line at `warn` — enough to notice that the database and the
/// schema disagree — and the per-column detail at `debug`, because a legacy
/// database can disagree about hundreds of columns and a wall of warnings is
/// read by nobody. `checkNullability` is the API for the full list.
///
/// The count that matters is `breaksReads`: those are the columns that turn
/// into a runtime `error.TypeMismatch` when a NULL turns up.
fn reportNullabilityDrift(drifts: []const NullabilityDrift) void {
    if (drifts.len == 0) return;
    var breaking: usize = 0;
    for (drifts) |d| {
        if (d.breaksReads()) breaking += 1;
        zent_log.debug(
            "zent: nullability drift on {s}.{s}: schema says {s}, database says {s}",
            .{
                d.table,
                d.column,
                if (d.schema_optional) "NULL allowed" else "NOT NULL",
                if (d.db_nullable) "NULL allowed" else "NOT NULL",
            },
        );
    }
    zent_log.warn(
        "zent: {d} column(s) differ in nullability between the schema and the database{s}; call sql_schema.checkNullability for the list",
        .{
            drifts.len,
            if (breaking > 0)
                ", and reads will fail on existing NULLs in some of them"
            else
                "",
        },
    );
}

/// CREATE TABLE statement for the migration history table.
/// Works on SQLite, PostgreSQL, and MySQL.
const migrationsTableSQL =
    "CREATE TABLE IF NOT EXISTS zent_schema_migrations (" ++
    "version INTEGER PRIMARY KEY, " ++
    "applied_at INTEGER NOT NULL, " ++
    "checksum TEXT)";

/// Ensure the migration history table exists. Idempotent at the SQL level.
fn ensureMigrationsTable(drv: sql_driver.Driver) !void {
    _ = try drv.exec(migrationsTableSQL, &.{});
}

/// Returns true if `sql_type` is an integer type that supports AUTO_INCREMENT in MySQL.
fn isMySqlAutoIncrementType(sql_type: []const u8) bool {
    const types = &[_][]const u8{ "INTEGER", "INT", "BIGINT", "SMALLINT", "TINYINT", "MEDIUMINT" };
    for (types) |t| {
        if (std.ascii.eqlIgnoreCase(sql_type, t)) return true;
    }
    return false;
}

/// MySQL's BLOB/TEXT/JSON family, spelled in lower case for a
/// case-insensitive comparison.
const mysql_blob_text_json_types = [_][]const u8{
    "text", "tinytext", "mediumtext", "longtext",
    "blob", "tinyblob", "mediumblob", "longblob",
    "json",
};

/// True when `sql_type` is in MySQL's BLOB/TEXT/JSON family.
///
/// These are the types MySQL refuses to use in a key specification without a
/// key length (errno 1170, `BLOB/TEXT column used in key specification
/// without a key length`) and — the TEXT and BLOB members — refuses to give a
/// literal `DEFAULT` (errno 1101). PostgreSQL and SQLite have neither
/// restriction, which is why `field.Text` keeps mapping to `TEXT` on every
/// dialect (`src/core/field.zig`): the difference is diagnosed here, at DDL
/// generation, instead of being papered over in the type mapping.
///
/// A parenthesized modifier (`TEXT(100)`, `BLOB(16)`) is ignored, the same
/// way `normalizeSqlType` ignores it.
fn isMySqlBlobTextJsonType(sql_type: []const u8) bool {
    var base = sql_type;
    if (std.mem.indexOfScalar(u8, base, '(')) |paren| base = base[0..paren];
    base = std.mem.trimEnd(u8, base, " ");
    for (mysql_blob_text_json_types) |candidate| {
        if (std.ascii.eqlIgnoreCase(base, candidate)) return true;
    }
    return false;
}

/// Which server is behind a `.mysql`-kind connection, for the DDL rules the two
/// server families do not share.
///
/// MySQL and MariaDB speak the same wire protocol and share the errno
/// numbering, but not every rule: **MariaDB >= 10.2.1 accepts a `DEFAULT` on a
/// BLOB/TEXT column**, which MySQL refuses with errno 1101 (the column cannot
/// have a default value). Everything else `findMySqlTextRestriction` classifies
/// — the key-length restriction behind errno 1170 — is refused by both, so it is
/// the same on either server.
///
/// The name is derived once per migration from `SELECT VERSION()` (see
/// `detectMySqlServer`) and threaded through the DDL generators, so a preview
/// and the run it previews classify identically.
pub const MySqlServer = enum {
    /// MySQL — or a server that could not be identified, which is deliberately
    /// treated as MySQL so an unknown server never gets a rule relaxed for it.
    mysql,
    /// MariaDB, identified by "MariaDB" in `SELECT VERSION()`.
    mariadb,
};

/// The named errors a MySQL BLOB/TEXT/JSON restriction turns into.
///
/// Two names rather than one `MySQLTextColumnRestriction`, because they have
/// different fixes and different blast radii: a stray `DEFAULT` is dropped
/// from the declaration, while a key constraint has to move off the column
/// (usually to `field.String`, which is `VARCHAR(255)` on MySQL). A caller
/// switching on the error can tell the two apart; the unified name would fold
/// that back into a log line. Neither name can carry the table/column, which
/// is why the generator logs the detail (`MySqlTextRestriction`) before
/// returning.
pub const MySqlTextError = error{
    MySQLTextColumnCannotHaveDefault,
    MySQLTextColumnCannotBeIndexed,
};

/// The three ways a declared index method/opclass can be malformed. They are
/// raised while the DDL is generated, so every entry point that builds tables
/// carries them (`createTables` / `createAllTables` / the planner) and the
/// codegen client re-states this set in `CreateTablesError`.
pub const IndexDeclError = error{
    /// The `method` (or its `opclass`) is not a bare identifier — the DDL
    /// concatenates it verbatim, so anything else would be an injection hole.
    InvalidIndexMethod,
    InvalidIndexOpClass,
    /// A PostgreSQL opclass describes *one* indexed column
    /// (`(embedding vector_cosine_ops)`); declaring it over a multi-column
    /// index has no legal rendering.
    OpClassNeedsSingleColumn,
};

/// The named error a migration returns when a declared column type needs a
/// PostgreSQL extension this database does not have installed.
///
/// One name rather than one per extension: the fix is the same statement in
/// every case (`CREATE EXTENSION IF NOT EXISTS <name>`), and which extension is
/// missing is what the log line the check emits before returning carries — an
/// error tag cannot.
pub const PostgresExtensionError = error{
    /// The schema declares a column type provided by an extension
    /// (`vector(n)`, `citext`, `hstore`, `ltree`, PostGIS's `geometry` /
    /// `geography`) and `pg_extension` does not list that extension. Raised
    /// *before* any DDL, so the run leaves the database exactly as it was.
    MissingPostgresExtension,
};

/// A restriction MySQL puts on a BLOB/TEXT/JSON column that the DDL about to
/// be generated would trip.
///
/// The error carries no payload, so this is both the detail the generator logs
/// and the shape a caller can inspect *before* generating (via
/// `findMySqlTextRestriction`) when it wants to decide rather than fail.
pub const MySqlTextRestriction = struct {
    table: []const u8,
    column: []const u8,
    /// The column's MySQL type as `columnSQLType` resolves it (e.g. `TEXT`).
    sql_type: []const u8,
    kind: Kind,
    /// Set only for `.index`: the index whose key list names `column`.
    index_name: []const u8 = "",

    pub const Kind = enum {
        /// `DEFAULT` on the column — errno 1101.
        default_value,
        /// `UNIQUE` on the column — errno 1170.
        unique,
        /// `PRIMARY KEY`, inline or listed in a composite `PRIMARY KEY (...)` —
        /// errno 1170.
        primary_key,
        /// A key column of a `CREATE INDEX` — errno 1170.
        index,
    };
};

fn nameInList(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn columnDefByName(table: TableDef, name: []const u8) ?ColumnDef {
    for (table.columns) |col| {
        if (std.mem.eql(u8, col.name, name)) return col;
    }
    return null;
}

/// Scan the DDL a caller is *about to emit* — the column definitions of
/// `table`, plus `indexes` — for the first restriction MySQL puts on a
/// BLOB/TEXT/JSON column, or null when there is none.
///
/// Pure: no allocation, no connection, no database. Returns null for every
/// dialect but MySQL, whose restriction this is.
///
/// The rules applied are **MySQL's**, the stricter of the two server families:
/// a caller that knows it is talking to MariaDB (and only such a caller can
/// know, see `detectMySqlServer`) uses `findMySqlTextRestrictionWithServer`,
/// which drops the `DEFAULT` restriction on MariaDB >= 10.2.1. This spelling
/// stays the default so an unidentified server is never given the relaxed rule.
///
/// Each caller passes exactly what its statement contains:
/// `createTableSQLAlloc` passes the table's columns and no indexes (a table
/// statement never emits `table.indexes`, and rejecting a table that already
/// exists because of an index it will not create would turn a no-op into a
/// failed deploy), and `createIndexSQLForTableAlloc` passes the one index it
/// is about to emit. That keeps the check honest about the SQL it precedes.
pub fn findMySqlTextRestriction(table: TableDef, indexes: []const IndexDef, dialect: Dialect) ?MySqlTextRestriction {
    return findMySqlTextRestrictionWithServer(table, indexes, dialect, .mysql);
}

/// `findMySqlTextRestriction`, told which server the statement is for.
///
/// `server` is consulted for exactly one kind: `.default_value`. MariaDB has
/// accepted a `DEFAULT` on a BLOB/TEXT/JSON column since 10.2.1, so on
/// `.mariadb` that column is not a restriction and the scan moves on — a
/// column that is *also* UNIQUE (or a PRIMARY KEY, or a key of an index) is
/// still reported, because the key-length rule is shared. On `.mysql` this is
/// byte-for-byte `findMySqlTextRestriction`'s answer.
pub fn findMySqlTextRestrictionWithServer(
    table: TableDef,
    indexes: []const IndexDef,
    dialect: Dialect,
    server: MySqlServer,
) ?MySqlTextRestriction {
    if (dialect.kind() != .mysql) return null;

    for (table.columns) |col| {
        const sql_type = columnSQLType(col, dialect);
        if (!isMySqlBlobTextJsonType(sql_type)) continue;
        const kind: MySqlTextRestriction.Kind = if (col.default_value != null and server == .mysql)
            .default_value
        else if (col.unique and !col.primary_key)
            .unique
        else if (col.primary_key or nameInList(table.primary_keys, col.name))
            .primary_key
        else
            continue;
        return .{ .table = table.name, .column = col.name, .sql_type = sql_type, .kind = kind };
    }

    for (indexes) |idx| {
        for (idx.columns) |index_column| {
            const col = columnDefByName(table, index_column) orelse continue;
            const sql_type = columnSQLType(col, dialect);
            if (isMySqlBlobTextJsonType(sql_type)) {
                return .{
                    .table = table.name,
                    .column = index_column,
                    .sql_type = sql_type,
                    .kind = .index,
                    .index_name = idx.name,
                };
            }
        }
    }
    return null;
}

/// Identify the server behind a `.mysql`-kind connection from
/// `SELECT VERSION()`, or answer `.mysql` when it cannot be identified.
///
/// This is the one probe that lets the DDL layer tell MySQL and MariaDB apart
/// (they share the errno numbering but not every rule — see `MySqlServer`), and
/// it runs once per migration, on the same connection the introspection uses.
///
/// **Failures are conservative and never propagate.** A server that refuses the
/// query — no privilege, a connection mid-failure, a proxy that answers
/// something else — is treated as MySQL, so an unidentified server keeps every
/// restriction and never has one relaxed for it. Each failure logs a `warn`
/// naming the reason, so an operator sees why a MariaDB deploy still writes
/// MySQL-shaped DDL. The function has no error return on purpose: this probe is
/// not a step a migration can fail on. It is also read-only (`query`, never
/// `exec`), so the dry run can call the same code path.
fn detectMySqlServer(drv: sql_driver.Driver) MySqlServer {
    var rows = drv.query("SELECT VERSION()", &.{}) catch |err| {
        zent_log.warn(
            "zent: could not identify the MySQL/MariaDB server ({s}); applying MySQL's stricter BLOB/TEXT rules",
            .{@errorName(err)},
        );
        return .mysql;
    };
    defer rows.deinit();
    const row = rows.next() orelse {
        const reason = if (rows.nextError()) |err| @errorName(err) else "no rows";
        zent_log.warn(
            "zent: could not identify the MySQL/MariaDB server ({s}); applying MySQL's stricter BLOB/TEXT rules",
            .{reason},
        );
        return .mysql;
    };
    const version = row.getText(0) orelse {
        zent_log.warn(
            "zent: could not identify the MySQL/MariaDB server (SELECT VERSION() answered no text); applying MySQL's stricter BLOB/TEXT rules",
            .{},
        );
        return .mysql;
    };
    return classifyMySqlServer(version);
}

/// The classification half of `detectMySqlServer`, split out so the spelling
/// MariaDB is recognised by is pinned without a server: MariaDB's version
/// strings read `10.11.6-MariaDB-1~deb12u1` and MySQL's `9.7.0`. The substring
/// is the same one `tests/integration/mysql.zig`'s `isMariaDB` looks for.
fn classifyMySqlServer(version: []const u8) MySqlServer {
    return if (std.mem.indexOf(u8, version, "MariaDB") != null) .mariadb else .mysql;
}

/// Whether any table this plan can emit a `DEFAULT` for declares a
/// BLOB/TEXT/JSON column on MySQL — the one shape where MySQL and MariaDB
/// disagree, and therefore the only shape for which identifying the server can
/// change the SQL.
///
/// Pure and comptime: a schema whose text columns carry no `DEFAULT` produces
/// the same statements on both servers, so it is not worth a catalog round trip
/// to ask which one is there. The probe is then skipped and the MySQL rules are
/// used, which is exactly what the generators do with `.mysql` anyway. (The
/// statement-modelling stub tests in `src/test/allocation_failures_plan.zig`
/// depend on this: an unannounced `SELECT VERSION()` would be a statement they
/// never claimed.)
fn graphHasMySqlTextDefault(comptime infos: []const TypeInfo) bool {
    inline for (infos) |info| {
        if (info.is_view) continue;
        const table = comptime tableFromTypeInfoCrossRef(info, infos);
        inline for (table.columns) |col| {
            if (col.default_value == null) continue;
            if (isMySqlBlobTextJsonType(columnSQLType(col, Dialect.mysql))) return true;
        }
    }
    return false;
}

/// A PostgreSQL column type whose *provider is an extension*, and the extension
/// that provides it.
///
/// Deliberately small and exact. `zent` cannot ask a server "which extension
/// owns this type?" before the type exists, so the only safe default is silence:
/// a name this table does not know is not an extension type as far as the check
/// is concerned, and the migration proceeds exactly as it did before the check
/// existed. Guessing the other way would refuse a migration that would have
/// worked.
const PostgresExtensionType = struct {
    /// The declared type's bare name, lower case.
    declared_type: []const u8,
    /// The extension that provides it — also the name `CREATE EXTENSION` takes
    /// (pgvector's extension is `vector`, PostGIS's is `postgis`).
    extension: []const u8,
};

/// The known type → extension pairs: PostgreSQL's own types are all built in,
/// so what is left is the extension types a schema realistically declares.
///
/// `vector` is the one a `field.Vector` reaches (its spelling is `vector(n)`,
/// and the dimension is stripped before the lookup); the rest arrive through
/// `.SqlType(s)` / `field.Other(name, s)`, which on PostgreSQL is emitted
/// verbatim and can therefore name anything.
const postgres_extension_types = [_]PostgresExtensionType{
    .{ .declared_type = "vector", .extension = "vector" }, // pgvector
    .{ .declared_type = "citext", .extension = "citext" },
    .{ .declared_type = "hstore", .extension = "hstore" },
    .{ .declared_type = "ltree", .extension = "ltree" },
    .{ .declared_type = "geometry", .extension = "postgis" },
    .{ .declared_type = "geography", .extension = "postgis" },
    // Not a type PostGIS defines (`geometry` and `geography` are), but a
    // declaration that says `postgis` is asking for the same extension and
    // deserves the same diagnosis rather than silence.
    .{ .declared_type = "postgis", .extension = "postgis" },
};

/// The bare type name a declaration starts with: `vector(1536)` → `vector`,
/// `public.citext` → `citext`, `hstore[]` → `hstore`.
///
/// The declaration is what the schema wrote, so it carries everything a type
/// reference may: a schema qualifier, a dimension/scale, an array marker. Only
/// the bare name is comparable to the table above. Pure, so the decision can be
/// pinned without a server.
fn bareDeclaredType(declared: []const u8) []const u8 {
    var name = std.mem.trim(u8, declared, " \t");
    // A schema qualifier. The *last* dot, because a quoted qualifier may itself
    // contain one.
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name = name[dot + 1 ..];
    var end = name.len;
    if (std.mem.indexOfScalar(u8, name, '(')) |paren| end = @min(end, paren);
    if (std.mem.indexOfScalar(u8, name, '[')) |bracket| end = @min(end, bracket);
    return std.mem.trim(u8, name[0..end], " \t");
}

/// The extension a declared column type needs, or `null` when the name is not
/// one this module knows — the common answer, since it covers every type
/// PostgreSQL itself provides.
fn postgresExtensionForDeclaredType(declared: []const u8) ?[]const u8 {
    const bare = bareDeclaredType(declared);
    if (bare.len == 0) return null;
    for (postgres_extension_types) |entry| {
        if (std.ascii.eqlIgnoreCase(bare, entry.declared_type)) return entry.extension;
    }
    return null;
}

/// Every PostgreSQL extension this graph's *declarations* need, deduplicated,
/// in first-seen order.
///
/// Pure and comptime, so a schema that needs none answers with an empty list and
/// the catalog is never asked. That is the same rule `graphHasMySqlTextDefault`
/// follows and for the same reason: the statement-modelling stubs in
/// `src/test/allocation_failures_plan.zig` claim every statement the planner
/// issues, so a probe a schema did not warrant must not be issued at all.
///
/// Two declarations can need one. A `field.Vector` column always needs pgvector
/// (its `vector(n)` type is the extension's), and an explicit `.SqlType(s)` /
/// `field.Other(name, s)` override may name an extension type — it is emitted
/// The `comptime` branch budget a schema-shaped helper needs, **scaled by the
/// graph** rather than fixed.
///
/// A constant is the wrong shape for these loops: they are per table × per
/// field, and the cross-reference helpers add per table × per table again, so a
/// 2-table test graph and a 154-table consumer differ by orders of magnitude —
/// and the side that fails is the one that cannot see this file. A caller's own
/// `@setEvalBranchQuota` cannot help either: the innermost quota on an
/// evaluation path wins, and the failing evaluation happens *inside* these
/// private functions. Measured on a 154-table, ~15-field-per-table schema: the
/// default 1000 tripped in `requiredPostgresExtensions` (which had no quota at
/// all) and the fixed 50_000 tripped in `tableFromTypeInfoCrossRef`.
///
/// The quota is a ceiling, never work: raising it costs nothing when it is not
/// reached, which is why the base matches the codegen modules' 1_000_000 rather
/// than something tuned to today's graph sizes.
fn evalQuotaFor(comptime infos: []const TypeInfo) u32 {
    const n: u32 = @intCast(infos.len);
    return 1_000_000 + n * 20_000;
}

/// verbatim on PostgreSQL. The built-in field kinds cannot: `field.Json` is
/// `JSONB`, `field.Bytes` is `BYTEA`, and every other kind maps to a type
/// PostgreSQL owns.
fn requiredPostgresExtensions(comptime infos: []const TypeInfo) []const []const u8 {
    comptime {
        @setEvalBranchQuota(evalQuotaFor(infos));
        var needed: []const []const u8 = &.{};
        for (infos) |info| {
            if (info.is_view) continue;
            for (info.fields) |f| {
                const extension: ?[]const u8 = blk: {
                    if (f.field_type == .vector) break :blk "vector";
                    if (f.sql_type_override) |override| break :blk postgresExtensionForDeclaredType(override);
                    break :blk null;
                };
                const name = extension orelse continue;
                var seen = false;
                for (needed) |existing| {
                    if (std.mem.eql(u8, existing, name)) seen = true;
                }
                if (!seen) needed = needed ++ &[_][]const u8{name};
            }
        }
        return needed;
    }
}

/// `requiredPostgresExtensions` as one comma-separated string, for the warning
/// `checkPostgresExtensions` emits when the catalog cannot be read: the
/// returned value carries no text, so the line has to name what was asked
/// about. Pure and comptime, like the list it renders.
fn requiredExtensionsJoined(comptime infos: []const TypeInfo) []const u8 {
    comptime {
        @setEvalBranchQuota(evalQuotaFor(infos));
        var out: []const u8 = "";
        for (requiredPostgresExtensions(infos), 0..) |name, i| {
            if (i > 0) out = out ++ ", ";
            out = out ++ name;
        }
        return out;
    }
}

/// The opening of `pgRelationListed`'s statement.
///
/// Named once and used by both the producer and the stubs that answer it
/// (`ExtensionStub`, `PostgresIndexCatalogStub`, and the catalog stub in
/// `src/test/allocation_failures_plan.zig`), because the catalog queries
/// themselves join `pg_class` — a stub keying on that substring alone would
/// answer the *index read* with the probe's `count(*)` row and look, from the
/// test's side, exactly like a probe asked twice. `pub` for that third stub;
/// nothing outside the tests reads it.
pub const pg_relation_probe_prefix = "SELECT count(*) FROM pg_class WHERE relname";

/// Whether `pg_class` lists the relation `name` — the probe that decides
/// whether a PostgreSQL-catalog query may be sent at all.
///
/// **Why a probe rather than a retry.** A rejected statement aborts the
/// transaction it runs in on every PostgreSQL-compatible server ("current
/// transaction is aborted, commands ignored until end of transaction block"),
/// and this introspection runs inside the caller's migration transaction — so
/// recovering from the rejection is not recovery: the migration would carry on
/// over a dead transaction and fail somewhere else entirely (measured against
/// HeliosDB Nano, which refuses `pg_am` with SQLSTATE 42P01 *and* leaves the
/// transaction unusable). Asking a question that cannot fail keeps the decision
/// ahead of the damage: `pg_class` is the one catalog both full PostgreSQL and
/// the wire-compatible servers that lack the rest do have.
///
/// **One relation at a time, because the answer is per relation.** A
/// wire-compatible server may have the table and still not list it here —
/// HeliosDB Nano answers 0 for `pg_index` while `SELECT count(*) FROM pg_index`
/// returns its real rows — so a probe asking about several names at once would
/// read "none of them" and throw away reads that would have worked. The two
/// names asked about in this module are exactly the ones whose *absence* is
/// what has to be known in advance: `pg_am` (the join `getPostgresIndexes`
/// cannot send when it is missing) and `pg_extension` (the catalog
/// `checkPostgresExtensions` cannot read).
///
/// The statement is assembled rather than bound, and `name` is a `comptime`
/// parameter, so the literal is this module's own constant and never caller
/// input — a bind list could not spell `relname = '…'` either.
///
/// Conservative by construction: any problem reading `pg_class` — including
/// being inside an already-aborted transaction — answers "not listed", so the
/// caller drops to the reading that does not need it rather than assuming it is
/// there.
fn pgRelationListed(drv: sql_driver.Driver, comptime name: []const u8) bool {
    const sql = comptime pg_relation_probe_prefix ++ " = '" ++ name ++ "'";
    var rows = drv.query(sql, &.{}) catch return false;
    defer rows.deinit();
    const row = rows.next() orelse return false;
    const n = row.getInt(0) orelse return false;
    return n > 0;
}

/// Refuse a PostgreSQL migration whose schema declares a type this database has
/// no extension for — **before any DDL**, so the caller gets one named error
/// instead of `ERROR: type "vector" does not exist` from the middle of a
/// `CREATE TABLE`, with no way to tell a missing extension from a typo.
///
/// Never probed unless the schema needs something (`requiredPostgresExtensions`
/// is empty for a graph built from the built-in field kinds), and never on
/// another dialect — `pg_extension` is PostgreSQL's own catalog.
///
/// Only *installed* extensions count. An extension that is merely available
/// still needs a `CREATE EXTENSION` the caller has to run, and doing it here
/// would be a schema change outside the plan, with privileges the migration has
/// no business assuming — so the fix is stated and the decision stays with the
/// caller.
///
/// **A server with no `pg_extension` is not a server without the type.** The
/// catalog is how the check proves an extension is *missing*; it is not the
/// only way the type can exist. A wire-compatible server may carry the type
/// natively (HeliosDB Nano has no `pg_extension` at all and yet provides
/// `vector`), and refusing the migration on a catalog it does not have would
/// block a schema that would migrate perfectly — the opposite of what this
/// check is for. Two things therefore answer "this server cannot be asked":
///
/// - The **catalog is not listed** (`pgRelationListed`): the query is never
///   sent, one warning says so, and the run continues. This is the path a
///   wire-compatible server takes, and the reason the read is gated at all —
///   sending it anyway would abort the caller's transaction and turn one
///   unknown capability into a migration that dies somewhere unrelated.
/// - The catalog *is* listed and the **statement is rejected** anyway (SQLSTATE
///   42P01, which reaches this function as `error.ExecFailed` or as the
///   `error.DriverFailed` PostgreSQL's driver maps it to, both of them
///   `postgresStatementRefused`): warned the same way and the run continues.
///   Kept as a safety net behind the gate rather than as the mechanism, because
///   by the time it fires the transaction it ran in is already dead.
///
/// Either way the declared types go to the server as declared, and a server
/// that really cannot provide them answers its own, louder error at the
/// `CREATE TABLE`. Every other failure — a lost connection, a protocol error —
/// still propagates, because the check cannot tell "no catalog" from "no
/// connection" for those and guessing would be worse than failing.
fn checkPostgresExtensions(drv: sql_driver.Driver, comptime infos: []const TypeInfo) !void {
    if (drv.dialect().kind() != .postgres) return;
    const required = comptime requiredPostgresExtensions(infos);
    if (required.len == 0) return;

    // Ahead of the query: a rejection here would abort the caller's transaction
    // (see `pgRelationListed`), so a server that does not carry the catalog is
    // answered without asking it the question that would fail.
    if (!pgRelationListed(drv, "pg_extension")) {
        zent_log.warn(
            "zent: cannot verify the PostgreSQL extension(s) this schema declares ({s}) — this server does not list `pg_extension` in its catalog; the declared types are sent to the server as declared, which a server without that catalog may well provide natively",
            .{comptime requiredExtensionsJoined(infos)},
        );
        return;
    }

    // One bit per required extension. Every member of `required` came out of
    // `postgres_extension_types`, so the table's length bounds the index.
    var installed: [postgres_extension_types.len]bool = @splat(false);
    var rows = drv.query("SELECT extname FROM pg_extension", &.{}) catch |err| {
        if (!postgresStatementRefused(err)) return err;
        // Warned, with what was asked and what came back: the returned value is
        // `void`, so this line is the only trace of the check having been
        // skipped. `{s}` for the declared types so the reader knows which
        // `CREATE TABLE` is now on its own — and the last sentence names why
        // that is often fine.
        zent_log.warn(
            "zent: cannot verify the PostgreSQL extension(s) this schema declares ({s}) — `SELECT extname FROM pg_extension` failed with {s}; the declared types are sent to the server as declared, which a server without that catalog may well provide natively",
            .{ comptime requiredExtensionsJoined(infos), @errorName(err) },
        );
        return;
    };
    defer rows.deinit();
    while (rows.next()) |row| {
        const name = row.getText(0) orelse continue;
        for (required, 0..) |want, i| {
            if (std.ascii.eqlIgnoreCase(name, want)) installed[i] = true;
        }
    }
    // A fetch that broke is not "the extension is missing": a reader that skips
    // this reports a short result set as a successful one.
    if (rows.nextError()) |err| return err;

    for (required, 0..) |want, i| {
        if (installed[i]) continue;
        zent_log.warn(
            "zent: the schema declares a column type provided by the PostgreSQL extension '{s}', which this database does not have installed; run `CREATE EXTENSION IF NOT EXISTS {s};` and migrate again",
            .{ want, want },
        );
        return error.MissingPostgresExtension;
    }
}

/// Log what the error name cannot carry — which table, which column, which
/// type, and why MySQL refuses — and return the matching named error.
///
/// `warn` and not `err`, so a consumer whose log handling treats `err` as
/// fatal does not die on a diagnostic the caller is about to see as a returned
/// error anyway.
fn reportMySqlTextRestriction(restriction: MySqlTextRestriction) MySqlTextError {
    switch (restriction.kind) {
        .default_value => zent_log.warn(
            "zent: MySQL rejects a DEFAULT on {s}.{s} ({s}, errno 1101: BLOB/TEXT/JSON cannot have a default value); use field.String (VARCHAR(255) on MySQL) or drop the default",
            .{ restriction.table, restriction.column, restriction.sql_type },
        ),
        .unique => zent_log.warn(
            "zent: MySQL cannot index {s}.{s} ({s}, errno 1170: BLOB/TEXT/JSON key specification without a key length), so its UNIQUE constraint has no DDL; use field.String (VARCHAR(255) on MySQL) or drop the uniqueness",
            .{ restriction.table, restriction.column, restriction.sql_type },
        ),
        .primary_key => zent_log.warn(
            "zent: MySQL cannot index {s}.{s} ({s}, errno 1170: BLOB/TEXT/JSON key specification without a key length), so it cannot be a PRIMARY KEY; use field.String or a narrower type",
            .{ restriction.table, restriction.column, restriction.sql_type },
        ),
        .index => zent_log.warn(
            "zent: MySQL cannot index {s}.{s} ({s}, errno 1170: BLOB/TEXT/JSON key specification without a key length), so index {s} cannot be created; use field.String (VARCHAR(255) on MySQL) or drop the column from the index",
            .{ restriction.table, restriction.column, restriction.sql_type, restriction.index_name },
        ),
    }
    return switch (restriction.kind) {
        .default_value => error.MySQLTextColumnCannotHaveDefault,
        .unique, .primary_key, .index => error.MySQLTextColumnCannotBeIndexed,
    };
}

/// Build the dialect-appropriate INSERT statement for recording a migration.
/// SQLite and MySQL use `?` placeholders; PostgreSQL uses `$1, $2, $3`.
/// The statement tolerates duplicate versions so that re-running a migration
/// after a table has been dropped out-of-band doesn't blow up the whole batch.
fn buildRecordInsertSQL(dialect: Dialect, buf: []u8) ![]const u8 {
    const p1 = try dialect.placeholder(buf[0..32], 1);
    const p2 = try dialect.placeholder(buf[32..64], 2);
    const p3 = try dialect.placeholder(buf[64..96], 3);
    const suffix: []const u8 = switch (dialect.kind()) {
        // SQLite and an unnamed dialect both take the ON CONFLICT clause.
        .postgres, .sqlite, .unknown => " ON CONFLICT (version) DO NOTHING",
        .mysql => "",
    };
    const mysql_suffix: []const u8 = switch (dialect.kind()) {
        .mysql => " ON DUPLICATE KEY UPDATE applied_at = applied_at",
        .sqlite, .postgres, .unknown => "",
    };
    return std.fmt.bufPrint(
        buf[96..],
        "INSERT INTO zent_schema_migrations (version, applied_at, checksum) VALUES ({s}, {s}, {s}){s}{s}",
        .{ p1, p2, p3, suffix, mysql_suffix },
    );
}

/// Build the dialect-appropriate SELECT statement for listing applied
/// migrations. The checksum column may be NULL (schema-diff migrations and
/// rows written before checksums existed).
fn buildListVersionsSQL(dialect: Dialect, buf: []u8) ![]const u8 {
    _ = dialect;
    return std.fmt.bufPrint(buf, "SELECT version, checksum FROM zent_schema_migrations ORDER BY version", .{});
}

/// One row of the migration history table.
pub const AppliedMigration = struct {
    version: i64,
    /// Recorded checksum. NULL for schema-diff migrations (their DDL is
    /// generated at runtime, so there is no stable content to hash) and for
    /// rows written before checksum verification existed.
    checksum: ?[]u8,
};

/// Read all applied migrations, ordered ascending. Each non-null `checksum`
/// is owned by the returned slice; free with `freeAppliedMigrations`.
fn appliedMigrations(allocator: std.mem.Allocator, drv: sql_driver.Driver) ![]AppliedMigration {
    var sql_buf: [256]u8 = undefined;
    const sql = try buildListVersionsSQL(drv.dialect(), &sql_buf);
    var rows = try drv.query(sql, &.{});
    defer rows.deinit();
    var list = std.array_list.Managed(AppliedMigration).init(allocator);
    errdefer {
        for (list.items) |m| if (m.checksum) |c| allocator.free(c);
        list.deinit();
    }
    while (rows.next()) |row| {
        const version = row.getInt(0) orelse continue;
        const checksum: ?[]u8 = if (row.getText(1)) |t| try allocator.dupe(u8, t) else null;
        try list.append(.{ .version = version, .checksum = checksum });
    }
    return list.toOwnedSlice();
}

fn freeAppliedMigrations(allocator: std.mem.Allocator, applied: []AppliedMigration) void {
    for (applied) |m| if (m.checksum) |c| allocator.free(c);
    allocator.free(applied);
}

/// Insert a row into the migration history table.
fn recordMigration(drv: sql_driver.Driver, version: i64, checksum: ?[]const u8) !void {
    const now = unixTimestamp();
    var sql_buf: [384]u8 = undefined;
    const sql = try buildRecordInsertSQL(drv.dialect(), &sql_buf);
    _ = try drv.exec(
        sql,
        &.{
            .{ .int = version },
            .{ .int = now },
            if (checksum) |c| .{ .string = c } else .null,
        },
    );
}

/// True when `version` is already recorded in the history table.
fn versionContains(applied: []const AppliedMigration, version: i64) bool {
    for (applied) |m| {
        if (m.version == version) return true;
    }
    return false;
}

/// Advisory lock key for PostgreSQL cross-process migration exclusion.
/// ASCII "zent_mig" packed into an i64; exposed so tests can contend for the
/// same lock.
pub const advisory_lock_key: i64 = 0x7A65_6E74_5F6D6967;

/// Lock name used by MySQL's GET_LOCK/RELEASE_LOCK.
pub const mysql_lock_name = "zent_schema_migration";

const MigrationLockError = sql_driver.Error || error{MigrationLockTimeout};

const timespec = extern struct { tv_sec: c_long, tv_nsec: c_long };
extern fn nanosleep(req: *const timespec, rem: ?*timespec) c_int;

fn sleepMs(ms: u32) void {
    const ts = timespec{
        .tv_sec = @intCast(ms / 1000),
        .tv_nsec = @intCast(@as(u64, ms % 1000) * std.time.ns_per_ms),
    };
    _ = nanosleep(&ts, null);
}

/// Acquire the cross-process migration lock, returning true when it is held
/// (the caller must then call `unlockMigration`). `timeout_ms == 0` disables
/// locking.
///
/// SQLite is skipped: it is a single-writer database and the migration DDL
/// already runs inside one transaction, so there is no concurrent writer to
/// fence off.
///
/// PostgreSQL polls `pg_try_advisory_lock` until `timeout_ms` elapses;
/// MySQL uses `GET_LOCK` with a second-granularity timeout. A genuine timeout
/// is `error.MigrationLockTimeout`. If the lock statement itself fails (old
/// server, restricted permissions), the failure is logged as a warning and
/// the migration proceeds unlocked rather than becoming unusable; that
/// degradation is deliberate.
///
/// Both advisory locks are session-scoped, so the driver passed here must
/// keep one connection for the whole migration (the helpers migrate on a
/// single borrowed connection). A round-robin pool driver would acquire and
/// release on different sessions, making the fence ineffective.
fn lockMigration(drv: sql_driver.Driver, timeout_ms: u32) MigrationLockError!bool {
    if (timeout_ms == 0) return false;

    switch (drv.dialect().kind()) {
        // SQLite: no external lock, same reasoning as an unnamed dialect. The
        // comparison this arm replaces asked for `"sqlite"`, which is not the
        // name `Dialect.sqlite` carries (`"sqlite3"`), so it matched nothing and
        // SQLite fell through to the unnamed-dialect answer instead — the same
        // `false`, but by accident rather than by intent.
        .sqlite, .unknown => return false,
        .postgres => {
            var sql_buf: [128]u8 = undefined;
            const sql = std.fmt.bufPrint(&sql_buf, "SELECT pg_try_advisory_lock({d})", .{advisory_lock_key}) catch return false;
            const poll_ms: u32 = 25;
            var waited: u32 = 0;
            while (true) {
                var rows = drv.query(sql, &.{}) catch |err| {
                    zent_log.warn("zent migrations: pg advisory lock unavailable ({s}); continuing without lock", .{@errorName(err)});
                    return false;
                };
                defer rows.deinit();
                const acquired = if (rows.next()) |row| (row.getBool(0) orelse false) else false;
                if (acquired) return true;
                if (waited >= timeout_ms) return error.MigrationLockTimeout;
                const step = @min(poll_ms, timeout_ms - waited);
                sleepMs(step);
                waited += step;
            }
        },
        .mysql => {
            var sql_buf: [160]u8 = undefined;
            // GET_LOCK timeouts are whole seconds; a sub-second request rounds up
            // to 1 so a small test timeout does not become "wait forever".
            const secs: u32 = @max(1, timeout_ms / 1000);
            const sql = std.fmt.bufPrint(&sql_buf, "SELECT GET_LOCK('{s}', {d})", .{ mysql_lock_name, secs }) catch return false;
            var rows = drv.query(sql, &.{}) catch |err| {
                zent_log.warn("zent migrations: MySQL GET_LOCK unavailable ({s}); continuing without lock", .{@errorName(err)});
                return false;
            };
            defer rows.deinit();
            const row = rows.next() orelse return false;
            if (row.getInt(0)) |v| {
                if (v == 1) return true;
                if (v == 0) return error.MigrationLockTimeout;
            }
            zent_log.warn("zent migrations: MySQL GET_LOCK returned NULL; continuing without lock", .{});
            return false;
        },
    }
}

/// Best-effort release of the lock taken by `lockMigration`.
fn unlockMigration(drv: sql_driver.Driver) void {
    switch (drv.dialect().kind()) {
        .postgres => {
            var sql_buf: [128]u8 = undefined;
            const sql = std.fmt.bufPrint(&sql_buf, "SELECT pg_advisory_unlock({d})", .{advisory_lock_key}) catch return;
            _ = drv.exec(sql, &.{}) catch |err| {
                zent_log.warn("zent migrations: pg advisory unlock failed ({s})", .{@errorName(err)});
            };
        },
        .mysql => {
            var sql_buf: [160]u8 = undefined;
            const sql = std.fmt.bufPrint(&sql_buf, "SELECT RELEASE_LOCK('{s}')", .{mysql_lock_name}) catch return;
            _ = drv.exec(sql, &.{}) catch |err| {
                zent_log.warn("zent migrations: MySQL RELEASE_LOCK failed ({s})", .{@errorName(err)});
            };
        },
        // SQLite took no lock, and an unnamed dialect has none to release.
        .sqlite, .unknown => {},
    }
}

/// Reject a pending migration file whose content no longer matches the
/// checksum recorded when it was applied. Rows with a NULL checksum (schema
/// diffs) are not verifiable and are skipped.
fn verifyFileChecksums(applied: []const AppliedMigration, files: []const MigrationFile) !void {
    for (files) |f| {
        for (applied) |m| {
            if (m.version != f.version) continue;
            if (m.checksum) |stored| {
                if (!std.mem.eql(u8, stored, f.checksum)) {
                    zent_log.warn(
                        "zent migrations: checksum mismatch for migration {d} ({s}): recorded {s}, file now {s}; refusing to continue",
                        .{ f.version, f.name, stored, f.checksum },
                    );
                    return error.MigrationChecksumMismatch;
                }
            }
            break;
        }
    }
}

/// Column definition for CREATE TABLE.
pub const ColumnDef = struct {
    name: []const u8,
    /// Explicit SQL type for synthetic columns and backwards-compatible callers.
    sql_type: []const u8,
    /// Logical schema type. When present, migration SQL resolves it through the
    /// active dialect instead of reusing the SQLite-oriented `sql_type` value.
    logical_type: ?field_mod.FieldType = null,
    /// DDL spelling for a string column that declared `VarChar(n)` —
    /// comptime-formatted (`"VARCHAR(120)"`), because `columnSQLType` is a
    /// runtime fn returning a borrowed slice it cannot print into.
    /// `columnSQLType` uses it only for a MySQL dialect (replacing the
    /// default `VARCHAR(255)`); PostgreSQL and SQLite keep the `TEXT` the
    /// `.string` family already resolves to there. null for every column
    /// that declared no length.
    varchar_sql: ?[]const u8 = null,
    /// DDL spelling for a `field.Vector` column — comptime-formatted
    /// (`"vector(3)"`) for the same reason `varchar_sql` is:
    /// `columnSQLType` is a runtime fn returning a borrowed slice it cannot
    /// print into. `columnSQLType` uses it on a PostgreSQL dialect only;
    /// MySQL and SQLite get the field kind's mapping (`TEXT`). null for every
    /// column that declared no dimension.
    vector_sql: ?[]const u8 = null,
    /// Explicit SQL type declared by `.SqlType(s)` / `field.Other(name, s)`,
    /// null when the schema declared none. `columnSQLType` emits it verbatim
    /// and on a PostgreSQL dialect only; it wins over `varchar_sql`. Beside
    /// `logical_type` rather than inside `sql_type` for the same reason
    /// `varchar_sql` is: `sql_type` is the graph's comptime-resolved value for
    /// the dialect the graph was built with, while the override has to be
    /// resolved against the dialect the migration is actually running on.
    sql_type_override: ?[]const u8 = null,
    primary_key: bool = false,
    not_null: bool = false,
    unique: bool = false,
    default_value: ?[]const u8 = null,
    auto_increment: bool = false,
};

fn columnSQLType(column: ColumnDef, dialect: Dialect) []const u8 {
    // A declared `.SqlType(s)` / `field.Other(name, s)` names the column's type
    // outright, so it is resolved first — ahead of the kind's mapping and ahead
    // of a declared `VarChar(n)`. PostgreSQL only: the strings this names are
    // PostgreSQL's own extension/custom types and arrays, and a server that
    // cannot parse the name would fail `CREATE TABLE` rather than fall back.
    if (column.sql_type_override) |override| {
        if (dialect.kind() == .postgres) return override;
    }
    if (column.logical_type) |logical_type| {
        // A declared `VarChar(n)` replaces the default VARCHAR(255) on MySQL
        // only; every other dialect — and every undeclared column — resolves
        // through `sqlType` byte-for-byte unchanged.
        if (logical_type == .string) {
            if (column.varchar_sql) |varchar| {
                if (dialect.kind() == .mysql) return varchar;
            }
        }
        // A `field.Vector`'s type is dimension-bearing (`vector(3)`), which the
        // dimension-less `sqlType` cannot spell — the migration carries the
        // declaration as the comptime-formatted string, exactly as `VarChar(n)`
        // does. PostgreSQL only: MySQL and SQLite have no vector type, so they
        // take the `TEXT` mapping below (pgvector's own text form, `[1,2,3]`).
        if (logical_type == .vector) {
            if (column.vector_sql) |vector| {
                if (dialect.kind() == .postgres) return vector;
            }
        }
        return switch (logical_type) {
            inline else => |field_type| field_mod.sqlType(field_type, dialect),
        };
    }
    return column.sql_type;
}

/// What a column declared, and what this dialect will actually emit, when the
/// two differ because the declaration names a type the dialect does not have.
const DeclaredTypeRewrite = struct {
    /// The type the schema declared (`vector(1536)`, `citext`).
    declared: []const u8,
    /// The type `columnSQLType` resolves it to on this dialect (`TEXT`).
    emitted: []const u8,
};

/// The rewrite a column's declaration is about to suffer, or `null` when the
/// declaration is what gets emitted.
///
/// Two declarations can be rewritten, because only they name a type the schema
/// chose rather than a kind the dialect mapping owns:
///
///   - a `field.Vector` column: PostgreSQL gets `vector(n)` (pgvector),
///     MySQL/SQLite get the kind's `TEXT` (`field.sqlType`'s `.vector` arm),
///     which is a column of a different type, not a different spelling of the
///     same one;
///   - a `.SqlType(s)` / `field.Other(name, s)` override: `columnSQLType`
///     emits it verbatim on PostgreSQL **only**, so every other dialect falls
///     back to the field kind's mapping.
///
/// Everything else is a *mapping*, not a rewrite: `field.String` is `TEXT` on
/// PostgreSQL/SQLite and `VARCHAR(255)` on MySQL, `field.Json` is `JSONB` or
/// `TEXT` — the schema declared a kind and the dialect rendered it, which is
/// the dialect support working as documented. Those must stay silent, or every
/// schema warns.
///
/// Decided by comparing the declaration with `columnSQLType`'s own answer
/// rather than by re-deriving which arm fires, so the warning cannot disagree
/// with the SQL it accompanies (a hand-built `ColumnDef` whose `sql_type`
/// already *is* its override, for instance, is emitted as declared and stays
/// silent). Pure, so both dialects can be pinned without a server.
fn declaredTypeRewrite(col: ColumnDef, dialect: Dialect) ?DeclaredTypeRewrite {
    const declared: ?[]const u8 = if (col.sql_type_override) |override|
        override
    else if (col.logical_type != null and col.logical_type.? == .vector)
        (col.vector_sql orelse "vector")
    else
        null;
    const declared_type = declared orelse return null;
    const emitted = columnSQLType(col, dialect);
    if (std.mem.eql(u8, declared_type, emitted)) return null;
    return .{ .declared = declared_type, .emitted = emitted };
}

/// The dialect's name as the person reading the log says it.
fn dialectDisplayName(kind: Dialect.Kind) []const u8 {
    return switch (kind) {
        .sqlite => "SQLite",
        .postgres => "PostgreSQL",
        .mysql => "MySQL",
        .unknown => "this dialect",
    };
}

/// Say out loud that a declared column type has no column type on this dialect
/// and was emitted as something else.
///
/// The mirror image of the index-method/opclass warnings (`indexMethodFor`,
/// `indexOpClassFor`), and deliberately the same shape — declared here, dropped
/// with a line that names what was dropped. The *column* is the one that
/// matters: an index on a vector column that is stored as `TEXT` still indexes
/// the text, while the column itself is the whole loss (pgvector's operators
/// and its `vector` type are gone, and the value is a `[1,2,3]` string).
///
/// Once per (table, column) per migration is structural, not tracked: both
/// migration entry points call this once per entity, next to
/// `warnOutOfGraphEdgeRefs`, and a table's column list names a column once — so
/// the two DDL statements the planner can produce for one column (a `CREATE
/// TABLE` and, when the table already existed, an `ALTER TABLE ADD COLUMN`)
/// still produce one line.
fn warnDegradedColumnTypes(table: TableDef, dialect: Dialect) void {
    for (table.columns) |col| {
        const rewrite = declaredTypeRewrite(col, dialect) orelse continue;
        zent_log.warn(
            "zent: {s}.{s} declares the {s} type, which {s} has no column type for, so the column is emitted as {s}; it is stored and read as text and none of {s}'s operators or indexes for {s} apply — migrate this schema on PostgreSQL, or declare a type {s} can create",
            .{
                table.name,
                col.name,
                rewrite.declared,
                dialectDisplayName(dialect.kind()),
                rewrite.emitted,
                dialectDisplayName(dialect.kind()),
                rewrite.declared,
                dialectDisplayName(dialect.kind()),
            },
        );
    }
}

/// Dialect-aware epoch default for the conventional audit timestamp columns
/// (`created_at` / `updated_at` of logical type `.time`), matching zent's
/// i64-epoch representation (CURRENT_TIMESTAMP would store text and break
/// integer scanning). Returns null when the column has an explicit default
/// or is not an audit column.
fn auditTimestampDefault(column: ColumnDef, dialect: Dialect) ?[]const u8 {
    if (column.default_value != null) return null;
    if (column.logical_type == null or column.logical_type.? != .time) return null;
    if (!std.mem.eql(u8, column.name, "created_at") and !std.mem.eql(u8, column.name, "updated_at")) return null;
    // The spelling lives in `sql/dialect_expr.zig`; this form is the same
    // expression with the parentheses a DDL `DEFAULT` needs.
    return dialect_expr.nowSecsParenthesized(dialect);
}

/// Normalize a SQL type name for dialect-agnostic comparison by:
/// - Lowercasing
/// - Stripping size/precision modifiers: `varchar(255)` → `varchar`
/// - Canonicalizing aliases: `character varying` → `varchar`, `int` → `integer`
/// - Trimming whitespace
/// - On MySQL, mapping the server's storage names back onto the declared
///   family (see `server_canonical` below)
fn normalizeSqlType(sql_type: []const u8, buf: []u8, dialect: Dialect) ![]u8 {
    if (sql_type.len > buf.len) return error.NoSpaceLeft;

    // Lowercase and copy to buf
    for (sql_type, 0..) |c, i| buf[i] = std.ascii.toLower(c);

    // Strip parenthesized modifiers: e.g., "varchar(255)" → "varchar"
    var end = sql_type.len;
    if (std.mem.indexOfScalar(u8, buf[0..end], '(')) |paren_idx| {
        end = paren_idx;
        while (end > 0 and buf[end - 1] == ' ') end -= 1; // trim trailing space
    }

    const normalized = buf[0..end];

    // Canonicalize aliases — copy canonical name into buffer and return
    const canonical: ?[]const u8 = if (std.mem.eql(u8, normalized, "character varying")) "varchar" else if (std.mem.eql(u8, normalized, "int") or std.mem.eql(u8, normalized, "int4")) "integer" else if (std.mem.eql(u8, normalized, "double")) "double precision" else if (std.mem.eql(u8, normalized, "bool")) "boolean" else if (std.mem.eql(u8, normalized, "serial")) "integer" else if (std.mem.eql(u8, normalized, "bigserial")) "bigint" else if (std.mem.eql(u8, normalized, "timestamptz")) "timestamp with time zone" else null;

    // MySQL answers `information_schema.columns.data_type` with the **storage
    // type**, not the spelling the DDL used: BOOLEAN lands as `tinyint` (a
    // `tinyint(1)`) and REAL as `double` (REAL is a DOUBLE synonym there;
    // MariaDB behaves the same). zent emits both spellings dialect-independently
    // (`field.sqlType`), so without mapping the server's answer back every MySQL
    // table carrying a bool or a float reported a false `.type_mismatch` — and a
    // run with `allow_data_loss` then planned an ALTER TYPE to "repair" it,
    // which `alterColumnTypeSQL` refuses with `MySQLTypeChangeUnsafe`: planning
    // failed hard, dry-run included, and the version was never recorded.
    // Deliberately only these two, and gated on the dialect so PostgreSQL and
    // SQLite normalize exactly as before: `tinyint` cannot collide with a real
    // difference (zent's `.int` is emitted INTEGER and MySQL stores it as `int`,
    // normalized to `integer` — a genuine `tinyint` column is still not an
    // `.int`), and MySQL FLOAT keeps reporting `float`, distinct from the DOUBLE
    // family REAL belongs to.
    const server_canonical: ?[]const u8 = if (dialect.kind() != .mysql) null else if (std.mem.eql(u8, normalized, "tinyint")) "boolean" else if (std.mem.eql(u8, normalized, "real")) "double precision" else null;

    if (server_canonical orelse canonical) |canon| {
        if (canon.len > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[0..canon.len], canon);
        return buf[0..canon.len];
    }

    return normalized;
}

/// Foreign key definition.
pub const ForeignKeyDef = struct {
    columns: []const []const u8,
    ref_table: []const u8,
    ref_columns: []const []const u8,
    on_delete: []const u8 = "CASCADE",
    on_update: []const u8 = "CASCADE",
};

/// Index definition.
pub const IndexDef = struct {
    name: []const u8,
    columns: []const []const u8,
    unique: bool = false,
    /// Access method (`USING <method>`), `null` when the schema declared none.
    ///
    /// **Not compared by `checkSchema`.** It could be — PostgreSQL's
    /// `getPostgresIndexes` already joins `pg_am` (it uses `am.amname` to decide
    /// whether the key list is comparable at all), and MySQL carries
    /// `information_schema.statistics.INDEX_TYPE` — but a mismatch is a
    /// performance fact, and every drift reported here is one `assertSchema`
    /// turns into a blocked deploy. The comparison would also have to answer
    /// "equivalent?" rather than "equal?" for a great many pairs (a `btree`
    /// index and an undeclared method are the same thing; so are `USING BTREE`
    /// and the default on MySQL), and a wrong answer on either side is worse
    /// than no answer. So the method is written and never read: declaring it is
    /// free of drift risk, and changing it on an index that already exists by
    /// name is not repaired (an existing index is never re-created).
    method: ?[]const u8 = null,
    /// Operator class for the index's single key column (`"vector_cosine_ops"`,
    /// …). PostgreSQL only; see `createIndexSQLAlloc` for what the other two
    /// dialects do with a declaration they cannot express. Like `method`, it is
    /// never compared by `checkSchema`.
    opclass: ?[]const u8 = null,
};

/// `IndexInfo` → `IndexDef`: the one construction both migration paths use, so
/// a declaration cannot reach `migrateSchema` and not `planMigrateStatements`
/// (the dry run and the run it previews must agree), and so the test that pins
/// a schema's `method`/`opclass` reaching the DDL does not restate the mapping
/// it is testing.
fn indexDefFromInfo(idx: IndexInfo) IndexDef {
    return .{
        .name = idx.name,
        .columns = idx.columns,
        .unique = idx.unique,
        .method = idx.method,
        .opclass = idx.opclass,
    };
}

/// Table definition for CREATE TABLE.
pub const TableDef = struct {
    name: []const u8,
    columns: []const ColumnDef,
    primary_keys: []const []const u8,
    foreign_keys: []const ForeignKeyDef = &.{},
    indexes: []const IndexDef = &.{},
};

/// Generate a TableDef from a TypeInfo at comptime.
pub fn tableFromTypeInfo(comptime info: TypeInfo) TableDef {
    comptime {
        // 字段/外键循环在 `inline for (infos)` 的迁移入口下按表×字段展开，
        // 15+ 表的应用 schema 就会击穿默认 5000 分支限额(如 zenaipa);与
        // defaultValueStr 同量级提升配额，避免 "exceeded backwards branches"。
        @setEvalBranchQuota(50_000);
        var columns: []const ColumnDef = &.{};

        // Generate columns from fields. DDL uses the physical column name
        // (`StorageKey`), not the Zig field name.
        for (info.fields) |f| {
            const col = ColumnDef{
                .name = f.column_name,
                .sql_type = f.sql_type,
                .logical_type = f.field_type,
                .varchar_sql = if (f.max_length) |n| field_mod.varCharSQL(n) else null,
                .vector_sql = if (f.vector_dims) |n| field_mod.vectorSQL(n) else null,
                .sql_type_override = f.sql_type_override,
                .primary_key = f.is_id,
                .not_null = !f.optional and !f.nillable,
                .unique = f.unique,
                .default_value = defaultValueStr(f),
                // Only an integer primary key auto-increments. Marking every id as
                // auto-increment made PostgreSQL rewrite a UUID PK to SERIAL and
                // MySQL reject a TEXT PK, silently generating the wrong column type.
                .auto_increment = f.is_id and f.field_type == .int,
            };
            columns = columns ++ &[_]ColumnDef{col};
        }

        // Generate foreign keys from O2O and O2M edges (stored in target table)
        // For O2M edges where this entity is the "one" side, the foreign key
        // is in the target table, so we don't add it here.
        // For O2O edges and From edges, we might add a column.
        // For M2M edges, we need a junction table.
        var foreign_keys: []const ForeignKeyDef = &.{};

        for (info.edges) |e| {
            if (e.kind == .from and (e.relation == .o2m or e.relation == .m2o)) {
                // O2M/M2O From edge: this entity has a foreign key column
                // e.g., Car.owner -> User (owner_id column in car table), named
                // by the edge (`Field("owner_id")`) when it says so and
                // `<edge>_id` otherwise — `graph.getEdgeFKColumn`'s choice, so
                // this DDL and the queries name the same column.
                const fk_col_name = e.field_name orelse (e.name ++ "_id");
                const col = ColumnDef{
                    .name = fk_col_name,
                    .sql_type = "INTEGER",
                    .not_null = e.required,
                    .unique = e.unique,
                };
                columns = columns ++ &[_]ColumnDef{col};

                const fk = ForeignKeyDef{
                    .columns = &[_][]const u8{fk_col_name},
                    .ref_table = toSnakeCase(e.target_name),
                    // TODO: the referenced column is hardcoded to "id", so a
                    // target declaring `.pk` or a StorageKey-renamed `id` gets
                    // an FK to a column it does not have. Resolving it needs
                    // the target's TypeInfo, which this pub signature does not
                    // carry. The migration paths are not affected: they go
                    // through `tableFromTypeInfoCrossRef`, which references
                    // `graph.pkColumn` — and so does `junctionTableForEdge`,
                    // leaving this pub export the last of that family.
                    .ref_columns = &[_][]const u8{"id"},
                };
                foreign_keys = foreign_keys ++ &[_]ForeignKeyDef{fk};
            } else if (e.kind == .from and e.relation == .o2o) {
                // O2O From edge: foreign key column
                const fk_col_name = e.name ++ "_id";
                const col = ColumnDef{
                    .name = fk_col_name,
                    .sql_type = "INTEGER",
                    .not_null = e.required,
                    .unique = true, // O2O FK is always unique
                };
                columns = columns ++ &[_]ColumnDef{col};

                const fk = ForeignKeyDef{
                    .columns = &[_][]const u8{fk_col_name},
                    .ref_table = toSnakeCase(e.target_name),
                    // TODO: the referenced column is hardcoded to "id", so a
                    // target declaring `.pk` or a StorageKey-renamed `id` gets
                    // an FK to a column it does not have. Resolving it needs
                    // the target's TypeInfo, which this pub signature does not
                    // carry. The migration paths are not affected: they go
                    // through `tableFromTypeInfoCrossRef`, which references
                    // `graph.pkColumn` — and so does `junctionTableForEdge`,
                    // leaving this pub export the last of that family.
                    .ref_columns = &[_][]const u8{"id"},
                };
                foreign_keys = foreign_keys ++ &[_]ForeignKeyDef{fk};
            }
        }

        // Primary keys
        var pks: []const []const u8 = &.{};
        for (info.fields) |f| {
            if (f.is_id) {
                pks = pks ++ &[_][]const u8{f.column_name};
            }
        }

        return TableDef{
            .name = info.table_name,
            .columns = columns,
            .primary_keys = pks,
            .foreign_keys = foreign_keys,
        };
    }
}

/// Generate a junction table definition for M2M edges.
/// Columns and table name are deterministically ordered alphabetically
/// so that whichever edge triggers creation first produces the same schema.
///
/// Both ends resolve the way every other edge reference in this file does
/// (`edgeRefTarget` + `graph.pkColumn`): the source end from `source_info`
/// itself, the target end by looking the edge's target up in `all_infos` —
/// a declared `table_name` and a declared `.pk` (or a `StorageKey`-renamed
/// `id`) on either end are honoured, so the junction `migrateSchema` creates
/// and the one `buildEdgeStep`/`getJunctionTable` read derive the same name,
/// columns and referenced keys. A target outside the graph has no TypeInfo
/// to ask and keeps the historical shape — `toSnakeCase(target_name)`
/// referencing `"id"` — the same fallback `tableFromTypeInfoCrossRef` keeps,
/// because the reference dangles either way.
pub fn junctionTableForEdge(comptime edge: EdgeInfo, comptime source_info: TypeInfo, comptime all_infos: []const TypeInfo) TableDef {
    comptime {
        // Two ends × per-end name/column concatenations, per junction edge
        // inside the `inline for (infos)` migration loops, each end resolved by
        // a scan of `all_infos`: scaled with the graph like its siblings
        // (see `evalQuotaFor`).
        @setEvalBranchQuota(evalQuotaFor(all_infos));
        const ref = edgeRefTarget(edge, all_infos);
        const source_table = source_info.table_name;
        const target_table = ref.table;

        const a_first = std.mem.lessThan(u8, source_table, target_table);

        // Junction table name: alphabetically sorted
        const table_name = if (a_first)
            source_table ++ "_" ++ target_table
        else
            target_table ++ "_" ++ source_table;

        // Columns are also ordered alphabetically by their referenced table
        const col_a = source_table ++ "_id";
        const col_b = target_table ++ "_id";
        const col1 = if (a_first) col_a else col_b;
        const col2 = if (a_first) col_b else col_a;

        // Each reference names that end's primary-key column — `graph.pkColumn`
        // of the end's TypeInfo, the same resolver the relation query uses.
        const source_ref = pkColumn(source_info);
        const source_fk = ForeignKeyDef{
            .columns = if (a_first) &[_][]const u8{col1} else &[_][]const u8{col2},
            .ref_table = source_table,
            .ref_columns = &[_][]const u8{source_ref},
        };
        // A cross-graph end contributes its column and its half of the primary
        // key, and **no constraint**: the table name would have to be derived
        // from the entity name, and a wrong derivation is a rejected
        // `CREATE TABLE` rather than a dangling reference (see
        // `tableFromTypeInfoCrossRef`). Emitted in column order, so an in-graph
        // pair renders exactly as before.
        const target_fk = ForeignKeyDef{
            .columns = if (a_first) &[_][]const u8{col2} else &[_][]const u8{col1},
            .ref_table = target_table,
            .ref_columns = if (ref.info) |target|
                &[_][]const u8{pkColumn(target)}
            else
                &[_][]const u8{"id"},
        };
        const fk_for_col1 = if (a_first) source_fk else target_fk;
        const fk_for_col2 = if (a_first) target_fk else source_fk;
        const foreign_keys: []const ForeignKeyDef = if (ref.info == null)
            (if (a_first) &[_]ForeignKeyDef{fk_for_col1} else &[_]ForeignKeyDef{fk_for_col2})
        else
            &[_]ForeignKeyDef{ fk_for_col1, fk_for_col2 };

        return TableDef{
            .name = table_name,
            .columns = &.{
                ColumnDef{ .name = col1, .sql_type = "INTEGER", .not_null = true },
                ColumnDef{ .name = col2, .sql_type = "INTEGER", .not_null = true },
            },
            .primary_keys = &.{ col1, col2 },
            .foreign_keys = foreign_keys,
        };
    }
}

/// Generate CREATE TABLE SQL for a TableDef using specified allocator.
///
/// Fail-closed on MySQL: a BLOB/TEXT/JSON column the table would declare with
/// `DEFAULT`, `UNIQUE`, or as a `PRIMARY KEY` cannot be created at all, so the
/// statement is refused with a named error and a logged detail instead of
/// being emitted for the server to reject with errno 1101/1170 (see
/// `findMySqlTextRestriction`). Indexes are not `CREATE TABLE`'s business —
/// `table.indexes` is never emitted here — so they are checked by
/// `createIndexSQLForTableAlloc`.
///
/// This applies MySQL's rules; a caller that identified its server as MariaDB
/// (see `detectMySqlServer`) uses `createTableSQLAllocWithServer`, which emits
/// the `DEFAULT` MariaDB >= 10.2.1 accepts.
pub fn createTableSQLAlloc(allocator: std.mem.Allocator, table: TableDef, dialect: Dialect) ![]const u8 {
    return createTableSQLAllocWithServer(allocator, table, dialect, .mysql);
}

/// `createTableSQLAlloc`, told which server the statement is for.
///
/// The only difference is which text-column restrictions are enforced before
/// the SQL is built: on `.mariadb` a BLOB/TEXT `DEFAULT` is allowed through (and
/// then emitted below like any other column's), while UNIQUE and PRIMARY KEY
/// stay refused. On `.mysql` the output is identical to
/// `createTableSQLAlloc`.
pub fn createTableSQLAllocWithServer(
    allocator: std.mem.Allocator,
    table: TableDef,
    dialect: Dialect,
    server: MySqlServer,
) ![]const u8 {
    if (findMySqlTextRestrictionWithServer(table, &.{}, dialect, server)) |restriction| {
        return reportMySqlTextRestriction(restriction);
    }

    var buf = try std.array_list.Managed(u8).initCapacity(allocator, 256);
    defer buf.deinit();

    try buf.appendSlice("CREATE TABLE IF NOT EXISTS ");
    try quoteIdentToBuffer(dialect, &buf, table.name);
    try buf.appendSlice(" (\n");

    for (table.columns, 0..) |col, i| {
        var sql_type = columnSQLType(col, dialect);
        // PostgreSQL: a bare `INTEGER PRIMARY KEY` has no default, so an
        // INSERT without an explicit id fails NOT NULL on RETURNING. Map
        // auto-increment ids to SERIAL/BIGSERIAL (which own a sequence).
        if (col.auto_increment and dialect.kind() == .postgres) {
            sql_type = if (std.ascii.eqlIgnoreCase(sql_type, "BIGINT")) "BIGSERIAL" else "SERIAL";
        }
        if (i > 0) try buf.appendSlice(",\n");
        try buf.appendSlice("  ");
        try quoteIdentToBuffer(dialect, &buf, col.name);
        try buf.appendSlice(" ");
        try buf.appendSlice(sql_type);

        if (col.primary_key and isSQLiteDialect(dialect)) {
            // SQLite AUTOINCREMENT only valid on INTEGER PRIMARY KEY.
            if (std.ascii.eqlIgnoreCase(sql_type, "INTEGER") or
                std.ascii.eqlIgnoreCase(sql_type, "INT"))
            {
                try buf.appendSlice(" PRIMARY KEY AUTOINCREMENT");
            } else {
                try buf.appendSlice(" PRIMARY KEY");
            }
        } else if (col.primary_key) {
            try buf.appendSlice(" PRIMARY KEY");
            if (col.auto_increment and
                dialect.kind() == .mysql and
                isMySqlAutoIncrementType(sql_type))
            {
                try buf.appendSlice(" AUTO_INCREMENT");
            }
        }

        if (col.not_null and !col.primary_key) {
            try buf.appendSlice(" NOT NULL");
        }

        if (col.unique and !col.primary_key) {
            try buf.appendSlice(" UNIQUE");
        }

        if (col.default_value) |dv| {
            try buf.appendSlice(" DEFAULT ");
            try buf.appendSlice(dv);
        } else if (auditTimestampDefault(col, dialect)) |dv2| {
            try buf.appendSlice(" DEFAULT ");
            try buf.appendSlice(dv2);
        }
    }

    // Add composite primary key constraint (for multi-column PKs)
    if (table.primary_keys.len > 1) {
        try buf.appendSlice(",\n  PRIMARY KEY (");
        for (table.primary_keys, 0..) |pk, i| {
            if (i > 0) try buf.appendSlice(", ");
            try quoteIdentToBuffer(dialect, &buf, pk);
        }
        try buf.appendSlice(")");
    }

    // Add foreign key constraints
    for (table.foreign_keys) |fk| {
        try buf.appendSlice(",\n  FOREIGN KEY (");
        for (fk.columns, 0..) |col, i| {
            if (i > 0) try buf.appendSlice(", ");
            try quoteIdentToBuffer(dialect, &buf, col);
        }
        try buf.appendSlice(") REFERENCES ");
        try quoteIdentToBuffer(dialect, &buf, fk.ref_table);
        try buf.appendSlice(" (");
        for (fk.ref_columns, 0..) |col, i| {
            if (i > 0) try buf.appendSlice(", ");
            try quoteIdentToBuffer(dialect, &buf, col);
        }
        try buf.appendSlice(") ON DELETE ");
        try buf.appendSlice(fk.on_delete);
        try buf.appendSlice(" ON UPDATE ");
        try buf.appendSlice(fk.on_update);
    }

    try buf.appendSlice("\n)");

    return allocator.dupe(u8, buf.items);
}

/// Generate CREATE TABLE SQL for a TableDef.
pub fn createTableSQL(table: TableDef, dialect: Dialect) ![]const u8 {
    return createTableSQLAlloc(std.heap.page_allocator, table, dialect);
}

/// Generate CREATE INDEX SQL for an IndexDef using specified allocator.
///
/// Unchecked: without the table's column types this cannot tell whether the
/// dialect will accept the key list. `createIndexSQLForTableAlloc` is the
/// entry point that can, and is what the migration paths use.
///
/// The access method and operator class are the one part of an index
/// declaration the dialects genuinely disagree about, so each gets one spot:
///
/// | Dialect | `method` | `opclass` |
/// |---|---|---|
/// | PostgreSQL | `ON t USING <method> (…)`, verbatim | `<col> <opclass>` |
/// | MySQL | `INDEX i USING BTREE\|HASH ON t (…)`; any other method is omitted with a warning | omitted with a warning |
/// | SQLite (and an unknown dialect) | omitted with a warning | omitted with a warning |
///
/// Undeclared (the default) emits nothing new on any of them: the statement is
/// byte-for-byte the one this function produced before either slot existed.
/// Both values are validated against a bare-identifier shape before they are
/// emitted (they are the only parts of this statement that are neither quoted
/// nor a schema column), and a method/opclass pair the dialect cannot express is
/// *reported*, never silently rewritten into one that means something else.
pub fn createIndexSQLAlloc(allocator: std.mem.Allocator, index: IndexDef, table_name: []const u8, dialect: Dialect) ![]const u8 {
    var buf = try std.array_list.Managed(u8).initCapacity(allocator, 256);
    defer buf.deinit();

    const kind = dialect.kind();
    // Resolved before anything is written: both helpers can report, and a
    // statement half-emitted into `buf` would be discarded anyway.
    const method = try indexMethodFor(index, kind, table_name);
    const opclass = try indexOpClassFor(index, kind, table_name);

    try buf.appendSlice("CREATE ");
    if (index.unique) try buf.appendSlice("UNIQUE ");
    if (kind == .mysql) {
        // MySQL's grammar puts the index type between the name and `ON`;
        // PostgreSQL's puts `USING` after the table. Both were checked against
        // a running server.
        try buf.appendSlice("INDEX ");
        try quoteIdentToBuffer(dialect, &buf, index.name);
        if (method) |m| {
            try buf.appendSlice(" USING ");
            try buf.appendSlice(m);
        }
        try buf.appendSlice(" ON ");
        try quoteIdentToBuffer(dialect, &buf, table_name);
    } else {
        // `INDEX IF NOT EXISTS` is not accepted by MySQL at all, which is why
        // the two dialects need separate prefixes (the `CREATE INDEX` above is
        // not idempotent on MySQL — the migration layer's existence check in
        // front of it is what keeps a re-run from failing).
        try buf.appendSlice("INDEX IF NOT EXISTS ");
        try quoteIdentToBuffer(dialect, &buf, index.name);
        try buf.appendSlice(" ON ");
        try quoteIdentToBuffer(dialect, &buf, table_name);
        if (method) |m| {
            try buf.appendSlice(" USING ");
            try buf.appendSlice(m);
        }
    }
    try buf.appendSlice(" (");

    for (index.columns, 0..) |col, i| {
        if (i > 0) try buf.appendSlice(", ");
        try quoteIdentToBuffer(dialect, &buf, col);
        // `opclass` is non-null on PostgreSQL only (see `indexOpClassFor`),
        // and only for a single-column key, so this is the one column it can
        // belong to.
        if (opclass) |o| {
            if (i == 0) {
                try buf.appendSlice(" ");
                try buf.appendSlice(o);
            }
        }
    }
    try buf.appendSlice(")");

    return allocator.dupe(u8, buf.items);
}

/// Is `name` a bare SQL identifier, or a dotted chain of them
/// (`[A-Za-z_][A-Za-z0-9_$]*`, joined by `.`)?
///
/// An access method and an operator class are the only two things this file
/// emits *unquoted* and from outside the schema, and neither can be quoted
/// instead: MySQL rejects a quoted `index_type` outright (errno 1064), and on
/// PostgreSQL the unquoted spelling is what folds `HNSW` to `hnsw` the way every
/// other identifier does. So the value goes out verbatim and this is what keeps
/// "verbatim" from being an injection surface.
fn isBareIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    var part_start = true;
    for (name) |c| {
        if (c == '.') {
            // An empty part means a leading, trailing or doubled dot.
            if (part_start) return false;
            part_start = true;
            continue;
        }
        if (part_start) {
            if (!std.ascii.isAlphabetic(c) and c != '_') return false;
            part_start = false;
        } else if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '$') {
            return false;
        }
    }
    return !part_start;
}

/// The access method as `kind` can express it, or `null` when it has to be
/// omitted. See the table on `createIndexSQLAlloc`.
fn indexMethodFor(index: IndexDef, kind: Dialect.Kind, table_name: []const u8) !?[]const u8 {
    const declared = index.method orelse return null;
    return switch (kind) {
        .postgres => blk: {
            if (!isBareIdentifier(declared)) return error.InvalidIndexMethod;
            break :blk declared;
        },
        .mysql => blk: {
            // MySQL's *grammar* has two values, so a third can only be a
            // schema written for another database. Refusing the whole
            // migration would make a shared schema unmigratable here for a
            // performance-only declaration, so the index is created without
            // one and the omission is said out loud.
            if (std.ascii.eqlIgnoreCase(declared, "btree")) break :blk "BTREE";
            if (std.ascii.eqlIgnoreCase(declared, "hash")) break :blk "HASH";
            zent_log.warn(
                "zent: MySQL has no `{s}` index access method (only BTREE and HASH), so {s} on {s} was created without one",
                .{ declared, index.name, table_name },
            );
            break :blk null;
        },
        .sqlite, .unknown => blk: {
            zent_log.warn(
                "zent: this dialect has no index access methods, so `{s}` on {s} ({s}) was ignored",
                .{ declared, index.name, table_name },
            );
            break :blk null;
        },
    };
}

/// The key column's operator class, or `null` when the dialect has none. See
/// the table on `createIndexSQLAlloc`.
fn indexOpClassFor(index: IndexDef, kind: Dialect.Kind, table_name: []const u8) !?[]const u8 {
    const declared = index.opclass orelse return null;
    return switch (kind) {
        .postgres => blk: {
            // An operator class belongs to exactly one key column. Attaching it
            // to the first of several would build an index the schema did not
            // ask for, and silently dropping it would build one that cannot
            // answer the query it was declared for — so the declaration is
            // refused instead.
            if (index.columns.len != 1) return error.OpClassNeedsSingleColumn;
            if (!isBareIdentifier(declared)) return error.InvalidIndexOpClass;
            break :blk declared;
        },
        .mysql, .sqlite, .unknown => blk: {
            zent_log.warn(
                "zent: `{s}` is a PostgreSQL operator class and this dialect has none, so it was ignored on {s} ({s})",
                .{ declared, index.name, table_name },
            );
            break :blk null;
        },
    };
}

/// Generate CREATE INDEX SQL for an IndexDef.
pub fn createIndexSQL(index: IndexDef, table_name: []const u8, dialect: Dialect) ![]const u8 {
    return createIndexSQLAlloc(std.heap.page_allocator, index, table_name, dialect);
}

/// `createIndexSQLAlloc` for an index *declared on* `table`, with MySQL's
/// key-length restrictions enforced before any SQL is produced.
///
/// The column types are the whole point: a bare `CREATE INDEX ... (body)`
/// looks identical whether `body` is `VARCHAR(255)` (fine) or `TEXT` (errno
/// 1170, and no DDL MySQL will accept short of a key-length prefix that
/// changes the meaning of a UNIQUE index). Refusing here turns that into
/// `error.MySQLTextColumnCannotBeIndexed` with a logged table/column/reason,
/// and every caller that goes through this function inherits it — including
/// the dry run, which prints the SQL it would have executed.
///
/// This applies MySQL's rules; `createIndexSQLForTableAllocWithServer` is the
/// spelling for a caller that identified its server, and it differs only for a
/// table carrying a text `DEFAULT` the index is not the one to refuse.
pub fn createIndexSQLForTableAlloc(allocator: std.mem.Allocator, index: IndexDef, table: TableDef, dialect: Dialect) ![]const u8 {
    return createIndexSQLForTableAllocWithServer(allocator, index, table, dialect, .mysql);
}

/// `createIndexSQLForTableAlloc`, told which server the statement is for.
///
/// The index itself is refused on both families — a key column that is
/// BLOB/TEXT/JSON is errno 1170 on MariaDB too. `server` matters because the
/// scan walks the table's columns first: a text column carrying a `DEFAULT`
/// used to report `.default_value` here even though this statement does not
/// write that default, which on MariaDB would refuse the index for a reason
/// the server does not have.
pub fn createIndexSQLForTableAllocWithServer(
    allocator: std.mem.Allocator,
    index: IndexDef,
    table: TableDef,
    dialect: Dialect,
    server: MySqlServer,
) ![]const u8 {
    if (findMySqlTextRestrictionWithServer(table, &.{index}, dialect, server)) |restriction| {
        return reportMySqlTextRestriction(restriction);
    }
    return createIndexSQLAlloc(allocator, index, table.name, dialect);
}

/// Generate CREATE VIEW SQL using specified allocator.
///
/// The clause is dialect-dependent, and getting it wrong is not cosmetic:
/// **PostgreSQL has no `CREATE VIEW IF NOT EXISTS`** — it rejects the statement
/// with a syntax error (42601, `syntax error at or near "NOT"`), so on
/// PostgreSQL a schema declaring a view could not be migrated at all. SQLite is
/// the mirror image: it accepts `IF NOT EXISTS` and rejects `OR REPLACE`
/// (`near "OR": syntax error`). So:
///
///   - PostgreSQL and MySQL/MariaDB: `CREATE OR REPLACE VIEW`, which is
///     idempotent and replaces the stored definition — a changed `view_sql`
///     therefore **does** take effect on those two, as long as the new shape is
///     compatible (PostgreSQL allows columns to be added at the end, not
///     reordered or retyped).
///   - SQLite: `CREATE VIEW IF NOT EXISTS`, which creates a missing view and
///     leaves an existing one alone. It has no way to replace a view in place,
///     so on SQLite a changed `view_sql` still does not take effect — the
///     original behaviour, and the only one SQLite offers.
pub fn createViewSQLAlloc(allocator: std.mem.Allocator, comptime info: TypeInfo, dialect: Dialect) ![]const u8 {
    const view_sql = info.view_sql orelse return error.MissingViewSQL;
    var buf = try std.array_list.Managed(u8).initCapacity(allocator, 256);
    defer buf.deinit();

    // PostgreSQL has no `CREATE VIEW IF NOT EXISTS` (42601) and SQLite no
    // `CREATE OR REPLACE VIEW` (near `OR`), so SQLite alone takes IF NOT
    // EXISTS; an unnamed dialect keeps the OR REPLACE it has always taken.
    if (dialect.kind() == .sqlite) {
        try buf.appendSlice("CREATE VIEW IF NOT EXISTS ");
    } else {
        try buf.appendSlice("CREATE OR REPLACE VIEW ");
    }
    try quoteIdentToBuffer(dialect, &buf, info.table_name);
    try buf.appendSlice(" AS ");
    try buf.appendSlice(view_sql);

    return allocator.dupe(u8, buf.items);
}

/// Generate CREATE VIEW SQL.
pub fn createViewSQL(comptime info: TypeInfo, dialect: Dialect) ![]const u8 {
    return createViewSQLAlloc(std.heap.page_allocator, info, dialect);
}

test "CREATE VIEW uses the clause each dialect actually accepts" {
    // PostgreSQL has no `CREATE VIEW IF NOT EXISTS` (42601) and SQLite no
    // `CREATE OR REPLACE VIEW` (near "OR"), so a single clause cannot serve
    // both — and the wrong one is not a cosmetic difference: on PostgreSQL it
    // made a schema with a view entity unmigratable.
    const alloc = std.testing.allocator;
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;
    const field = @import("../../core/field.zig");

    const Probe = schema("CreateViewClauseProbe", .{
        .view = true,
        .view_sql = "SELECT 1 AS a",
        .fields = &.{field.Int("a")},
    });
    const info = comptime fromSchema(Probe);

    const pg = try createViewSQLAlloc(alloc, info, Dialect.postgres);
    defer alloc.free(pg);
    try std.testing.expectEqualStrings("CREATE OR REPLACE VIEW \"create_view_clause_probe\" AS SELECT 1 AS a", pg);

    const my = try createViewSQLAlloc(alloc, info, Dialect.mysql);
    defer alloc.free(my);
    try std.testing.expectEqualStrings("CREATE OR REPLACE VIEW `create_view_clause_probe` AS SELECT 1 AS a", my);

    const lite = try createViewSQLAlloc(alloc, info, Dialect.sqlite);
    defer alloc.free(lite);
    try std.testing.expectEqualStrings("CREATE VIEW IF NOT EXISTS \"create_view_clause_probe\" AS SELECT 1 AS a", lite);
}

/// Create entity and junction tables without creating indexes.
///
/// Generated SQL is allocated from `allocator` and freed with the same
/// allocator, so callers must pass the allocator they track (e.g. a testing
/// allocator or an arena).
///
/// `server` is the one `createAllTables` probed (`detectMySqlServer`); it only
/// matters for a text column with a `DEFAULT`, which MariaDB accepts.
fn createTables(
    allocator: std.mem.Allocator,
    driver_drv: sql_driver.Driver,
    comptime infos: []const TypeInfo,
    server: MySqlServer,
) !void {
    const dialect = driver_drv.dialect();

    // Create main entity tables (skip views)
    // For each entity, also check if any OTHER entity has a From edge pointing here,
    // which means we need to add FK columns to that other entity's table.
    // We handle this by building the table definition with FK columns from both
    // own From edges AND from cross-referenced To edges.
    inline for (infos) |info| {
        if (info.is_view) {
            const sql = try createViewSQLAlloc(allocator, info, dialect);
            defer allocator.free(sql);
            _ = try driver_drv.exec(
                sql,
                &.{},
            );
        } else {
            const table = comptime tableFromTypeInfoCrossRef(info, infos);
            warnOutOfGraphEdgeRefs(info, infos);
            warnDegradedColumnTypes(table, dialect);
            const sql = try createTableSQLAllocWithServer(allocator, table, dialect, server);
            defer allocator.free(sql);
            _ = try driver_drv.exec(sql, &.{});
        }
    }

    // Create junction tables for M2M edges (both To and From sides).
    // Skip edges that use an explicit edge schema (through).
    // CREATE TABLE IF NOT EXISTS handles duplicates when both sides declare M2M.
    inline for (infos) |info| {
        if (info.is_view) continue;
        inline for (info.edges) |e| {
            if (e.relation == .m2m and e.through == null) {
                const jtable = comptime junctionTableForEdge(e, info, infos);
                const sql = try createTableSQLAllocWithServer(allocator, jtable, dialect, server);
                defer allocator.free(sql);
                _ = try driver_drv.exec(
                    sql,
                    &.{},
                );
            }
        }
    }
}

/// Create all tables and indexes for a set of TypeInfos.
///
/// NOTE: This is a legacy helper that creates tables/indexes directly without
/// recording migration history or wrapping in a transaction. Prefer
/// `migrateSchema` for production use — it provides transactional atomicity
/// (SQLite, PostgreSQL), idempotency via `zent_schema_migrations`, and
/// automatic column/index additions on re-run.
pub fn createAllTables(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, comptime infos: []const TypeInfo) !void {
    const dialect = driver_drv.dialect();
    // Before any DDL: a declared extension type this server has no extension
    // for is refused here rather than by the server in the middle of a
    // `CREATE TABLE` (see `checkPostgresExtensions`).
    try checkPostgresExtensions(driver_drv, infos);
    // One probe per entry point, shared by the table and index statements so
    // both classify a text `DEFAULT` the same way, and skipped entirely when
    // the schema declares none (see `graphHasMySqlTextDefault`).
    const mysql_server: MySqlServer = if (dialect.kind() == .mysql and graphHasMySqlTextDefault(infos))
        detectMySqlServer(driver_drv)
    else
        .mysql;
    try createTables(allocator, driver_drv, infos, mysql_server);

    inline for (infos) |info| {
        if (info.is_view or info.indexes.len == 0) continue;

        var existing_mysql_indexes: ?std.array_list.Managed(ExistingIndex) = null;
        if (dialect.kind() == .mysql) {
            existing_mysql_indexes = getExistingIndexes(allocator, driver_drv, info.table_name) catch |err| switch (err) {
                error.UnsupportedDialect => unreachable, // The dialect was checked immediately above.
                error.InvalidTableName => unreachable, // SQLite-only, and the dialect was checked immediately above.
                error.IndexCatalogUnavailable => unreachable, // PostgreSQL-only, and the dialect was checked immediately above.
                error.ForeignKeyCatalogUnavailable => unreachable, // PostgreSQL-only, and the dialect was checked immediately above.
                error.OutOfMemory => return error.OutOfMemory,
                error.PoolExhausted => return error.PoolExhausted,
                error.PoolWaitTimeout => return error.PoolWaitTimeout,
                error.PoolClosed => return error.PoolClosed,
                error.ConnectionFailed => return error.ConnectionFailed,
                error.ExecFailed => return error.ExecFailed,
                error.QueryFailed => return error.QueryFailed,
                error.TxFailed => return error.TxFailed,
                error.PingFailed => return error.PingFailed,
                error.BindFailed => return error.BindFailed,
                error.PrepareFailed => return error.PrepareFailed,
                error.ProtocolError => return error.ProtocolError,
                error.DriverFailed => return error.DriverFailed,
                error.ParamCountMismatch => return error.ParamCountMismatch,
                error.QueryTimeout => return error.QueryTimeout,
                error.UniqueViolation, error.NotNullViolation, error.ForeignKeyViolation => return error.ExecFailed,
                error.OptimisticLockConflict => return error.OptimisticLockConflict,
                error.DeadlockDetected => return error.DeadlockDetected,
                error.SerializationFailure => return error.SerializationFailure,
                error.LockTimeout => return error.LockTimeout,
            };
        }
        defer if (existing_mysql_indexes) |*indexes| {
            freeExistingIndexes(allocator, indexes);
        };

        const table = comptime tableFromTypeInfoCrossRef(info, infos);
        inline for (info.indexes) |idx| {
            const idx_def = indexDefFromInfo(idx);
            const already_exists = if (existing_mysql_indexes) |indexes|
                indexExists(indexes.items, idx_def.name)
            else
                false;
            if (!already_exists) {
                const sql = try createIndexSQLForTableAllocWithServer(allocator, idx_def, table, dialect, mysql_server);
                defer allocator.free(sql);
                _ = try driver_drv.exec(sql, &.{});
            }
        }
    }
}

/// The table — and, when the edge's target is in this graph, the entity —
/// an edge's foreign key must reference. The target's declared `table_name`
/// wins when the target is in this graph, and the snake_case derivation of
/// its schema name is the fallback when it is not (the historical spelling,
/// kept for a caller that migrates a table whose target it did not pass — a
/// foreign key to an entity outside the graph is dangling either way).
///
/// The derivation is *not* the same thing: an entity that declares
/// `table_name = "xdaofood_upload_file"` is stored in that table, and an FK that
/// names `upload_file` instead points at nothing. On SQLite, where foreign keys
/// are enforced since v0.70, the child's first INSERT then fails with
/// `no such table: main.upload_file` — the symptom a consumer reported as a
/// "short name" defect. `tableFromTypeInfoCrossRef`'s To-edge half has always
/// resolved this through `other_info.table_name`; the From-edge half derived the
/// name instead, which is the inconsistency this closes.
const EdgeRefTarget = struct {
    table: []const u8,
    /// The target entity when it is in this graph — the referenced column is
    /// `graph.pkColumn` of it. `null` means the target is outside the graph
    /// and there is no TypeInfo to ask.
    info: ?TypeInfo,
};

fn edgeRefTarget(comptime e: EdgeInfo, comptime all_infos: []const TypeInfo) EdgeRefTarget {
    comptime {
        for (all_infos) |ti| {
            if (std.mem.eql(u8, ti.name, e.target_name))
                return .{ .table = ti.table_name, .info = ti };
        }
        return .{ .table = toSnakeCase(e.target_name), .info = null };
    }
}

/// The edges whose foreign key goes through `edgeRefTarget`: a From m2o/o2o
/// edge gets the FK column in this table, and an M2M edge without a `Through`
/// gets one in the junction `junctionTableForEdge` derives. All other edges
/// reference an in-graph entity by construction.
fn edgeFKUsesRefTarget(comptime e: EdgeInfo) bool {
    return (e.kind == .from and (e.relation == .m2o or e.relation == .o2o)) or
        (e.relation == .m2m and e.through == null);
}

/// Say out loud which edge crosses this graph, so the foreign key it cannot
/// name is left out of the DDL instead of guessed.
///
/// Every surface that resolves an edge for a *query* refuses this at compile
/// time (`codegen/graph.edgeTargetInfo`, Z16), but a migration-only consumer —
/// the multi-database deployment that migrates each graph on its own, or one
/// that migrates a large schema in chunks — never builds a Client, and
/// `migrateSchema` / `createAllTables` build the table from the `infos` alone.
/// A target that is not in `infos` has **no table name this graph can know**:
/// `toSnakeCase(target_name)` is a guess that ignores the target's declared
/// `table_name`, and a wrong guess is not a dangling reference but a
/// `CREATE TABLE` the server rejects (`relation "…" does not exist`, measured on
/// PostgreSQL), which made a chunked migration fail on every retry. So the
/// column stays and the constraint is left out — that is the *silent* half; this
/// function is the other half, because the database error never named the edge
/// that caused it.
///
/// Warning once per (source entity, edge) is structural, not tracked state:
/// `inline for` visits each edge of `info` once, and each migration entry point
/// calls this once per entity. `planMigrateStatements` is the shared planner of
/// both the dry run and the real run, so neither rebuild of the table
/// definition warns twice; `createTables` is the legacy path and never runs in
/// the same migration.
fn warnOutOfGraphEdgeRefs(comptime info: TypeInfo, comptime all_infos: []const TypeInfo) void {
    // `comptime` on the operand: this function is reached from a runtime frame,
    // where a plain call would be a runtime value the builtin refuses.
    @setEvalBranchQuota(comptime evalQuotaFor(all_infos));
    inline for (info.edges) |e| {
        const crosses: bool = comptime edgeFKUsesRefTarget(e) and edgeRefTarget(e, all_infos).info == null;
        if (crosses) {
            zent_log.warn(
                "zent: the edge '{s}' on entity {s} targets {s}, which is not in this graph's infos, so the foreign key is left out of the CREATE TABLE (its column stays): the referenced table's name cannot be resolved from this graph — migrate each graph separately in a multi-database deployment, or add {s} to this graph (cross-graph edges are Z16)",
                .{ e.name, info.name, e.target_name, e.target_name },
            );
        }
    }
}

/// Like tableFromTypeInfo, but also adds FK columns from cross-referenced To edges.
/// For example, if User has a To("cars", Car) O2M edge, this adds a "user_id" FK column
/// to the Car table pointing back to User.
fn tableFromTypeInfoCrossRef(comptime info: TypeInfo, comptime all_infos: []const TypeInfo) TableDef {
    comptime {
        // 字段/外键/交叉引用循环在 `inline for (infos)` 的迁移入口下按
        // 表×字段×表展开，15+ 表的应用 schema 就会击穿默认 5000 分支限额
        // (如 zenaipa)；固定常数在 154 表的消费者上同样会溢出，所以配额随
        // 图规模缩放（见 `evalQuotaFor`）。
        @setEvalBranchQuota(evalQuotaFor(all_infos));
        var columns: []const ColumnDef = &.{};
        var foreign_keys: []const ForeignKeyDef = &.{};

        // Generate columns from fields. DDL uses the physical column name
        // (`StorageKey`), not the Zig field name.
        for (info.fields) |f| {
            const col = ColumnDef{
                .name = f.column_name,
                .sql_type = f.sql_type,
                .logical_type = f.field_type,
                .varchar_sql = if (f.max_length) |n| field_mod.varCharSQL(n) else null,
                .vector_sql = if (f.vector_dims) |n| field_mod.vectorSQL(n) else null,
                .sql_type_override = f.sql_type_override,
                .primary_key = f.is_id,
                .not_null = !f.optional and !f.nillable,
                .unique = f.unique,
                .default_value = defaultValueStr(f),
                // Only an integer primary key auto-increments. Marking every id as
                // auto-increment made PostgreSQL rewrite a UUID PK to SERIAL and
                // MySQL reject a TEXT PK, silently generating the wrong column type.
                .auto_increment = f.is_id and f.field_type == .int,
            };
            columns = columns ++ &[_]ColumnDef{col};
        }

        // Own From edges generate FK columns in this table
        for (info.edges) |e| {
            if (e.kind == .from and (e.relation == .m2o or e.relation == .o2o)) {
                // The column the edge names (`Field("image_id")`) or `<edge>_id`
                // without one — the same choice `graph.getEdgeFKColumn` makes for
                // the query side. Deriving `<edge>_id` unconditionally put the FK
                // on a column nothing reads, while the column the queries use held
                // the reference with no constraint on it.
                const fk_col_name = e.field_name orelse (e.name ++ "_id");
                // Skip adding the column definition if it was already added via info.fields
                // (e.g., from addEdgeFields), but still add the FK constraint.
                var col_exists = false;
                for (columns) |c| {
                    if (std.mem.eql(u8, c.name, fk_col_name)) {
                        col_exists = true;
                        break;
                    }
                }
                if (!col_exists) {
                    const col = ColumnDef{
                        .name = fk_col_name,
                        .sql_type = "INTEGER",
                        .not_null = e.required,
                        .unique = e.unique,
                    };
                    columns = columns ++ &[_]ColumnDef{col};
                }

                // The constraint only when the target is resolvable. Its
                // reference names the target's primary-key column
                // (`graph.pkColumn`): the query side has always resolved it that
                // way, while a literal "id" gave a target that declares `.pk`
                // (or stores `id` under a StorageKey) an FK to a column it does
                // not have — on SQLite the child's first INSERT then failed with
                // `foreign key mismatch`.
                //
                // **A target outside this graph has no table name to name.** The
                // historical fallback (`toSnakeCase(target_name)`) is a guess,
                // and a wrong guess is not a dangling reference — it is a
                // `CREATE TABLE` the server rejects (`relation "…" does not
                // exist`, measured on PostgreSQL for a graph whose entities
                // carry an explicit `table_name`), which made a chunked
                // migration fail on every retry. The column stays: the data
                // shape has to match what the query side reads. The constraint
                // is left out, and `warnOutOfGraphEdgeRefs` names the edge.
                const ref = edgeRefTarget(e, all_infos);
                if (ref.info) |target| {
                    const fk = ForeignKeyDef{
                        .columns = &[_][]const u8{fk_col_name},
                        .ref_table = ref.table,
                        .ref_columns = &[_][]const u8{pkColumn(target)},
                    };
                    foreign_keys = foreign_keys ++ &[_]ForeignKeyDef{fk};
                }
            }
        }

        // Cross-referenced To edges: if another entity has a To edge pointing here
        // with O2M relation, add the FK column to THIS table.
        // For example: User has To("cars", Car) → Car gets "user_id" FK column.
        // If this entity already has a corresponding From edge, the FK is handled
        // by that From edge (e.g., Car.From("owner", User).Ref("cars")) and we
        // skip adding a duplicate column.
        for (all_infos) |other_info| {
            for (other_info.edges) |e| {
                // Find To edges from other entities pointing to this entity
                if (e.kind == .to and std.mem.eql(u8, e.target_name, info.name)) {
                    // Check if this entity already has a corresponding From edge.
                    var has_from_inverse = false;
                    for (info.edges) |my_edge| {
                        if (my_edge.kind == .from and
                            std.mem.eql(u8, my_edge.target_name, other_info.name) and
                            my_edge.ref != null and
                            std.mem.eql(u8, my_edge.ref.?, e.name))
                        {
                            has_from_inverse = true;
                            break;
                        }
                    }
                    if (has_from_inverse) continue;

                    if (e.relation == .o2m) {
                        // O2M: "one User has many Cars" → Car table gets FK column
                        const fk_col_name = e.field_name orelse toSnakeCase(other_info.name) ++ "_id";
                        // Check if this column already exists
                        var exists = false;
                        for (columns) |c| {
                            if (std.mem.eql(u8, c.name, fk_col_name)) {
                                exists = true;
                                break;
                            }
                        }
                        if (!exists) {
                            const col = ColumnDef{
                                .name = fk_col_name,
                                .sql_type = "INTEGER",
                                .not_null = true,
                                .unique = false,
                            };
                            columns = columns ++ &[_]ColumnDef{col};

                            const fk = ForeignKeyDef{
                                .columns = &[_][]const u8{fk_col_name},
                                .ref_table = other_info.table_name,
                                // Same rule as the From-edge half: reference
                                // the target's primary-key column
                                // (`graph.pkColumn`), not a literal "id".
                                .ref_columns = &[_][]const u8{pkColumn(other_info)},
                            };
                            foreign_keys = foreign_keys ++ &[_]ForeignKeyDef{fk};
                        }
                    }
                }
            }
        }

        // Primary keys
        var pks: []const []const u8 = &.{};
        for (info.fields) |f| {
            if (f.is_id) {
                pks = pks ++ &[_][]const u8{f.column_name};
            }
        }

        return TableDef{
            .name = info.table_name,
            .columns = columns,
            .primary_keys = pks,
            .foreign_keys = foreign_keys,
        };
    }
}

fn quoteIdentToBuffer(dialect: Dialect, buf: *std.array_list.Managed(u8), name: []const u8) !void {
    const quote: u8 = if (dialect.kind() == .mysql) '`' else '"';
    try buf.append(quote);
    for (name) |c| {
        try buf.append(c);
        // SQL-92 escapes an embedded quote by doubling it, so the identifier
        // cannot be terminated early by a quote inside the name.
        if (c == quote) try buf.append(c);
    }
    try buf.append(quote);
}

fn isSQLiteDialect(dialect: Dialect) bool {
    return dialect.kind() == .sqlite;
}

fn defaultValueStr(comptime f: FieldInfo) ?[]const u8 {
    // comptimePrint 的泛型格式化在 `inline for (infos)` 下按表×字段展开,
    // 15+ 表的应用 schema 就会击穿默认 5000 分支限额(如 zenaipa);在此
    // 提升当前 comptime 子树的配额,避免 "exceeded backwards branches"。
    @setEvalBranchQuota(50_000);
    return switch (f.default) {
        .none => null,
        .bool => |v| if (v) "TRUE" else "FALSE",
        .int => |v| comptime std.fmt.comptimePrint("{d}", .{v}),
        .float => |v| comptime std.fmt.comptimePrint("{d}", .{v}),
        .string => |v| comptime std.fmt.comptimePrint("'{s}'", .{v}),
    };
}

const toSnakeCase = @import("../../codegen/graph.zig").toSnakeCase;
const pkColumn = @import("../../codegen/graph.zig").pkColumn;

/// A column as the *database* reports it. Owned: `name`, `sql_type` and
/// `udt_name` are allocated, release the list with `freeExistingColumns`.
pub const ExistingColumn = struct {
    name: []const u8,
    /// `information_schema.columns.data_type` — the driver's own type name for
    /// the column (`text`, `integer`, `varchar`), lower-cased. On PostgreSQL a
    /// type that is *not* one of its built-ins answers `user-defined` or
    /// `array`, with the concrete name in `udt_name`.
    sql_type: []const u8,
    /// PostgreSQL's `udt_name`, lower-cased; empty on every other dialect
    /// (MySQL's and SQLite's catalogs have no such column). It holds the
    /// concrete `pg_type.typname` — `vector` for a `vector(1536)` column,
    /// `_int4` for an `integer[]` one — i.e. exactly the name
    /// `information_schema.columns.data_type` replaces with `user-defined` /
    /// `array`. See `columnTypesAgree`.
    udt_name: []const u8 = "",
    not_null: bool,
    pk: bool,
};

/// An index as the *database* reports it. Owned: `name` and every string in
/// `columns` are allocated, release the list with `freeExistingIndexes`.
pub const ExistingIndex = struct {
    name: []const u8,
    unique: bool,
    /// The index's key columns, **in index order**. Empty unless
    /// `columns_comparable`.
    columns: []const []const u8 = &.{},
    /// Whether `columns` may be compared against a declared index at all.
    ///
    /// False whenever the database's answer cannot be read reliably: an
    /// expression/functional key, a partial index (`WHERE`), a non-btree
    /// access method (PostgreSQL `USING gin/hash/...`), an index PostgreSQL
    /// marks invalid, a key list with `INCLUDE` columns, or a key list that
    /// did not come back at all. A caller that compares anyway reports a
    /// difference that is not one — and index drift is a
    /// performance/consistency signal, not a broken read, so a false report
    /// costs a blocked deploy via `assertSchema` while a missed one costs a
    /// log line. **Skip, never guess.**
    columns_comparable: bool = false,
};

/// The introspection helpers' error set.
///
/// `InvalidTableName` is SQLite's alone and exists for one reason: `PRAGMA`
/// statements take their argument as **syntax** (`PRAGMA table_info(?)` is a
/// parse error), so a table name has to be interpolated there. A name carrying
/// the quote that closes the literal would end the argument early and turn the
/// rest of the name into more statement — the injection shape a bound
/// parameter exists to remove. The names come from a comptime schema and never
/// from user input, so this is a fail-closed guard rather than a sanitiser:
/// refuse the name, and say which one.
///
/// `IndexCatalogUnavailable` and `ForeignKeyCatalogUnavailable` are
/// PostgreSQL's alone, and each is the answer to a server that speaks the wire
/// protocol without carrying the catalog the comparison needs: `pg_index` and
/// `pg_class` answer while `pg_am` does not (`getPostgresIndexes`), or the
/// catalogs answer while `pg_proc` — where `generate_subscripts` would have to
/// live — does not (`getPostgresForeignKeys`). Both are *named* errors rather
/// than propagated driver failures, so a consumer can tell "this server cannot
/// compare this at all" from "the migration broke", and both are returned
/// before the statement that would be refused rather than after it: a refusal
/// poisons the caller's transaction (see `pgRelationListed`).
const IntrospectionError = sql_driver.Error || error{ UnsupportedDialect, InvalidTableName, IndexCatalogUnavailable, ForeignKeyCatalogUnavailable };

/// True when `name` can be interpolated into a SQLite `PRAGMA` argument.
///
/// SQLite accepts `'`, `"` and `` ` `` as identifier quotes, and the argument
/// here is interpolated — not escaped — so any of the three would end it
/// early; a NUL truncates the statement on the C side before SQLite ever sees
/// the rest. Everything else, spaces and non-ASCII included, is a legal
/// argument inside the quotes: this rejects the shapes that break the
/// statement, not the shapes one would not have chosen.
fn sqlitePragmaNameUsable(name: []const u8) bool {
    for (name) |c| {
        switch (c) {
            '\'', '"', '`', 0 => return false,
            else => {},
        }
    }
    return true;
}

/// Whether `err` is *the server refusing the statement* — the one condition the
/// two PostgreSQL catalog fallbacks in this file are written against
/// (`getPostgresIndexes`'s retry without `pg_am`, `checkPostgresExtensions`'s
/// tolerance for a server with no `pg_extension`).
///
/// `sql_driver.classify(err) == .client` is the direct spelling of it, and it is
/// the whole answer on a driver that reports a rejected statement as
/// `error.ExecFailed`.
///
/// `error.DriverFailed` is PostgreSQL's own spelling of the same event, and at
/// this level it is indistinguishable from a driver fault: `sqlstateToError`
/// maps SQLSTATE 42P01 (`undefined_table`) to `error.ExecFailed`, and
/// `toDriverError` — which every call through the `Driver` vtable goes through
/// — funnels everything outside its short list of named errors, `ExecFailed`
/// included, into `error.DriverFailed`. So "this server has no such catalog"
/// *arrives here as `DriverFailed` on PostgreSQL*, measured against HeliosDB
/// 4.41.1: the `pg_am` join is refused with SQLSTATE 42P01 and the migration
/// sees `error.DriverFailed`. Without this arm both fallbacks are dead code on
/// the very server they were written for.
///
/// Treating it as a refusal is safe because the two are told apart by *asking
/// again*: each fallback either succeeds (a degraded but honest answer) or
/// returns an error — never a silent success — so a genuine driver fault stays
/// a failure, just a named one. `.capacity` (a dead connection, a pool with
/// nothing to give) is in neither answer and propagates unchanged, which is
/// what a caller reacting to a lost connection needs.
fn postgresStatementRefused(err: anyerror) bool {
    return sql_driver.classify(err) == .client or err == error.DriverFailed;
}

/// The error carries no payload, so the name it refused is logged instead —
/// `warn`, because this is a diagnostic the caller is about to see as a
/// returned error, not a failed statement of its own.
fn reportUnusableSqliteName(pragma: []const u8, table_name: []const u8) void {
    zent_log.warn(
        "zent: refusing to build SQLite PRAGMA {s} for table {s} — the name contains a quote or NUL that would end the statement early; rename the table or reach it through a dialect that binds the name",
        .{ pragma, table_name },
    );
}

/// A lower-cased, owned copy of `text` — what `ExistingColumn` stores.
///
/// The comparison in `columnTypesAgree` is case-insensitive by construction,
/// and both catalog answers (`data_type`, `udt_name`) arrive in the server's own
/// spelling, so every string this struct owns is normalized once, here, rather
/// than at each comparison.
fn dupeLower(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const owned = try allocator.alloc(u8, text.len);
    for (text, owned) |byte, *dest| dest.* = std.ascii.toLower(byte);
    return owned;
}

/// Query existing columns for a table using dialect-specific metadata.
///
/// The table name is **bound** on PostgreSQL (`$1`) and MySQL (`?`), never
/// interpolated into a string literal, so a name carrying a quote cannot end
/// the predicate early. SQLite is the exception and cannot be: `PRAGMA` takes
/// no placeholders, so the name is checked first
/// (`sqlitePragmaNameUsable`) and refused with `error.InvalidTableName`
/// rather than emitted into a statement it would break.
pub fn getExistingColumns(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingColumn) {
    var result = std.array_list.Managed(ExistingColumn).init(allocator);
    errdefer freeExistingColumns(allocator, &result);

    const kind = driver_drv.dialect().kind();
    const is_sqlite = kind == .sqlite;
    const is_postgres = kind == .postgres;
    const is_mysql = kind == .mysql;

    if (is_sqlite and !sqlitePragmaNameUsable(table_name)) {
        reportUnusableSqliteName("table_info", table_name);
        return error.InvalidTableName;
    }

    // PostgreSQL's `udt_name` is appended to the select list, not folded into
    // the middle of it: it is the only place the concrete type of a column shows
    // up when `data_type` answers `USER-DEFINED` (an extension or custom type:
    // `vector`, `citext`, a domain) or `ARRAY` (any array: `_int4` for
    // `integer[]`) — comparing `data_type` alone reported a `type_mismatch` for
    // every such column — and keeping the first three columns exactly where they
    // were keeps every model of this query that already exists honest (the
    // allocation-failure sweep's catalog stub answers three). MySQL and SQLite
    // have no such column (MySQL's `information_schema.columns` is its own
    // catalog, not PostgreSQL's), so their query text is unchanged and their
    // `udt_name` stays empty.
    const sql_text = if (is_sqlite)
        try allocator.print("PRAGMA table_info(\"{s}\")", .{table_name})
    else if (is_postgres)
        try allocator.dupe(u8, "SELECT column_name, data_type, is_nullable, column_default, udt_name FROM information_schema.columns WHERE table_name = $1 AND table_schema = current_schema()")
    else if (is_mysql)
        try allocator.dupe(u8, "SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_name = ? AND table_schema = DATABASE()")
    else
        return error.UnsupportedDialect;
    defer allocator.free(sql_text);

    var rows = if (is_sqlite)
        try driver_drv.query(sql_text, &.{})
    else
        try driver_drv.query(sql_text, &.{.{ .string = table_name }});
    defer rows.deinit();

    while (rows.next()) |row| {
        const name = row.getText(if (is_sqlite) 1 else 0) orelse continue;
        const sql_type = row.getText(if (is_sqlite) 2 else 1) orelse "";
        // A driver that does not answer the trailing column reads as "no
        // `udt_name`" rather than as an error, and `columnTypesAgree` has a
        // fallback for exactly that.
        const udt_name = if (is_postgres) (row.getText(4) orelse "") else "";
        const not_null = if (is_sqlite)
            (row.getInt(3) orelse 0) != 0
        else
            std.ascii.eqlIgnoreCase(row.getText(2) orelse "YES", "NO");
        const pk = is_sqlite and (row.getInt(5) orelse 0) != 0;

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_type = try dupeLower(allocator, sql_type);
        errdefer allocator.free(owned_type);
        // Not allocated when absent, so `udt_name` is never a slice
        // `freeExistingColumns` would have to tell apart from the empty
        // default the struct carries on the other dialects.
        const owned_udt: []const u8 = if (udt_name.len == 0) "" else try dupeLower(allocator, udt_name);
        errdefer if (owned_udt.len > 0) allocator.free(owned_udt);

        try result.append(.{
            .name = owned_name,
            .sql_type = owned_type,
            .udt_name = owned_udt,
            .not_null = not_null,
            .pk = pk,
        });
    }
    if (rows.nextError()) |err| return err;
    return result;
}

pub fn freeExistingColumns(allocator: std.mem.Allocator, columns: *std.array_list.Managed(ExistingColumn)) void {
    for (columns.items) |c| {
        allocator.free(c.name);
        allocator.free(c.sql_type);
        // Only a PostgreSQL column carries one, and the empty default is not an
        // allocation (see `getExistingColumns`).
        if (c.udt_name.len > 0) allocator.free(c.udt_name);
    }
    columns.deinit();
}

/// Query existing indexes for a table using dialect-specific metadata.
///
/// Every dialect reads the key columns from a **structured catalog** — MySQL's
/// `information_schema.statistics`, PostgreSQL's `pg_index`/`pg_attribute`,
/// SQLite's `PRAGMA index_info` — never by parsing a rendered statement. An
/// index whose key list cannot be compared comes back with
/// `columns_comparable = false` (see `ExistingIndex`), which is the signal a
/// caller must honour instead of guessing.
pub fn getExistingIndexes(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingIndex) {
    return switch (driver_drv.dialect().kind()) {
        .sqlite => getSQLiteIndexes(allocator, driver_drv, table_name),
        .postgres => getPostgresIndexes(allocator, driver_drv, table_name),
        .mysql => getMySQLIndexes(allocator, driver_drv, table_name),
        // An unnamed dialect has no catalog query of its own; it was the
        // fallthrough before, and it still is.
        .unknown => error.UnsupportedDialect,
    };
}

/// Hand the accumulated key columns to the index at `current` and reset the
/// accumulator for the next one. A no-op before the first index.
///
/// `comparable` is the caller's verdict, which may depend on more than the
/// columns themselves (PostgreSQL's key count, SQLite's partial flag). An
/// index with no readable key at all is never comparable, a key list being
/// what an index is.
fn closeExistingIndex(
    result: *std.array_list.Managed(ExistingIndex),
    current: ?usize,
    keys: *std.array_list.Managed([]const u8),
    comparable: bool,
) !void {
    const idx = current orelse return;
    result.items[idx].columns = try keys.toOwnedSlice();
    result.items[idx].columns_comparable = comparable and result.items[idx].columns.len > 0;
}

/// `information_schema.statistics` is one row per (index, column), so
/// `seq_in_index` is what orders a multi-column index's key list.
///
/// Two shapes cannot be compared against the schema's key list:
///
///   - `column_name` is NULL for a **functional index** (MySQL 8.0.13+): the
///     key is an expression, not a column.
///   - `sub_part` is non-NULL for a **prefix index** (`KEY (c(10))`): the key
///     covers the first N characters, so reporting its column list as equal to
///     a schema index over the full column would claim a match that does not
///     exist — a prefix index is not the index the schema asked for.
///
/// MySQL has no partial indexes and InnoDB only btree access methods, so those
/// two cases are the whole of it here.
///
/// `pub` for the alloc-failure sweep in `src/test/allocation_failures_plan.zig`
/// — its only caller outside this module; `getExistingIndexes` remains the only
/// one inside it.
pub fn getMySQLIndexes(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingIndex) {
    var result = std.array_list.Managed(ExistingIndex).init(allocator);
    errdefer freeExistingIndexes(allocator, &result);

    var keys = std.array_list.Managed([]const u8).init(allocator);
    defer {
        // Reached on an error path only: `toOwnedSlice` hands the finished
        // list to the index it belongs to.
        for (keys.items) |k| allocator.free(k);
        keys.deinit();
    }

    var rows = try driver_drv.query(
        "SELECT index_name, non_unique, column_name, sub_part FROM information_schema.statistics WHERE table_name = ? AND table_schema = DATABASE() ORDER BY index_name, seq_in_index",
        &.{.{ .string = table_name }},
    );
    defer rows.deinit();

    var current: ?usize = null;
    var comparable = true;
    while (rows.next()) |row| {
        const name = row.getText(0) orelse continue;
        if (current == null or !std.mem.eql(u8, result.items[current.?].name, name)) {
            try closeExistingIndex(&result, current, &keys, comparable);
            // The copy is made first and released by `errdefer` when `append`
            // fails — declared inside the loop body, so it covers this
            // iteration only. Same shape as `getSQLiteIndexes`, and pinned the
            // same way: the sweep in `src/test/allocation_failures_plan.zig`
            // reaches this line through its MySQL catalog stub and fails each
            // `append` in turn.
            const owned_name = try allocator.dupe(u8, name);
            errdefer allocator.free(owned_name);
            try result.append(.{
                .name = owned_name,
                .unique = (row.getInt(1) orelse 1) == 0,
            });
            current = result.items.len - 1;
            comparable = true;
        }
        if (row.getText(2)) |column| {
            const owned_column = try allocator.dupe(u8, column);
            errdefer allocator.free(owned_column);
            try keys.append(owned_column);
        } else {
            comparable = false; // functional index: the key is an expression
        }
        if (row.getText(3) != null) comparable = false; // prefix index: partial coverage
    }
    if (rows.nextError()) |err| return err;
    try closeExistingIndex(&result, current, &keys, comparable);
    return result;
}

/// PostgreSQL, from the catalog: `pg_index` for the flags and `pg_attribute`
/// (joined through `indkey`) for the key columns.
///
/// `indkey` is an `int2vector` whose text form is the attribute numbers in key
/// order — `array_position` over it restores that order for the join, so the
/// rows arrive in index order. `pg_indexes.indexdef` is *not* used: its key
/// list is a rendered expression (`lower(a)`, `a DESC`, `("a")`), and parsing
/// SQL text back into a column list is how a comparison starts lying.
///
/// Nothing here can distinguish "the schema's index lost a column" from "this
/// is a different kind of index", so every index whose keys are not plain
/// columns of the table — expression keys, `WHERE` predicates, non-btree
/// access methods, `INCLUDE` payload columns, invalid indexes, or a key list
/// that does not add up — is reported as not comparable.
///
/// **A server that has no `pg_am` is still read, by name and uniqueness.**
/// PostgreSQL's access-method catalog is not part of what a wire-compatible
/// server has to carry, and one that omits it (HeliosDB Nano answers
/// `Table 'pg_am' does not exist` with SQLSTATE 42P01) refuses the whole
/// statement — so *every* index would go unreported, and the migration would
/// treat each declared index as missing and re-`CREATE` it. The access method is
/// therefore asked about **before** any query that joins it
/// (`pgRelationListed`), because a rejection poisons the transaction this runs
/// in: "is `pg_am` there?" is answered without a statement that can fail, and
/// the answer selects which read is sent. **Not listed** means the read without
/// the access-method join goes first — a server in that shape is read, not
/// refused, and the read is the one `readIndexCatalog` describes below.
/// **Listed** means the full read goes first, and a statement rejection behind
/// the gate is still handled the way it always was (a server can answer the
/// probe and refuse the query) — refused twice, the answer is
/// `error.IndexCatalogUnavailable` rather than a failure dressed as an empty
/// catalog. Either way, in the retry **no index is comparable**: the key list's
/// order is restored by the dropped `array_position` term and the access method
/// that decides `btree` is exactly what is missing, so the honest answer is
/// "unknown" — not "btree, go ahead and compare". Names and uniqueness survive
/// because neither needs `pg_am`, and those two are what the migration plans
/// against (`indexExists`) and what the drift report gates the key list on.
///
/// `pub` for the alloc-failure sweep in `src/test/allocation_failures_plan.zig`
/// — its only caller outside this module; `getExistingIndexes` remains the only
/// one inside it.
pub fn getPostgresIndexes(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingIndex) {
    var result = std.array_list.Managed(ExistingIndex).init(allocator);
    errdefer freeExistingIndexes(allocator, &result);

    // The access method before the query that joins it: on a server without it
    // the rejection would abort the migration's transaction, and a retry inside
    // a dead transaction cannot answer anything (see `pgRelationListed`). Only
    // this one relation is probed — `pg_index`, `pg_attribute` and
    // `pg_namespace` are read on both shapes below and a server may answer a
    // query over them without listing them in `pg_class` (HeliosDB Nano does).
    const access_method_listed = pgRelationListed(driver_drv, "pg_am");

    const args = [_]Value{.{ .string = table_name }};

    // The table name is bound (`$1`), not interpolated: a name carrying a
    // quote would otherwise end the predicate early. `relkind = 'r'` and the
    // schema predicate stay literal — they are this function's own constants.
    const sql_text =
        \\SELECT i.relname,
        \\       (ix.indisunique)::int,
        \\       (ix.indisvalid)::int,
        \\       (ix.indpred IS NOT NULL)::int,
        \\       (ix.indnatts <> ix.indnkeyatts)::int,
        \\       ix.indnkeyatts::int,
        \\       am.amname,
        \\       a.attname
        \\FROM pg_index ix
        \\JOIN pg_class i ON i.oid = ix.indexrelid
        \\JOIN pg_class t ON t.oid = ix.indrelid
        \\JOIN pg_am am ON am.oid = i.relam
        \\LEFT JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY (ix.indkey)
        \\WHERE t.relname = $1 AND t.relkind = 'r'
        \\  AND t.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = current_schema())
        \\ORDER BY i.relname, array_position(string_to_array(ix.indkey::text, ' ')::smallint[], a.attnum)
    ;

    // The retry: `sql_text` with the `pg_am` join and its column removed, and
    // the three `::int` casts on a boolean written as `CASE … THEN 1 ELSE 0
    // END`. The case form is not cosmetic — the server that has no `pg_am`
    // refuses `Boolean(false)::INT4` too ("Cannot cast Boolean(false) to
    // INT4"), so leaving the casts in would make the retry fail for the same
    // class of reason it exists to work around. The `ORDER BY` loses its
    // `array_position` term with the same justification: it exists to restore
    // the key *order*, and no key order is read on this path.
    const sql_no_am =
        \\SELECT i.relname,
        \\       CASE WHEN ix.indisunique THEN 1 ELSE 0 END,
        \\       CASE WHEN ix.indisvalid THEN 1 ELSE 0 END,
        \\       CASE WHEN ix.indpred IS NOT NULL THEN 1 ELSE 0 END,
        \\       CASE WHEN ix.indnatts <> ix.indnkeyatts THEN 1 ELSE 0 END,
        \\       ix.indnkeyatts::int,
        \\       a.attname
        \\FROM pg_index ix
        \\JOIN pg_class i ON i.oid = ix.indexrelid
        \\JOIN pg_class t ON t.oid = ix.indrelid
        \\LEFT JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY (ix.indkey)
        \\WHERE t.relname = $1 AND t.relkind = 'r'
        \\  AND t.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = current_schema())
        \\ORDER BY i.relname
    ;

    // Which of the two shapes answered. `true` also means the rows carry the
    // `amname` column, which shifts every column after `indnkeyatts` by one —
    // the parse below reads that offset off this flag instead of running twice.
    var method_known = access_method_listed;
    // The error the full read was refused with, when the probe said the catalog
    // is there and the server refused the query anyway. `null` on the probe's
    // own path: nothing failed, the access method is simply not listed.
    var refused_reason: ?[]const u8 = null;

    // The full read, when the access method is there to join. A refusal is the
    // one thing that makes the retry worth asking — `postgresStatementRefused`
    // is the whole condition, so `.capacity` (the connection is gone) is not
    // repaired by asking a shorter question and propagates unchanged instead;
    // see the helper for why `DriverFailed` counts as a refusal on this dialect.
    var full: ?sql_driver.Rows = null;
    if (access_method_listed) {
        full = driver_drv.query(sql_text, &args) catch |err| refused: {
            if (!postgresStatementRefused(err)) return err;
            refused_reason = @errorName(err);
            method_known = false;
            break :refused null;
        };
    }

    // The read that is sent whenever the full one was not: the probe said the
    // access method is not listed, or the server refused the statement that
    // joins it. Refused here too, this server has no index catalog to read at
    // all — named, not a raw driver error, so the caller can tell it from a
    // migration that broke.
    const rows = full orelse retry: {
        const retried = driver_drv.query(sql_no_am, &args) catch |retry_err| {
            if (!postgresStatementRefused(retry_err)) return retry_err;
            zent_log.warn(
                "zent: this PostgreSQL-wire server has no PostgreSQL index catalog — reading the indexes of table {s} failed with {s}, with and without the pg_am access-method join; indexes do not take part in the comparison",
                .{ table_name, @errorName(retry_err) },
            );
            return error.IndexCatalogUnavailable;
        };
        break :retry retried;
    };
    defer rows.deinit();

    if (!method_known) {
        // One line per table, naming the reason the key lists cannot be
        // compared — the error, when there was one, and the probe's answer when
        // there was not.
        zent_log.warn(
            "zent: this PostgreSQL-wire server has no `pg_am` ({s}), so the indexes of table {s} are read without the access method; they are still matched by name and uniqueness, but their key columns are not compared",
            .{ refused_reason orelse "not listed in its catalog", table_name },
        );
    }

    var keys = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit();
    }

    // Which shape answered decides one offset and one verdict, so it is read
    // here rather than duplicated into a second parse loop: the retry's select
    // list is `amname` shorter, which moves `attname` from column 7 to 6, and
    // it carries no access method at all.
    const attname_col: usize = if (method_known) 7 else 6;

    var current: ?usize = null;
    var comparable = true;
    var expected_keys: i64 = 0;
    var seen_keys: i64 = 0;
    while (rows.next()) |row| {
        const name = row.getText(0) orelse continue;
        if (current == null or !std.mem.eql(u8, result.items[current.?].name, name)) {
            try closeExistingIndex(&result, current, &keys, comparable and seen_keys == expected_keys);
            // As in `getMySQLIndexes`: the copy is made first, and released by
            // an `errdefer` scoped to this loop iteration when `append` fails.
            // The sweep in `src/test/allocation_failures_plan.zig` reaches this
            // line through its PostgreSQL catalog stub.
            const owned_name = try allocator.dupe(u8, name);
            errdefer allocator.free(owned_name);
            try result.append(.{
                .name = owned_name,
                .unique = (row.getInt(1) orelse 0) != 0,
            });
            current = result.items.len - 1;
            comparable = (row.getInt(2) orelse 0) != 0 // indisvalid
            and (row.getInt(3) orelse 1) == 0 // indpred IS NULL
            and (row.getInt(4) orelse 1) == 0 // indnatts == indnkeyatts (no INCLUDE)
                // No access method was read, so no key list is comparable — the
                // `and` short-circuits before column 6, which does not exist in
                // that shape. An unknown method is *not* `btree`: assuming it is
                // would compare a `USING gin`/`hash` index's keys as if it keyed
                // the declared columns, which is the guess `columns_comparable`
                // exists to refuse. The index keeps its name and its uniqueness,
                // and only the key list becomes "unknown".
            and method_known and std.mem.eql(u8, row.getText(6) orelse "", "btree");
            expected_keys = row.getInt(5) orelse 0;
            seen_keys = 0;
        }
        seen_keys += 1;
        if (comparable) {
            // A NULL attname is an expression key (attnum 0), which no
            // declared column list can be equal to.
            if (row.getText(attname_col)) |column| {
                const owned_column = try allocator.dupe(u8, column);
                errdefer allocator.free(owned_column);
                try keys.append(owned_column);
            } else {
                comparable = false;
            }
        }
    }
    if (rows.nextError()) |err| return err;
    try closeExistingIndex(&result, current, &keys, comparable and seen_keys == expected_keys);
    return result;
}

/// SQLite, in two phases: `PRAGMA index_list` for the names, then
/// `PRAGMA index_info` per index for its key columns.
///
/// The split is not cosmetic — the SQLite driver holds its connection mutex
/// for as long as a `Rows` value lives, so the first statement must be
/// finished before the second can be prepared.
///
/// `PRAGMA` takes no placeholders, so the table name is interpolated here and
/// checked first (`sqlitePragmaNameUsable`); `error.InvalidTableName` is the
/// answer for a name that would break the statement. The index names in the
/// second phase come from the catalog, not from a declaration, and go through
/// `quoteIdentToBuffer`, which doubles the quote.
fn getSQLiteIndexes(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingIndex) {
    var result = std.array_list.Managed(ExistingIndex).init(allocator);
    errdefer freeExistingIndexes(allocator, &result);

    const dialect = driver_drv.dialect();

    if (!sqlitePragmaNameUsable(table_name)) {
        reportUnusableSqliteName("index_list", table_name);
        return error.InvalidTableName;
    }

    {
        const list_sql = try allocator.print("PRAGMA index_list(\"{s}\")", .{table_name});
        defer allocator.free(list_sql);
        var rows = try driver_drv.query(list_sql, &.{});
        defer rows.deinit();
        while (rows.next()) |row| {
            const name = row.getText(1) orelse continue;
            // Column 4 is `partial`, available since SQLite 3.16; a partial
            // index has no equivalent in an IndexDef, so it is never compared.
            const partial = row.columnCount() > 4 and (row.getInt(4) orelse 0) != 0;
            // The name is duplicated before the list grows, and growing it is
            // an allocation: an `append(.{ .name = try dupe(…) })` whose
            // `append` fails leaves the copy owned by nobody. The `errdefer` is
            // dropped at the end of this iteration, so it covers exactly the
            // window between the copy and the item entering the list.
            const owned_name = try allocator.dupe(u8, name);
            errdefer allocator.free(owned_name);
            try result.append(.{
                .name = owned_name,
                .unique = (row.getInt(2) orelse 0) != 0,
                .columns_comparable = !partial,
            });
        }
        if (rows.nextError()) |err| return err;
    }

    var keys = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit();
    }

    for (result.items) |*idx| {
        var quoted = std.array_list.Managed(u8).init(allocator);
        defer quoted.deinit();
        try quoteIdentToBuffer(dialect, &quoted, idx.name);
        const info_sql = try allocator.print("PRAGMA index_info({s})", .{quoted.items});
        defer allocator.free(info_sql);

        var rows = try driver_drv.query(info_sql, &.{});
        defer rows.deinit();

        const declared_comparable = idx.columns_comparable;
        var columns_readable = true;
        while (rows.next()) |row| {
            // (seqno, cid, name): a NULL name is an expression key, and a
            // `cid` of -1 means the rowid, which no declared index names.
            const column = row.getText(2);
            const cid = row.getInt(1) orelse -1;
            if (column == null or cid < 0) {
                columns_readable = false;
                continue;
            }
            // Same window as the name above: the copy exists before the append
            // that would hand it to `keys`, so the append's failure has to
            // release it.
            const owned_column = try allocator.dupe(u8, column.?);
            errdefer allocator.free(owned_column);
            try keys.append(owned_column);
        }
        if (rows.nextError()) |err| return err;

        idx.columns = try keys.toOwnedSlice();
        idx.columns_comparable = declared_comparable and columns_readable and idx.columns.len > 0;
    }

    return result;
}

pub fn freeExistingIndexes(allocator: std.mem.Allocator, indexes: *std.array_list.Managed(ExistingIndex)) void {
    for (indexes.items) |i| {
        allocator.free(i.name);
        for (i.columns) |c| allocator.free(c);
        allocator.free(i.columns);
    }
    indexes.deinit();
}

/// A foreign key as the *database* reports it. Owned: `ref_table` and every
/// string in `columns` / `ref_columns` are allocated, release the list with
/// `freeExistingForeignKeys`.
///
/// There is deliberately **no name**: the comparison is by shape (see
/// `checkSchema`), and a name is the one thing the three catalogs do not agree
/// on — PostgreSQL and MySQL generate one, SQLite keeps none. `ON DELETE` /
/// `ON UPDATE` are not read either.
pub const ExistingForeignKey = struct {
    /// Local columns, in constraint order.
    columns: []const []const u8,
    /// The referenced table, as the database spells it.
    ref_table: []const u8,
    /// Referenced columns, in constraint order. Empty unless
    /// `ref_columns_comparable`.
    ref_columns: []const []const u8 = &.{},
    /// Whether `ref_columns` may be compared at all. False for exactly one
    /// shape: SQLite's `REFERENCES t` with no column list, where
    /// `PRAGMA foreign_key_list` reports a NULL `to` because the target is the
    /// other table's primary key. The constraint is real and its shape is not
    /// wrong — it is *unreadable*, and a caller that reads that as a difference
    /// blocks a deploy over its own guess.
    ref_columns_comparable: bool = true,
};

/// Query the foreign keys a table declares, using dialect-specific catalogs.
///
/// Every dialect reads a **structured catalog** — PostgreSQL's `pg_constraint`
/// (`contype = 'f'`) with its `conkey`/`confkey` arrays, MySQL/MariaDB's
/// `information_schema.key_column_usage`, SQLite's
/// `PRAGMA foreign_key_list(<table>)` — and never the `REFERENCES` clause out of
/// rendered DDL text, for the same reason `getExistingIndexes` does not parse
/// `indexdef`.
///
/// The table name is **bound** on PostgreSQL (`$1`) and MySQL (`?`), never
/// interpolated into a string literal. SQLite is the exception and cannot be:
/// `PRAGMA` takes no placeholders, so the name is checked first
/// (`sqlitePragmaNameUsable`) and refused with `error.InvalidTableName` rather
/// than emitted into a statement it would break.
///
/// A table that does not exist answers an **empty list**, not an error — on
/// SQLite because `PRAGMA` has no opinion about a name it cannot find, and on
/// the other two because a `WHERE table_name = …` over a catalog that does not
/// contain the table matches no rows. That is why `checkSchema` calls this only
/// after `getExistingColumns` has said the table is there: "no foreign keys" and
/// "no table at all" are different answers, and only the caller knows which
/// question it asked.
pub fn getExistingForeignKeys(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingForeignKey) {
    return switch (driver_drv.dialect().kind()) {
        .sqlite => getSQLiteForeignKeys(allocator, driver_drv, table_name),
        .postgres => getPostgresForeignKeys(allocator, driver_drv, table_name),
        .mysql => getMySQLForeignKeys(allocator, driver_drv, table_name),
        .unknown => error.UnsupportedDialect,
    };
}

/// Hand the accumulated columns to the foreign key at `current` and reset the
/// accumulators for the next one. A no-op before the first key.
///
/// `comparable` is the caller's verdict about the *referenced* column list,
/// which is only ever false when the database did not record one. A key that
/// came back with fewer referenced columns than local ones is not comparable
/// either: the two lists are positional, and a short one cannot be lined up.
fn closeExistingForeignKey(
    result: *std.array_list.Managed(ExistingForeignKey),
    current: ?usize,
    columns: *std.array_list.Managed([]const u8),
    ref_columns: *std.array_list.Managed([]const u8),
    comparable: bool,
) !void {
    const idx = current orelse return;
    result.items[idx].columns = try columns.toOwnedSlice();
    result.items[idx].ref_columns = try ref_columns.toOwnedSlice();
    result.items[idx].ref_columns_comparable = comparable and
        result.items[idx].ref_columns.len == result.items[idx].columns.len;
}

/// `information_schema.key_column_usage`, filtered to foreign keys by
/// `referenced_table_name IS NOT NULL` — the same row shape every other
/// constraint kind would have, minus the reference, so that one predicate is
/// what keeps only the constraints asked for.
///
/// `ordinal_position` restarts at 1 for each constraint and the rows arrive
/// ordered by it, which is what groups them without a name to group on.
///
/// This is standard `information_schema`, not a server-specific view: the same
/// statement runs unchanged on MySQL and MariaDB.
fn getMySQLForeignKeys(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingForeignKey) {
    var result = std.array_list.Managed(ExistingForeignKey).init(allocator);
    errdefer freeExistingForeignKeys(allocator, &result);

    var cols = std.array_list.Managed([]const u8).init(allocator);
    defer {
        // Reached on an error path only: `toOwnedSlice` hands each finished
        // list to the constraint it belongs to.
        for (cols.items) |c| allocator.free(c);
        cols.deinit();
    }
    var refs = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (refs.items) |c| allocator.free(c);
        refs.deinit();
    }

    var rows = try driver_drv.query(
        "SELECT column_name, referenced_table_name, referenced_column_name, ordinal_position FROM information_schema.key_column_usage WHERE table_name = ? AND table_schema = DATABASE() AND referenced_table_name IS NOT NULL ORDER BY constraint_name, ordinal_position",
        &.{.{ .string = table_name }},
    );
    defer rows.deinit();

    var current: ?usize = null;
    var comparable = true;
    while (rows.next()) |row| {
        const position = row.getInt(3) orelse continue;
        if (current == null or position == 1) {
            try closeExistingForeignKey(&result, current, &cols, &refs, comparable);
            // Same copy-then-append shape as `getMySQLIndexes`: the dupe is
            // released by an `errdefer` declared in the loop body when the
            // `append` itself fails — the entry never reached `result`, so the
            // function's `errdefer freeExistingForeignKeys` cannot free it.
            const owned_ref_table = try allocator.dupe(u8, row.getText(1) orelse "");
            errdefer allocator.free(owned_ref_table);
            try result.append(.{
                .columns = &.{},
                .ref_table = owned_ref_table,
            });
            current = result.items.len - 1;
            comparable = true;
        }
        if (row.getText(0)) |column| {
            const owned_column = try allocator.dupe(u8, column);
            errdefer allocator.free(owned_column);
            try cols.append(owned_column);
        } else {
            comparable = false; // no local column: not a shape to compare
        }
        if (row.getText(2)) |ref_column| {
            const owned_ref_column = try allocator.dupe(u8, ref_column);
            errdefer allocator.free(owned_ref_column);
            try refs.append(owned_ref_column);
        } else {
            comparable = false; // referenced column not recorded
        }
    }
    if (rows.nextError()) |err| return err;
    try closeExistingForeignKey(&result, current, &cols, &refs, comparable);
    return result;
}

/// PostgreSQL, from `pg_constraint` alone — no `pg_get_constraintdef()` text,
/// which would have to be parsed back into a shape and is exactly the kind of
/// comparison that starts lying.
///
/// `conkey` and `confkey` are the local and referenced attribute numbers **in
/// constraint order**, so `generate_subscripts` walks the two in step and each
/// `pg_attribute` join resolves one position of each side to a name. `contype =
/// 'f'` is the foreign-key filter; the namespace join keeps a same-named table
/// in another schema out of the answer.
///
/// **A server that cannot answer this is skipped, not refused.** The set
/// returning function in the `FROM` clause is what makes the read a single
/// statement, and it is a PostgreSQL function, not a catalog a wire-compatible
/// server has to carry: HeliosDB Nano answers `Table 'generate_subscripts' does
/// not exist` (SQLSTATE 42P01) and, like every rejected statement, leaves the
/// caller's transaction unusable — so the read is gated on `pg_proc` first
/// (`pgRelationListed`), the catalog such a function would be listed in. Not
/// listed means one warning and `error.ForeignKeyCatalogUnavailable`, which the
/// two callers turn into "this comparison is skipped" rather than a failed
/// migration: a declared key that cannot be compared must not be reported as
/// missing, because the report is what makes the planner emit a second
/// `ADD CONSTRAINT` for a key the database may already have.
fn getPostgresForeignKeys(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingForeignKey) {
    var result = std.array_list.Managed(ExistingForeignKey).init(allocator);
    errdefer freeExistingForeignKeys(allocator, &result);

    // Ahead of the query, never behind it: see the doc comment above.
    if (!pgRelationListed(driver_drv, "pg_proc")) {
        zent_log.warn(
            "zent: this PostgreSQL-wire server does not list `pg_proc`, so the foreign keys of table {s} are not compared — a declared key is left alone rather than reported missing and added a second time",
            .{table_name},
        );
        return error.ForeignKeyCatalogUnavailable;
    }

    // The table name is bound (`$1`), not interpolated: a name carrying a
    // quote would otherwise end the predicate early. `contype` and the schema
    // predicate stay literal — they are this function's own constants.
    const sql_text =
        \\SELECT con.conname,
        \\       a.attname,
        \\       rc.relname,
        \\       ra.attname,
        \\       k.ord
        \\FROM pg_constraint con
        \\JOIN pg_class t ON t.oid = con.conrelid
        \\JOIN pg_class rc ON rc.oid = con.confrelid
        \\JOIN pg_namespace n ON n.oid = t.relnamespace
        \\JOIN generate_subscripts(con.conkey, 1) AS k(ord) ON true
        \\JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = con.conkey[k.ord]
        \\JOIN pg_attribute ra ON ra.attrelid = rc.oid AND ra.attnum = con.confkey[k.ord]
        \\WHERE con.contype = 'f'
        \\  AND t.relname = $1
        \\  AND n.nspname = current_schema()
        \\ORDER BY con.conname, k.ord
    ;

    var rows = try driver_drv.query(sql_text, &.{.{ .string = table_name }});
    defer rows.deinit();

    var cols = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (cols.items) |c| allocator.free(c);
        cols.deinit();
    }
    var refs = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (refs.items) |c| allocator.free(c);
        refs.deinit();
    }

    var current: ?usize = null;
    var comparable = true;
    while (rows.next()) |row| {
        // `generate_subscripts` counts from 1, so a position of 1 is the start
        // of the next constraint.
        const position = row.getInt(4) orelse continue;
        if (current == null or position == 1) {
            try closeExistingForeignKey(&result, current, &cols, &refs, comparable);
            // Same copy-then-append shape as `getMySQLIndexes`: the dupe is
            // released by an `errdefer` declared in the loop body when the
            // `append` itself fails.
            const owned_ref_table = try allocator.dupe(u8, row.getText(2) orelse "");
            errdefer allocator.free(owned_ref_table);
            try result.append(.{
                .columns = &.{},
                .ref_table = owned_ref_table,
            });
            current = result.items.len - 1;
            comparable = true;
        }
        if (row.getText(1)) |column| {
            const owned_column = try allocator.dupe(u8, column);
            errdefer allocator.free(owned_column);
            try cols.append(owned_column);
        } else {
            comparable = false;
        }
        if (row.getText(3)) |ref_column| {
            const owned_ref_column = try allocator.dupe(u8, ref_column);
            errdefer allocator.free(owned_ref_column);
            try refs.append(owned_ref_column);
        } else {
            comparable = false;
        }
    }
    if (rows.nextError()) |err| return err;
    try closeExistingForeignKey(&result, current, &cols, &refs, comparable);
    return result;
}

/// SQLite, from `PRAGMA foreign_key_list(<table>)`: one row per (constraint,
/// column) shaped `(id, seq, "table", "from", "to", on_update, on_delete,
/// match)`.
///
/// There is no constraint name and no `ORDER BY`, so the rows are grouped by
/// `seq` restarting at 0 — SQLite emits one constraint's rows consecutively,
/// outermost loop over the constraint. `to` is NULL when the DDL said
/// `REFERENCES t` with no column list, which is recorded as *unreadable* rather
/// than as an empty list (see `ExistingForeignKey`).
///
/// Column 2 is the table **referenced**, not the table being asked about: the
/// pragma is a list of outgoing references.
///
/// `PRAGMA` takes no placeholders, so the table name is interpolated and checked
/// first (`sqlitePragmaNameUsable`); a name for a table that does not exist
/// answers an empty list, exactly like a table with no foreign keys.
fn getSQLiteForeignKeys(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingForeignKey) {
    var result = std.array_list.Managed(ExistingForeignKey).init(allocator);
    errdefer freeExistingForeignKeys(allocator, &result);

    if (!sqlitePragmaNameUsable(table_name)) {
        reportUnusableSqliteName("foreign_key_list", table_name);
        return error.InvalidTableName;
    }

    const sql_text = try allocator.print("PRAGMA foreign_key_list(\"{s}\")", .{table_name});
    defer allocator.free(sql_text);

    var rows = try driver_drv.query(sql_text, &.{});
    defer rows.deinit();

    var cols = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (cols.items) |c| allocator.free(c);
        cols.deinit();
    }
    var refs = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (refs.items) |c| allocator.free(c);
        refs.deinit();
    }

    var current: ?usize = null;
    var comparable = true;
    while (rows.next()) |row| {
        const seq = row.getInt(1) orelse continue;
        if (current == null or seq == 0) {
            try closeExistingForeignKey(&result, current, &cols, &refs, comparable);
            // Same copy-then-append shape as `getMySQLIndexes`: the dupe is
            // released by an `errdefer` declared in the loop body when the
            // `append` itself fails.
            const owned_ref_table = try allocator.dupe(u8, row.getText(2) orelse "");
            errdefer allocator.free(owned_ref_table);
            try result.append(.{
                .columns = &.{},
                .ref_table = owned_ref_table,
            });
            current = result.items.len - 1;
            comparable = true;
        }
        if (row.getText(3)) |column| {
            const owned_column = try allocator.dupe(u8, column);
            errdefer allocator.free(owned_column);
            try cols.append(owned_column);
        } else {
            comparable = false;
        }
        if (row.getText(4)) |ref_column| {
            const owned_ref_column = try allocator.dupe(u8, ref_column);
            errdefer allocator.free(owned_ref_column);
            try refs.append(owned_ref_column);
        } else {
            comparable = false;
        }
    }
    if (rows.nextError()) |err| return err;
    try closeExistingForeignKey(&result, current, &cols, &refs, comparable);
    return result;
}

pub fn freeExistingForeignKeys(allocator: std.mem.Allocator, foreign_keys: *std.array_list.Managed(ExistingForeignKey)) void {
    for (foreign_keys.items) |fk| {
        for (fk.columns) |c| allocator.free(c);
        allocator.free(fk.columns);
        allocator.free(fk.ref_table);
        for (fk.ref_columns) |c| allocator.free(c);
        allocator.free(fk.ref_columns);
    }
    foreign_keys.deinit();
}

/// A view as the *database* reports it. Owned: `name` and `definition` are
/// allocated, release the list with `freeExistingViews`.
pub const ExistingView = struct {
    /// The view's name, as the database spells it.
    name: []const u8,
    /// The definition **as the database stores it** — which is why it is not
    /// comparable with the schema's `view_sql`; see `getExistingViews`.
    definition: []const u8,
};

/// Query the view the database holds under `view_name`, from the catalog each
/// dialect keeps: PostgreSQL's `pg_views`, MySQL/MariaDB's
/// `information_schema.views`, SQLite's `sqlite_master` (`type = 'view'`). Never
/// from a rendered `CREATE VIEW` statement parsed back into shape, for the same
/// reason `getExistingIndexes` does not parse `indexdef`.
///
/// **`definition` cannot be compared against `TypeInfo.view_sql`**, and nothing
/// here tries to. The database does not keep the text the schema wrote:
///
///   - PostgreSQL stores a **rewritten** query in `pg_views.definition` —
///     explicit `::text`/`::integer` casts, added parentheses, schema-qualified
///     relation names, `WHERE ((status)::text = 'active'::text)` for a schema
///     that wrote `WHERE status = 'active'`.
///   - MySQL and MariaDB store their own normalization (backtick-quoted
///     identifiers, added parentheses), and the two servers differ from each
///     other in how much they rewrite.
///   - SQLite keeps the original statement text, but for a view this library
///     created that text begins `CREATE VIEW IF NOT EXISTS "<name>" AS ` — the
///     prefix is zent's, so the strings differ even there.
///
/// A string comparison would therefore report a difference on **every** database
/// and, through `assertSchema`, block every deploy — the false-report trap this
/// module's comparisons are written to avoid. That is why `checkSchema` reports
/// a missing relation (`missing_view`) but never a changed definition, and why
/// **a stale `view_sql` stays invisible**: the caller who wants to compare can
/// normalize per dialect from this function and decide, which is a judgement
/// this layer must not make for them.
///
/// The name is **bound** on all three dialects (`$1`, `?`), never interpolated:
/// every query here is an ordinary catalog `SELECT`, not a `PRAGMA`, so no name
/// has to be refused up front and `error.InvalidTableName` is never returned
/// from this function.
///
/// A name that is not a view of this schema answers an **empty list**, not an
/// error — a table of that name, a view in another schema, and no relation at
/// all are all "no view", which is the question asked here. (`checkSchema` asks
/// a different one — *any* relation of that name — which is why it probes with
/// `getExistingColumns`; see its doc comment.)
///
/// PostgreSQL withholds `definition` (NULL) from a user without privilege on the
/// view, and MySQL does the same without `SHOW VIEW`; the row is still returned,
/// with an empty `definition`, because the view's *existence* is the answer this
/// call also carries.
pub fn getExistingViews(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, view_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingView) {
    return switch (driver_drv.dialect().kind()) {
        .sqlite => getSQLiteViews(allocator, driver_drv, view_name),
        .postgres => getPostgresViews(allocator, driver_drv, view_name),
        .mysql => getMySQLViews(allocator, driver_drv, view_name),
        .unknown => error.UnsupportedDialect,
    };
}

/// The body the three dialect wrappers share: one catalog row per view, two
/// columns — the name and the stored definition — with the name bound as the
/// single parameter. `sql_text` is a comptime literal from each caller; nothing
/// is built from `view_name` at runtime.
fn getViewsByQuery(
    allocator: std.mem.Allocator,
    driver_drv: sql_driver.Driver,
    sql_text: []const u8,
    view_name: []const u8,
) IntrospectionError!std.array_list.Managed(ExistingView) {
    var result = std.array_list.Managed(ExistingView).init(allocator);
    errdefer freeExistingViews(allocator, &result);

    var rows = try driver_drv.query(sql_text, &.{.{ .string = view_name }});
    defer rows.deinit();

    while (rows.next()) |row| {
        const name = row.getText(0) orelse continue;
        // NULL means the catalog withheld the text (no privilege), not that the
        // view has an empty definition — see `getExistingViews`.
        const definition = row.getText(1) orelse "";

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_definition = try allocator.dupe(u8, definition);
        errdefer allocator.free(owned_definition);

        try result.append(.{ .name = owned_name, .definition = owned_definition });
    }
    if (rows.nextError()) |err| return err;
    return result;
}

/// SQLite: `sqlite_master`'s `sql` column, which is the statement text SQLite
/// kept — see `getExistingViews` for why that still differs from the schema's
/// `view_sql`. `sqlite_master` is an ordinary table, so the name is bound and
/// `sqlitePragmaNameUsable` is not needed (no statement text is built here).
fn getSQLiteViews(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, view_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingView) {
    return getViewsByQuery(
        allocator,
        driver_drv,
        "SELECT name, sql FROM sqlite_master WHERE type = 'view' AND name = ?",
        view_name,
    );
}

/// PostgreSQL: `pg_views`, filtered by `current_schema()` — the same schema
/// predicate `getExistingColumns` uses, so a view of another schema is not
/// mistaken for this one.
fn getPostgresViews(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, view_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingView) {
    return getViewsByQuery(
        allocator,
        driver_drv,
        "SELECT viewname, definition FROM pg_views WHERE schemaname = current_schema() AND viewname = $1",
        view_name,
    );
}

/// MySQL and MariaDB: `information_schema.views`, filtered by `DATABASE()` like
/// every other MySQL introspection here. Standard `information_schema`, not a
/// server-specific view, so the same statement runs on both servers.
fn getMySQLViews(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, view_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingView) {
    return getViewsByQuery(
        allocator,
        driver_drv,
        "SELECT table_name, view_definition FROM information_schema.views WHERE table_schema = DATABASE() AND table_name = ?",
        view_name,
    );
}

pub fn freeExistingViews(allocator: std.mem.Allocator, views: *std.array_list.Managed(ExistingView)) void {
    for (views.items) |v| {
        allocator.free(v.name);
        allocator.free(v.definition);
    }
    views.deinit();
}

fn columnExists(columns: []const ExistingColumn, name: []const u8) bool {
    for (columns) |c| {
        if (std.mem.eql(u8, c.name, name)) return true;
    }
    return false;
}

fn indexExists(indexes: []const ExistingIndex, name: []const u8) bool {
    for (indexes) |i| {
        if (std.mem.eql(u8, i.name, name)) return true;
    }
    return false;
}

/// Look up an ExistingIndex by name. Returns null when not found.
fn getExistingIndexByName(indexes: []const ExistingIndex, name: []const u8) ?ExistingIndex {
    for (indexes) |i| {
        if (std.mem.eql(u8, i.name, name)) return i;
    }
    return null;
}

/// Check whether a column name exists in a TableDef's columns list.
fn columnExistsTableDef(table: TableDef, name: []const u8) bool {
    for (table.columns) |c| {
        if (std.mem.eql(u8, c.name, name)) return true;
    }
    return false;
}

/// Look up an ExistingColumn by name. Returns null when not found.
fn getExistingColumnByName(columns: []const ExistingColumn, name: []const u8) ?ExistingColumn {
    for (columns) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

/// Generate ALTER TABLE ADD COLUMN SQL for a single column.
///
/// `converge_not_null` is `MigrateOptions.allow_nullability_change`: with it a
/// NOT NULL column is *added* NOT NULL (and a DEFAULT is then mandatory), rather
/// than arriving nullable and becoming the drift `check_nullability` reports.
///
/// Fail-closed on MySQL, like `createTableSQLAlloc`: `ADD COLUMN body TEXT
/// DEFAULT 'x'` is errno 1101 for exactly the reason `CREATE TABLE` would have
/// been, and this path is reached *instead of* it whenever the table already
/// exists — the case where the CREATE-side guard never runs. The two go through
/// the same classification (`findMySqlTextRestriction`), so the diagnosis and
/// the way out are the same sentence in both places.
///
/// `server` is what lets MariaDB through: on MariaDB >= 10.2.1 the same
/// `ADD COLUMN … DEFAULT 'x'` is legal and this emits it, while on MySQL it is
/// still refused (see `MySqlServer`). Every other restriction is unchanged.
fn alterTableAddColumnSQL(
    allocator: std.mem.Allocator,
    table_name: []const u8,
    col: ColumnDef,
    dialect: Dialect,
    converge_not_null: bool,
    server: MySqlServer,
) ![]const u8 {
    // The check is handed exactly what the statement below emits: a name, a
    // type, and — where one exists — a DEFAULT. UNIQUE and PRIMARY KEY are
    // deliberately not part of an `ADD COLUMN` here (see the note at the end of
    // this function), so they are not part of the declaration the check sees
    // either; flagging a constraint this statement never writes would refuse
    // SQL that the server accepts, for a difference the ALTER is not what
    // introduced. `not_null` rides along: it is emitted, and it only changes
    // whether a DEFAULT is mandatory.
    const emitted = ColumnDef{
        .name = col.name,
        .sql_type = col.sql_type,
        .logical_type = col.logical_type,
        .varchar_sql = col.varchar_sql,
        .vector_sql = col.vector_sql,
        .sql_type_override = col.sql_type_override,
        .not_null = col.not_null,
        .default_value = col.default_value,
    };
    if (findMySqlTextRestrictionWithServer(.{ .name = table_name, .columns = &.{emitted}, .primary_keys = &.{} }, &.{}, dialect, server)) |restriction| {
        return reportMySqlTextRestriction(restriction);
    }

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try buf.appendSlice("ALTER TABLE ");
    try quoteIdentToBuffer(dialect, &buf, table_name);
    try buf.appendSlice(" ADD COLUMN ");
    try quoteIdentToBuffer(dialect, &buf, col.name);
    try buf.print(" {s}", .{columnSQLType(col, dialect)});

    // For ALTER ADD COLUMN, avoid NOT NULL without a default to keep SQLite happy.
    const backfill = col.default_value orelse auditTimestampDefault(col, dialect);

    if (converge_not_null and col.not_null) {
        // SQLite rejects `ADD COLUMN … NOT NULL` with no DEFAULT outright, and
        // the other backends need a value for the rows the table already holds.
        // An explicit (or audit-timestamp) default is the only backfill this
        // layer is entitled to pick, so without one it refuses instead of
        // adding the nullable column the schema disagrees with — the drift this
        // option exists to stop creating.
        const dv = backfill orelse {
            // `warn`, like the drift report: an `err` line is what a failing
            // migration says, and the error this returns is the signal — the
            // log only adds the column name an error tag cannot carry.
            zent_log.warn(
                "zent: cannot add NOT NULL column {s}.{s} without a DEFAULT — the rows already in the table have no value to take; give the field a default, or make it Optional() and backfill it yourself",
                .{ table_name, col.name },
            );
            return error.NotNullNeedsDefault;
        };
        try buf.appendSlice(" NOT NULL");
        try buf.print(" DEFAULT {s}", .{dv});
    } else if (backfill) |dv| {
        try buf.print(" DEFAULT {s}", .{dv});
    }

    // UNIQUE is intentionally NOT appended: SQLite's ALTER TABLE ADD
    // COLUMN does not support it, and for PG/MySQL the createTableSQL
    // output already carries the UNIQUE constraint on this column.

    return buf.toOwnedSlice();
}

test "createTableSQL adds epoch default to audit timestamp columns" {
    const table = TableDef{
        .name = "audit_demo",
        .columns = &.{
            .{ .name = "id", .sql_type = "INTEGER", .logical_type = .int, .primary_key = true },
            .{ .name = "created_at", .sql_type = "INTEGER", .logical_type = .time },
            .{ .name = "updated_at", .sql_type = "INTEGER", .logical_type = .time },
        },
        .primary_keys = &.{"id"},
    };

    const sqlite_sql = try createTableSQL(table, Dialect.sqlite);
    defer std.heap.page_allocator.free(sqlite_sql);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_sql, "created_at") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_sql, "DEFAULT (unixepoch())") != null);

    const pg_sql = try createTableSQL(table, Dialect.postgres);
    defer std.heap.page_allocator.free(pg_sql);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "DEFAULT (EXTRACT(EPOCH FROM now())::bigint)") != null);

    const mysql_sql = try createTableSQL(table, Dialect.mysql);
    defer std.heap.page_allocator.free(mysql_sql);
    try std.testing.expect(std.mem.indexOf(u8, mysql_sql, "DEFAULT (UNIX_TIMESTAMP())") != null);

    // A plain Time column keeps no default.
    const plain = TableDef{
        .name = "t",
        .columns = &.{
            .{ .name = "id", .sql_type = "INTEGER", .logical_type = .int, .primary_key = true },
            .{ .name = "seen_at", .sql_type = "INTEGER", .logical_type = .time },
        },
        .primary_keys = &.{"id"},
    };
    const plain_sql = try createTableSQL(plain, Dialect.sqlite);
    defer std.heap.page_allocator.free(plain_sql);
    try std.testing.expect(std.mem.indexOf(u8, plain_sql, "DEFAULT") == null);
}

/// Generate DROP COLUMN SQL for a table column in a dialect-specific format.
fn dropColumnSQL(
    allocator: std.mem.Allocator,
    table_name: []const u8,
    column_name: []const u8,
    dialect: Dialect,
) ![]const u8 {
    // The first-character dispatch this replaces treated any name starting with
    // 's' as SQLite (`"sqlserver"` got SQLite's DROP COLUMN and would have been
    // sent to the server verbatim); an unrecognised name is refused instead.
    return switch (dialect.kind()) {
        .sqlite => allocator.print("ALTER TABLE \"{s}\" DROP COLUMN \"{s}\"", .{ table_name, column_name }),
        .postgres => allocator.print("ALTER TABLE \"{s}\" DROP COLUMN \"{s}\" CASCADE", .{ table_name, column_name }),
        .mysql => allocator.print("ALTER TABLE `{s}` DROP COLUMN `{s}`", .{ table_name, column_name }),
        .unknown => error.UnsupportedDialect,
    };
}

/// `normalizeSqlType` into a caller-provided stack buffer, falling back to the
/// heap when the declared type does not fit. The dialect rides along because
/// the comparison is not spelling-identity on every server: MySQL reports its
/// storage types under different names (see `normalizeSqlType`).
///
/// The fallback is the point. This comparison used to read
/// `normalizeSqlType(...) catch null` with a 128-byte stack buffer, so a type
/// longer than that — a hand-written `sql_type`, a `longtext CHARACTER SET …
/// COLLATE …`, an `ENUM` dump — made the whole comparison **disappear**, and
/// "no `type_mismatch` reported" is indistinguishable from "the types agree".
/// That is the one outcome a drift check must never fake, so a type that does
/// not fit is normalized on the heap rather than skipped.
fn normalizeTypeForCompare(
    allocator: std.mem.Allocator,
    sql_type: []const u8,
    stack_buf: *[128]u8,
    dialect: Dialect,
) error{OutOfMemory}!NormalizedType {
    if (normalizeSqlType(sql_type, stack_buf, dialect)) |norm| {
        return .{ .text = norm, .owned = null };
    } else |err| switch (err) {
        error.NoSpaceLeft => {},
    }

    const heap = try allocator.alloc(u8, sql_type.len);
    if (normalizeSqlType(sql_type, heap, dialect)) |norm| {
        return .{ .text = norm, .owned = heap };
    } else |_| {
        allocator.free(heap);
        return error.OutOfMemory;
    }
}

const NormalizedType = struct {
    text: []const u8,
    /// Set when `text` came from the heap and the caller must free it.
    owned: ?[]u8,

    fn deinit(self: NormalizedType, allocator: std.mem.Allocator) void {
        if (self.owned) |buf| allocator.free(buf);
    }
};

/// Whether a declared column type and the type the database reports describe
/// the same column — the **one** comparison `checkSchema` and the migration
/// plan's ALTER TYPE branch share.
///
/// Two sides, two spellings. The declared side comes from `columnSQLType`
/// (`TEXT`, `VARCHAR(120)`, `vector(1536)`, `integer[]`); the database side is
/// whatever the catalog answers — MySQL's storage names, SQLite's declared
/// type, and on PostgreSQL a name of its own for the columns that are neither
/// one of its built-ins nor spellable in `data_type`:
///
///   - `data_type = 'USER-DEFINED'` (an extension type, a domain, an enum)
///     with the real name in `udt_name` — `vector`, `citext`;
///   - `data_type = 'ARRAY'` with the element type in `udt_name` — `_int4` for
///     `integer[]`, `_citext` for `citext[]`.
///
/// Comparing `data_type` itself reported a `type_mismatch` for every such
/// column, so a schema declaring one could never pass `assertSchema` — and
/// `migrateSchema(allow_data_loss)` would then plan an `ALTER TYPE` to a type
/// the column already is. Both answers are resolved here: the `udt_name` is
/// what gets compared, the array marker is compared as a *marker*, and the
/// declared side is stripped the same way (a `schema.` qualifier and any
/// `(...)`/`[]` decoration), so `integer[]` matches `ARRAY`/`_int4` and
/// `vector(1536)` matches `USER-DEFINED`/`vector`.
///
/// It is a **comparison**, not a relaxation: only the names the catalog says
/// are the same type are unified (`text[]` against `_int4` is still reported,
/// and so is a scalar declared where the database holds an array). Dialects
/// other than PostgreSQL take the branch they always took, byte for byte —
/// including MySQL's storage-name mapping, which is why this cannot be one flat
/// `normalizeSqlType` call on a decorated name.
fn columnTypesAgree(
    allocator: std.mem.Allocator,
    schema_type: []const u8,
    db_col: ExistingColumn,
    schema_buf: *[128]u8,
    db_buf: *[128]u8,
    dialect: Dialect,
) error{OutOfMemory}!bool {
    if (dialect.kind() == .postgres and db_col.udt_name.len > 0) {
        // Case-insensitively: `getExistingColumns` lower-cases both answers, but
        // `ExistingColumn` is a public shape a caller can hand-build with the
        // server's own `USER-DEFINED`/`ARRAY` spelling, and taking the wrong
        // branch there would be an unreported difference.
        const db_is_array: ?bool = if (std.ascii.eqlIgnoreCase(db_col.sql_type, "user-defined"))
            false
        else if (std.ascii.eqlIgnoreCase(db_col.sql_type, "array"))
            true
        else
            null;
        if (db_is_array) |is_array| {
            // The marker first: `integer` and `integer[]` are different
            // columns, and only one of them is what `ARRAY` describes.
            const declared = declaredPgType(schema_type);
            if (declared.is_array != is_array) return false;

            const declared_norm = try normalizeTypeForCompare(allocator, pgInternalSpelling(declared.name), schema_buf, dialect);
            defer declared_norm.deinit(allocator);
            const db_norm = try normalizeTypeForCompare(allocator, pgInternalSpelling(pgUdtBaseName(db_col.udt_name, is_array)), db_buf, dialect);
            defer db_norm.deinit(allocator);
            return std.mem.eql(u8, declared_norm.text, db_norm.text);
        }
    }

    const schema_norm = try normalizeTypeForCompare(allocator, schema_type, schema_buf, dialect);
    defer schema_norm.deinit(allocator);
    const db_norm = try normalizeTypeForCompare(allocator, db_col.sql_type, db_buf, dialect);
    defer db_norm.deinit(allocator);
    return std.mem.eql(u8, schema_norm.text, db_norm.text);
}

/// A declared PostgreSQL type split into the name its element/own type is
/// compared under, and whether the declaration is an array of it.
const DeclaredPgType = struct {
    name: []const u8,
    is_array: bool,
};

/// Split a declared PostgreSQL type: drop every `[]` suffix and any `schema.`
/// qualifier, and report whether the declaration was an array.
///
/// Every `[]` goes, not just one: PostgreSQL's catalog reports `integer[][]`
/// and `integer[]` identically (`ARRAY` + `_int4`) — the dimensionality is not
/// in `information_schema.columns` at all — so refusing the multi-dimensional
/// spelling would be a drift report for a difference the server cannot express.
/// The qualifier goes because `udt_name` is the bare `pg_type.typname` with no
/// schema in it: a `public.vector(1536)` declaration has to compare equal to
/// the `vector` the catalog answers, and `udt_schema` (which would tell them
/// apart) is deliberately not read.
fn declaredPgType(schema_type: []const u8) DeclaredPgType {
    var name = std.mem.trim(u8, schema_type, " ");
    var is_array = false;
    while (std.mem.endsWith(u8, name, "[]")) {
        name = std.mem.trimEnd(u8, name[0 .. name.len - 2], " ");
        is_array = true;
    }
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name = name[dot + 1 ..];
    return .{ .name = name, .is_array = is_array };
}

/// The element type behind an `ARRAY` column's `udt_name`: PostgreSQL names
/// every array type after its element with a leading `_` (`_int4`, `_citext`).
/// A name without the prefix is returned as it is.
fn pgUdtBaseName(udt_name: []const u8, is_array: bool) []const u8 {
    if (is_array and udt_name.len > 1 and udt_name[0] == '_') return udt_name[1..];
    return udt_name;
}

/// `udt_name`'s spellings for the built-in types that have one, mapped onto
/// `information_schema`'s — `_float8` is a `double precision[]` column, so its
/// element is compared as `double precision`, and `_int2` as `smallint`.
///
/// The shared alias table (`normalizeSqlType`) already carries `int4` →
/// `integer`; this is the rest of the family. It is consulted from the
/// `USER-DEFINED`/`ARRAY` branch only, so the built-in comparison keeps its
/// exact behaviour, and every entry maps two spellings of *one* PostgreSQL
/// type — it can turn a false drift into a match, never a difference into one.
/// (`_bpchar` is `character`, whose element name would otherwise not match.)
fn pgInternalSpelling(name: []const u8) []const u8 {
    const aliases = [_]struct { udt: []const u8, info_schema: []const u8 }{
        .{ .udt = "int2", .info_schema = "smallint" },
        .{ .udt = "int8", .info_schema = "bigint" },
        .{ .udt = "float4", .info_schema = "real" },
        .{ .udt = "float8", .info_schema = "double precision" },
        .{ .udt = "bpchar", .info_schema = "character" },
    };
    for (aliases) |alias| {
        if (std.ascii.eqlIgnoreCase(name, alias.udt)) return alias.info_schema;
    }
    return name;
}

/// Generate ALTER COLUMN SQL to change a column's type.
///
/// SQLite has no native ALTER TYPE. MySQL's `MODIFY COLUMN name type` replaces
/// the full column definition and can silently strip NOT NULL, DEFAULT, UNIQUE,
/// and AUTO_INCREMENT attributes. Until the migration layer can reproduce the
/// complete existing definition, MySQL type changes fail closed.
fn alterColumnTypeSQL(
    allocator: std.mem.Allocator,
    table_name: []const u8,
    column_name: []const u8,
    new_type: []const u8,
    dialect: Dialect,
) ![]const u8 {
    return switch (dialect.kind()) {
        .sqlite, .unknown => error.UnsupportedDialect,
        .postgres => allocator.print("ALTER TABLE \"{s}\" ALTER COLUMN \"{s}\" TYPE {s} USING \"{s}\"::{s}", .{ table_name, column_name, new_type, column_name, new_type }),
        .mysql => error.MySQLTypeChangeUnsafe,
    };
}

/// Generate ALTER COLUMN SQL to change a column's nullability, the operation
/// `migrateSchema` used to never issue (so the schema and the database stayed
/// disagreed about NULL for the life of the deployment).
///
/// SQLite has no `ALTER COLUMN` — the only way is a full table rebuild — so it
/// is unsupported. MySQL changes a column only through `MODIFY COLUMN`, which
/// replaces the whole definition. `getExistingColumns` does fetch
/// `column_default` from `information_schema.columns`, but `ExistingColumn`
/// keeps only name / type / nullability, and the definition carries more that
/// no query here asks for: `EXTRA` (`AUTO_INCREMENT`, `ON UPDATE
/// CURRENT_TIMESTAMP`), charset, collation, comment, generated-column
/// expressions. A `MODIFY COLUMN` rebuilt from what this layer knows would
/// silently drop every one of them, so it fails closed, like the type change
/// above. Widening this is a matter of introspecting `EXTRA` and the rest
/// first — not of changing the SQL below.
fn alterColumnNullabilitySQL(
    allocator: std.mem.Allocator,
    table_name: []const u8,
    column_name: []const u8,
    not_null: bool,
    dialect: Dialect,
) ![]const u8 {
    return switch (dialect.kind()) {
        .postgres => allocator.print(
            "ALTER TABLE \"{s}\" ALTER COLUMN \"{s}\" {s} NOT NULL",
            .{ table_name, column_name, if (not_null) "SET" else "DROP" },
        ),
        .mysql => error.MySQLNullabilityChangeUnsafe,
        .sqlite, .unknown => error.UnsupportedDialect,
    };
}

/// Generate the `ALTER TABLE … ADD CONSTRAINT … FOREIGN KEY …` that adds a
/// declared foreign key to a table that already exists — the statement
/// `MigrateOptions.add_missing_foreign_keys` opts into, and the repair for
/// `SchemaDrift.Kind.missing_foreign_key`, which the default path only reports.
///
/// `not_valid` is PostgreSQL's `ADD CONSTRAINT … NOT VALID`: the constraint is
/// created without scanning the table, so the rows already in it are not checked
/// here and the lock is held for the catalog update alone. The scan is the
/// separate `validateConstraintSQL` statement `planMissingForeignKeys` plans
/// next to this one. PostgreSQL allows the clause on foreign key and check
/// constraints only; no other dialect has it, and the caller never asks for it
/// there.
///
/// `ON DELETE` / `ON UPDATE` come from the declaration, exactly as
/// `createTableSQLAlloc` writes them: the repaired constraint has to mean what
/// the inline one would have meant, and `checkSchema` does not compare the
/// actions, so a silent `NO ACTION` would be a behaviour change it could not
/// report.
fn addForeignKeySQLAlloc(
    allocator: std.mem.Allocator,
    table_name: []const u8,
    constraint_name: []const u8,
    fk: ForeignKeyDef,
    dialect: Dialect,
    not_valid: bool,
) ![]const u8 {
    // SQLite has no ADD CONSTRAINT; the caller already skips it, and this is the
    // second, fail-loud guard rather than a silent emission of invalid SQL.
    if (dialect.kind() == .sqlite) return error.UnsupportedDialect;

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try buf.appendSlice("ALTER TABLE ");
    try quoteIdentToBuffer(dialect, &buf, table_name);
    try buf.appendSlice(" ADD CONSTRAINT ");
    try quoteIdentToBuffer(dialect, &buf, constraint_name);
    try buf.appendSlice(" FOREIGN KEY (");
    for (fk.columns, 0..) |col, i| {
        if (i > 0) try buf.appendSlice(", ");
        try quoteIdentToBuffer(dialect, &buf, col);
    }
    try buf.appendSlice(") REFERENCES ");
    try quoteIdentToBuffer(dialect, &buf, fk.ref_table);
    try buf.appendSlice(" (");
    for (fk.ref_columns, 0..) |col, i| {
        if (i > 0) try buf.appendSlice(", ");
        try quoteIdentToBuffer(dialect, &buf, col);
    }
    try buf.appendSlice(") ON DELETE ");
    try buf.appendSlice(fk.on_delete);
    try buf.appendSlice(" ON UPDATE ");
    try buf.appendSlice(fk.on_update);
    if (not_valid) try buf.appendSlice(" NOT VALID");
    return buf.toOwnedSlice();
}

/// `ALTER TABLE … VALIDATE CONSTRAINT …`: the scan half of the PostgreSQL pair
/// `addForeignKeySQLAlloc` opens with `NOT VALID`, and the statement a table
/// holding an orphan fails on (`error.ForeignKeyViolation`, naming the
/// constraint).
///
/// Two statements rather than one plain `ADD CONSTRAINT` because the two take
/// different locks: the `NOT VALID` add holds `ACCESS EXCLUSIVE` for the catalog
/// update alone, while the validation scan holds the weaker
/// `SHARE UPDATE EXCLUSIVE`, so a large table is not blocked for the length of
/// the scan. PostgreSQL only; both statements carry the same plan slot, so the
/// preview and the run stay in step.
fn validateConstraintSQLAlloc(
    allocator: std.mem.Allocator,
    table_name: []const u8,
    constraint_name: []const u8,
    dialect: Dialect,
) ![]const u8 {
    if (dialect.kind() != .postgres) return error.UnsupportedDialect;

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    try buf.appendSlice("ALTER TABLE ");
    try quoteIdentToBuffer(dialect, &buf, table_name);
    try buf.appendSlice(" VALIDATE CONSTRAINT ");
    try quoteIdentToBuffer(dialect, &buf, constraint_name);
    return buf.toOwnedSlice();
}

/// The deterministic name `add_missing_foreign_keys` gives an added foreign key:
/// `fk_<table>_<columns…>` — the `uq_<table>_<column>` shape
/// `planUniqueColumnIndex` uses for a generated unique index. The table name is
/// part of it because MySQL scopes a constraint name to the whole schema, so two
/// tables must not collide on one; and an entity's foreign key is single-column,
/// so the local column is unique within a table and one table gets one name per
/// key. A name that does not fit `buf` answers null, and the key is left to the
/// drift report rather than named with a truncation that could collide with
/// another.
///
/// The comparison that *decides* whether to emit is shape-based
/// (`foreignKeyPresent`), never name-based, so this name only has to be stable:
/// the database may hold the key as `t_col_fkey`, `t_ibfk_1` or with no name at
/// all, and it is left alone.
///
/// Not length-checked against the server's identifier limit (63 bytes on
/// PostgreSQL, 64 on MySQL): like `uq_…`, the name is derived from the table and
/// column names as declared, and a schema whose own names sit at that limit is
/// the caller's decision — MySQL reports an over-long identifier rather than
/// truncating it silently, so the failure is visible there.
fn foreignKeyConstraintName(buf: []u8, table_name: []const u8, fk: ForeignKeyDef) ?[]const u8 {
    var len: usize = 0;
    if (!appendNamePart(buf, &len, "fk_")) return null;
    if (!appendNamePart(buf, &len, table_name)) return null;
    for (fk.columns) |col| {
        if (!appendNamePart(buf, &len, "_")) return null;
        if (!appendNamePart(buf, &len, col)) return null;
    }
    return buf[0..len];
}

/// Append `part` to a name accumulator, or answer false when it does not fit.
fn appendNamePart(buf: []u8, len: *usize, part: []const u8) bool {
    if (len.* + part.len > buf.len) return false;
    @memcpy(buf[len.*..][0..part.len], part);
    len.* += part.len;
    return true;
}

test "ALTER ADD COLUMN is NOT NULL only when nullability convergence is asked for" {
    const alloc = std.testing.allocator;

    const col = ColumnDef{
        .name = "status",
        .sql_type = "TEXT",
        .logical_type = .string,
        .not_null = true,
        .default_value = "'pending'",
    };

    // Default: the column arrives nullable, which is the drift `checkNullability`
    // then reports — the behaviour every existing caller has.
    const loose = try alterTableAddColumnSQL(alloc, "t", col, Dialect.sqlite, false, .mysql);
    defer alloc.free(loose);
    try std.testing.expectEqualStrings(
        "ALTER TABLE \"t\" ADD COLUMN \"status\" TEXT DEFAULT 'pending'",
        loose,
    );

    // Opted in: the default is what the rows already in the table take.
    const strict = try alterTableAddColumnSQL(alloc, "t", col, Dialect.sqlite, true, .mysql);
    defer alloc.free(strict);
    try std.testing.expectEqualStrings(
        "ALTER TABLE \"t\" ADD COLUMN \"status\" TEXT NOT NULL DEFAULT 'pending'",
        strict,
    );

    // An audit timestamp column's epoch default is a backfill like any other.
    const audit = ColumnDef{
        .name = "created_at",
        .sql_type = "INTEGER",
        .logical_type = .time,
        .not_null = true,
    };
    const audit_sql = try alterTableAddColumnSQL(alloc, "t", audit, Dialect.sqlite, true, .mysql);
    defer alloc.free(audit_sql);
    try std.testing.expectEqualStrings(
        "ALTER TABLE \"t\" ADD COLUMN \"created_at\" BIGINT NOT NULL DEFAULT (unixepoch())",
        audit_sql,
    );

    // An optional column has nothing to converge: no NOT NULL, no backfill.
    var optional_col = col;
    optional_col.not_null = false;
    optional_col.default_value = null;
    const optional_sql = try alterTableAddColumnSQL(alloc, "t", optional_col, Dialect.sqlite, true, .mysql);
    defer alloc.free(optional_sql);
    try std.testing.expectEqualStrings("ALTER TABLE \"t\" ADD COLUMN \"status\" TEXT", optional_sql);
}

test "a NOT NULL column with no DEFAULT refuses instead of arriving nullable" {
    const col = ColumnDef{
        .name = "status",
        .sql_type = "TEXT",
        .logical_type = .string,
        .not_null = true,
    };

    try std.testing.expectError(
        error.NotNullNeedsDefault,
        alterTableAddColumnSQL(std.testing.allocator, "t", col, Dialect.sqlite, true, .mysql),
    );

    // Without the option the column is still added — the old behaviour is only
    // ever left behind by an explicit decision.
    const sql = try alterTableAddColumnSQL(std.testing.allocator, "t", col, Dialect.sqlite, false, .mysql);
    defer std.testing.allocator.free(sql);
    try std.testing.expectEqualStrings("ALTER TABLE \"t\" ADD COLUMN \"status\" TEXT", sql);
}

test "ALTER COLUMN nullability renders on PostgreSQL, refuses elsewhere" {
    const alloc = std.testing.allocator;

    const set_sql = try alterColumnNullabilitySQL(alloc, "t", "c", true, Dialect.postgres);
    defer alloc.free(set_sql);
    try std.testing.expectEqualStrings("ALTER TABLE \"t\" ALTER COLUMN \"c\" SET NOT NULL", set_sql);

    const drop_sql = try alterColumnNullabilitySQL(alloc, "t", "c", false, Dialect.postgres);
    defer alloc.free(drop_sql);
    try std.testing.expectEqualStrings("ALTER TABLE \"t\" ALTER COLUMN \"c\" DROP NOT NULL", drop_sql);

    try std.testing.expectError(
        error.UnsupportedDialect,
        alterColumnNullabilitySQL(alloc, "t", "c", true, Dialect.sqlite),
    );
    try std.testing.expectError(
        error.MySQLNullabilityChangeUnsafe,
        alterColumnNullabilitySQL(alloc, "t", "c", true, Dialect.mysql),
    );
}

/// One statement a `migrateSchemaWithOptions` run would execute, in execution
/// order. `sql` is owned by the plan list (`freePlannedStatements` releases
/// it); `version` is the `zent_schema_migrations` history row recorded after a
/// successful exec, or null for the statements the migration deliberately does
/// not record (DROP COLUMN, nullability convergence).
pub const PlannedStatement = struct {
    sql: []const u8,
    version: ?i64,
};

/// Release a plan (its statements' SQL and the list itself).
///
/// `pub` for the same sweep as `planMigrateStatements`, which owns the plan it
/// gets back and has to free it.
pub fn freePlannedStatements(allocator: std.mem.Allocator, plan: *std.array_list.Managed(PlannedStatement)) void {
    for (plan.items) |s| allocator.free(s.sql);
    plan.deinit();
}

/// Append one statement to a plan, releasing that statement's SQL when the
/// append itself fails.
///
/// `plan.append(.{ .sql = try createX(…) })` builds the statement **before**
/// the list grows, and the growth is an allocation that can fail: the new item
/// never reaches `plan.items`, so the caller's `errdefer
/// freePlannedStatements` (which walks exactly that list) cannot see it and the
/// SQL buffer leaks. Routing every append through here makes the error path
/// own the statement from the moment it exists. The list itself is unchanged
/// when `append` fails (`ensureUnusedCapacity` then `appendAssumeCapacity`), so
/// freeing here is the whole cleanup.
fn appendPlanned(
    allocator: std.mem.Allocator,
    plan: *std.array_list.Managed(PlannedStatement),
    statement_sql: []const u8,
    version: ?i64,
) !void {
    errdefer allocator.free(statement_sql);
    try plan.append(.{ .sql = statement_sql, .version = version });
}

/// Compute the ordered statement list a `migrateSchemaWithOptions` run would
/// execute, without executing anything.
///
/// This is the single diff the real path and the dry-run share: the real path
/// plans and then execs each statement (recording `version` when one is
/// carried); the dry-run plans through this same function and prints the
/// result. Because both sides call this one function, the preview cannot drift
/// from what a real run would do — the statement set, the order and the
/// opt-in gates are decided here, once.
///
/// `driver` is used for **read-only** introspection only — table/column/index
/// existence through the catalog helpers, never `exec` — so the real path can
/// hand its transaction driver and the dry-run its plain driver. `applied` is
/// the history snapshot the version gates check against: the same snapshot the
/// real path reads before opening its transaction, so a plan is always the
/// answer to "given this history, what runs next".
///
/// One ordering subtlety: the ADD COLUMN loop is skipped for a table this run
/// creates. The real path introspects a freshly created table (every column
/// present, by construction) and emits nothing there; planning against the
/// pre-creation state would otherwise invent ALTERs the CREATE TABLE already
/// carries. The other per-column gates need no such skip — they are keyed on a
/// column *existing* in the introspected state, which a not-yet-created table
/// fails for every column — and the named-index check still runs, matching the
/// real path, which creates named indexes even on a table it just created.
///
/// `pub` for the alloc-failure sweep in `src/test/allocation_failures_plan.zig`
/// — its only caller outside this module; `migrateSchemaWithOptions` is still
/// the only one inside it.
pub fn planMigrateStatements(
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
    comptime infos: []const TypeInfo,
    opts: MigrateOptions,
    applied: []const AppliedMigration,
) !std.array_list.Managed(PlannedStatement) {
    const dialect = driver.dialect();
    var plan = std.array_list.Managed(PlannedStatement).init(allocator);
    errdefer freePlannedStatements(allocator, &plan);

    // Which server the DDL is for, asked at most once per plan. A `.mysql`-kind
    // connection may be MySQL or MariaDB and the two disagree about a text
    // `DEFAULT` (see `MySqlServer`); every generator below is handed this so a
    // preview and the run it previews classify the same. The probe only runs
    // when the schema actually declares such a `DEFAULT` (`graphHasMySqlTextDefault`),
    // and on any other dialect — or when the probe cannot answer — this stays
    // `.mysql`: the stricter rules, which is the only answer that never widens
    // what a server accepts.
    const mysql_server: MySqlServer = if (dialect.kind() == .mysql and graphHasMySqlTextDefault(infos))
        detectMySqlServer(driver)
    else
        .mysql;

    // Step 1: create tables, views, and M2M junction tables. `created[i]`
    // records whether entity i is created by this run, so step 2 can tell
    // "fresh table, matches the schema by construction" apart from "existing
    // table, diff it". Same existence + history gates as the real path.
    var created: [infos.len]bool = @splat(false);
    inline for (infos, 0..) |info, i| {
        if (info.is_view) {
            const version = computeMigrationVersion(info.table_name, "create_view", "");
            if (!versionContains(applied, version)) {
                try appendPlanned(allocator, &plan, try createViewSQLAlloc(allocator, info, dialect), version);
            } else {
                // Version is recorded but the view may have been dropped
                // out-of-band. If the view no longer exists, re-create it.
                var existing = try getExistingColumns(allocator, driver, info.table_name);
                if (existing.items.len == 0) {
                    existing.deinit();
                    try appendPlanned(allocator, &plan, try createViewSQLAlloc(allocator, info, dialect), version);
                } else {
                    freeExistingColumns(allocator, &existing);
                }
            }
        } else {
            const table = comptime tableFromTypeInfoCrossRef(info, infos);
            warnOutOfGraphEdgeRefs(info, infos);
            warnDegradedColumnTypes(table, dialect);
            const version = computeMigrationVersion(info.table_name, "create_table", "");
            // `created` is true only when the table is genuinely absent
            // before this run: only then does the CREATE build a fresh table
            // that matches the schema by construction, so only then does the
            // real path find every column present in step 2 and emit nothing.
            // When the version is missing from the history but the table
            // already exists (created by hand, or a wiped history), the
            // CREATE TABLE IF NOT EXISTS is a no-op and the real path still
            // diffs — and adds to — the existing table.
            if (!versionContains(applied, version)) {
                try appendPlanned(allocator, &plan, try createTableSQLAllocWithServer(allocator, table, dialect, mysql_server), version);
                var existing = try getExistingColumns(allocator, driver, table.name);
                if (existing.items.len == 0) {
                    existing.deinit();
                    created[i] = true;
                } else {
                    freeExistingColumns(allocator, &existing);
                }
            } else {
                // Version is recorded but the table may have been dropped
                // out-of-band. If the table no longer exists, re-create it.
                var existing = try getExistingColumns(allocator, driver, table.name);
                if (existing.items.len == 0) {
                    existing.deinit();
                    try appendPlanned(allocator, &plan, try createTableSQLAllocWithServer(allocator, table, dialect, mysql_server), version);
                    created[i] = true;
                } else {
                    freeExistingColumns(allocator, &existing);
                }
            }
        }
    }

    // M2M junction tables: only declared on one side at a time, and only
    // when the edge doesn't use an explicit edge schema (through).
    inline for (infos) |info| {
        if (info.is_view) continue;
        inline for (info.edges) |e| {
            if (e.relation == .m2m and e.through == null) {
                const jtable = comptime junctionTableForEdge(e, info, infos);
                const edge_target_table = comptime edgeRefTarget(e, infos).table;
                // The name is an entity's table (see
                // `.junction_name_collision`): the CREATE below is a no-op
                // against the table that entity's own step just created, so
                // the relation surface ends up reading the wrong columns. It
                // cannot be repaired here — only one of the two names can
                // exist — so it is said out loud at the moment it is created,
                // in the dry run too.
                // Only from the side whose table name sorts first — the side the junction
                // name is derived *from*, the same two names `junctionTableForEdge`
                // sorted (a declared target `table_name`, not the short name). Both
                // sides of a symmetric edge reach this line, and one junction
                // deserves one warning.
                if (comptime std.mem.lessThan(u8, info.table_name, edge_target_table)) {
                    if (comptime junctionNameOwner(infos, jtable)) |owner| {
                        zent_log.warn(
                            "zent: the M2M edge {s} <-> {s} joins through '{s}', which is already the table of entity {s}; the junction's CREATE TABLE IF NOT EXISTS is a no-op and the relation query will read that table's columns — give the entity a different table name or rename one side",
                            .{ info.table_name, edge_target_table, jtable.name, owner.name },
                        );
                    }
                }
                const version = computeMigrationVersion(jtable.name, "create_junction", "");
                if (!versionContains(applied, version)) {
                    try appendPlanned(allocator, &plan, try createTableSQLAllocWithServer(allocator, jtable, dialect, mysql_server), version);
                } else {
                    // Version is recorded but the junction table may have
                    // been dropped out-of-band. Re-create it if missing.
                    var existing = try getExistingColumns(allocator, driver, jtable.name);
                    if (existing.items.len == 0) {
                        existing.deinit();
                        try appendPlanned(allocator, &plan, try createTableSQLAllocWithServer(allocator, jtable, dialect, mysql_server), version);
                    } else {
                        freeExistingColumns(allocator, &existing);
                    }
                }
            }
        }
    }

    // Step 2: for each non-view entity, add missing columns and indexes, plus
    // the opt-in convergences. The live schema (introspected via
    // information_schema / PRAGMA) is the authoritative gate — exactly the
    // checks the real path performs before each exec.
    inline for (infos, 0..) |info, i| {
        if (info.is_view) continue;

        const table = comptime tableFromTypeInfoCrossRef(info, infos);

        var existing_cols = try getExistingColumns(allocator, driver, table.name);
        defer freeExistingColumns(allocator, &existing_cols);

        if (!created[i]) {
            inline for (table.columns) |col| {
                if (!columnExists(existing_cols.items, col.name)) {
                    try appendPlanned(
                        allocator,
                        &plan,
                        try alterTableAddColumnSQL(allocator, table.name, col, dialect, opts.allow_nullability_change, mysql_server),
                        computeMigrationVersion(info.table_name, "add_column", col.name),
                    );
                }
            }
        }

        // Phase 3 Task 12 — DROP COLUMN: remove columns that exist in the
        // database but not in the schema. Guarded by opts.drop_columns to
        // avoid accidental data loss. No version recording: column names are
        // runtime data from introspection.
        if (opts.drop_columns) {
            for (existing_cols.items) |existing_col| {
                if (!columnExistsTableDef(table, existing_col.name)) {
                    try appendPlanned(
                        allocator,
                        &plan,
                        try dropColumnSQL(allocator, table.name, existing_col.name, dialect),
                        null,
                    );
                }
            }
        }

        // Phase 3 Task 12 — ALTER TYPE: change column types that differ
        // between the database and the schema. Guarded by opts.allow_data_loss;
        // SQLite is skipped (unsupported).
        if (opts.allow_data_loss) {
            inline for (table.columns) |col| {
                if (columnExists(existing_cols.items, col.name)) {
                    const existing_col = getExistingColumnByName(existing_cols.items, col.name) orelse unreachable;
                    const schema_type = columnSQLType(col, dialect);
                    // The same comparison `checkSchema` makes, through the same
                    // `columnTypesAgree`: one implementation, so a plan
                    // cannot disagree with the drift report it previews — and
                    // the heap fallback is why a declared type longer than the
                    // stack buffer is *compared* here instead of erroring
                    // `NoSpaceLeft` out of the whole plan. The type comes from
                    // `columnSQLType`, not from `col.sql_type` (the value the
                    // graph resolved for the dialect it was built with): a
                    // `.SqlType` / `VarChar(n)` column must be altered to the
                    // type this dialect declares, the one just compared.
                    var schema_buf: [128]u8 = undefined;
                    var db_buf: [128]u8 = undefined;
                    if (!try columnTypesAgree(allocator, schema_type, existing_col, &schema_buf, &db_buf, dialect)) {
                        // Skip ALTER TYPE on SQLite, which has no such statement
                        // (`alterColumnTypeSQL` refuses it); an unrecognised dialect
                        // is passed through so that function refuses it *by name*
                        // rather than being skipped silently here.
                        if (dialect.kind() != .sqlite) {
                            const version = computeMigrationVersion(info.table_name, "alter_type", col.name);
                            if (!versionContains(applied, version)) {
                                try appendPlanned(
                                    allocator,
                                    &plan,
                                    try alterColumnTypeSQL(allocator, table.name, col.name, schema_type, dialect),
                                    version,
                                );
                            }
                        }
                    }
                }
            }
        }

        // Nullability of an **existing** column — the opt-in that fixes the
        // drift `checkNullability` reports. Gated like drop_columns /
        // allow_data_loss because SET NOT NULL fails on rows already holding
        // a NULL. SQLite is skipped: it has no ALTER COLUMN at all.
        if (opts.allow_nullability_change and dialect.kind() != .sqlite) {
            inline for (table.columns) |col| {
                if (getExistingColumnByName(existing_cols.items, col.name)) |existing_col| {
                    if (db_nullableOf(existing_col) != !col.not_null) {
                        try appendPlanned(
                            allocator,
                            &plan,
                            try alterColumnNullabilitySQL(allocator, table.name, col.name, col.not_null, dialect),
                            null,
                        );
                    }
                }
            }
        }

        // No index catalog on this server (HeliosDB Nano): the existing index
        // set is unknown, so planning an index here would duplicate whatever is
        // already there. Skip the index half of this table's plan.
        index_plan: {
            var existing_idxs = getExistingIndexes(allocator, driver, table.name) catch |err| switch (err) {
                error.IndexCatalogUnavailable => break :index_plan,
                else => return err,
            };
            defer freeExistingIndexes(allocator, &existing_idxs);

            inline for (info.indexes) |idx| {
                const idx_def = indexDefFromInfo(idx);
                if (!indexExists(existing_idxs.items, idx_def.name)) {
                    const version = computeMigrationVersion(info.table_name, "create_index", idx.name);
                    try appendPlanned(
                        allocator,
                        &plan,
                        try createIndexSQLForTableAllocWithServer(allocator, idx_def, table, dialect, mysql_server),
                        version,
                    );
                }
            }

            // A **column** declared UNIQUE, on a table that already exists. The
            // declaration is inline in `CREATE TABLE` (and `ALTER TABLE ADD COLUMN`
            // cannot carry it — see `alterTableAddColumnSQL`, which drops it on
            // purpose), so a table created before the field was marked unique never
            // gets the constraint. That is not a cosmetic drift: with no unique
            // index the statement `SaveOrUpdateOn` builds is rejected outright
            // ("ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE
            // constraint" on SQLite and PostgreSQL), so every upsert call site
            // against that table fails at runtime while the schema says it works.
            // The dialect-neutral form is a unique index over the one column — no
            // table rebuild, no data moved.
            //
            // Silent when a unique index exists whose keys could not be read
            // (`lower(email)`, `email(10)`, a `WHERE`): such an index does
            // constrain the column, so "is it constrained?" has no answer and a
            // second index would be a guess. The primary key is skipped by
            // `uniqueColumnChecked` — it is unique by construction.
            if (!created[i] and !hasUnreadableUniqueIndex(existing_idxs.items)) {
                inline for (table.columns) |col| {
                    try planUniqueColumnIndex(allocator, &plan, info, table, col, existing_idxs.items, dialect, mysql_server);
                }
            }
        }

        // A foreign key the schema declares and the database does not have — the
        // other half of Z31, opt-in for the same reason `drop_columns` is: an
        // `ALTER TABLE … ADD CONSTRAINT` can fail against a table that already
        // holds rows, and that decision is the caller's (see
        // `MigrateOptions.add_missing_foreign_keys` for what each dialect does
        // with it). `created[i]` tables need nothing: the CREATE TABLE that made
        // them carries its keys, and so does the one this run just planned.
        //
        // Last in the loop body on purpose: an FK whose column the migration adds
        // in this same run needs the ADD COLUMN to come first in the plan, and it
        // does — that statement is appended above.
        if (opts.add_missing_foreign_keys and !created[i]) {
            try planMissingForeignKeys(allocator, &plan, driver, table, dialect);
        }
    }

    return plan;
}

/// Plan the unique index a **column-level** `UNIQUE` needs on a table that
/// already exists — see the call site in `planMigrateStatements` for why the
/// declaration is not there already.
///
/// Returns without planning anything when the constraint is already the
/// primary key's (`uniqueColumnChecked`), when some unique index already forces
/// exactly this column (`indexForcesColumnAlone`), or when the name it would
/// use is taken — the last one after trying a suffixed name, because an index
/// of that name which does *not* force the column leaves the promise unkept.
fn planUniqueColumnIndex(
    allocator: std.mem.Allocator,
    plan: *std.array_list.Managed(PlannedStatement),
    comptime info: TypeInfo,
    table: TableDef,
    col: ColumnDef,
    existing_idxs: []const ExistingIndex,
    dialect: Dialect,
    server: MySqlServer,
) !void {
    if (!uniqueColumnChecked(col, table)) return;
    if (indexForcesColumnAlone(existing_idxs, col.name)) return;

    var name_buf: [256]u8 = undefined;
    var idx_name = std.fmt.bufPrint(&name_buf, "uq_{s}_{s}", .{ table.name, col.name }) catch return;
    if (indexExists(existing_idxs, idx_name)) {
        idx_name = std.fmt.bufPrint(&name_buf, "uq_{s}_{s}_zent", .{ table.name, col.name }) catch return;
        if (indexExists(existing_idxs, idx_name)) return;
    }

    const uniq_def = IndexDef{ .name = idx_name, .columns = &[_][]const u8{col.name}, .unique = true };
    if (findMySqlTextRestrictionWithServer(table, &.{uniq_def}, dialect, server)) |_| {
        // MySQL cannot index a BLOB/TEXT/JSON key without a key length, and a
        // prefix would change what the UNIQUE index means. The create-table
        // path warns for the same column; skipping keeps the migration alive
        // on a server that refuses the index outright.
        zent_log.warn(
            "zent: MySQL cannot index {s}.{s} ({s}, errno 1170), so no UNIQUE index was created for it; use field.String (VARCHAR(255) on MySQL) or drop the uniqueness",
            .{ table.name, col.name, columnSQLType(col, dialect) },
        );
        return;
    }
    try appendPlanned(
        allocator,
        plan,
        try createIndexSQLForTableAllocWithServer(allocator, uniq_def, table, dialect, server),
        computeMigrationVersion(info.table_name, "create_unique_index", col.name),
    );
}

/// Plan the `ALTER TABLE … ADD CONSTRAINT … FOREIGN KEY` statements that repair
/// the `missing_foreign_key` drift on a table that already exists — the body of
/// `MigrateOptions.add_missing_foreign_keys`.
///
/// The gate is the same introspection `checkSchema` uses (`foreignKeyPresent`,
/// by shape), so the run after a successful one sees the constraint this one
/// added and plans nothing: the repair is idempotent for the same reason the
/// drift report is stable. Only a key the schema declares and the database lacks
/// is touched; the reverse direction — a constraint the database has and the
/// schema does not — stays as silent here as it is in `checkSchema`.
///
/// PostgreSQL gets both halves of the pair (`addForeignKeySQLAlloc` with
/// `NOT VALID`, then `validateConstraintSQLAlloc`); every other dialect gets the
/// single plain statement. Both statements of the pair are planned, so a preview
/// and the run it previews are the same list. The `VALIDATE` carries no version:
/// it is the second half of one migration, and on the migration's own
/// transaction a failure there rolls the whole thing back.
///
/// **SQLite is a no-op**, decided here rather than at the call site because it
/// is a property of the dialect: SQLite has no `ALTER TABLE ADD CONSTRAINT` at
/// all, and the only way to add or change one is to rebuild the table — a
/// feature of its own, deliberately not smuggled into this option. So nothing is
/// emitted, the drift keeps being reported there, and a SQLite run stays
/// byte-identical to the default.
///
/// **M2M junction tables are not repaired here.** Their two keys are part of the
/// `CREATE TABLE` that makes them (`junctionTableForEdge`), the junction
/// traversal in `planMigrateStatements` is a separate one, and a key dropped out
/// of band from a junction is a different repair from the one this option exists
/// for — the drift report is where it stays.
fn planMissingForeignKeys(
    allocator: std.mem.Allocator,
    plan: *std.array_list.Managed(PlannedStatement),
    driver: sql_driver.Driver,
    table: TableDef,
    dialect: Dialect,
) !void {
    if (table.foreign_keys.len == 0) return;
    if (dialect.kind() == .sqlite) return;

    // No foreign-key read, no planned ALTER: `ALTER TABLE ADD CONSTRAINT` is not
    // idempotent, so planning one without knowing which keys are already there
    // is how a table ends up with the same key twice. Skipped, not guessed —
    // the drift report is where the caller sees it (see
    // `getPostgresForeignKeys`).
    var existing = getExistingForeignKeys(allocator, driver, table.name) catch |err| switch (err) {
        error.ForeignKeyCatalogUnavailable => return,
        else => return err,
    };
    defer freeExistingForeignKeys(allocator, &existing);

    var name_buf: [256]u8 = undefined;
    for (table.foreign_keys) |fk| {
        if (foreignKeyPresent(existing.items, fk)) continue;
        const name = foreignKeyConstraintName(&name_buf, table.name, fk) orelse {
            // A name this long cannot happen for a schema whose table and column
            // names fit the server, but a silent skip would leave the caller
            // believing the key was added: the drift report stays the answer.
            zent_log.warn(
                "zent: the foreign key {s}({s}) -> {s} needs a constraint name longer than {d} bytes; it was left to the drift report rather than truncated into one that could collide",
                .{
                    table.name,
                    if (fk.columns.len > 0) fk.columns[0] else "",
                    fk.ref_table,
                    name_buf.len,
                },
            );
            continue;
        };
        // One version per key, derived the way `add_column` / `create_index` do
        // it: the local column names the key within its table, so the derived
        // number cannot repeat for two keys of the same table.
        const version = computeMigrationVersion(
            table.name,
            "add_foreign_key",
            if (fk.columns.len > 0) fk.columns[0] else "",
        );
        if (dialect.kind() == .postgres) {
            try appendPlanned(
                allocator,
                plan,
                try addForeignKeySQLAlloc(allocator, table.name, name, fk, dialect, true),
                version,
            );
            try appendPlanned(
                allocator,
                plan,
                try validateConstraintSQLAlloc(allocator, table.name, name, dialect),
                null,
            );
        } else {
            try appendPlanned(
                allocator,
                plan,
                try addForeignKeySQLAlloc(allocator, table.name, name, fk, dialect, false),
                version,
            );
        }
    }
}

/// Migrate schema: create missing tables, add missing columns, create missing
/// indexes, and — when requested via `opts` — drop orphaned columns, alter
/// column types, converge nullability, and/or add the foreign keys the schema
/// declares and the database lacks.
///
/// Phase 2 Task 8: every operation is recorded in `zent_schema_migrations`
/// with a deterministic CRC32 version, and the entire run is wrapped in a
/// single transaction. Re-running `migrateSchema` is a no-op for operations
/// already present in the history table; on any error path, `tx.deinit()`
/// rolls back the whole batch.
///
/// Phase 3 Task 12: DROP COLUMN is gated behind `opts.drop_columns`; ALTER
/// TYPE is gated behind `opts.allow_data_loss`. Both are opt-in to prevent
/// accidental schema destruction. `opts.allow_nullability_change` is the third
/// of the family: a NOT NULL column that has to be added, or an existing
/// column whose nullability differs, is a data decision — see its doc comment
/// for what each dialect can actually do with it.
/// `opts.add_missing_foreign_keys` is the fourth: an `ALTER TABLE ADD
/// CONSTRAINT` against a table that already holds rows can fail on data that
/// violates the key, which is why the default only reports the drift (see
/// `planMissingForeignKeys` for what each dialect emits, SQLite included).
///
/// Concurrency: a cross-process advisory lock (`opts.lock_timeout_ms`, see
/// `lockMigration`) is taken before any introspection so two instances
/// deploying at once cannot both pass the "table missing" checks and race on
/// DDL. Checksums are not verified here because schema-diff migrations record
/// NULL; files are verified by `migrateFromFilesWithOptions`.
///
/// **One call is one transaction, and that transaction is this function's.**
/// The boundary is the call, not the schema: a caller that migrates several
/// groups in a loop —
/// `inline for (groups) |g| try migrateSchema(allocator, driver, g)` — gets one
/// committed transaction *per group*, so group 1 is already durable when group
/// 3 fails and the database holds a schema that matches none of the groups.
/// There is no way to tell that from the outside afterwards, which is the whole
/// hazard. For all-or-nothing across several groups, open the transaction
/// yourself and use `migrateSchemaInTx` (see its doc comment for the boundary
/// it documents in turn).
pub fn migrateSchemaWithOptions(
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
    comptime infos: []const TypeInfo,
    opts: MigrateOptions,
) !void {
    // Dry-run: plan the exact statement list a real run would execute — same
    // introspection, same history snapshot, same opt-in gates, same order —
    // and print it without executing anything. Everything here is read-only:
    // no migration lock (it can only race a real deploy, and holding one
    // would make the preview fail with MigrationLockTimeout instead of
    // answering), no history bootstrap, and no extension probe (the migration
    // it previews is refused by `checkPostgresExtensions` before it reaches
    // this point, but a preview that cannot print the DDL it was asked about
    // is worth less than the diagnosis the run itself gives).
    if (opts.dry_run) return printMigrationPlan(allocator, driver, infos, opts);

    // Cross-process mutual exclusion: without it, two instances starting at
    // once both see a table/column as missing (TOCTOU on the introspection
    // checks) and race on the same DDL. Held for the whole run; on any error
    // path the `defer` still releases it.
    const lock_held = try lockMigration(driver, opts.lock_timeout_ms);
    defer if (lock_held) unlockMigration(driver);

    // A declared extension type the database has no extension for, refused
    // before any DDL — including the history table, which is DDL too: the run
    // then leaves the database exactly as it was.
    try checkPostgresExtensions(driver, infos);

    // Bootstrap the history table outside the transaction; the SQL is
    // already idempotent (CREATE TABLE IF NOT EXISTS) and there's no
    // point rolling it back if a later step fails.
    try ensureMigrationsTable(driver);

    // Read already-applied migrations once, before opening the transaction.
    // Schema-diff migrations record a NULL checksum (their DDL is generated
    // at runtime), so there is nothing to verify here; checksum validation
    // lives on the file-based path (`verifyFileChecksums`).
    const applied = try appliedMigrations(allocator, driver);
    defer freeAppliedMigrations(allocator, applied);

    // The transaction is released by `defer`, not `errdefer` + an explicit
    // release at the end. The two are not the same thing: an `errdefer` stays
    // armed after the explicit `tx.deinit()` below it, so an error raised
    // *later* in this function — `reportNullability` reads the database again,
    // after the transaction is gone — releases the same handle a second time.
    // That is a double free of the driver's `PostgresTx`, and measured against
    // HeliosDB Nano it takes the whole process down with a segfault rather than
    // returning the error. One `defer` covers both paths, and `deinit` after a
    // successful `commit` destroys the handle instead of rolling back
    // (`PostgresTx.deinit` reads the state it was left in).
    var tx = try driver.beginTx();
    defer tx.deinit();

    // Tx.inner is a Driver value type, so every helper that accepts a Driver
    // can run inside the transaction unchanged.
    const tx_drv = tx.inner;

    try applyMigrationPlan(allocator, tx_drv, infos, opts, applied);

    try tx.commit();

    try reportNullability(allocator, driver, infos, opts);
}

/// `migrateSchemaWithOptions` **inside a transaction the caller owns**.
///
/// The boundary, explicitly: **one call is one run inside the caller's
/// transaction.** This function never begins, commits or rolls back — the DDL,
/// the history rows and the `zent_schema_migrations` bootstrap all happen on
/// `tx`'s connection, so the caller's `commit` is what makes them durable and
/// the caller's `rollback` is what makes them vanish (SQLite and PostgreSQL have
/// transactional DDL; MySQL does not — see the file header). A failed call
/// returns the error to the caller, and *nothing this call wrote is undone
/// here*, because undoing it would mean rolling back the caller's transaction,
/// which is the caller's decision and may already carry work of its own.
///
/// That is the point of the entry point: several calls on the same `tx` are one
/// atomic unit —
///
/// ```zig
/// var tx = try driver.beginTx();
/// defer tx.deinit();                                       // one release, both paths
/// try migrateSchemaInTx(allocator, tx, infos, .{});        // group A
/// try migrateSchemaInTx(allocator, tx, more_infos, .{});   // group B
/// try tx.commit();                                         // both, or neither
/// ```
///
/// — where two `migrateSchema` calls would have been two independent
/// transactions with group A committed before group B was even attempted.
///
/// **One `defer`, never `errdefer` plus a `deinit` at the end.** The two look
/// equivalent and are not: an `errdefer` is armed against *any* later error
/// return, including one raised after the explicit release has already run, so
/// the handle is released twice. Measured against HeliosDB Nano — a rejected
/// statement there made a post-`commit` read fail — the double release
/// segfaults the process instead of returning an error.
///
/// The rule in one sentence: **one call = one transaction; N calls = N
/// transactions, and the earlier ones are already committed; for all-or-nothing,
/// open the transaction yourself and use this function.**
///
/// The handle is **borrowed**: `tx` is not consumed and its lifetime stays the
/// caller's (`deinit` exactly once, after `commit`/`rollback` as usual). A
/// `dry_run` prints the plan through this connection and touches nothing, as it
/// does on the self-managing path.
///
/// Two consequences worth stating rather than discovering:
///
///   - **The migration lock covers this call, not the caller's transaction.**
///     The advisory lock is still taken (on `tx`'s connection) and released
///     before returning, so two `migrateSchemaInTx` calls cannot interleave
///     their DDL — but a second process can start migrating in the window
///     between this call's return and the caller's `commit`, while this
///     caller's DDL is still uncommitted and therefore invisible to that
///     process's introspection. A caller that needs cross-process exclusion for
///     the whole unit has to hold the lock itself for that whole unit.
///   - **The post-run nullability report reads inside the transaction**, since
///     that is the state this call just produced. On a caller that rolls back,
///     the report described a schema that was never committed.
pub fn migrateSchemaInTx(
    allocator: std.mem.Allocator,
    tx: sql_driver.Tx,
    comptime infos: []const TypeInfo,
    opts: MigrateOptions,
) !void {
    // `Tx.inner` is a Driver value type, so every helper that accepts a Driver
    // runs on the transaction's connection unchanged — the same driver
    // `migrateSchemaWithOptions` hands to the plan once it owns the tx.
    const tx_drv = tx.inner;

    if (opts.dry_run) return printMigrationPlan(allocator, tx_drv, infos, opts);

    const lock_held = try lockMigration(tx_drv, opts.lock_timeout_ms);
    defer if (lock_held) unlockMigration(tx_drv);

    try checkPostgresExtensions(tx_drv, infos);

    // Inside the caller's transaction, deliberately: a rollback has to take the
    // history table with it, or "this run was undone" would leave a trace that
    // says otherwise.
    try ensureMigrationsTable(tx_drv);

    const applied = try appliedMigrations(allocator, tx_drv);
    defer freeAppliedMigrations(allocator, applied);

    try applyMigrationPlan(allocator, tx_drv, infos, opts, applied);

    try reportNullability(allocator, tx_drv, infos, opts);
}

/// The dry-run body: plan the exact statement list a real run would execute —
/// same introspection, same history snapshot, same opt-in gates, same order —
/// and print it without executing anything.
///
/// It reads through `drv`, which is whatever connection the caller's entry
/// point would migrate on (the driver, or a caller-owned transaction's), so a
/// preview seen from inside a transaction previews that transaction's view.
fn printMigrationPlan(
    allocator: std.mem.Allocator,
    drv: sql_driver.Driver,
    comptime infos: []const TypeInfo,
    opts: MigrateOptions,
) !void {
    // The version gates read the same history snapshot a real run would.
    // A database that has never been migrated has no history table at
    // all — that means "nothing applied". Probing with the same read-only
    // existence check `checkSchema` uses keeps this branch a pure read.
    var applied: []AppliedMigration = &.{};
    var history_cols = try getExistingColumns(allocator, drv, "zent_schema_migrations");
    const has_history = history_cols.items.len > 0;
    freeExistingColumns(allocator, &history_cols);
    if (has_history) {
        applied = try appliedMigrations(allocator, drv);
    }
    defer if (has_history) freeAppliedMigrations(allocator, applied);

    var plan = try planMigrateStatements(allocator, drv, infos, opts, applied);
    defer freePlannedStatements(allocator, &plan);

    // Print collected SQL.
    for (plan.items) |st| {
        std.debug.print("{s};\n", .{st.sql});
    }
}

/// The plan-and-execute half of a real run, on the connection the DDL goes
/// through: this function owns neither the boundary nor the locking, so the
/// two entry points that do (`migrateSchemaWithOptions`'s own transaction,
/// `migrateSchemaInTx`'s caller's) cannot drift apart in what they execute.
///
/// The statement list is planned up front — the same `planMigrateStatements`
/// call the dry-run previews — and then applied in order. Planning introspects
/// through `tx_drv`, exactly where the old interleaved path performed its
/// checks, against the `applied` snapshot the caller read, so the executed set
/// is unchanged: one shared diff, not two copies that can drift apart.
///
/// Step 1+2 shape the plan: create tables/views/junction tables first
/// (CREATE TABLE IF NOT EXISTS keeps this safe even on a partial previous
/// run), then per-entity column/index diffs. The schema state
/// (table/column/index existence) is the authoritative gate — we always
/// re-check the database before planning each change.
/// `zent_schema_migrations` is an audit trail: `recordMigration` uses
/// `ON CONFLICT DO NOTHING` / `ON DUPLICATE KEY UPDATE`, so re-recording
/// a version (e.g. after a table was dropped out-of-band) never produces
/// duplicates.
fn applyMigrationPlan(
    allocator: std.mem.Allocator,
    tx_drv: sql_driver.Driver,
    comptime infos: []const TypeInfo,
    opts: MigrateOptions,
    applied: []const AppliedMigration,
) !void {
    var plan = try planMigrateStatements(allocator, tx_drv, infos, opts, applied);
    defer freePlannedStatements(allocator, &plan);

    for (plan.items) |st| {
        _ = try tx_drv.exec(st.sql, &.{});
        if (st.version) |version| try recordMigration(tx_drv, version, null);
    }
}

/// Compare every column's nullability between the schema and the database and
/// warn per difference — `opts.check_nullability`. No-op when it is off.
///
/// Runs on the connection whose schema is the one to report on: the driver
/// after `migrateSchemaWithOptions` committed, or the caller's transaction
/// while `migrateSchemaInTx` is still inside it.
fn reportNullability(
    allocator: std.mem.Allocator,
    drv: sql_driver.Driver,
    comptime infos: []const TypeInfo,
    opts: MigrateOptions,
) !void {
    if (!opts.check_nullability) return;
    const drifts = try checkNullability(allocator, drv, infos);
    defer freeNullabilityDrift(allocator, drifts);
    reportNullabilityDrift(drifts);
}

/// Backward-compatible entry point: calls `migrateSchemaWithOptions` with
/// default `MigrateOptions{}` (no drops, no type changes, no foreign keys added
/// by `ALTER`). All existing callers continue to work without modification.
///
/// **One call is one transaction** — this function opens it and commits it, so
/// N calls are N committed transactions. For all-or-nothing across several
/// schema groups, use `migrateSchemaInTx` on a transaction you opened yourself.
pub fn migrateSchema(
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
    comptime infos: []const TypeInfo,
) !void {
    return migrateSchemaWithOptions(allocator, driver, infos, MigrateOptions{});
}

// ------------------------------------------------------------------
// File-based migrations
// ------------------------------------------------------------------

pub const FileMigrationOptions = struct {
    /// If true, don't execute any SQL — only print what would be done.
    dry_run: bool = false,
    /// If true, rollback skips migrations that have no .down.sql file.
    /// If false, missing down files produce error.MissingDownMigration.
    allow_missing_down: bool = true,
    /// How long to wait for the cross-process migration lock before giving up
    /// with `error.MigrationLockTimeout`. `0` disables locking. SQLite
    /// ignores this (single-writer database, see `lockMigration`).
    lock_timeout_ms: u32 = 10_000,
};

const MigrationFile = struct {
    version: i64,
    name: []const u8,
    up_sql: []const u8,
    down_sql: ?[]const u8,
    checksum: []const u8,
};

pub const MigrateFilesError = sql_driver.Error || std.Io.Dir.OpenError || std.Io.Dir.ReadFileAllocError || std.Io.Dir.AccessError || std.Io.Dir.Iterator.Error || error{
    NoSpaceLeft,
    InvalidMigrationFilename,
    DuplicateMigrationVersion,
    MissingDownMigration,
    MigrationChecksumMismatch,
    MigrationLockTimeout,
};

/// Parse a migration filename and return the numeric version if it matches the
/// requested direction (e.g. `.up.sql`). Filenames must begin with a positive
/// integer version, optionally followed by an underscore and a description.
fn parseMigrationFilename(name: []const u8, direction: []const u8) !?i64 {
    const suffix = try std.heap.page_allocator.print(".{s}.sql", .{direction});
    defer std.heap.page_allocator.free(suffix);
    if (!std.mem.endsWith(u8, name, suffix)) return null;

    const stem = name[0 .. name.len - suffix.len];
    const underscore_idx = std.mem.indexOfScalar(u8, stem, '_') orelse stem.len;
    const version_str = stem[0..underscore_idx];

    if (version_str.len == 0) return error.InvalidMigrationFilename;
    return std.fmt.parseInt(i64, version_str, 10) catch error.InvalidMigrationFilename;
}

fn fileChecksum(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(data);
    // zig std renamed the CRC-32 catalog entry between 0.17 dev builds:
    // `Crc32` (dev.813 / CI) vs `@"CRC-32/ISO-HDLC"` (newer dev). Probe at
    // comptime so both std versions compile.
    const crc = if (@hasDecl(std.hash.crc, "Crc32"))
        std.hash.crc.Crc32.hash(data)
    else
        std.hash.crc.@"CRC-32/ISO-HDLC".hash(data);
    return try allocator.print("{x:0>8}", .{crc});
}

/// Split a SQL script into individual statements on unquoted `;` terminators.
/// This is intentionally simple: it does not parse PL/pgSQL bodies or trigger
/// definitions that contain nested semicolons. Complex procedural objects should
/// be placed in separate migration files or use a tool that understands statement
/// boundaries.
fn splitSqlStatements(allocator: std.mem.Allocator, sql: []const u8) ![]const []const u8 {
    var statements = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (statements.items) |s| allocator.free(s);
        statements.deinit();
    }

    var start: usize = 0;
    var in_string = false;
    var string_char: u8 = 0;
    var i: usize = 0;
    while (i < sql.len) : (i += 1) {
        const c = sql[i];
        if (in_string) {
            if (c == string_char) {
                if (i + 1 < sql.len and sql[i + 1] == string_char) {
                    i += 1;
                } else {
                    in_string = false;
                }
            }
        } else if (c == '\'' or c == '"') {
            in_string = true;
            string_char = c;
        } else if (c == ';') {
            const stmt = std.mem.trim(u8, sql[start..i], " \t\r\n");
            if (stmt.len > 0) {
                // Copy first, then append — not `append(try dupe(...))`. An
                // `append` OOM after a successful `dupe` would leak the copy,
                // because the errdefer above frees only what is already in
                // the list. The inline errdefer covers exactly that window;
                // on success it is discarded, and the top errdefer then owns
                // the copy like every other list item (no double free: a
                // failed append never inserted it).
                const copy = try allocator.dupe(u8, stmt);
                errdefer allocator.free(copy);
                try statements.append(copy);
            }
            start = i + 1;
        }
    }
    const last = std.mem.trim(u8, sql[start..], " \t\r\n");
    if (last.len > 0) {
        // Same shape as the `;`-terminated branch above: the top errdefer
        // owns the copy only once `append` succeeds.
        const copy = try allocator.dupe(u8, last);
        errdefer allocator.free(copy);
        try statements.append(copy);
    }
    return statements.toOwnedSlice();
}

fn executeMigrationSql(allocator: std.mem.Allocator, drv: sql_driver.Driver, sql: []const u8) !void {
    const statements = try splitSqlStatements(allocator, sql);
    defer {
        for (statements) |s| allocator.free(s);
        allocator.free(statements);
    }
    for (statements) |stmt| {
        _ = try drv.exec(stmt, &.{});
    }
}

fn freeMigrationFile(allocator: std.mem.Allocator, mf: *MigrationFile) void {
    allocator.free(mf.name);
    allocator.free(mf.up_sql);
    if (mf.down_sql) |d| allocator.free(d);
    allocator.free(mf.checksum);
    mf.* = undefined;
}

fn readSingleMigrationFile(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8, name: []const u8) !MigrationFile {
    const up_version = try parseMigrationFilename(name, "up") orelse return error.InvalidMigrationFilename;

    const up_path = try std.fs.path.join(allocator, &.{ dir_path, name });
    defer allocator.free(up_path);

    const up_sql = try std.Io.Dir.cwd().readFileAlloc(io, up_path, allocator, .limited(1024 * 1024));
    errdefer allocator.free(up_sql);

    const checksum = try fileChecksum(io, allocator, up_path);
    errdefer allocator.free(checksum);

    const stem = name[0 .. name.len - ".up.sql".len];
    const down_name = try allocator.print("{s}.down.sql", .{stem});
    defer allocator.free(down_name);
    const down_path = try std.fs.path.join(allocator, &.{ dir_path, down_name });
    defer allocator.free(down_path);

    var down_sql: ?[]const u8 = null;
    errdefer if (down_sql) |d| allocator.free(d);
    down_sql = std.Io.Dir.cwd().readFileAlloc(io, down_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };

    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);

    return MigrationFile{
        .version = up_version,
        .name = name_copy,
        .up_sql = up_sql,
        .down_sql = down_sql,
        .checksum = checksum,
    };
}

fn insertionSortMigrationFiles(files: []MigrationFile) void {
    if (files.len < 2) return;
    var i: usize = 1;
    while (i < files.len) : (i += 1) {
        var j = i;
        while (j > 0 and files[j - 1].version > files[j].version) : (j -= 1) {
            const tmp = files[j - 1];
            files[j - 1] = files[j];
            files[j] = tmp;
        }
    }
}

fn readMigrationDir(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) ![]MigrationFile {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var files = std.array_list.Managed(MigrationFile).init(allocator);
    errdefer {
        for (files.items) |*f| freeMigrationFile(allocator, f);
        files.deinit();
    }

    var seen = std.AutoHashMap(i64, void).init(allocator);
    defer seen.deinit();

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const up_version = parseMigrationFilename(entry.name, "up") catch |err| switch (err) {
            error.InvalidMigrationFilename => continue,
            else => |e| return e,
        } orelse continue;

        if (seen.contains(up_version)) return error.DuplicateMigrationVersion;
        try seen.put(up_version, {});

        var mf = try readSingleMigrationFile(io, allocator, dir_path, entry.name);
        errdefer freeMigrationFile(allocator, &mf);
        try files.append(mf);
    }

    const slice = try files.toOwnedSlice();
    insertionSortMigrationFiles(slice);
    return slice;
}

fn freeMigrationFiles(allocator: std.mem.Allocator, files: []MigrationFile) void {
    for (files) |*f| freeMigrationFile(allocator, f);
    allocator.free(files);
}

fn deleteMigrationRecord(drv: sql_driver.Driver, version: i64) !void {
    const dialect = drv.dialect();
    var buf: [384]u8 = undefined;
    const p1 = try dialect.placeholder(&buf, 1);
    const sql = try std.fmt.bufPrint(buf[p1.len..], "DELETE FROM zent_schema_migrations WHERE version = {s}", .{p1});
    _ = try drv.exec(sql, &.{.{ .int = version }});
}

/// Apply pending `.up.sql` migration files from `dir_path` in version order.
/// Already-applied versions (tracked in `zent_schema_migrations`) are skipped.
/// The whole run is wrapped in a transaction on backends that support
/// transactional DDL (SQLite, PostgreSQL). MySQL applies DDL immediately.
pub fn migrateFromFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
    dir_path: []const u8,
) MigrateFilesError!void {
    return migrateFromFilesWithOptions(io, allocator, driver, dir_path, .{});
}

/// Options-aware version of `migrateFromFiles`.
pub fn migrateFromFilesWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
    dir_path: []const u8,
    opts: FileMigrationOptions,
) MigrateFilesError!void {
    if (opts.dry_run) {
        const files = try readMigrationDir(io, allocator, dir_path);
        defer freeMigrationFiles(allocator, files);
        std.debug.print("-- Dry-run: would apply {d} migration(s) from {s}\n", .{ files.len, dir_path });
        for (files) |f| {
            std.debug.print("-- {s} (version {d}, checksum {s})\n", .{ f.name, f.version, f.checksum });
        }
        return;
    }

    // Cross-process exclusion (see `lockMigration`); released on every exit.
    const lock_held = try lockMigration(driver, opts.lock_timeout_ms);
    defer if (lock_held) unlockMigration(driver);

    try ensureMigrationsTable(driver);
    const applied = try appliedMigrations(allocator, driver);
    defer freeAppliedMigrations(allocator, applied);

    const files = try readMigrationDir(io, allocator, dir_path);
    defer freeMigrationFiles(allocator, files);

    // An applied file whose content changed is exactly the "edited migration"
    // mistake checksums exist to catch; refuse before touching any DDL.
    try verifyFileChecksums(applied, files);

    var tx = try driver.beginTx();
    defer tx.deinit();
    const tx_drv = tx.inner;

    for (files) |f| {
        if (versionContains(applied, f.version)) continue;
        try executeMigrationSql(allocator, tx_drv, f.up_sql);
        try recordMigration(tx_drv, f.version, f.checksum);
    }

    try tx.commit();
}

/// Roll back the last `steps` applied file migrations, using `.down.sql` files
/// from `dir_path`. Migrations are rolled back in reverse application order.
pub fn rollbackFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
    dir_path: []const u8,
    steps: usize,
) MigrateFilesError!void {
    return rollbackFilesWithOptions(io, allocator, driver, dir_path, steps, .{});
}

pub fn rollbackFilesWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
    dir_path: []const u8,
    steps: usize,
    opts: FileMigrationOptions,
) MigrateFilesError!void {
    // Cross-process exclusion; a rollback races the same DDL checks as an
    // apply, so it takes the same lock.
    const lock_held = try lockMigration(driver, opts.lock_timeout_ms);
    defer if (lock_held) unlockMigration(driver);

    try ensureMigrationsTable(driver);
    const applied = try appliedMigrations(allocator, driver);
    defer freeAppliedMigrations(allocator, applied);
    if (applied.len == 0) return;

    const files = try readMigrationDir(io, allocator, dir_path);
    defer freeMigrationFiles(allocator, files);

    var tx = try driver.beginTx();
    defer tx.deinit();
    const tx_drv = tx.inner;

    var rolled: usize = 0;
    var i: usize = applied.len;
    while (i > 0 and rolled < steps) {
        i -= 1;
        const version = applied[i].version;
        const mf = for (files) |f| {
            if (f.version == version) break f;
        } else continue;

        if (mf.down_sql) |down| {
            try executeMigrationSql(allocator, tx_drv, down);
            try deleteMigrationRecord(tx_drv, version);
            rolled += 1;
        } else if (!opts.allow_missing_down) {
            return error.MissingDownMigration;
        }
    }

    try tx.commit();
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "Migration version uses stable positive FNV-1a hash" {
    const version = computeMigrationVersion("user", "add_column", "email");
    try std.testing.expectEqual(@as(i64, 1_157_043_292), version);
    try std.testing.expect(version >= 0);
    try std.testing.expect(version <= std.math.maxInt(i32));
}

test "TableDef from TypeInfo" {
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const table = comptime tableFromTypeInfo(info);

    try std.testing.expectEqualStrings("user", table.name);
    try std.testing.expectEqual(@as(usize, 3), table.columns.len); // id + name + age
    try std.testing.expectEqualStrings("id", table.columns[0].name);
    try std.testing.expect(table.columns[0].primary_key);
    try std.testing.expectEqualStrings("name", table.columns[1].name);
    try std.testing.expectEqualStrings("TEXT", table.columns[1].sql_type);
    try std.testing.expectEqualStrings("age", table.columns[2].name);
    try std.testing.expectEqualStrings("INTEGER", table.columns[2].sql_type);
}

test "columnSQLType resolves a declared VarChar width per dialect" {
    const declared = ColumnDef{ .name = "bio", .sql_type = "TEXT", .logical_type = .string, .varchar_sql = field_mod.varCharSQL(120) };
    // MySQL: the declared width replaces the default.
    try std.testing.expectEqualStrings("VARCHAR(120)", columnSQLType(declared, Dialect.mysql));
    // PG/SQLite: the dialect split `.string` already had, unchanged.
    try std.testing.expectEqualStrings("TEXT", columnSQLType(declared, Dialect.postgres));
    try std.testing.expectEqualStrings("TEXT", columnSQLType(declared, Dialect.sqlite));

    // Undeclared: byte-for-byte the old resolution everywhere.
    const plain = ColumnDef{ .name = "nick", .sql_type = "TEXT", .logical_type = .string };
    try std.testing.expectEqualStrings("VARCHAR(255)", columnSQLType(plain, Dialect.mysql));
    try std.testing.expectEqualStrings("TEXT", columnSQLType(plain, Dialect.postgres));
    try std.testing.expectEqualStrings("TEXT", columnSQLType(plain, Dialect.sqlite));

    // A width is consumed only by the `.string` family (`VarChar` refuses to
    // declare one elsewhere; this guards hand-built ColumnDef values).
    const mismatched = ColumnDef{ .name = "body", .sql_type = "TEXT", .logical_type = .text, .varchar_sql = field_mod.varCharSQL(120) };
    try std.testing.expectEqualStrings("TEXT", columnSQLType(mismatched, Dialect.mysql));
}

test "a schema-declared VarChar width reaches the DDL on MySQL only" {
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const graph = @import("../../codegen/graph.zig");

    const Profile = schema("MigrateProfile", .{
        .fields = &.{
            field.String("bio").VarChar(120),
            field.String("nick"),
        },
    });

    // MySQL build: the declared width in the statement, the undeclared field
    // still the default VARCHAR(255).
    const mysql_info = comptime graph.fromSchemaDialect(Profile, Dialect.mysql);
    const mysql_table = comptime tableFromTypeInfo(mysql_info);
    const mysql_sql = try createTableSQL(mysql_table, Dialect.mysql);
    defer std.heap.page_allocator.free(mysql_sql);
    try std.testing.expect(std.mem.indexOf(u8, mysql_sql, "`bio` VARCHAR(120)") != null);
    try std.testing.expect(std.mem.indexOf(u8, mysql_sql, "`nick` VARCHAR(255)") != null);

    // PG/SQLite: both columns stay TEXT, no VARCHAR anywhere — the dialect
    // split the undeclared default already had.
    const pg_info = comptime graph.fromSchemaDialect(Profile, Dialect.postgres);
    const pg_table = comptime tableFromTypeInfo(pg_info);
    const pg_sql = try createTableSQL(pg_table, Dialect.postgres);
    defer std.heap.page_allocator.free(pg_sql);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "\"bio\" TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "VARCHAR") == null);

    const sqlite_info = comptime graph.fromSchemaDialect(Profile, Dialect.sqlite);
    const sqlite_table = comptime tableFromTypeInfo(sqlite_info);
    const sqlite_sql = try createTableSQL(sqlite_table, Dialect.sqlite);
    defer std.heap.page_allocator.free(sqlite_sql);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_sql, "\"bio\" TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_sql, "VARCHAR") == null);
}

test "a declared VarChar width compares drift-free against the database's varchar" {
    // checkSchema compares `normalizeTypeForCompare(columnSQLType(col))`
    // against `normalizeTypeForCompare(db answer)`. MySQL's
    // information_schema.columns.data_type answers `varchar` — the storage
    // name, without the length — so the declared width must vanish in
    // normalization. It does, by the same parenthesis-stripping that made the
    // old VARCHAR(255) compare clean; bare `varchar` is already the canonical
    // form (`character varying` maps onto it), so no alias entry is needed
    // and none is added.
    var schema_buf: [128]u8 = undefined;
    var db_buf: [128]u8 = undefined;

    const schema_declared = try normalizeSqlType(field_mod.varCharSQL(120), &schema_buf, Dialect.mysql);
    try std.testing.expectEqualStrings("varchar", schema_declared);

    const schema_legacy = try normalizeSqlType("VARCHAR(255)", &db_buf, Dialect.mysql);
    try std.testing.expectEqualStrings(schema_declared, schema_legacy);

    var db_buf2: [128]u8 = undefined;
    const db_answer = try normalizeSqlType("varchar", &db_buf2, Dialect.mysql);
    try std.testing.expectEqualStrings(schema_declared, db_answer);

    // PG/SQLite: the declared spelling stays TEXT on both sides of the same
    // comparison.
    var pg_buf: [128]u8 = undefined;
    const pg_schema = try normalizeSqlType("TEXT", &pg_buf, Dialect.postgres);
    try std.testing.expectEqualStrings("text", pg_schema);
}

test "a declared Other/SqlType reaches the DDL, on PostgreSQL only" {
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const graph = @import("../../codegen/graph.zig");

    const NgTypes = schema("MigratePgTypes", .{
        .fields = &.{
            field.Other("embedding", "vector(1536)"),
            field.Other("tags", "integer[]"),
            field.Other("addr", "inet"),
            field.Other("plain", null),
            field.Text("handle").SqlType("citext"),
            field.String("short").VarChar(10),
        },
    });

    // The graph resolves `sql_type` for the dialect it is built with, and this
    // one is built for SQLite — the case the migration path has to survive:
    // `checkSchema` runs against whatever driver it is handed, so the
    // declaration has to travel beside `sql_type` (`ColumnDef.sql_type_override`)
    // rather than only inside it.
    const sqlite_info = comptime graph.fromSchemaDialect(NgTypes, Dialect.sqlite);
    try std.testing.expectEqualStrings("TEXT", sqlite_info.fields[1].sql_type);
    try std.testing.expectEqualStrings("vector(1536)", sqlite_info.fields[1].sql_type_override.?);

    const table = comptime tableFromTypeInfo(sqlite_info);
    try std.testing.expectEqualStrings("vector(1536)", table.columns[1].sql_type_override.?);

    // PostgreSQL: every declaration verbatim; a field that declared none keeps
    // the kind's mapping (`TEXT`), and `VarChar(10)` — which loses to an
    // explicit `.SqlType` — is not part of this schema's PG output either way.
    const pg_sql = try createTableSQL(table, Dialect.postgres);
    defer std.heap.page_allocator.free(pg_sql);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "\"embedding\" vector(1536)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "\"tags\" integer[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "\"addr\" inet") != null);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "\"plain\" TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "\"handle\" citext") != null);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "\"short\" TEXT") != null);

    // MySQL: the field kinds' own mapping, byte for byte — including the
    // declared `VarChar(10)` width, which the override would have replaced on
    // PostgreSQL. A `vector(1536)` column cannot be created there at all, so
    // emitting the declaration verbatim would be a schema that cannot migrate.
    const mysql_sql = try createTableSQL(table, Dialect.mysql);
    defer std.heap.page_allocator.free(mysql_sql);
    try std.testing.expect(std.mem.indexOf(u8, mysql_sql, "`embedding` TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, mysql_sql, "`tags` TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, mysql_sql, "`addr` TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, mysql_sql, "`handle` TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, mysql_sql, "`short` VARCHAR(10)") != null);
    try std.testing.expect(std.mem.indexOf(u8, mysql_sql, "vector") == null);

    // SQLite: same answer (`TEXT`), no `[]` either.
    const sqlite_sql = try createTableSQL(table, Dialect.sqlite);
    defer std.heap.page_allocator.free(sqlite_sql);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_sql, "\"tags\" TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_sql, "citext") == null);

    // `checkSchema` reads its TableDef through the cross-referenced builder (it
    // has to see the FK columns the To-edges add), so the override has to be
    // there too — the two builders are one declaration each and this is the one
    // drift reporting actually walks.
    const cross = comptime tableFromTypeInfoCrossRef(sqlite_info, &.{sqlite_info});
    try std.testing.expectEqualStrings("vector(1536)", cross.columns[1].sql_type_override.?);
    try std.testing.expectEqualStrings("integer[]", cross.columns[2].sql_type_override.?);
    try std.testing.expectEqualStrings("vector(1536)", columnSQLType(cross.columns[1], Dialect.postgres));
    try std.testing.expectEqualStrings("integer[]", columnSQLType(cross.columns[2], Dialect.postgres));
    // The override is PostgreSQL's; the other dialects keep the mapping even
    // when the graph carrying it was built for one of them.
    try std.testing.expectEqualStrings("TEXT", columnSQLType(cross.columns[1], Dialect.sqlite));
    try std.testing.expectEqualStrings("TEXT", columnSQLType(cross.columns[1], Dialect.mysql));
}

test "PostgreSQL USER-DEFINED and ARRAY columns compare by udt_name, not data_type" {
    // The shape PostgreSQL answers for a column whose type is not one of its
    // own (`vector(1536)`, `citext`, any array) — `data_type` says
    // `USER-DEFINED`/`ARRAY` and the concrete name is in `udt_name`. Comparing
    // `data_type` reported a `type_mismatch` for every such column.
    const Case = struct {
        declared: []const u8,
        data_type: []const u8,
        udt_name: []const u8,
        agree: bool,
    };
    const cases = [_]Case{
        // USER-DEFINED: the extension/custom type by name. The `(...)` and a
        // `schema.` qualifier are decoration, dropped on both sides — and so is
        // the extension type's own modifier, deliberately: the catalog answer
        // carries the type *name* only, so a `vector(3)` column and this
        // `vector(1536)` declaration both read `USER-DEFINED`/`vector` and the
        // dimension is not compared. Reading it would mean
        // `pg_attribute.atttypmod` (a second introspection query, with a
        // different answer shape for every built-in), which this branch does not
        // do. Pinned here so the limitation is a decision, not a surprise.
        .{ .declared = "vector(1536)", .data_type = "user-defined", .udt_name = "vector", .agree = true },
        .{ .declared = "vector", .data_type = "user-defined", .udt_name = "vector", .agree = true },
        .{ .declared = "public.vector(1536)", .data_type = "user-defined", .udt_name = "vector", .agree = true },
        .{ .declared = "citext", .data_type = "user-defined", .udt_name = "citext", .agree = true },
        // ...and a *different* type is still a mismatch.
        .{ .declared = "vector(1536)", .data_type = "user-defined", .udt_name = "halfvec", .agree = false },
        .{ .declared = "text", .data_type = "user-defined", .udt_name = "citext", .agree = false },
        .{ .declared = "cidr", .data_type = "user-defined", .udt_name = "inet", .agree = false },
        .{ .declared = "int4range", .data_type = "user-defined", .udt_name = "int8range", .agree = false },

        // ARRAY: the element name out of `udt_name` (`_int4` → `int4`), through
        // the same alias pass the built-ins get (`int4` → `integer`).
        .{ .declared = "integer[]", .data_type = "array", .udt_name = "_int4", .agree = true },
        .{ .declared = "int4[]", .data_type = "array", .udt_name = "_int4", .agree = true },
        .{ .declared = "text[]", .data_type = "array", .udt_name = "_text", .agree = true },
        .{ .declared = "citext[]", .data_type = "array", .udt_name = "_citext", .agree = true },
        .{ .declared = "character varying[]", .data_type = "array", .udt_name = "_varchar", .agree = true },
        // The spellings whose element name the shared alias table does not
        // carry (`_float8` is a double precision, `_int2` a smallint).
        .{ .declared = "double precision[]", .data_type = "array", .udt_name = "_float8", .agree = true },
        .{ .declared = "float8[]", .data_type = "array", .udt_name = "_float8", .agree = true },
        .{ .declared = "smallint[]", .data_type = "array", .udt_name = "_int2", .agree = true },
        .{ .declared = "character[]", .data_type = "array", .udt_name = "_bpchar", .agree = true },
        // An array of a different element type is not an agreement — this is
        // the counterexample that keeps the branch a comparison: `text[]` and
        // `integer[]` both answer `ARRAY`, and only the element tells them
        // apart.
        .{ .declared = "text[]", .data_type = "array", .udt_name = "_int4", .agree = false },
        .{ .declared = "cidr[]", .data_type = "array", .udt_name = "_inet", .agree = false },
        .{ .declared = "vector[]", .data_type = "array", .udt_name = "_citext", .agree = false },
        // A scalar declared where the column is an array, and an array declared
        // where the column is a scalar: the array marker itself is compared.
        .{ .declared = "integer", .data_type = "array", .udt_name = "_int4", .agree = false },
        .{ .declared = "integer[]", .data_type = "integer", .udt_name = "int4", .agree = false },

        // A catalog answer with no `udt_name` cannot be resolved, so the
        // comparison falls back to `data_type` and reports the difference
        // rather than pretending to have checked.
        .{ .declared = "vector(1536)", .data_type = "user-defined", .udt_name = "", .agree = false },
        // The catalog's own spelling, which `getExistingColumns` lower-cases
        // before it stores it — accepted here too, because `ExistingColumn` is
        // public and a caller may build one from the server's answer.
        .{ .declared = "vector(1536)", .data_type = "USER-DEFINED", .udt_name = "vector", .agree = true },
        .{ .declared = "integer[]", .data_type = "ARRAY", .udt_name = "_int4", .agree = true },
        .{ .declared = "integer[]", .data_type = "ARRAY", .udt_name = "_INT4", .agree = true },
    };

    for (cases) |case| {
        var schema_buf: [128]u8 = undefined;
        var db_buf: [128]u8 = undefined;
        const got = try columnTypesAgree(
            std.testing.allocator,
            case.declared,
            .{ .name = "c", .sql_type = case.data_type, .udt_name = case.udt_name, .not_null = false, .pk = false },
            &schema_buf,
            &db_buf,
            Dialect.postgres,
        );
        if (got != case.agree) {
            std.debug.print("declared={s} data_type={s} udt_name={s}: expected agree={} got={}\n", .{ case.declared, case.data_type, case.udt_name, case.agree, got });
            return error.TestUnexpectedResult;
        }
    }
}

test "the built-in type comparison is unchanged, and udt_name is PostgreSQL-only" {
    const Case = struct {
        declared: []const u8,
        sql_type: []const u8,
        udt_name: []const u8,
        dialect: Dialect,
        agree: bool,
    };
    const cases = [_]Case{
        // PostgreSQL's built-ins never answered `USER-DEFINED`/`ARRAY`, so they
        // take the branch they always took.
        .{ .declared = "TEXT", .sql_type = "text", .udt_name = "text", .dialect = Dialect.postgres, .agree = true },
        .{ .declared = "INTEGER", .sql_type = "integer", .udt_name = "int4", .dialect = Dialect.postgres, .agree = true },
        .{ .declared = "BIGINT", .sql_type = "bigint", .udt_name = "int8", .dialect = Dialect.postgres, .agree = true },
        .{ .declared = "JSONB", .sql_type = "jsonb", .udt_name = "jsonb", .dialect = Dialect.postgres, .agree = true },
        // `inet`, `cidr`, `tsvector`, `jsonpath` and the ranges are built-in
        // PostgreSQL types (no extension): their own `data_type`, so a declared
        // `inet` compares without any of the new branch.
        .{ .declared = "inet", .sql_type = "inet", .udt_name = "inet", .dialect = Dialect.postgres, .agree = true },
        .{ .declared = "int4range", .sql_type = "int4range", .udt_name = "int4range", .dialect = Dialect.postgres, .agree = true },
        .{ .declared = "TEXT", .sql_type = "citext", .udt_name = "citext", .dialect = Dialect.postgres, .agree = false },

        // MySQL and SQLite: byte-for-byte the old path, and the `udt_name` is
        // deliberately invisible there — MySQL's `information_schema.columns`
        // has no such column and `getExistingColumns` never fills it, so the
        // branch cannot fire even on a hand-built answer that carries one.
        .{ .declared = "BOOLEAN", .sql_type = "tinyint", .udt_name = "_int4", .dialect = Dialect.mysql, .agree = true },
        .{ .declared = "REAL", .sql_type = "double", .udt_name = "", .dialect = Dialect.mysql, .agree = true },
        .{ .declared = "VARCHAR(255)", .sql_type = "varchar", .udt_name = "", .dialect = Dialect.mysql, .agree = true },
        .{ .declared = "TEXT", .sql_type = "text", .udt_name = "_int4", .dialect = Dialect.mysql, .agree = true },
        .{ .declared = "INTEGER", .sql_type = "integer", .udt_name = "", .dialect = Dialect.sqlite, .agree = true },
        .{ .declared = "TEXT", .sql_type = "varchar(20)", .udt_name = "", .dialect = Dialect.sqlite, .agree = false },
    };

    for (cases) |case| {
        var schema_buf: [128]u8 = undefined;
        var db_buf: [128]u8 = undefined;
        const got = try columnTypesAgree(
            std.testing.allocator,
            case.declared,
            .{ .name = "c", .sql_type = case.sql_type, .udt_name = case.udt_name, .not_null = false, .pk = false },
            &schema_buf,
            &db_buf,
            case.dialect,
        );
        if (got != case.agree) {
            std.debug.print("{s}: declared={s} db={s} udt_name={s}: expected agree={} got={}\n", .{ case.dialect.name, case.declared, case.sql_type, case.udt_name, case.agree, got });
            return error.TestUnexpectedResult;
        }
    }
}

test "Create table SQL" {
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const table = comptime tableFromTypeInfo(info);
    const sql = try createTableSQL(table, Dialect.sqlite);
    defer std.heap.page_allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "CREATE TABLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "PRIMARY KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "AUTOINCREMENT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"name\" TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"age\" INTEGER") != null);
}

test "createTableSQL escapes embedded quotes in identifiers" {
    const quoted = TableDef{
        .name = "we\"ird",
        .columns = &.{
            ColumnDef{ .name = "co\"l", .sql_type = "INTEGER" },
        },
        .primary_keys = &.{},
    };
    const sql = try createTableSQL(quoted, Dialect.sqlite);
    defer std.heap.page_allocator.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"we\"\"ird\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"co\"\"l\"") != null);

    const backticked = TableDef{
        .name = "we`ird",
        .columns = &.{
            ColumnDef{ .name = "co`l", .sql_type = "INTEGER" },
        },
        .primary_keys = &.{},
    };
    const mysql_sql = try createTableSQL(backticked, Dialect.mysql);
    defer std.heap.page_allocator.free(mysql_sql);
    try std.testing.expect(std.mem.indexOf(u8, mysql_sql, "`we``ird`") != null);
    try std.testing.expect(std.mem.indexOf(u8, mysql_sql, "`co``l`") != null);
}

test "CREATE TABLE SQL includes ON DELETE/UPDATE cascade" {
    const table = TableDef{
        .name = "order",
        .columns = &.{
            ColumnDef{ .name = "id", .sql_type = "INTEGER", .primary_key = true },
            ColumnDef{ .name = "user_id", .sql_type = "INTEGER" },
        },
        .primary_keys = &.{"id"},
        .foreign_keys = &.{
            ForeignKeyDef{
                .columns = &.{"user_id"},
                .ref_table = "user",
                .ref_columns = &.{"id"},
                .on_delete = "CASCADE",
                .on_update = "CASCADE",
            },
        },
    };
    const sql = try createTableSQL(table, Dialect.sqlite);
    defer std.heap.page_allocator.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "ON DELETE CASCADE") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "ON UPDATE CASCADE") != null);
}

test "PostgreSQL migration SQL resolves logical field types" {
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    const Payload = struct { value: i64 };
    const Event = schema("DialectEvent", .{
        .fields = &.{ field.Time("occurred_at"), field.JSON("payload", Payload), field.UUID("external_id") },
    });

    const info = comptime fromSchema(Event);
    const table = comptime tableFromTypeInfo(info);
    const sql = try createTableSQL(table, Dialect.postgres);
    defer std.heap.page_allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "\"occurred_at\" BIGINT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"payload\" JSONB") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"external_id\" UUID") != null);
}

test "MySQL type-only ALTER is rejected as unsafe" {
    const result = alterColumnTypeSQL(std.testing.allocator, "user", "name", "TEXT", Dialect.mysql);
    if (result) |sql| {
        std.testing.allocator.free(sql);
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.MySQLTypeChangeUnsafe, err);
    }
}

test "Migrate schema adds missing columns" {
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    // Create legacy table with only id + name
    _ = try drv.exec("CREATE TABLE legacy_user (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)", &.{});

    const LegacyUser = schema("LegacyUser", .{
        .fields = &.{ field.String("name"), field.Int("age"), field.String("email") },
    });

    const info = comptime fromSchema(LegacyUser);
    const infos = &[_]TypeInfo{info};
    try migrateSchema(std.testing.allocator, drv.asDriver(), infos);

    // Verify new columns exist via PRAGMA
    var rows = try drv.query("PRAGMA table_info(legacy_user)", &.{});
    defer rows.deinit();

    var found_age = false;
    var found_email = false;
    while (rows.next()) |row| {
        const col_name = row.getText(1) orelse continue;
        if (std.mem.eql(u8, col_name, "age")) found_age = true;
        if (std.mem.eql(u8, col_name, "email")) found_email = true;
    }
    try std.testing.expect(found_age);
    try std.testing.expect(found_email);
}

test "Migrate schema drops columns when opts.drop_columns set (SQLite)" {
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    // Create table with id, name, and an extra column "legacy_field"
    _ = try drv.exec(
        "CREATE TABLE book (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, legacy_field TEXT)",
        &.{},
    );

    // Schema only declares id + name — legacy_field should be dropped.
    const Book = schema("Book", .{
        .fields = &.{field.String("name")},
    });

    const info = comptime fromSchema(Book);
    const infos = &[_]TypeInfo{info};
    try migrateSchemaWithOptions(std.testing.allocator, drv.asDriver(), infos, MigrateOptions{
        .drop_columns = true,
    });

    // Verify legacy_field was dropped.
    var rows = try drv.query("PRAGMA table_info(book)", &.{});
    defer rows.deinit();

    var found_legacy = false;
    while (rows.next()) |row| {
        const col_name = row.getText(1) orelse continue;
        if (std.mem.eql(u8, col_name, "legacy_field")) found_legacy = true;
    }
    try std.testing.expect(!found_legacy);
}

test "Migrate schema does NOT drop columns when opts.drop_columns false (default)" {
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec(
        "CREATE TABLE album (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, extra_col TEXT)",
        &.{},
    );

    const Album = schema("Album", .{
        .fields = &.{field.String("title")},
    });

    const info = comptime fromSchema(Album);
    const infos = &[_]TypeInfo{info};
    // Default MigrateOptions{} has drop_columns=false.
    try migrateSchema(std.testing.allocator, drv.asDriver(), infos);

    // extra_col should still exist.
    var rows = try drv.query("PRAGMA table_info(album)", &.{});
    defer rows.deinit();

    var found_extra = false;
    while (rows.next()) |row| {
        const col_name = row.getText(1) orelse continue;
        if (std.mem.eql(u8, col_name, "extra_col")) found_extra = true;
    }
    try std.testing.expect(found_extra);
}

test "Migrate schema alters column type when opts.allow_data_loss set (SQLite — skips gracefully)" {
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    // Create a table where "score" column is TEXT but schema says INTEGER.
    _ = try drv.exec(
        "CREATE TABLE entry (id INTEGER PRIMARY KEY AUTOINCREMENT, score TEXT)",
        &.{},
    );

    const Entry = schema("Entry", .{
        .fields = &.{field.Int("score")},
    });

    const info = comptime fromSchema(Entry);
    const infos = &[_]TypeInfo{info};
    // allow_data_loss=true, but SQLite returns UnsupportedDialect — must not crash.
    try migrateSchemaWithOptions(std.testing.allocator, drv.asDriver(), infos, MigrateOptions{
        .allow_data_loss = true,
    });

    // The type won't change on SQLite (unsupported), but migration must succeed.
    var rows = try drv.query("PRAGMA table_info(entry)", &.{});
    defer rows.deinit();

    while (rows.next()) |row| {
        const col_name = row.getText(1) orelse continue;
        if (std.mem.eql(u8, col_name, "score")) {
            const col_type = row.getText(2) orelse "";
            // On SQLite the type stays TEXT because ALTER TYPE is unsupported.
            try std.testing.expect(std.mem.eql(u8, col_type, "TEXT"));
        }
    }
}

/// Test-only driver wrapper: forwards every operation to a real driver and
/// records each executed SQL string. Lets a test assert that the statements a
/// real migration ran are exactly the ones `planMigrateStatements` — the
/// dry-run's computation — produced, in order.
const RecordingDriver = struct {
    inner: sql_driver.Driver,
    allocator: std.mem.Allocator,
    execs: std.array_list.Managed([]const u8),

    fn init(allocator: std.mem.Allocator, inner: sql_driver.Driver) RecordingDriver {
        return .{
            .inner = inner,
            .allocator = allocator,
            .execs = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    fn deinit(self: *RecordingDriver) void {
        self.clearExecs();
        self.execs.deinit();
    }

    fn clearExecs(self: *RecordingDriver) void {
        for (self.execs.items) |s| self.allocator.free(s);
        self.execs.clearRetainingCapacity();
    }

    fn asDriver(self: *RecordingDriver) sql_driver.Driver {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn execHook(ptr: *anyopaque, ctx: ?*const sql_driver.ExecutionContext, query: []const u8, args: []const Value) sql_driver.Error!sql_driver.Result {
        const self: *RecordingDriver = @ptrCast(@alignCast(ptr));
        const owned = self.allocator.dupe(u8, query) catch return error.OutOfMemory;
        self.execs.append(owned) catch {
            self.allocator.free(owned);
            return error.OutOfMemory;
        };
        return self.inner.execCtx(ctx, query, args);
    }

    fn queryHook(ptr: *anyopaque, ctx: ?*const sql_driver.ExecutionContext, query: []const u8, args: []const Value) sql_driver.Error!sql_driver.Rows {
        const self: *RecordingDriver = @ptrCast(@alignCast(ptr));
        return self.inner.queryCtx(ctx, query, args);
    }

    fn beginTxHook(ptr: *anyopaque) sql_driver.Error!sql_driver.Tx {
        const self: *RecordingDriver = @ptrCast(@alignCast(ptr));
        var tx = try self.inner.beginTx();
        // The migration execs through `tx.inner`, so re-route the tx's inner
        // driver back through this wrapper — transaction-scoped DDL must be
        // recorded too. commit/rollback/deinit keep the original handle.
        tx.inner = self.asDriver();
        return tx;
    }

    fn beginSavepointHook(ptr: *anyopaque, name: []const u8) sql_driver.Error!sql_driver.Tx {
        const self: *RecordingDriver = @ptrCast(@alignCast(ptr));
        var tx = try self.inner.beginSavepoint(name);
        tx.inner = self.asDriver();
        return tx;
    }

    fn closeHook(ptr: *anyopaque) void {
        const self: *RecordingDriver = @ptrCast(@alignCast(ptr));
        self.inner.close();
    }

    fn dialectHook(ptr: *anyopaque) Dialect {
        const self: *RecordingDriver = @ptrCast(@alignCast(ptr));
        return self.inner.dialect();
    }

    fn pingHook(ptr: *anyopaque) sql_driver.Error!void {
        const self: *RecordingDriver = @ptrCast(@alignCast(ptr));
        return self.inner.ping();
    }

    fn inTransactionHook(ptr: *anyopaque) bool {
        const self: *RecordingDriver = @ptrCast(@alignCast(ptr));
        return self.inner.inTransaction();
    }

    const vtable: sql_driver.Driver.VTable = .{
        .exec = execHook,
        .query = queryHook,
        .beginTx = beginTxHook,
        .close = closeHook,
        .dialect = dialectHook,
        .ping = pingHook,
        .inTransaction = inTransactionHook,
        .beginSavepoint = beginSavepointHook,
    };
};

/// The DDL statements recorded by a real run, minus the history-table
/// bookkeeping (`ensureMigrationsTable`, `recordMigration` INSERTs) that the
/// statement plan deliberately does not carry.
fn recordedDdl(allocator: std.mem.Allocator, rec: *RecordingDriver) !std.array_list.Managed([]const u8) {
    var ddl = std.array_list.Managed([]const u8).init(allocator);
    errdefer ddl.deinit();
    for (rec.execs.items) |s| {
        if (std.mem.indexOf(u8, s, "zent_schema_migrations") != null) continue;
        try ddl.append(s);
    }
    return ddl;
}

/// The core dry-run invariant: the statement list `planMigrateStatements`
/// produces (what the dry-run prints, one line per statement) is exactly the
/// list a real run executes, in the same order.
fn expectPlanMatchesRecorded(plan: []const PlannedStatement, ddl: []const []const u8) !void {
    try std.testing.expectEqual(plan.len, ddl.len);
    for (plan, ddl, 0..) |st, exec_sql, k| {
        if (!std.mem.eql(u8, st.sql, exec_sql)) {
            std.debug.print("statement {d} differs:\n  plan: {s}\n  exec: {s}\n", .{ k, st.sql, exec_sql });
            return error.TestUnexpectedResult;
        }
    }
}

fn planHasStatementContaining(plan: []const PlannedStatement, needle: []const u8) bool {
    for (plan) |st| {
        if (std.mem.indexOf(u8, st.sql, needle) != null) return true;
    }
    return false;
}

test "dry-run plans exactly the statements an incremental migrate executes (SQLite)" {
    const allocator = std.testing.allocator;
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const index = @import("../../core/index.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    var rec = RecordingDriver.init(allocator, drv.asDriver());
    defer rec.deinit();

    // V1: plan_user(name) — migrated for real, so the history table records
    // the create_table version exactly as it would in production.
    const V1 = schema("PlanUser", .{
        .fields = &.{field.String("name")},
    });
    const v1_infos = &[_]TypeInfo{comptime fromSchema(V1)};
    try migrateSchema(allocator, rec.asDriver(), v1_infos);
    rec.clearExecs();

    // Out-of-band drift the V2 schema does not declare: an extra column.
    _ = try drv.exec("ALTER TABLE plan_user ADD COLUMN obsolete TEXT", &.{});
    _ = try drv.exec("INSERT INTO plan_user (name, obsolete) VALUES ('n', 'o')", &.{});

    // V2: adds age/email/status (status carries a DEFAULT backfill), an
    // index on name, and — with drop_columns — drops "obsolete".
    const V2 = schema("PlanUser", .{
        .fields = &.{
            field.String("name"),
            field.Int("age"),
            field.String("email"),
            field.String("status").Default("pending"),
        },
        .indexes = &.{
            index.Named("idx_plan_user_name", &.{"name"}),
        },
    });
    const v2_infos = &[_]TypeInfo{comptime fromSchema(V2)};
    const opts = MigrateOptions{ .drop_columns = true };

    // Plan first, against the history snapshot a real run would read...
    const applied = try appliedMigrations(allocator, rec.asDriver());
    defer freeAppliedMigrations(allocator, applied);
    var plan = try planMigrateStatements(allocator, rec.asDriver(), v2_infos, opts, applied);
    defer freePlannedStatements(allocator, &plan);

    // Semantic anchors: the plan is an *incremental* diff, not a fresh dump.
    try std.testing.expect(!planHasStatementContaining(plan.items, "CREATE TABLE"));
    try std.testing.expect(planHasStatementContaining(plan.items, "ADD COLUMN \"age\" INTEGER"));
    try std.testing.expect(planHasStatementContaining(plan.items, "ADD COLUMN \"status\" TEXT DEFAULT 'pending'"));
    try std.testing.expect(planHasStatementContaining(plan.items, "DROP COLUMN \"obsolete\""));
    try std.testing.expect(planHasStatementContaining(plan.items, "CREATE INDEX"));
    // The recorded kind is set: add_column records history, drop does not.
    for (plan.items) |st| {
        if (std.mem.indexOf(u8, st.sql, "DROP COLUMN") != null) {
            try std.testing.expectEqual(@as(?i64, null), st.version);
        }
        if (std.mem.indexOf(u8, st.sql, "ADD COLUMN") != null) {
            try std.testing.expect(st.version != null);
        }
    }

    // ...then the real run, recorded statement for statement.
    try migrateSchemaWithOptions(allocator, rec.asDriver(), v2_infos, opts);
    var ddl = try recordedDdl(allocator, &rec);
    defer ddl.deinit();

    try expectPlanMatchesRecorded(plan.items, ddl.items);

    // And the drift is actually gone, so the migration did what the plan said.
    var rows = try drv.query("PRAGMA table_info(plan_user)", &.{});
    defer rows.deinit();
    var found_age = false;
    var found_obsolete = false;
    while (rows.next()) |row| {
        const col_name = row.getText(1) orelse continue;
        if (std.mem.eql(u8, col_name, "age")) found_age = true;
        if (std.mem.eql(u8, col_name, "obsolete")) found_obsolete = true;
    }
    try std.testing.expect(found_age);
    try std.testing.expect(!found_obsolete);
}

test "dry-run on a fresh database plans the same statements the real migrate executes" {
    const allocator = std.testing.allocator;
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const buildGraph = @import("../../codegen/graph.zig").buildGraph;
    const edge = @import("../../core/edge.zig");
    const field = @import("../../core/field.zig");
    const index = @import("../../core/index.zig");
    const schema = @import("../../core/schema.zig").Schema;

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    var rec = RecordingDriver.init(allocator, drv.asDriver());
    defer rec.deinit();

    const Doc = schema("FreshDoc", .{
        .fields = &.{
            field.String("title"),
            field.Int("pages"),
        },
        .indexes = &.{
            index.Named("idx_fresh_doc_title", &.{"title"}),
        },
    });

    // A view entity and an m2m pair, so the plan covers the CREATE VIEW and
    // junction-table branches too — both are existence-gated exactly like
    // the real path.
    const DocView = schema("FreshDocView", .{
        .view = true,
        .view_sql = "SELECT 1 AS one",
        .fields = &.{field.Int("one")},
    });
    const PostBase = schema("FreshPost", .{
        .fields = &.{field.String("title")},
    });
    const TagBase = schema("FreshTag", .{
        .fields = &.{field.String("label")},
    });
    const Post = struct {
        pub const schema_name = PostBase.schema_name;
        pub const fields = PostBase.fields;
        pub const edges = &.{edge.To("tags", TagBase)};
        pub const indexes = PostBase.indexes;
        pub const policy = PostBase.policy;
        pub const is_view = PostBase.is_view;
        pub const view_sql = PostBase.view_sql;
        pub const soft_delete = PostBase.soft_delete;
    };
    const Tag = struct {
        pub const schema_name = TagBase.schema_name;
        pub const fields = TagBase.fields;
        pub const edges = &.{edge.To("posts", PostBase)};
        pub const indexes = TagBase.indexes;
        pub const policy = TagBase.policy;
        pub const is_view = TagBase.is_view;
        pub const view_sql = TagBase.view_sql;
        pub const soft_delete = TagBase.soft_delete;
    };

    const infos = comptime buildGraph(&.{ Doc, DocView, Post, Tag }).types;

    // No history table, nothing applied — the dry-run branch reads exactly
    // this shape of (empty) history.
    var plan = try planMigrateStatements(allocator, rec.asDriver(), infos, .{}, &.{});
    defer freePlannedStatements(allocator, &plan);

    try std.testing.expect(planHasStatementContaining(plan.items, "CREATE TABLE IF NOT EXISTS \"fresh_doc\""));
    try std.testing.expect(planHasStatementContaining(plan.items, "CREATE INDEX"));
    try std.testing.expect(planHasStatementContaining(plan.items, "CREATE VIEW IF NOT EXISTS \"fresh_doc_view\""));
    try std.testing.expect(planHasStatementContaining(plan.items, "CREATE TABLE IF NOT EXISTS \"fresh_post_fresh_tag\""));
    // Tables this run creates get no ALTER ADD COLUMNs: the CREATEs carry
    // the full shape.
    try std.testing.expect(!planHasStatementContaining(plan.items, "ADD COLUMN"));

    try migrateSchema(allocator, rec.asDriver(), infos);
    var ddl = try recordedDdl(allocator, &rec);
    defer ddl.deinit();

    try expectPlanMatchesRecorded(plan.items, ddl.items);
}

test "dry-run honours the opt-in switches on an existing table" {
    const allocator = std.testing.allocator;
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const Gate = schema("GateDoc", .{
        .fields = &.{
            field.String("name"),
            field.String("status").Default("pending"),
        },
    });
    const infos = &[_]TypeInfo{comptime fromSchema(Gate)};
    try migrateSchema(allocator, drv.asDriver(), infos);

    // Drift: a column the schema does not declare, and — for the
    // nullability half — the table simply predates "status".
    _ = try drv.exec("ALTER TABLE gate_doc ADD COLUMN stray TEXT", &.{});
    _ = try drv.exec("ALTER TABLE gate_doc DROP COLUMN status", &.{});

    // Default opts: no DROP COLUMN, and an added NOT NULL column arrives
    // nullable (the drift check_nullability reports) rather than converged.
    const applied = try appliedMigrations(allocator, drv.asDriver());
    defer freeAppliedMigrations(allocator, applied);
    var loose = try planMigrateStatements(allocator, drv.asDriver(), infos, .{}, applied);
    defer freePlannedStatements(allocator, &loose);
    try std.testing.expect(!planHasStatementContaining(loose.items, "DROP COLUMN"));
    try std.testing.expect(planHasStatementContaining(loose.items, "ADD COLUMN \"status\" TEXT DEFAULT 'pending'"));
    try std.testing.expect(!planHasStatementContaining(loose.items, "NOT NULL"));

    // Opted in: the DROP appears and the column converges NOT NULL with its
    // DEFAULT backfill.
    var strict = try planMigrateStatements(allocator, drv.asDriver(), infos, .{
        .drop_columns = true,
        .allow_nullability_change = true,
    }, applied);
    defer freePlannedStatements(allocator, &strict);
    try std.testing.expect(planHasStatementContaining(strict.items, "DROP COLUMN \"stray\""));
    try std.testing.expect(planHasStatementContaining(strict.items, "ADD COLUMN \"status\" TEXT NOT NULL DEFAULT 'pending'"));

    // A converged database plans nothing at all.
    try migrateSchemaWithOptions(allocator, drv.asDriver(), infos, .{
        .drop_columns = true,
        .allow_nullability_change = true,
    });
    var settled = try planMigrateStatements(allocator, drv.asDriver(), infos, .{}, applied);
    defer freePlannedStatements(allocator, &settled);
    try std.testing.expectEqual(@as(usize, 0), settled.items.len);
}

test "migrateSchemaWithOptions dry_run executes nothing but plans the incremental diff" {
    const allocator = std.testing.allocator;
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    var rec = RecordingDriver.init(allocator, drv.asDriver());
    defer rec.deinit();

    const V1 = schema("DryRunDoc", .{
        .fields = &.{field.String("name")},
    });
    const v1_infos = &[_]TypeInfo{comptime fromSchema(V1)};
    try migrateSchema(allocator, rec.asDriver(), v1_infos);
    rec.clearExecs();

    const V2 = schema("DryRunDoc", .{
        .fields = &.{
            field.String("name"),
            field.Int("age"),
        },
    });
    const v2_infos = &[_]TypeInfo{comptime fromSchema(V2)};

    // The dry-run branch itself: it introspects (queries are fine) but must
    // never exec — the recording wrapper is the witness.
    try migrateSchemaWithOptions(allocator, rec.asDriver(), v2_infos, .{ .dry_run = true });
    try std.testing.expectEqual(@as(usize, 0), rec.execs.items.len);

    // And it changed nothing.
    var rows = try drv.query("PRAGMA table_info(dry_run_doc)", &.{});
    defer rows.deinit();
    while (rows.next()) |row| {
        try std.testing.expect(!std.mem.eql(u8, row.getText(1) orelse "", "age"));
    }

    // The real run then applies exactly the diff the dry-run previewed.
    const applied = try appliedMigrations(allocator, rec.asDriver());
    defer freeAppliedMigrations(allocator, applied);
    var plan = try planMigrateStatements(allocator, rec.asDriver(), v2_infos, .{}, applied);
    defer freePlannedStatements(allocator, &plan);
    try migrateSchemaWithOptions(allocator, rec.asDriver(), v2_infos, .{});
    var ddl = try recordedDdl(allocator, &rec);
    defer ddl.deinit();
    try expectPlanMatchesRecorded(plan.items, ddl.items);
}

test "file migration checksum mismatch is rejected" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;

    const dir_name = "test_migrations_checksum_mismatch";
    try std.Io.Dir.cwd().createDirPath(io, dir_name);
    defer std.Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var dir = try std.Io.Dir.cwd().openDir(io, dir_name, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{
            .sub_path = "001_create_cs_items.up.sql",
            .data = "CREATE TABLE cs_items (id INTEGER PRIMARY KEY, name TEXT);",
        });
    }

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    try migrateFromFilesWithOptions(io, allocator, drv.asDriver(), dir_name, .{});

    // Simulate an edited migration: the recorded checksum no longer matches
    // the file on disk.
    _ = try drv.exec("UPDATE zent_schema_migrations SET checksum = 'deadbeef' WHERE version = 1", &.{});

    try std.testing.expectError(
        error.MigrationChecksumMismatch,
        migrateFromFilesWithOptions(io, allocator, drv.asDriver(), dir_name, .{}),
    );
}

test "lock_timeout_ms is a no-op on SQLite and repeated runs succeed" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;

    const dir_name = "test_migrations_lock_sqlite";
    try std.Io.Dir.cwd().createDirPath(io, dir_name);
    defer std.Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var dir = try std.Io.Dir.cwd().openDir(io, dir_name, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{
            .sub_path = "001_create_lock_items.up.sql",
            .data = "CREATE TABLE lock_items (id INTEGER PRIMARY KEY, name TEXT);",
        });
        try dir.writeFile(io, .{
            .sub_path = "002_add_lock_item.up.sql",
            .data = "INSERT INTO lock_items (id, name) VALUES (1, 'first');",
        });
    }

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    try migrateFromFilesWithOptions(io, allocator, drv.asDriver(), dir_name, .{ .lock_timeout_ms = 50 });
    // Second run: everything is already applied; the lock path must neither
    // block nor fail (SQLite skips the external lock entirely).
    try migrateFromFilesWithOptions(io, allocator, drv.asDriver(), dir_name, .{ .lock_timeout_ms = 50 });

    var rows = try drv.query("SELECT COUNT(*) FROM lock_items", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try std.testing.expectEqual(@as(i64, 1), row.getInt(0).?);

    // Unlocking is skipped too: a second acquire/release cycle still works.
    try rollbackFilesWithOptions(io, allocator, drv.asDriver(), dir_name, 1, .{ .lock_timeout_ms = 50 });
}

test "schema-diff migration succeeds with locking enabled (SQLite)" {
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    const LockItem = schema("LockDiffItem", .{
        .fields = &.{field.String("name")},
    });
    const info = comptime fromSchema(LockItem);
    const infos = &[_]TypeInfo{info};

    try migrateSchemaWithOptions(std.testing.allocator, drv.asDriver(), infos, .{ .lock_timeout_ms = 100 });
    // Re-running also acquires/releases the (skipped) lock cleanly.
    try migrateSchemaWithOptions(std.testing.allocator, drv.asDriver(), infos, .{ .lock_timeout_ms = 100 });
}

test "MySQL BLOB/TEXT/JSON restrictions are classified before SQL is emitted" {
    const mysql = Dialect{ .name = "mysql" };
    // Hand-built columns, like a consumer's own TableDef: no logical type, so
    // the check has to read `sql_type` itself.
    const table = TableDef{
        .name = "article",
        .columns = &.{
            ColumnDef{ .name = "id", .sql_type = "INTEGER", .primary_key = true },
            ColumnDef{ .name = "body", .sql_type = "TEXT", .not_null = true },
            ColumnDef{ .name = "note", .sql_type = "LONGTEXT", .default_value = "'x'" },
            ColumnDef{ .name = "metadata", .sql_type = "JSON", .unique = true },
            ColumnDef{ .name = "raw", .sql_type = "BLOB", .primary_key = true },
            ColumnDef{ .name = "title", .sql_type = "VARCHAR(255)", .unique = true, .default_value = "'t'" },
        },
        .primary_keys = &.{"id"},
    };

    // The first restricted column wins, in declaration order.
    const default_restriction = findMySqlTextRestriction(table, &.{}, mysql).?;
    try std.testing.expectEqual(MySqlTextRestriction.Kind.default_value, default_restriction.kind);
    try std.testing.expectEqualStrings("note", default_restriction.column);
    try std.testing.expectEqualStrings("LONGTEXT", default_restriction.sql_type);

    // Take the restricted columns away one at a time and watch the next one
    // surface: the check walks declaration order, not a set.
    const without_default = TableDef{
        .name = table.name,
        .columns = &.{ table.columns[0], table.columns[1], table.columns[3], table.columns[4], table.columns[5] },
        .primary_keys = table.primary_keys,
    };
    const unique_restriction = findMySqlTextRestriction(without_default, &.{}, mysql).?;
    try std.testing.expectEqual(MySqlTextRestriction.Kind.unique, unique_restriction.kind);
    try std.testing.expectEqualStrings("metadata", unique_restriction.column);

    const only_primary = TableDef{
        .name = table.name,
        .columns = &.{ table.columns[0], table.columns[1], table.columns[4], table.columns[5] },
        .primary_keys = table.primary_keys,
    };
    const pk_restriction = findMySqlTextRestriction(only_primary, &.{}, mysql).?;
    try std.testing.expectEqual(MySqlTextRestriction.Kind.primary_key, pk_restriction.kind);
    try std.testing.expectEqualStrings("raw", pk_restriction.column);

    // A composite PRIMARY KEY (...) naming the column is the same errno 1170
    // even when the column itself is not marked.
    const composite = TableDef{
        .name = table.name,
        .columns = &.{ table.columns[1], table.columns[5] },
        .primary_keys = &.{ "body", "title" },
    };
    try std.testing.expectEqual(MySqlTextRestriction.Kind.primary_key, findMySqlTextRestriction(composite, &.{}, mysql).?.kind);

    // Nothing restricted: VARCHAR(255) and an unconstrained TEXT column.
    const clean = TableDef{
        .name = "article",
        .columns = &.{
            ColumnDef{ .name = "id", .sql_type = "INTEGER", .primary_key = true },
            ColumnDef{ .name = "body", .sql_type = "TEXT", .not_null = true },
            ColumnDef{ .name = "title", .sql_type = "VARCHAR(255)", .unique = true, .default_value = "'t'" },
        },
        .primary_keys = &.{"id"},
    };
    try std.testing.expect(findMySqlTextRestriction(clean, &.{}, mysql) == null);

    // The restriction is MySQL's own: the same table is fine elsewhere.
    for ([_]Dialect{ Dialect.sqlite, Dialect.postgres }) |other| {
        try std.testing.expect(findMySqlTextRestriction(table, &.{}, other) == null);
    }

    // Case-insensitive and tolerant of a modifier, so `text`, `TEXT(100)` and
    // `longtext` are all recognized.
    for ([_][]const u8{ "text", "Text", "TEXT(100)", "tinytext", "mediumblob", "json" }) |sql_type| {
        const one = TableDef{
            .name = "t",
            .columns = &.{ColumnDef{ .name = "c", .sql_type = sql_type, .unique = true }},
            .primary_keys = &.{},
        };
        try std.testing.expect(findMySqlTextRestriction(one, &.{}, mysql) != null);
    }
    for ([_][]const u8{ "VARCHAR(255)", "varchar", "INTEGER", "BIGINT", "BOOLEAN" }) |sql_type| {
        const one = TableDef{
            .name = "t",
            .columns = &.{ColumnDef{ .name = "c", .sql_type = sql_type, .unique = true }},
            .primary_keys = &.{},
        };
        try std.testing.expect(findMySqlTextRestriction(one, &.{}, mysql) == null);
    }
}

test "MySQL CREATE TABLE refuses the three DDL shapes the server would reject" {
    const mysql = Dialect{ .name = "mysql" };

    const unique_text = TableDef{
        .name = "article",
        .columns = &.{
            ColumnDef{ .name = "id", .sql_type = "INTEGER", .primary_key = true },
            ColumnDef{ .name = "body", .sql_type = "TEXT", .not_null = true, .unique = true },
        },
        .primary_keys = &.{"id"},
    };
    try std.testing.expectError(
        error.MySQLTextColumnCannotBeIndexed,
        createTableSQLAlloc(std.testing.allocator, unique_text, mysql),
    );

    const default_text = TableDef{
        .name = "article",
        .columns = &.{
            ColumnDef{ .name = "id", .sql_type = "INTEGER", .primary_key = true },
            ColumnDef{ .name = "body", .sql_type = "TEXT", .default_value = "'none'" },
        },
        .primary_keys = &.{"id"},
    };
    try std.testing.expectError(
        error.MySQLTextColumnCannotHaveDefault,
        createTableSQLAlloc(std.testing.allocator, default_text, mysql),
    );

    const text_pk = TableDef{
        .name = "article",
        .columns = &.{ColumnDef{ .name = "slug", .sql_type = "TEXT", .primary_key = true }},
        .primary_keys = &.{"slug"},
    };
    try std.testing.expectError(
        error.MySQLTextColumnCannotBeIndexed,
        createTableSQLAlloc(std.testing.allocator, text_pk, mysql),
    );

    // The same declarations are legal on SQLite and PostgreSQL and must still
    // generate SQL — the check is dialect-gated, not a blanket refusal.
    for ([_]Dialect{ Dialect.sqlite, Dialect.postgres }) |dialect| {
        const sql = try createTableSQLAlloc(std.testing.allocator, unique_text, dialect);
        defer std.testing.allocator.free(sql);
        try std.testing.expect(std.mem.indexOf(u8, sql, "UNIQUE") != null);

        const default_sql = try createTableSQLAlloc(std.testing.allocator, default_text, dialect);
        defer std.testing.allocator.free(default_sql);
        try std.testing.expect(std.mem.indexOf(u8, default_sql, "DEFAULT 'none'") != null);
    }

    // MySQL still emits the same table when every column is indexable.
    const clean = TableDef{
        .name = "article",
        .columns = &.{
            ColumnDef{ .name = "id", .sql_type = "INTEGER", .primary_key = true },
            ColumnDef{ .name = "title", .sql_type = "VARCHAR(255)", .unique = true, .default_value = "'t'" },
        },
        .primary_keys = &.{"id"},
    };
    const sql = try createTableSQLAlloc(std.testing.allocator, clean, mysql);
    defer std.testing.allocator.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "`title` VARCHAR(255) UNIQUE DEFAULT 't'") != null);
}

test "MySQL CREATE INDEX refuses a BLOB/TEXT/JSON key column" {
    const mysql = Dialect{ .name = "mysql" };
    const table = TableDef{
        .name = "article",
        .columns = &.{
            ColumnDef{ .name = "id", .sql_type = "INTEGER", .primary_key = true },
            ColumnDef{ .name = "body", .sql_type = "TEXT" },
            ColumnDef{ .name = "title", .sql_type = "VARCHAR(255)" },
        },
        .primary_keys = &.{"id"},
    };

    const on_text = IndexDef{ .name = "idx_body", .columns = &.{"body"} };
    try std.testing.expectError(
        error.MySQLTextColumnCannotBeIndexed,
        createIndexSQLForTableAlloc(std.testing.allocator, on_text, table, mysql),
    );

    // The pure check names the index, which the error cannot.
    const restriction = findMySqlTextRestriction(table, &.{on_text}, mysql).?;
    try std.testing.expectEqual(MySqlTextRestriction.Kind.index, restriction.kind);
    try std.testing.expectEqualStrings("idx_body", restriction.index_name);
    try std.testing.expectEqualStrings("body", restriction.column);
    try std.testing.expectEqualStrings("TEXT", restriction.sql_type);

    // A key column of a *multi-column* index counts too, and the columns are
    // the index's, not the table's.
    const mixed = IndexDef{ .name = "idx_title_body", .columns = &.{ "title", "body" } };
    try std.testing.expectEqualStrings("idx_title_body", findMySqlTextRestriction(table, &.{mixed}, mysql).?.index_name);

    // VARCHAR is indexable, and PostgreSQL/SQLite take the TEXT index.
    const on_varchar = IndexDef{ .name = "idx_title", .columns = &.{"title"} };
    const mysql_sql = try createIndexSQLForTableAlloc(std.testing.allocator, on_varchar, table, mysql);
    defer std.testing.allocator.free(mysql_sql);
    try std.testing.expectEqualStrings("CREATE INDEX `idx_title` ON `article` (`title`)", mysql_sql);

    for ([_]Dialect{ Dialect.sqlite, Dialect.postgres }) |dialect| {
        const sql = try createIndexSQLForTableAlloc(std.testing.allocator, on_text, table, dialect);
        defer std.testing.allocator.free(sql);
        try std.testing.expect(std.mem.indexOf(u8, sql, "(\"body\")") != null);
    }
}

test "CREATE INDEX: an undeclared method/opclass is byte-for-byte the old statement" {
    // The whole declaration surface this feature adds is opt-in: a schema that
    // declares neither must produce exactly the SQL it produced before
    // `IndexDef.method` existed, on every dialect, unique or not. These are the
    // literals the surrounding tests already pin; if one of them ever changes,
    // this says which half did it.
    const table_name = "users";
    const cases = [_]struct { dialect: Dialect, expected: []const u8 }{
        .{ .dialect = Dialect.postgres, .expected = "CREATE INDEX IF NOT EXISTS \"idx_name\" ON \"users\" (\"name\")" },
        .{ .dialect = Dialect.sqlite, .expected = "CREATE INDEX IF NOT EXISTS \"idx_name\" ON \"users\" (\"name\")" },
        .{ .dialect = Dialect{ .name = "mysql" }, .expected = "CREATE INDEX `idx_name` ON `users` (`name`)" },
    };
    for (cases) |case| {
        const plain = IndexDef{ .name = "idx_name", .columns = &.{"name"} };
        const sql = try createIndexSQLAlloc(std.testing.allocator, plain, table_name, case.dialect);
        defer std.testing.allocator.free(sql);
        try std.testing.expectEqualStrings(case.expected, sql);
    }

    // Unique, multi-column, and a second key column: no `USING`, no opclass,
    // and no `errno 1064`-triggering MySQL syntax change.
    const unique_two = IndexDef{ .name = "idx_a_b", .columns = &.{ "a", "b" }, .unique = true };
    const pg_sql = try createIndexSQLAlloc(std.testing.allocator, unique_two, table_name, Dialect.postgres);
    defer std.testing.allocator.free(pg_sql);
    try std.testing.expectEqualStrings(
        "CREATE UNIQUE INDEX IF NOT EXISTS \"idx_a_b\" ON \"users\" (\"a\", \"b\")",
        pg_sql,
    );
}

test "CREATE INDEX: PostgreSQL renders USING and the key column's operator class" {
    const table_name = "docs";

    // The declaration this exists for: a pgvector nearest-neighbour index.
    const hnsw = IndexDef{
        .name = "idx_docs_embedding_hnsw",
        .columns = &.{"embedding"},
        .method = "hnsw",
        .opclass = "vector_cosine_ops",
    };
    const sql = try createIndexSQLAlloc(std.testing.allocator, hnsw, table_name, Dialect.postgres);
    defer std.testing.allocator.free(sql);
    try std.testing.expectEqualStrings(
        "CREATE INDEX IF NOT EXISTS \"idx_docs_embedding_hnsw\" ON \"docs\" USING hnsw (\"embedding\" vector_cosine_ops)",
        sql,
    );

    // Method alone — `USING hnsw` with no operator class. `ivfflat` is the
    // other pgvector method and goes out just as verbatim.
    const ivfflat = IndexDef{ .name = "idx_docs_e_ivf", .columns = &.{"embedding"}, .method = "ivfflat" };
    const ivf_sql = try createIndexSQLAlloc(std.testing.allocator, ivfflat, table_name, Dialect.postgres);
    defer std.testing.allocator.free(ivf_sql);
    try std.testing.expectEqualStrings(
        "CREATE INDEX IF NOT EXISTS \"idx_docs_e_ivf\" ON \"docs\" USING ivfflat (\"embedding\")",
        ivf_sql,
    );

    // A schema-qualified operator class is a dotted identifier, and a
    // `UNIQUE` + `USING` combination keeps both slots.
    const qualified = IndexDef{
        .name = "idx_q",
        .columns = &.{"embedding"},
        .unique = true,
        .method = "hnsw",
        .opclass = "public.vector_l2_ops",
    };
    const q_sql = try createIndexSQLAlloc(std.testing.allocator, qualified, table_name, Dialect.postgres);
    defer std.testing.allocator.free(q_sql);
    try std.testing.expectEqualStrings(
        "CREATE UNIQUE INDEX IF NOT EXISTS \"idx_q\" ON \"docs\" USING hnsw (\"embedding\" public.vector_l2_ops)",
        q_sql,
    );

    // An operator class belongs to one key column, so a composite index has no
    // answer to "which one"; the declaration is refused rather than guessed at.
    const two_cols = IndexDef{
        .name = "idx_two",
        .columns = &.{ "embedding", "created_at" },
        .opclass = "vector_cosine_ops",
    };
    try std.testing.expectError(
        error.OpClassNeedsSingleColumn,
        createIndexSQLAlloc(std.testing.allocator, two_cols, table_name, Dialect.postgres),
    );

    // These two are the only parts of a CREATE INDEX that go out unquoted and
    // do not come from the schema, so a value that is not a bare identifier is
    // an injection surface and is rejected — never escaped into something the
    // server would accept as a different declaration.
    const bad_method = IndexDef{ .name = "idx_bad", .columns = &.{"embedding"}, .method = "hnsw); DROP TABLE docs; --" };
    try std.testing.expectError(
        error.InvalidIndexMethod,
        createIndexSQLAlloc(std.testing.allocator, bad_method, table_name, Dialect.postgres),
    );
    const bad_opclass = IndexDef{ .name = "idx_bad2", .columns = &.{"embedding"}, .opclass = "vector_cosine_ops)" };
    try std.testing.expectError(
        error.InvalidIndexOpClass,
        createIndexSQLAlloc(std.testing.allocator, bad_opclass, table_name, Dialect.postgres),
    );
    const empty_part = IndexDef{ .name = "idx_bad3", .columns = &.{"embedding"}, .method = "hnsw." };
    try std.testing.expectError(
        error.InvalidIndexMethod,
        createIndexSQLAlloc(std.testing.allocator, empty_part, table_name, Dialect.postgres),
    );
}

test "CREATE INDEX: MySQL maps btree/hash onto USING and omits anything else" {
    const mysql = Dialect{ .name = "mysql" };

    // MySQL's grammar has exactly two index types, and the index type sits
    // between the name and `ON` (`CREATE INDEX i USING BTREE ON t (…)`), not
    // where PostgreSQL's `USING` goes. Both spellings were checked against a
    // running server.
    const btree = IndexDef{ .name = "idx_a", .columns = &.{"a"}, .method = "btree" };
    const btree_sql = try createIndexSQLAlloc(std.testing.allocator, btree, "t", mysql);
    defer std.testing.allocator.free(btree_sql);
    try std.testing.expectEqualStrings("CREATE INDEX `idx_a` USING BTREE ON `t` (`a`)", btree_sql);

    // Case-insensitive, and canonicalised on the way out.
    const hash = IndexDef{ .name = "idx_a2", .columns = &.{"a"}, .method = "HASH" };
    const hash_sql = try createIndexSQLAlloc(std.testing.allocator, hash, "t", mysql);
    defer std.testing.allocator.free(hash_sql);
    try std.testing.expectEqualStrings("CREATE INDEX `idx_a2` USING HASH ON `t` (`a`)", hash_sql);

    // A pgvector method has no MySQL equivalent. The statement still has to be
    // one the server accepts, so the method is dropped — the migration is not
    // aborted over a declaration that can only be a performance hint here.
    const hnsw = IndexDef{ .name = "idx_vec", .columns = &.{"e"}, .method = "hnsw" };
    const hnsw_sql = try createIndexSQLAlloc(std.testing.allocator, hnsw, "t", mysql);
    defer std.testing.allocator.free(hnsw_sql);
    try std.testing.expectEqualStrings("CREATE INDEX `idx_vec` ON `t` (`e`)", hnsw_sql);

    // Same for the operator class: MySQL does not have them at all. Note that
    // a *quoted* index type is a syntax error on MySQL (errno 1064), which is
    // why the method is validated instead of quoted — `` USING `BTREE` `` is
    // not an alternative spelling.
    const with_opclass = IndexDef{ .name = "idx_vec2", .columns = &.{"e"}, .opclass = "vector_l2_ops" };
    const oc_sql = try createIndexSQLAlloc(std.testing.allocator, with_opclass, "t", mysql);
    defer std.testing.allocator.free(oc_sql);
    try std.testing.expectEqualStrings("CREATE INDEX `idx_vec2` ON `t` (`e`)", oc_sql);

    // An opclass on a multi-column key is *not* an error here: the declaration
    // is inexpressible on this dialect either way, so it is reported and
    // dropped before the single-column rule could apply.
    const two_cols = IndexDef{
        .name = "idx_vec3",
        .columns = &.{ "e", "created_at" },
        .opclass = "vector_l2_ops",
    };
    const two_sql = try createIndexSQLAlloc(std.testing.allocator, two_cols, "t", mysql);
    defer std.testing.allocator.free(two_sql);
    try std.testing.expectEqualStrings("CREATE INDEX `idx_vec3` ON `t` (`e`, `created_at`)", two_sql);
}

test "CREATE INDEX: SQLite has no access methods or operator classes and drops both" {
    // SQLite's `CREATE INDEX` grammar has no `USING` and no operator class, so
    // a schema shared with PostgreSQL keeps migrating here — the index is
    // simply not an accelerated one. (The `vector` queries themselves do not
    // exist on SQLite; this is about the *index* declaration not blocking the
    // rest of the schema's migration.)
    const hnsw = IndexDef{
        .name = "idx_e",
        .columns = &.{"e"},
        .method = "hnsw",
        .opclass = "vector_cosine_ops",
    };
    const sql = try createIndexSQLAlloc(std.testing.allocator, hnsw, "docs", Dialect.sqlite);
    defer std.testing.allocator.free(sql);
    try std.testing.expectEqualStrings("CREATE INDEX IF NOT EXISTS \"idx_e\" ON \"docs\" (\"e\")", sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "USING") == null);

    // A `btree` declaration is dropped here too, not passed through as
    // `USING btree` — SQLite would reject it, and `btree` is what an index
    // with no declaration already is.
    const btree = IndexDef{ .name = "idx_e2", .columns = &.{"e"}, .method = "btree" };
    const btree_sql = try createIndexSQLAlloc(std.testing.allocator, btree, "docs", Dialect.sqlite);
    defer std.testing.allocator.free(btree_sql);
    try std.testing.expectEqualStrings("CREATE INDEX IF NOT EXISTS \"idx_e2\" ON \"docs\" (\"e\")", btree_sql);
}

test "an index declaration reaches the DDL, and the migration plans the hnsw statement" {
    // The end-to-end half of the declaration: `index.Named(...).Using(...)` on
    // a schema → `IndexInfo` → `IndexDef` → the statement `migrateSchema`
    // would run. The unit above pins the DDL; this pins that a schema's
    // declaration is what reaches it.
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const index = @import("../../core/index.zig");
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;
    const allocator = std.testing.allocator;

    const Doc = schema("Doc", .{
        .fields = &.{
            field.Int("id"),
            field.Other("embedding", "vector(3)"),
        },
        .indexes = &.{
            index.Named("idx_doc_embedding_hnsw", &.{"embedding"})
                .Using("hnsw", "vector_cosine_ops"),
            // Declared with field names, like every other index: `embedding`
            // here, not the storage key.
            index.Fields(&.{"embedding"}).Method("hnsw").OpClass("vector_l2_ops"),
        },
    });
    const info = comptime fromSchema(Doc);
    const infos = &[_]TypeInfo{info};

    const table = comptime tableFromTypeInfo(info);
    // The same `IndexInfo` → `IndexDef` mapping the migration uses, so this is
    // not a restatement of it.
    const sql = try createIndexSQLForTableAlloc(allocator, indexDefFromInfo(info.indexes[0]), table, Dialect.postgres);
    defer allocator.free(sql);
    try std.testing.expectEqualStrings(
        "CREATE INDEX IF NOT EXISTS \"idx_doc_embedding_hnsw\" ON \"doc\" USING hnsw (\"embedding\" vector_cosine_ops)",
        sql,
    );

    // The `Fields(...)` form generates the index name and keeps the method.
    try std.testing.expectEqualStrings("hnsw", info.indexes[1].method.?);
    try std.testing.expectEqualStrings("vector_l2_ops", info.indexes[1].opclass.?);
    try std.testing.expectEqualStrings("doc", info.table_name);
    _ = infos;
}

test "MySQL ALTER ADD COLUMN refuses a BLOB/TEXT DEFAULT" {
    const mysql = Dialect{ .name = "mysql" };

    // The shape the CREATE-side guard never sees: the table already exists, so
    // `createTableSQLAlloc` is skipped and this ALTER is the only statement
    // that would reach the server — as errno 1101, with no way out named.
    const text_default = ColumnDef{ .name = "body", .sql_type = "TEXT", .default_value = "'x'" };
    try std.testing.expectError(
        error.MySQLTextColumnCannotHaveDefault,
        alterTableAddColumnSQL(std.testing.allocator, "article", text_default, mysql, false, .mysql),
    );

    // `allow_nullability_change` takes the NOT NULL branch, which emits the
    // same DEFAULT for a different reason; the restriction is the type and the
    // default, and it does not care which branch asked for it.
    const not_null_default = ColumnDef{ .name = "body", .sql_type = "TEXT", .default_value = "'x'", .not_null = true };
    try std.testing.expectError(
        error.MySQLTextColumnCannotHaveDefault,
        alterTableAddColumnSQL(std.testing.allocator, "article", not_null_default, mysql, true, .mysql),
    );

    // `field.Bytes` is BLOB on MySQL and carries errno 1101 like TEXT does.
    // (`field.JSON` is TEXT there, not MySQL's JSON type — see `field.sqlType`.)
    for ([_][]const u8{ "BLOB", "TINYBLOB", "MEDIUMBLOB", "LONGBLOB", "JSON" }) |sql_type| {
        const blob_default = ColumnDef{ .name = "payload", .sql_type = sql_type, .default_value = "'{}'" };
        try std.testing.expectError(
            error.MySQLTextColumnCannotHaveDefault,
            alterTableAddColumnSQL(std.testing.allocator, "article", blob_default, mysql, false, .mysql),
        );
    }

    // Everything the server accepts still renders: the guard is about the type
    // carrying a DEFAULT, not about the ALTER.
    const varchar_default = ColumnDef{ .name = "title", .sql_type = "VARCHAR(255)", .default_value = "'t'" };
    const ok = try alterTableAddColumnSQL(std.testing.allocator, "article", varchar_default, mysql, false, .mysql);
    defer std.testing.allocator.free(ok);
    try std.testing.expectEqualStrings("ALTER TABLE `article` ADD COLUMN `title` VARCHAR(255) DEFAULT 't'", ok);

    // A TEXT column without a default is legal, and is what the schema gets.
    const text_plain = ColumnDef{ .name = "body", .sql_type = "TEXT" };
    const plain = try alterTableAddColumnSQL(std.testing.allocator, "article", text_plain, mysql, false, .mysql);
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("ALTER TABLE `article` ADD COLUMN `body` TEXT", plain);

    // PostgreSQL and SQLite have no such restriction and must still generate
    // the statement — the check is dialect-gated, not a blanket refusal.
    for ([_]Dialect{ Dialect.sqlite, Dialect.postgres }) |dialect| {
        const sql = try alterTableAddColumnSQL(std.testing.allocator, "article", text_default, dialect, false, .mysql);
        defer std.testing.allocator.free(sql);
        try std.testing.expectEqualStrings("ALTER TABLE \"article\" ADD COLUMN \"body\" TEXT DEFAULT 'x'", sql);
    }

    // UNIQUE is deliberately not part of this statement (see the note above the
    // return), so the check is not handed it either: a unique TEXT column is
    // added as a TEXT column. What the ALTER would silently not enforce is the
    // constraint — not the DEFAULT this guard exists for — and the CREATE-side
    // guard is where a schema declaring it is refused.
    const unique_text = ColumnDef{ .name = "body", .sql_type = "TEXT", .unique = true };
    const unique_sql = try alterTableAddColumnSQL(std.testing.allocator, "article", unique_text, mysql, false, .mysql);
    defer std.testing.allocator.free(unique_sql);
    try std.testing.expectEqualStrings("ALTER TABLE `article` ADD COLUMN `body` TEXT", unique_sql);
}

test "MariaDB: a TEXT DEFAULT is allowed where MySQL refuses it" {
    const mysql = Dialect{ .name = "mysql" };

    // One table, one difference: MySQL refuses `body TEXT DEFAULT 'x'` (errno
    // 1101), MariaDB >= 10.2.1 accepts it. The restriction scan is the single
    // place that decides, so every generator below follows from it.
    const default_text = TableDef{
        .name = "article",
        .columns = &.{
            ColumnDef{ .name = "id", .sql_type = "INTEGER", .primary_key = true },
            ColumnDef{ .name = "body", .sql_type = "TEXT", .default_value = "'x'" },
        },
        .primary_keys = &.{"id"},
    };

    // MySQL: unchanged, still refused.
    try std.testing.expectError(
        error.MySQLTextColumnCannotHaveDefault,
        createTableSQLAllocWithServer(std.testing.allocator, default_text, mysql, .mysql),
    );
    try std.testing.expectEqual(
        MySqlTextRestriction.Kind.default_value,
        findMySqlTextRestrictionWithServer(default_text, &.{}, mysql, .mysql).?.kind,
    );

    // MariaDB: no restriction, and the statement carries the DEFAULT.
    try std.testing.expect(findMySqlTextRestrictionWithServer(default_text, &.{}, mysql, .mariadb) == null);
    const mariadb_sql = try createTableSQLAllocWithServer(std.testing.allocator, default_text, mysql, .mariadb);
    defer std.testing.allocator.free(mariadb_sql);
    try std.testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS `article` (\n  `id` INTEGER PRIMARY KEY,\n  `body` TEXT DEFAULT 'x'\n)",
        mariadb_sql,
    );

    // Blob types are the same errno 1101 on MySQL and the same relaxation on
    // MariaDB — the rule is about the DEFAULT on a BLOB/TEXT column, not about
    // the TEXT spelling.
    const blob_default = TableDef{
        .name = "article",
        .columns = &.{ColumnDef{ .name = "payload", .sql_type = "LONGBLOB", .default_value = "'{}'" }},
        .primary_keys = &.{},
    };
    try std.testing.expectError(
        error.MySQLTextColumnCannotHaveDefault,
        createTableSQLAllocWithServer(std.testing.allocator, blob_default, mysql, .mysql),
    );
    const blob_sql = try createTableSQLAllocWithServer(std.testing.allocator, blob_default, mysql, .mariadb);
    defer std.testing.allocator.free(blob_sql);
    try std.testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS `article` (\n  `payload` LONGBLOB DEFAULT '{}'\n)",
        blob_sql,
    );

    // What is *not* relaxed: the key-length rule. A UNIQUE text column is still
    // errno 1170 on MariaDB, and one that also carries a DEFAULT reports the
    // UNIQUE — the relaxed kind must not swallow the refused one.
    const unique_text = TableDef{
        .name = "article",
        .columns = &.{ColumnDef{ .name = "body", .sql_type = "TEXT", .unique = true, .default_value = "'x'" }},
        .primary_keys = &.{},
    };
    try std.testing.expectEqual(
        MySqlTextRestriction.Kind.unique,
        findMySqlTextRestrictionWithServer(unique_text, &.{}, mysql, .mariadb).?.kind,
    );
    try std.testing.expectError(
        error.MySQLTextColumnCannotBeIndexed,
        createTableSQLAllocWithServer(std.testing.allocator, unique_text, mysql, .mariadb),
    );

    // ... and an index over a text column, likewise.
    const indexed = TableDef{
        .name = "article",
        .columns = &.{ColumnDef{ .name = "body", .sql_type = "TEXT" }},
        .primary_keys = &.{},
    };
    const on_text = IndexDef{ .name = "idx_body", .columns = &.{"body"}, .unique = false };
    try std.testing.expectEqual(
        MySqlTextRestriction.Kind.index,
        findMySqlTextRestrictionWithServer(indexed, &.{on_text}, mysql, .mariadb).?.kind,
    );
    try std.testing.expectError(
        error.MySQLTextColumnCannotBeIndexed,
        createIndexSQLForTableAllocWithServer(std.testing.allocator, on_text, indexed, mysql, .mariadb),
    );

    // The ALTER path follows the same answer — it is the path reached when the
    // table already exists, so the CREATE-side guard never runs for it.
    const body = ColumnDef{ .name = "body", .sql_type = "TEXT", .default_value = "'x'" };
    try std.testing.expectError(
        error.MySQLTextColumnCannotHaveDefault,
        alterTableAddColumnSQL(std.testing.allocator, "article", body, mysql, false, .mysql),
    );
    const alter_sql = try alterTableAddColumnSQL(std.testing.allocator, "article", body, mysql, false, .mariadb);
    defer std.testing.allocator.free(alter_sql);
    try std.testing.expectEqualStrings("ALTER TABLE `article` ADD COLUMN `body` TEXT DEFAULT 'x'", alter_sql);

    // A non-MySQL dialect never consults the server name: the same table is
    // emitted either way.
    for ([_]Dialect{ Dialect.sqlite, Dialect.postgres }) |other| {
        const sql = try createTableSQLAllocWithServer(std.testing.allocator, default_text, other, .mysql);
        defer std.testing.allocator.free(sql);
        try std.testing.expect(std.mem.indexOf(u8, sql, "DEFAULT 'x'") != null);
    }
}

test "MySQL/MariaDB identification is the version string, and an unknown server keeps MySQL's rules" {
    // MariaDB's version strings carry the family name; MySQL's do not. This is
    // the spelling the DDL layer branches on, so it is pinned here and in
    // `tests/integration/mysql.zig`'s `isMariaDB`.
    try std.testing.expectEqual(MySqlServer.mariadb, classifyMySqlServer("10.11.6-MariaDB-1~deb12u1"));
    try std.testing.expectEqual(MySqlServer.mariadb, classifyMySqlServer("5.5.5-10.2.1-MariaDB"));
    try std.testing.expectEqual(MySqlServer.mysql, classifyMySqlServer("9.7.0"));
    try std.testing.expectEqual(MySqlServer.mysql, classifyMySqlServer("8.0.36"));
    // A version that identifies nothing keeps the stricter rules, so a proxy or
    // a stripped string never relaxes a guard.
    try std.testing.expectEqual(MySqlServer.mysql, classifyMySqlServer(""));
    try std.testing.expectEqual(MySqlServer.mysql, classifyMySqlServer("10.11.6"));

    // The probe never turns into a migration failure. The only server here is
    // SQLite, whose `SELECT VERSION()` does not answer (and whose version would
    // not name MariaDB either way), so this is the conservative path: warn and
    // answer `.mysql`. The success path is exercised against a real server by
    // the MySQL integration tests.
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();
    try std.testing.expectEqual(MySqlServer.mysql, detectMySqlServer(drv.asDriver()));
}

test "SQLite introspection refuses a table name that would break the PRAGMA" {
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    // A table that really exists under a name no PRAGMA argument can carry:
    // SQLite accepts this name, the argument of `PRAGMA table_info("…")` does
    // not.
    _ = try drv.exec("CREATE TABLE \"we'ird\" (id INTEGER PRIMARY KEY, email TEXT)", &.{});

    // One name per quote character, plus the NUL that truncates the statement
    // before SQLite parses it.
    for ([_][]const u8{ "we'ird", "we\"ird", "we`ird", "we\x00ird", "'; DROP TABLE t; --" }) |name| {
        try std.testing.expectError(error.InvalidTableName, getExistingColumns(std.testing.allocator, drv.asDriver(), name));
        try std.testing.expectError(error.InvalidTableName, getExistingIndexes(std.testing.allocator, drv.asDriver(), name));
        // The foreign-key pragma interpolates the name the same way, so it
        // carries the same guard — `PRAGMA foreign_key_list("…")`.
        try std.testing.expectError(error.InvalidTableName, getExistingForeignKeys(std.testing.allocator, drv.asDriver(), name));
    }

    // The guard is about the statement, not about names one would not have
    // chosen: spaces and non-ASCII are legal inside the quotes and go through.
    _ = try drv.exec("CREATE TABLE \"space name\" (id INTEGER PRIMARY KEY, email TEXT)", &.{});
    _ = try drv.exec("CREATE INDEX idx_space_name_email ON \"space name\" (email)", &.{});

    var cols = try getExistingColumns(std.testing.allocator, drv.asDriver(), "space name");
    defer freeExistingColumns(std.testing.allocator, &cols);
    try std.testing.expectEqual(@as(usize, 2), cols.items.len);

    var idxs = try getExistingIndexes(std.testing.allocator, drv.asDriver(), "space name");
    defer freeExistingIndexes(std.testing.allocator, &idxs);
    try std.testing.expectEqual(@as(usize, 1), idxs.items.len);
    try std.testing.expectEqualStrings("idx_space_name_email", idxs.items[0].name);

    // A name that is simply absent is still "no columns", not a refusal.
    var absent = try getExistingColumns(std.testing.allocator, drv.asDriver(), "no such table here");
    defer freeExistingColumns(std.testing.allocator, &absent);
    try std.testing.expectEqual(@as(usize, 0), absent.items.len);

    var fks = try getExistingForeignKeys(std.testing.allocator, drv.asDriver(), "space name");
    defer freeExistingForeignKeys(std.testing.allocator, &fks);
    try std.testing.expectEqual(@as(usize, 0), fks.items.len);
}

test "getExistingIndexes reports key columns in order (SQLite)" {
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE ix_item (id INTEGER PRIMARY KEY, tenant TEXT, email TEXT, body TEXT)", &.{});
    _ = try drv.exec("CREATE UNIQUE INDEX idx_ix_item_tenant_email ON ix_item (tenant, email)", &.{});
    _ = try drv.exec("CREATE INDEX idx_ix_item_body ON ix_item (body)", &.{});
    // Neither of these can be compared: an expression key has no column name,
    // and a partial index has a WHERE the schema cannot express.
    _ = try drv.exec("CREATE INDEX idx_ix_item_lower ON ix_item (lower(email))", &.{});
    _ = try drv.exec("CREATE INDEX idx_ix_item_partial ON ix_item (email) WHERE email IS NOT NULL", &.{});

    var indexes = try getExistingIndexes(std.testing.allocator, drv.asDriver(), "ix_item");
    defer freeExistingIndexes(std.testing.allocator, &indexes);

    // Key order is the index's, not the table's.
    const composite = getExistingIndexByName(indexes.items, "idx_ix_item_tenant_email").?;
    try std.testing.expect(composite.unique);
    try std.testing.expect(composite.columns_comparable);
    try std.testing.expectEqual(@as(usize, 2), composite.columns.len);
    try std.testing.expectEqualStrings("tenant", composite.columns[0]);
    try std.testing.expectEqualStrings("email", composite.columns[1]);

    const single = getExistingIndexByName(indexes.items, "idx_ix_item_body").?;
    try std.testing.expect(!single.unique);
    try std.testing.expect(single.columns_comparable);
    try std.testing.expectEqualStrings("body", single.columns[0]);

    try std.testing.expect(!getExistingIndexByName(indexes.items, "idx_ix_item_lower").?.columns_comparable);
    try std.testing.expect(!getExistingIndexByName(indexes.items, "idx_ix_item_partial").?.columns_comparable);

    // A table with no indexes, and a table that does not exist.
    _ = try drv.exec("CREATE TABLE ix_bare (id INTEGER PRIMARY KEY)", &.{});
    var none = try getExistingIndexes(std.testing.allocator, drv.asDriver(), "ix_bare");
    defer freeExistingIndexes(std.testing.allocator, &none);
    try std.testing.expectEqual(@as(usize, 0), none.items.len);

    var missing = try getExistingIndexes(std.testing.allocator, drv.asDriver(), "ix_absent");
    defer freeExistingIndexes(std.testing.allocator, &missing);
    try std.testing.expectEqual(@as(usize, 0), missing.items.len);
}

test "checkSchema reports index column drift and read_breaking_only ignores it (SQLite)" {
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const index = @import("../../core/index.zig");
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    // The database has the index by name, but built over one column of the two
    // the schema declares. NOT NULL on both columns so that the only difference
    // left is the index.
    _ = try drv.exec(
        "CREATE TABLE drift_item (id INTEGER PRIMARY KEY AUTOINCREMENT, tenant TEXT NOT NULL, email TEXT NOT NULL)",
        &.{},
    );
    _ = try drv.exec("CREATE INDEX idx_drift_item_tenant_email ON drift_item (tenant)", &.{});

    const DriftItem = schema("DriftItem", .{
        .fields = &.{ field.String("tenant"), field.String("email") },
        .indexes = &.{index.Named("idx_drift_item_tenant_email", &.{ "tenant", "email" })},
    });
    const info = comptime fromSchema(DriftItem);
    const infos = &[_]TypeInfo{info};

    const drifts = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
    defer freeSchemaDrift(std.testing.allocator, drifts);

    var index_drift: ?SchemaDrift = null;
    for (drifts) |d| {
        if (d.kind == .index_columns) index_drift = d;
    }
    try std.testing.expect(index_drift != null);
    try std.testing.expectEqualStrings("idx_drift_item_tenant_email", index_drift.?.index_name);
    try std.testing.expectEqualStrings("", index_drift.?.column);
    try std.testing.expect(std.mem.indexOf(u8, index_drift.?.index_detail, "schema wants (tenant, email), database has (tenant)") != null);
    // The drift is a difference in *how* a query runs, so the read-breaking
    // gate must not fail on it …
    try std.testing.expect(!index_drift.?.breaksReads());
    try assertSchema(std.testing.allocator, drv.asDriver(), infos, .read_breaking_only);
    // … while "everything must agree" is exactly the mode that does.
    try std.testing.expectError(error.SchemaDrift, assertSchema(std.testing.allocator, drv.asDriver(), infos, .any));
}

test "checkSchema stays silent about indexes it cannot compare (SQLite)" {
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const index = @import("../../core/index.zig");
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec(
        "CREATE TABLE quiet_item (id INTEGER PRIMARY KEY AUTOINCREMENT, tenant TEXT NOT NULL, email TEXT NOT NULL)",
        &.{},
    );
    // Same columns, same order: no drift at all.
    _ = try drv.exec("CREATE INDEX idx_quiet_item_tenant_email ON quiet_item (tenant, email)", &.{});

    const QuietItem = schema("QuietItem", .{
        .fields = &.{ field.String("tenant"), field.String("email") },
        .indexes = &.{index.Named("idx_quiet_item_tenant_email", &.{ "tenant", "email" })},
    });
    const info = comptime fromSchema(QuietItem);
    const infos = &[_]TypeInfo{info};

    const drifts = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
    defer freeSchemaDrift(std.testing.allocator, drifts);
    try std.testing.expectEqual(@as(usize, 0), drifts.len);

    // Order matters for an index, so the same columns in the other order are a
    // different key list.
    _ = try drv.exec("DROP INDEX idx_quiet_item_tenant_email", &.{});
    _ = try drv.exec("CREATE INDEX idx_quiet_item_tenant_email ON quiet_item (email, tenant)", &.{});

    const reordered = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
    defer freeSchemaDrift(std.testing.allocator, reordered);
    try std.testing.expectEqual(@as(usize, 1), reordered.len);
    try std.testing.expectEqual(SchemaDrift.Kind.index_columns, reordered[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, reordered[0].index_detail, "schema wants (tenant, email), database has (email, tenant)") != null);

    // The identical *name* over an expression key is not a difference the
    // declaration can be compared against: skip it, do not report a guess.
    _ = try drv.exec("DROP INDEX idx_quiet_item_tenant_email", &.{});
    _ = try drv.exec("CREATE INDEX idx_quiet_item_tenant_email ON quiet_item (lower(tenant), email)", &.{});

    const unreadable = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
    defer freeSchemaDrift(std.testing.allocator, unreadable);
    try std.testing.expectEqual(@as(usize, 0), unreadable.len);
}

test "checkSchema reports an index whose uniqueness differs (SQLite)" {
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const index = @import("../../core/index.zig");
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    // Two indexes the schema and the database agree about by name and by key
    // list, and disagree about in the only way that lets duplicate rows in.
    _ = try drv.exec(
        "CREATE TABLE unique_item (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT NOT NULL, tenant TEXT NOT NULL)",
        &.{},
    );
    _ = try drv.exec("CREATE INDEX idx_unique_item_email ON unique_item (email)", &.{});
    _ = try drv.exec("CREATE UNIQUE INDEX idx_unique_item_tenant ON unique_item (tenant)", &.{});

    const UniqueItem = schema("UniqueItem", .{
        .fields = &.{ field.String("email"), field.String("tenant") },
        .indexes = &.{
            index.Named("idx_unique_item_email", &.{"email"}).Unique(),
            index.Named("idx_unique_item_tenant", &.{"tenant"}),
        },
    });
    const info = comptime fromSchema(UniqueItem);
    const infos = &[_]TypeInfo{info};

    {
        const drifts = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, drifts);

        // Both directions, and nothing else: the key lists match, so the only
        // difference left is the one that matters.
        try std.testing.expectEqual(@as(usize, 2), drifts.len);

        var missing_unique: ?SchemaDrift = null;
        var unexpected_unique: ?SchemaDrift = null;
        for (drifts) |d| {
            try std.testing.expectEqual(SchemaDrift.Kind.index_uniqueness, d.kind);
            try std.testing.expectEqualStrings("unique_item", d.table);
            try std.testing.expectEqualStrings("", d.column);
            // A read returns what it always returned; it is a *write* that the
            // constraint would have rejected and now does not.
            try std.testing.expect(!d.breaksReads());
            if (std.mem.eql(u8, d.index_name, "idx_unique_item_email")) {
                missing_unique = d;
            } else if (std.mem.eql(u8, d.index_name, "idx_unique_item_tenant")) {
                unexpected_unique = d;
            }
        }
        try std.testing.expect(missing_unique != null);
        try std.testing.expectEqualStrings(
            "schema declares UNIQUE, database index is not unique",
            missing_unique.?.index_detail,
        );
        try std.testing.expect(unexpected_unique != null);
        try std.testing.expectEqualStrings(
            "schema declares a non-unique index, database index is UNIQUE",
            unexpected_unique.?.index_detail,
        );

        // The gate: a uniqueness difference is not a broken read, so the mode
        // that exists to stop a deploy that would break reads must not fail …
        try assertSchema(std.testing.allocator, drv.asDriver(), infos, .read_breaking_only);
        // … while "everything must agree" is exactly the mode that does.
        try std.testing.expectError(error.SchemaDrift, assertSchema(std.testing.allocator, drv.asDriver(), infos, .any));
    }

    // Rebuild both indexes with the uniqueness the schema declares: same names,
    // same key lists, now the same constraint — and silence.
    _ = try drv.exec("DROP INDEX idx_unique_item_email", &.{});
    _ = try drv.exec("DROP INDEX idx_unique_item_tenant", &.{});
    _ = try drv.exec("CREATE UNIQUE INDEX idx_unique_item_email ON unique_item (email)", &.{});
    _ = try drv.exec("CREATE INDEX idx_unique_item_tenant ON unique_item (tenant)", &.{});

    const agreeing = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
    defer freeSchemaDrift(std.testing.allocator, agreeing);
    try std.testing.expectEqual(@as(usize, 0), agreeing.len);
}

test "checkSchema reports uniqueness drift on an index it cannot compare by key (SQLite)" {
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const index = @import("../../core/index.zig");
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec(
        "CREATE TABLE expr_item (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT NOT NULL)",
        &.{},
    );
    // An expression key: `columns_comparable` is false, so the key list is not
    // compared — but `PRAGMA index_list` still answers `unique`, and that
    // answer is what says the application's constraint is not there.
    _ = try drv.exec("CREATE UNIQUE INDEX idx_expr_item_email ON expr_item (lower(email))", &.{});

    const ExprItem = schema("ExprItem", .{
        .fields = &.{field.String("email")},
        .indexes = &.{index.Named("idx_expr_item_email", &.{"email"})},
    });
    const info = comptime fromSchema(ExprItem);
    const infos = &[_]TypeInfo{info};

    const drifts = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
    defer freeSchemaDrift(std.testing.allocator, drifts);

    // Exactly one, and it is the uniqueness one: the two conditions are
    // separate on purpose, so the unreadable key list must not suppress it —
    // and the uniqueness difference must not produce an `index_columns` report
    // either.
    try std.testing.expectEqual(@as(usize, 1), drifts.len);
    try std.testing.expectEqual(SchemaDrift.Kind.index_uniqueness, drifts[0].kind);
    try std.testing.expectEqualStrings("idx_expr_item_email", drifts[0].index_name);
    try std.testing.expectEqualStrings(
        "schema declares a non-unique index, database index is UNIQUE",
        drifts[0].index_detail,
    );
    try std.testing.expect(!drifts[0].breaksReads());
    try assertSchema(std.testing.allocator, drv.asDriver(), infos, .read_breaking_only);
    try std.testing.expectError(error.SchemaDrift, assertSchema(std.testing.allocator, drv.asDriver(), infos, .any));
}

test "getExistingForeignKeys reads local and referenced columns in order (SQLite)" {
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE fk_parent (id INTEGER PRIMARY KEY, code TEXT UNIQUE)", &.{});
    _ = try drv.exec(
        \\CREATE TABLE fk_child (
        \\  id INTEGER PRIMARY KEY,
        \\  a_id INTEGER,
        \\  b_id INTEGER,
        \\  FOREIGN KEY (a_id) REFERENCES fk_parent (id),
        \\  FOREIGN KEY (b_id) REFERENCES fk_parent (code)
        \\)
    , &.{});
    // `REFERENCES t` with no column list: SQLite records the constraint and
    // reports no target column at all, so the shape is unreadable rather than
    // empty.
    _ = try drv.exec("CREATE TABLE fk_implicit (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES fk_parent)", &.{});

    var keys = try getExistingForeignKeys(std.testing.allocator, drv.asDriver(), "fk_child");
    defer freeExistingForeignKeys(std.testing.allocator, &keys);

    // `PRAGMA foreign_key_list` emits the constraints in its own order (not the
    // declaration's), so the entries are found by shape here.
    try std.testing.expectEqual(@as(usize, 2), keys.items.len);
    var saw_a = false;
    var saw_b = false;
    for (keys.items) |fk| {
        try std.testing.expectEqualStrings("fk_parent", fk.ref_table);
        try std.testing.expectEqual(@as(usize, 1), fk.columns.len);
        try std.testing.expect(fk.ref_columns_comparable);
        try std.testing.expectEqual(@as(usize, 1), fk.ref_columns.len);
        if (std.mem.eql(u8, fk.columns[0], "a_id")) {
            saw_a = true;
            try std.testing.expectEqualStrings("id", fk.ref_columns[0]);
        } else if (std.mem.eql(u8, fk.columns[0], "b_id")) {
            saw_b = true;
            try std.testing.expectEqualStrings("code", fk.ref_columns[0]);
        }
    }
    try std.testing.expect(saw_a and saw_b);

    var implicit = try getExistingForeignKeys(std.testing.allocator, drv.asDriver(), "fk_implicit");
    defer freeExistingForeignKeys(std.testing.allocator, &implicit);
    try std.testing.expectEqual(@as(usize, 1), implicit.items.len);
    try std.testing.expectEqualStrings("fk_parent", implicit.items[0].ref_table);
    try std.testing.expectEqualStrings("parent_id", implicit.items[0].columns[0]);
    try std.testing.expect(!implicit.items[0].ref_columns_comparable);
    try std.testing.expectEqual(@as(usize, 0), implicit.items[0].ref_columns.len);

    // A table with none, and a table that does not exist: the same empty answer,
    // which is why `checkSchema` asks this only once it knows the table is there.
    _ = try drv.exec("CREATE TABLE fk_bare (id INTEGER PRIMARY KEY, body TEXT)", &.{});
    var none = try getExistingForeignKeys(std.testing.allocator, drv.asDriver(), "fk_bare");
    defer freeExistingForeignKeys(std.testing.allocator, &none);
    try std.testing.expectEqual(@as(usize, 0), none.items.len);

    var missing = try getExistingForeignKeys(std.testing.allocator, drv.asDriver(), "fk_absent");
    defer freeExistingForeignKeys(std.testing.allocator, &missing);
    try std.testing.expectEqual(@as(usize, 0), missing.items.len);
}

test "checkSchema reports a declared foreign key the database does not have (SQLite)" {
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const edge = @import("../../core/edge.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const buildGraph = @import("../../codegen/graph.zig").buildGraph;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    const FkOwner = schema("FkOwner", .{ .fields = &.{field.String("name")} });
    const FkCar = schema("FkCar", .{
        .fields = &.{field.String("model")},
        .edges = &.{edge.From("owner", FkOwner)},
    });
    // Both ends in the graph: a key whose target is *out* of it is not declared
    // at all any more (there is no table name to reference — see
    // `tableFromTypeInfoCrossRef`), so the report this test is about only exists
    // for a resolvable target.
    const infos = comptime buildGraph(&.{ FkOwner, FkCar }).types;

    // The legacy pair: the column the edge generated is there, the constraint
    // is not. This is the shape a table created before the edge existed has, and
    // `migrateSchema` will never add the constraint to it.
    _ = try drv.exec(
        "CREATE TABLE fk_owner (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)",
        &.{},
    );
    _ = try drv.exec(
        "CREATE TABLE fk_car (id INTEGER PRIMARY KEY AUTOINCREMENT, model TEXT NOT NULL, owner_id INTEGER)",
        &.{},
    );

    {
        const drifts = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, drifts);

        // Nothing else about the table differs, so this is the whole report.
        try std.testing.expectEqual(@as(usize, 1), drifts.len);
        try std.testing.expectEqual(SchemaDrift.Kind.missing_foreign_key, drifts[0].kind);
        try std.testing.expectEqualStrings("fk_car", drifts[0].table);
        try std.testing.expectEqualStrings("owner_id", drifts[0].column);
        try std.testing.expectEqualStrings(
            "schema declares FOREIGN KEY (owner_id) REFERENCES fk_owner (id), database has none",
            drifts[0].index_detail,
        );
        // `assertSchema` prints the column *and* this sentence: a table can carry
        // several foreign keys, and "one is missing" does not say which.
        try std.testing.expect(!drifts[0].breaksReads());
        try assertSchema(std.testing.allocator, drv.asDriver(), infos, .read_breaking_only);
        try std.testing.expectError(error.SchemaDrift, assertSchema(std.testing.allocator, drv.asDriver(), infos, .any));
    }

    // Rebuild the table with the constraint — under a name SQLite invents, which
    // is the whole point: the comparison is by shape, so the name is irrelevant.
    _ = try drv.exec("DROP TABLE fk_car", &.{});
    _ = try drv.exec(
        "CREATE TABLE fk_car (id INTEGER PRIMARY KEY AUTOINCREMENT, model TEXT NOT NULL, owner_id INTEGER, FOREIGN KEY (owner_id) REFERENCES fk_owner (id))",
        &.{},
    );

    const agreeing = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
    defer freeSchemaDrift(std.testing.allocator, agreeing);
    try std.testing.expectEqual(@as(usize, 0), agreeing.len);

    // A constraint the database has and the schema does not is **not** drift:
    // it can only reject writes the schema never promised, so a table somebody
    // hardened by hand must not turn the deploy red.
    _ = try drv.exec("DROP TABLE fk_car", &.{});
    _ = try drv.exec(
        "CREATE TABLE fk_car (id INTEGER PRIMARY KEY AUTOINCREMENT, model TEXT NOT NULL, owner_id INTEGER, FOREIGN KEY (owner_id) REFERENCES fk_owner (id), FOREIGN KEY (model) REFERENCES fk_owner (name))",
        &.{},
    );

    const extra = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
    defer freeSchemaDrift(std.testing.allocator, extra);
    try std.testing.expectEqual(@as(usize, 0), extra.len);
}

test "foreignKeyPresent compares by shape, not by name or position (SQLite)" {
    // The comparison itself, without a database: a constraint that matches on
    // the local columns, the target table and the target columns is present even
    // though nothing records a name, and one that disagrees on any of the three
    // is not.
    const declared = ForeignKeyDef{
        .columns = &[_][]const u8{"user_id"},
        .ref_table = "app_user",
        .ref_columns = &[_][]const u8{"id"},
    };

    const matching = [_]ExistingForeignKey{.{
        .columns = &[_][]const u8{"user_id"},
        .ref_table = "app_user",
        .ref_columns = &[_][]const u8{"id"},
    }};
    try std.testing.expect(foreignKeyPresent(&matching, declared));

    // Unquoted DDL reaches PostgreSQL as lower case and SQLite/MySQL compare
    // table names case-insensitively, so a case difference is not a shape
    // difference. Column names stay exact.
    const other_case = [_]ExistingForeignKey{.{
        .columns = &[_][]const u8{"user_id"},
        .ref_table = "APP_USER",
        .ref_columns = &[_][]const u8{"id"},
    }};
    try std.testing.expect(foreignKeyPresent(&other_case, declared));

    // `REFERENCES app_user` with no column list: unreadable, not wrong.
    const unreadable = [_]ExistingForeignKey{.{
        .columns = &[_][]const u8{"user_id"},
        .ref_table = "app_user",
        .ref_columns = &.{},
        .ref_columns_comparable = false,
    }};
    try std.testing.expect(foreignKeyPresent(&unreadable, declared));

    // A different target column is a different constraint …
    const wrong_ref = [_]ExistingForeignKey{.{
        .columns = &[_][]const u8{"user_id"},
        .ref_table = "app_user",
        .ref_columns = &[_][]const u8{"code"},
    }};
    try std.testing.expect(!foreignKeyPresent(&wrong_ref, declared));

    // … and so is a different target table, or a different local column list.
    const wrong_table = [_]ExistingForeignKey{.{
        .columns = &[_][]const u8{"user_id"},
        .ref_table = "other_user",
        .ref_columns = &[_][]const u8{"id"},
    }};
    try std.testing.expect(!foreignKeyPresent(&wrong_table, declared));

    const wrong_local = [_]ExistingForeignKey{.{
        .columns = &[_][]const u8{"other_id"},
        .ref_table = "app_user",
        .ref_columns = &[_][]const u8{"id"},
    }};
    try std.testing.expect(!foreignKeyPresent(&wrong_local, declared));

    // No constraint at all: the drift.
    try std.testing.expect(!foreignKeyPresent(&[_]ExistingForeignKey{}, declared));
}

test "uniqueColumnChecked exempts only a primary key's own uniqueness" {
    const single = TableDef{
        .name = "t",
        .columns = &.{.{ .name = "id", .sql_type = "INTEGER", .primary_key = true, .unique = true }},
        .primary_keys = &.{"id"},
    };
    try std.testing.expect(!uniqueColumnChecked(single.columns[0], single));

    // One part of a composite key is not unique on its own, so a `UNIQUE` on it
    // is still a declaration that needs something enforcing it.
    const composite = TableDef{
        .name = "t",
        .columns = &.{.{ .name = "a", .sql_type = "INTEGER", .primary_key = true, .unique = true }},
        .primary_keys = &.{ "a", "b" },
    };
    try std.testing.expect(uniqueColumnChecked(composite.columns[0], composite));

    const plain = TableDef{
        .name = "t",
        .columns = &.{.{ .name = "email", .sql_type = "TEXT", .unique = true }},
        .primary_keys = &.{"id"},
    };
    try std.testing.expect(uniqueColumnChecked(plain.columns[0], plain));

    const not_unique = TableDef{
        .name = "t",
        .columns = &.{.{ .name = "email", .sql_type = "TEXT" }},
        .primary_keys = &.{"id"},
    };
    try std.testing.expect(!uniqueColumnChecked(not_unique.columns[0], not_unique));

    try std.testing.expect(wantsUniqueColumnCheck(plain));
    try std.testing.expect(!wantsUniqueColumnCheck(not_unique));
    try std.testing.expect(!wantsUniqueColumnCheck(single));
}

test "checkSchema reports a UNIQUE column nothing forces, and only then (SQLite)" {
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    // No declared index at all: the `UNIQUE` is inlined into `CREATE TABLE` and
    // is invisible to the index comparison, which is exactly the gap.
    _ = try drv.exec(
        "CREATE TABLE uq_item (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT NOT NULL, tenant TEXT NOT NULL)",
        &.{},
    );

    const UqItem = schema("UqItem", .{
        .fields = &.{ field.String("email").Unique(), field.String("tenant") },
    });
    const info = comptime fromSchema(UqItem);
    const infos = &[_]TypeInfo{info};

    {
        const drifts = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, drifts);

        try std.testing.expectEqual(@as(usize, 1), drifts.len);
        try std.testing.expectEqual(SchemaDrift.Kind.unique_constraint, drifts[0].kind);
        try std.testing.expectEqualStrings("uq_item", drifts[0].table);
        try std.testing.expectEqualStrings("email", drifts[0].column);
        try std.testing.expectEqualStrings(
            "schema declares the column UNIQUE, database has no unique constraint covering it",
            drifts[0].index_detail,
        );
        // The detail is a literal, not an allocation: freeing the report must
        // leave it alone (a double free here would show up as a leak check
        // failure on the freeing allocator, not as a test assertion).
        try std.testing.expect(!ownsIndexDetail(drifts[0].kind));
        // A duplicate row is a *write* the database accepts, not a broken read.
        try std.testing.expect(!drifts[0].breaksReads());
        try assertSchema(std.testing.allocator, drv.asDriver(), infos, .read_breaking_only);
        try std.testing.expectError(error.SchemaDrift, assertSchema(std.testing.allocator, drv.asDriver(), infos, .any));
    }

    // A unique index over exactly that column satisfies it — whatever the
    // database chose to call it.
    _ = try drv.exec("CREATE UNIQUE INDEX idx_uq_item_email ON uq_item (email)", &.{});
    {
        const satisfied = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, satisfied);
        try std.testing.expectEqual(@as(usize, 0), satisfied.len);
    }

    // A **composite** unique index does not: `UNIQUE (tenant, email)` still
    // permits two rows with the same `email`.
    _ = try drv.exec("DROP INDEX idx_uq_item_email", &.{});
    _ = try drv.exec("CREATE UNIQUE INDEX idx_uq_item_tenant_email ON uq_item (tenant, email)", &.{});
    {
        const composite = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, composite);
        try std.testing.expectEqual(@as(usize, 1), composite.len);
        try std.testing.expectEqual(SchemaDrift.Kind.unique_constraint, composite[0].kind);
        try std.testing.expectEqualStrings("email", composite[0].column);
    }

    // A non-unique index over it forces nothing either.
    _ = try drv.exec("DROP INDEX idx_uq_item_tenant_email", &.{});
    _ = try drv.exec("CREATE INDEX idx_uq_item_email ON uq_item (email)", &.{});
    {
        const non_unique = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, non_unique);
        try std.testing.expectEqual(@as(usize, 1), non_unique.len);
        try std.testing.expectEqual(SchemaDrift.Kind.unique_constraint, non_unique[0].kind);
    }

    // A column of the database's own primary key is unique by construction, so
    // the declaration on it needs nothing else — SQLite gives `INTEGER PRIMARY
    // KEY` no entry in `PRAGMA index_list` at all, which is why the exemption
    // has to come from the declaration rather than from an index.
    _ = try drv.exec("CREATE TABLE uq_pk (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT NOT NULL)", &.{});
    const UqPk = schema("UqPk", .{ .fields = &.{ field.Int("id").Unique(), field.String("body") } });
    const pk_info = comptime fromSchema(UqPk);
    const pk_infos = &[_]TypeInfo{pk_info};
    const pk_drifts = try checkSchema(std.testing.allocator, drv.asDriver(), pk_infos);
    defer freeSchemaDrift(std.testing.allocator, pk_drifts);
    try std.testing.expectEqual(@as(usize, 0), pk_drifts.len);
}

test "checkSchema stays silent about a UNIQUE column a unique index it cannot read may force (SQLite)" {
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec(
        "CREATE TABLE uq_expr_item (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT NOT NULL)",
        &.{},
    );
    // `lower(email)` is a unique constraint on the column that the key list
    // cannot describe, so "is this column constrained?" has no answer — and a
    // report would be a guess that blocks a deploy.
    _ = try drv.exec("CREATE UNIQUE INDEX idx_uq_expr_item_email ON uq_expr_item (lower(email))", &.{});

    const UqExprItem = schema("UqExprItem", .{ .fields = &.{field.String("email").Unique()} });
    const info = comptime fromSchema(UqExprItem);
    const infos = &[_]TypeInfo{info};

    const drifts = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
    defer freeSchemaDrift(std.testing.allocator, drifts);
    try std.testing.expectEqual(@as(usize, 0), drifts.len);
    try assertSchema(std.testing.allocator, drv.asDriver(), infos, .any);
}

test "checkSchema still reports a UNIQUE column when the unreadable index is not unique (SQLite)" {
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec(
        "CREATE TABLE uq_plain_item (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT NOT NULL)",
        &.{},
    );
    // Unreadable, but not unique: whatever it covers, it enforces no
    // uniqueness, so it cannot stand in the way of the answer. Only an
    // unreadable *unique* index makes the question unanswerable.
    _ = try drv.exec("CREATE INDEX idx_uq_plain_item_email ON uq_plain_item (lower(email))", &.{});

    const UqPlainItem = schema("UqPlainItem", .{ .fields = &.{field.String("email").Unique()} });
    const info = comptime fromSchema(UqPlainItem);
    const infos = &[_]TypeInfo{info};

    const drifts = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
    defer freeSchemaDrift(std.testing.allocator, drifts);
    try std.testing.expectEqual(@as(usize, 1), drifts.len);
    try std.testing.expectEqual(SchemaDrift.Kind.unique_constraint, drifts[0].kind);
    try std.testing.expectEqualStrings("email", drifts[0].column);
    try assertSchema(std.testing.allocator, drv.asDriver(), infos, .read_breaking_only);
    try std.testing.expectError(error.SchemaDrift, assertSchema(std.testing.allocator, drv.asDriver(), infos, .any));
}

test "checkSchema reports a view the database does not have, and read_breaking_only stops it (SQLite)" {
    // A view entity was the one declared shape `checkSchema` never looked at
    // (the entity loop skipped `is_view` outright), so a view that was never
    // created — or was dropped out of band — produced a green check while
    // `SELECT … FROM it` errored. That is a *broken read*, not a missed
    // optimisation, and this pins the difference.
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE vw_base_row (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)", &.{});

    const VwActiveRow = schema("VwActiveRow", .{
        .view = true,
        .view_sql = "SELECT id, name FROM vw_base_row",
        .fields = &.{field.String("name")},
    });
    const info = comptime fromSchema(VwActiveRow);
    const infos = &[_]TypeInfo{info};

    // Never created: one report, and it is the relation that is missing.
    {
        const drifts = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, drifts);
        try std.testing.expectEqual(@as(usize, 1), drifts.len);
        try std.testing.expectEqual(SchemaDrift.Kind.missing_view, drifts[0].kind);
        try std.testing.expectEqualStrings("vw_active_row", drifts[0].table);
        try std.testing.expectEqualStrings("", drifts[0].column);
        try std.testing.expectEqualStrings(missingViewDriftDetail, drifts[0].index_detail);
        // The whole point of the kind: a missing view breaks reads, so the gate
        // that exists to stop such a deploy has to fail on it.
        try std.testing.expect(drifts[0].breaksReads());
        try std.testing.expectError(error.SchemaDrift, assertSchema(std.testing.allocator, drv.asDriver(), infos, .read_breaking_only));
        try std.testing.expectError(error.SchemaDrift, assertSchema(std.testing.allocator, drv.asDriver(), infos, .any));
    }

    // Created in the shape `migrateSchema` builds: silence. This also pins that
    // the existence probe reads a *view* — a check that only understood tables
    // would report every view here.
    _ = try drv.exec("CREATE VIEW IF NOT EXISTS \"vw_active_row\" AS SELECT id, name FROM vw_base_row", &.{});
    {
        const drifts = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, drifts);
        try std.testing.expectEqual(@as(usize, 0), drifts.len);
        try assertSchema(std.testing.allocator, drv.asDriver(), infos, .any);
    }

    // A **changed definition is silence**: the view exists, and its SQL is not
    // compared (the database stores its own text, so comparing would report
    // every view in every database). A stale `view_sql` is invisible here, and
    // that is the documented boundary of this check.
    _ = try drv.exec("DROP VIEW vw_active_row", &.{});
    _ = try drv.exec("CREATE VIEW IF NOT EXISTS \"vw_active_row\" AS SELECT id, name FROM vw_base_row WHERE name <> ''", &.{});
    {
        const drifts = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, drifts);
        try std.testing.expectEqual(@as(usize, 0), drifts.len);
    }

    // Dropped out of band: reported again.
    _ = try drv.exec("DROP VIEW vw_active_row", &.{});
    {
        const drifts = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, drifts);
        try std.testing.expectEqual(@as(usize, 1), drifts.len);
        try std.testing.expectEqual(SchemaDrift.Kind.missing_view, drifts[0].kind);
    }

    // A *relation* of that name is what the check asks about, not a view
    // specifically: `PRAGMA table_info` reads a view's columns as readily as a
    // table's, so one probe answers both shapes and a name an existing table
    // already serves is not reported.
    _ = try drv.exec("CREATE TABLE vw_active_row (id INTEGER PRIMARY KEY, name TEXT NOT NULL)", &.{});
    {
        const drifts = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, drifts);
        try std.testing.expectEqual(@as(usize, 0), drifts.len);
    }
}

test "checkSchema reports a missing M2M junction table, and read_breaking_only stops it (SQLite)" {
    // The last declared shape the entity loop walked past: a junction table is
    // not a `TypeInfo`, so an M2M edge survived a green check while a query over
    // it failed with "no such table". Same silent class as `missing_view`, and
    // pinned the same way.
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const edge = @import("../../core/edge.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const buildGraph = @import("../../codegen/graph.zig").buildGraph;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    const JcMemberBase = schema("JcMember", .{ .fields = &.{field.String("name")} });
    const JcTagBase = schema("JcTag", .{ .fields = &.{field.String("label")} });
    const JcMember = struct {
        pub const schema_name = JcMemberBase.schema_name;
        pub const fields = JcMemberBase.fields;
        // Both sides declare the edge, which is what makes it M2M — and what
        // makes the junction table get reported once instead of twice.
        pub const edges = &.{edge.To("tags", JcTagBase)};
        pub const indexes = JcMemberBase.indexes;
    };
    const JcTag = struct {
        pub const schema_name = JcTagBase.schema_name;
        pub const fields = JcTagBase.fields;
        pub const edges = &.{edge.To("members", JcMemberBase)};
        pub const indexes = JcTagBase.indexes;
    };
    const graph = comptime buildGraph(&.{ JcMember, JcTag });
    const infos = graph.types;

    // Never migrated: the two entity tables and the junction table they need are
    // all absent, and each relation is reported on its own — the junction check
    // is not gated on the entity tables, exactly as the view check is not. A
    // whole-database first run therefore says "three relations are missing", not
    // two with a gap where the edge's table should be.
    {
        const drifts = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, drifts);
        try std.testing.expectEqual(@as(usize, 3), drifts.len);
        var missing_tables: usize = 0;
        var missing_junctions: usize = 0;
        for (drifts) |d| switch (d.kind) {
            .missing_table => missing_tables += 1,
            .missing_junction_table => missing_junctions += 1,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(@as(usize, 2), missing_tables);
        try std.testing.expectEqual(@as(usize, 1), missing_junctions);
        try std.testing.expectError(error.SchemaDrift, assertSchema(std.testing.allocator, drv.asDriver(), infos, .read_breaking_only));
    }

    // `migrateSchema` builds both entity tables and the junction table between
    // them, and the junction table's own primary key and foreign keys disturb
    // nothing else here: complete agreement. That is the other half of this
    // kind — it reports an absent relation, not the shape of a present one.
    try migrateSchema(std.testing.allocator, drv.asDriver(), infos);
    {
        const agreeing = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, agreeing);
        try std.testing.expectEqual(@as(usize, 0), agreeing.len);
        try assertSchema(std.testing.allocator, drv.asDriver(), infos, .any);
    }

    // Dropped out of band. One report, not two: both sides of the edge derive
    // the same junction table name.
    _ = try drv.exec("DROP TABLE jc_member_jc_tag", &.{});
    {
        const drifts = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, drifts);
        try std.testing.expectEqual(@as(usize, 1), drifts.len);
        try std.testing.expectEqual(SchemaDrift.Kind.missing_junction_table, drifts[0].kind);
        // `table` is the relation that is missing; the edge that needs it is in
        // the detail, spelled out in the same alphabetical order the junction
        // table's name uses, together with the columns a hand-created one needs.
        try std.testing.expectEqualStrings("jc_member_jc_tag", drifts[0].table);
        try std.testing.expectEqualStrings("", drifts[0].column);
        try std.testing.expectEqualStrings(
            "schema declares the M2M edge jc_member <-> jc_tag, database has no relation named jc_member_jc_tag " ++
                "(expected columns jc_member_id, jc_tag_id); migrateSchema creates it, and a relation of that name " ++
                "is then compared on its columns, pair uniqueness and foreign keys",
            drifts[0].index_detail,
        );
        // The detail is a comptime literal, not an allocation: freeing the
        // report must leave it alone (a double free would show up as a leak
        // check failure on the freeing allocator, not as an assertion).
        try std.testing.expect(!ownsIndexDetail(drifts[0].kind));
        // The relation query fails outright; that is the stake behind
        // `breaksReads`, and why the read-breaking gate has to catch it.
        try std.testing.expect(drifts[0].breaksReads());
        try std.testing.expectError(error.SqlitePrepareFailed, drv.query("SELECT jc_member_id, jc_tag_id FROM jc_member_jc_tag", &.{}));
        try std.testing.expectError(error.SchemaDrift, assertSchema(std.testing.allocator, drv.asDriver(), infos, .read_breaking_only));
        try std.testing.expectError(error.SchemaDrift, assertSchema(std.testing.allocator, drv.asDriver(), infos, .any));
    }

    // A relation that *is* there never reaches this kind — what it is compared
    // on instead is the subject of the test below.

    // `migrateSchema` heals it: the recorded `create_junction` version is
    // present but the relation is gone, so the junction table is re-created —
    // the out-of-band-drop path it already has for tables and views.
    try migrateSchema(std.testing.allocator, drv.asDriver(), infos);
    const healed = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
    defer freeSchemaDrift(std.testing.allocator, healed);
    try std.testing.expectEqual(@as(usize, 0), healed.len);

    var junction = try getExistingColumns(std.testing.allocator, drv.asDriver(), "jc_member_jc_tag");
    defer freeExistingColumns(std.testing.allocator, &junction);
    try std.testing.expectEqual(@as(usize, 2), junction.items.len);
    try std.testing.expectEqualStrings("jc_member_id", junction.items[0].name);
    try std.testing.expectEqualStrings("jc_tag_id", junction.items[1].name);
}

test "indexForcesPairAlone asks about the pair, in either order" {
    const pair = ExistingIndex{ .name = "i", .unique = true, .columns = &.{ "a", "b" }, .columns_comparable = true };
    try std.testing.expect(indexForcesPairAlone(&.{pair}, "a", "b"));
    // `UNIQUE (b, a)` rejects the same duplicate pairs, so reading the reversed
    // key list as a difference would report a constraint the database does
    // enforce — the false report that blocks a deploy.
    try std.testing.expect(indexForcesPairAlone(&.{pair}, "b", "a"));

    // Wider is not the same question: two rows may share `(a, b)` as soon as `c`
    // differs, which is not the key a junction is built on.
    const wider = ExistingIndex{ .name = "i", .unique = true, .columns = &.{ "a", "b", "c" }, .columns_comparable = true };
    try std.testing.expect(!indexForcesPairAlone(&.{wider}, "a", "b"));
    // Narrower neither: one column of the pair is not the pair.
    const single = ExistingIndex{ .name = "i", .unique = true, .columns = &.{"a"}, .columns_comparable = true };
    try std.testing.expect(!indexForcesPairAlone(&.{single}, "a", "b"));
    // A non-unique index forces nothing, and an unreadable one is not an answer
    // at all (the caller skips the report while one is present).
    const not_unique = ExistingIndex{ .name = "i", .unique = false, .columns = &.{ "a", "b" }, .columns_comparable = true };
    try std.testing.expect(!indexForcesPairAlone(&.{not_unique}, "a", "b"));
    const unreadable = ExistingIndex{ .name = "i", .unique = true, .columns = &.{}, .columns_comparable = false };
    try std.testing.expect(!indexForcesPairAlone(&.{unreadable}, "a", "b"));
    try std.testing.expect(hasUnreadableUniqueIndex(&.{unreadable}));
}

test "checkSchema compares a present M2M junction table's shape (SQLite)" {
    // `missing_junction_table` answers "is the relation there"; this pins what
    // happens when it *is*: the table is compared against the shape
    // `junctionTableForEdge` derives and `migrateSchema` creates — the two
    // columns, the pair's composite key, the two foreign keys — because a
    // junction of the right name with the wrong shape fails the relation query
    // (`no such column`) or accepts the same pair twice.
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const edge = @import("../../core/edge.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const buildGraph = @import("../../codegen/graph.zig").buildGraph;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    const JsMemberBase = schema("JsMember", .{ .fields = &.{field.String("name")} });
    const JsTagBase = schema("JsTag", .{ .fields = &.{field.String("label")} });
    const JsMember = struct {
        pub const schema_name = JsMemberBase.schema_name;
        pub const fields = JsMemberBase.fields;
        pub const edges = &.{edge.To("tags", JsTagBase)};
        pub const indexes = JsMemberBase.indexes;
    };
    const JsTag = struct {
        pub const schema_name = JsTagBase.schema_name;
        pub const fields = JsTagBase.fields;
        pub const edges = &.{edge.To("members", JsMemberBase)};
        pub const indexes = JsTagBase.indexes;
    };
    const graph = comptime buildGraph(&.{ JsMember, JsTag });
    const infos = graph.types;

    // Migrated: the junction table `migrateSchema` created is the reference
    // shape, and it has to stay silent on every gate — if its own primary key
    // and foreign keys did not satisfy these three checks, every consumer with
    // an M2M edge would see a false drift.
    try migrateSchema(std.testing.allocator, drv.asDriver(), infos);
    {
        const agreeing = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, agreeing);
        try std.testing.expectEqual(@as(usize, 0), agreeing.len);
        try assertSchema(std.testing.allocator, drv.asDriver(), infos, .any);
    }

    // A table of the right name with neither the columns nor the keys: two
    // missing columns the relation query would fail on, the pair nothing forces
    // unique, and the two foreign keys that are not there.
    _ = try drv.exec("DROP TABLE js_member_js_tag", &.{});
    _ = try drv.exec("CREATE TABLE js_member_js_tag (id INTEGER PRIMARY KEY)", &.{});
    {
        const drifts = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, drifts);
        try std.testing.expectEqual(@as(usize, 5), drifts.len);

        var missing_columns: usize = 0;
        var pair_uniqueness: usize = 0;
        var missing_fks: usize = 0;
        for (drifts) |d| {
            try std.testing.expectEqualStrings("js_member_js_tag", d.table);
            switch (d.kind) {
                .missing_column => {
                    missing_columns += 1;
                    // The relation query names this column, so the read fails
                    // outright — the `missing_column` half of the junction.
                    try std.testing.expect(d.breaksReads());
                    try std.testing.expectEqualStrings("INTEGER", d.schema_type);
                    // The column is not a `field` anywhere in the schema, so the
                    // report has to say which edge put the expectation there.
                    const prefix = "schema declares the M2M edge js_member <-> js_tag, which joins through " ++
                        "js_member_js_tag (expected columns js_member_id, js_tag_id); the relation query names ";
                    try std.testing.expect(std.mem.startsWith(u8, d.index_detail, prefix));
                    try std.testing.expectEqualStrings(d.column, d.index_detail[prefix.len..]);
                    try std.testing.expect(
                        std.mem.eql(u8, d.column, "js_member_id") or std.mem.eql(u8, d.column, "js_tag_id"),
                    );
                },
                .junction_pair_uniqueness => {
                    pair_uniqueness += 1;
                    try std.testing.expectEqualStrings("", d.column);
                    // A write constraint, not a broken read: the queries still run.
                    try std.testing.expect(!d.breaksReads());
                    try std.testing.expectEqualStrings(
                        "schema declares the M2M edge js_member <-> js_tag, which joins through js_member_js_tag " ++
                            "(expected columns js_member_id, js_tag_id), whose primary key is that pair; the database " ++
                            "has no unique constraint over the two columns, so a duplicate pair is accepted and the " ++
                            "relation query then returns the same neighbour twice",
                        d.index_detail,
                    );
                },
                .missing_foreign_key => {
                    missing_fks += 1;
                    try std.testing.expect(!d.breaksReads());
                    try std.testing.expect(std.mem.indexOf(u8, d.index_detail, "database has none") != null);
                },
                else => return error.TestUnexpectedResult,
            }
        }
        try std.testing.expectEqual(@as(usize, 2), missing_columns);
        try std.testing.expectEqual(@as(usize, 1), pair_uniqueness);
        try std.testing.expectEqual(@as(usize, 2), missing_fks);

        // The whole point of the split: only the missing columns may block a
        // deploy, and they do.
        try std.testing.expectError(error.SchemaDrift, assertSchema(std.testing.allocator, drv.asDriver(), infos, .read_breaking_only));
        try std.testing.expectError(error.SchemaDrift, assertSchema(std.testing.allocator, drv.asDriver(), infos, .any));
    }

    // The columns are there but nothing keys the pair and nothing points it at
    // the two entity tables. Every query over the edge runs, so the
    // read-breaking gate passes — and `.any` still reports what a hand-fix has
    // to cover.
    _ = try drv.exec("DROP TABLE js_member_js_tag", &.{});
    _ = try drv.exec("CREATE TABLE js_member_js_tag (js_member_id INTEGER NOT NULL, js_tag_id INTEGER NOT NULL, created_at INTEGER)", &.{});
    {
        const drifts = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, drifts);
        try std.testing.expectEqual(@as(usize, 3), drifts.len);
        for (drifts) |d| {
            try std.testing.expect(d.kind == .junction_pair_uniqueness or d.kind == .missing_foreign_key);
            try std.testing.expect(!d.breaksReads());
        }
        // The extra `created_at` column is deliberately not drift: it changes
        // nothing the relation query reads, and the schema's junction shape is a
        // derivation, not a declaration the consumer chose.
        for (drifts) |d| try std.testing.expect(!std.mem.eql(u8, d.column, "created_at"));
        try assertSchema(std.testing.allocator, drv.asDriver(), infos, .read_breaking_only);
        try std.testing.expectError(error.SchemaDrift, assertSchema(std.testing.allocator, drv.asDriver(), infos, .any));
    }

    // The pair keyed the other way round satisfies the composite key: the two
    // orders reject the same duplicates. The foreign keys are still missing, so
    // the count is two — and the uniqueness report is gone.
    _ = try drv.exec("DROP TABLE js_member_js_tag", &.{});
    _ = try drv.exec("CREATE TABLE js_member_js_tag (js_member_id INTEGER NOT NULL, js_tag_id INTEGER NOT NULL, PRIMARY KEY (js_tag_id, js_member_id))", &.{});
    {
        const drifts = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, drifts);
        try std.testing.expectEqual(@as(usize, 2), drifts.len);
        for (drifts) |d| try std.testing.expectEqual(SchemaDrift.Kind.missing_foreign_key, d.kind);
    }

    // A unique index it cannot read may be what forces the pair, so the
    // uniqueness question has no answer and the report stays silent — the same
    // erring-towards-silence rule the column UNIQUE check follows.
    _ = try drv.exec("DROP TABLE js_member_js_tag", &.{});
    _ = try drv.exec("CREATE TABLE js_member_js_tag (js_member_id INTEGER NOT NULL, js_tag_id INTEGER NOT NULL)", &.{});
    _ = try drv.exec("CREATE UNIQUE INDEX js_partial ON js_member_js_tag (js_member_id, js_tag_id) WHERE js_member_id > 0", &.{});
    {
        const drifts = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, drifts);
        for (drifts) |d| try std.testing.expect(d.kind != .junction_pair_uniqueness);
    }

    // The shape `migrateSchema` itself creates is the one accepted, foreign keys
    // and all — hand-created here, as a consumer with a `.sql` DDL would.
    _ = try drv.exec("DROP TABLE js_member_js_tag", &.{});
    _ = try drv.exec(
        "CREATE TABLE js_member_js_tag (" ++
            "js_member_id INTEGER NOT NULL, js_tag_id INTEGER NOT NULL, " ++
            "PRIMARY KEY (js_member_id, js_tag_id), " ++
            "FOREIGN KEY (js_member_id) REFERENCES js_member (id) ON DELETE CASCADE ON UPDATE CASCADE, " ++
            "FOREIGN KEY (js_tag_id) REFERENCES js_tag (id) ON DELETE CASCADE ON UPDATE CASCADE)",
        &.{},
    );
    {
        const agreeing = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, agreeing);
        try std.testing.expectEqual(@as(usize, 0), agreeing.len);
        try assertSchema(std.testing.allocator, drv.asDriver(), infos, .any);
    }
}

test "checkSchema compares a junction served by a view on its columns alone (SQLite)" {
    // The existence probe accepts any relation of the junction's name, so a view
    // that exposes the two columns is a junction this check must not report on:
    // a view can carry neither a primary key nor a foreign key, and asking would
    // report two foreign keys and a primary key no view could ever have — the
    // false report that blocks a deploy.
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const edge = @import("../../core/edge.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const buildGraph = @import("../../codegen/graph.zig").buildGraph;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    const JvMemberBase = schema("JvMember", .{ .fields = &.{field.String("name")} });
    const JvTagBase = schema("JvTag", .{ .fields = &.{field.String("label")} });
    const JvMember = struct {
        pub const schema_name = JvMemberBase.schema_name;
        pub const fields = JvMemberBase.fields;
        pub const edges = &.{edge.To("tags", JvTagBase)};
        pub const indexes = JvMemberBase.indexes;
    };
    const JvTag = struct {
        pub const schema_name = JvTagBase.schema_name;
        pub const fields = JvTagBase.fields;
        pub const edges = &.{edge.To("members", JvMemberBase)};
        pub const indexes = JvTagBase.indexes;
    };
    const graph = comptime buildGraph(&.{ JvMember, JvTag });
    const infos = graph.types;

    try migrateSchema(std.testing.allocator, drv.asDriver(), infos);
    _ = try drv.exec("DROP TABLE jv_member_jv_tag", &.{});
    _ = try drv.exec(
        "CREATE VIEW jv_member_jv_tag AS SELECT id AS jv_member_id, id AS jv_tag_id FROM jv_member",
        &.{},
    );
    {
        const agreeing = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, agreeing);
        try std.testing.expectEqual(@as(usize, 0), agreeing.len);
        try assertSchema(std.testing.allocator, drv.asDriver(), infos, .any);
    }

    // The columns are still compared: a view that does not expose the names the
    // relation query selects fails it exactly as a table would.
    _ = try drv.exec("DROP VIEW jv_member_jv_tag", &.{});
    _ = try drv.exec("CREATE VIEW jv_member_jv_tag AS SELECT id AS member_ref, id AS tag_ref FROM jv_member", &.{});
    {
        const drifts = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, drifts);
        try std.testing.expectEqual(@as(usize, 2), drifts.len);
        for (drifts) |d| {
            try std.testing.expectEqual(SchemaDrift.Kind.missing_column, d.kind);
            try std.testing.expect(d.breaksReads());
        }
        try std.testing.expectError(error.SchemaDrift, assertSchema(std.testing.allocator, drv.asDriver(), infos, .read_breaking_only));
    }
}

test "checkSchema needs no junction table for an M2M edge with an explicit edge schema (SQLite)" {
    // The other half of the enumeration: an edge with `Through(EdgeSchema)`
    // reads and writes the through entity's own table, which is a declared
    // entity and is checked as one. Expecting an implicit junction here would
    // report a table `migrateSchema` never creates — a false drift, which blocks
    // deploys.
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const edge = @import("../../core/edge.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const buildGraph = @import("../../codegen/graph.zig").buildGraph;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    const JtTagBase = schema("JtTag", .{ .fields = &.{field.String("label")} });
    const JtPostBase = schema("JtPost", .{ .fields = &.{field.String("title")} });
    const JtPostTag = schema("JtPostTag", .{
        .fields = &.{ field.Int("jt_post_id"), field.Int("jt_tag_id") },
    });
    const JtTag = struct {
        pub const schema_name = JtTagBase.schema_name;
        pub const fields = JtTagBase.fields;
        pub const edges = &.{edge.To("posts", JtPostBase).Through(JtPostTag)};
        pub const indexes = JtTagBase.indexes;
    };
    const JtPost = struct {
        pub const schema_name = JtPostBase.schema_name;
        pub const fields = JtPostBase.fields;
        pub const edges = &.{edge.To("tags", JtTagBase).Through(JtPostTag)};
        pub const indexes = JtPostBase.indexes;
    };
    const graph = comptime buildGraph(&.{ JtTag, JtPost, JtPostTag });
    const infos = graph.types;

    // Nothing migrated: the three declared entities are missing, and nothing
    // else is — in particular no `jt_tag_jt_post` junction table, which no
    // `CREATE TABLE` on the migration side ever emits for a through edge.
    {
        const drifts = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
        defer freeSchemaDrift(std.testing.allocator, drifts);
        try std.testing.expectEqual(@as(usize, 3), drifts.len);
        for (drifts) |d| try std.testing.expectEqual(SchemaDrift.Kind.missing_table, d.kind);
    }

    try migrateSchema(std.testing.allocator, drv.asDriver(), infos);
    const agreeing = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
    defer freeSchemaDrift(std.testing.allocator, agreeing);
    try std.testing.expectEqual(@as(usize, 0), agreeing.len);
}

test "a through schema's declared table_name names the junction end to end (SQLite)" {
    // v0.87.0 known-shape: the edge derived its junction from the through
    // schema's *name* while the migration created and checked the through
    // entity under its declared `table_name`. On a through schema with the
    // override the DDL built `zt_link`, but every junction statement aimed at
    // the short name — the first m2m write answered `no such table`, and
    // checkSchema reported nothing because the through entity is checked as
    // its own entity. Both faces now resolve through one rule
    // (graph.throughTableName): the write, the adjacency read and the drift
    // check all land on `zt_link`, and no short-name junction is created.
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const edge = @import("../../core/edge.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const buildGraph = @import("../../codegen/graph.zig").buildGraph;
    const client_mod = @import("../../codegen/client.zig");
    const deinitEntity = @import("../../codegen/entity.zig").deinitEntity;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    const ZmTagBase = schema("ZmTag", .{ .fields = &.{field.String("label")} });
    const ZmMemberBase = schema("ZmMember", .{ .fields = &.{field.String("name")} });
    const ZmLink = schema("ZmMemberTag", .{
        .fields = &.{ field.Int("zm_member_id"), field.Int("zm_tag_id") },
        .table_name = "zt_link",
    });
    const ZmTag = struct {
        pub const schema_name = ZmTagBase.schema_name;
        pub const fields = ZmTagBase.fields;
        pub const edges = &.{edge.To("members", ZmMemberBase).Through(ZmLink)};
        pub const indexes = ZmTagBase.indexes;
    };
    const ZmMember = struct {
        pub const schema_name = ZmMemberBase.schema_name;
        pub const fields = ZmMemberBase.fields;
        pub const edges = &.{edge.To("tags", ZmTagBase).Through(ZmLink)};
        pub const indexes = ZmMemberBase.indexes;
    };
    const graph = comptime buildGraph(&.{ ZmMember, ZmTag, ZmLink });
    const infos = graph.types;
    const member_info = infos[0];
    const tag_info = infos[1];

    try migrateSchema(std.testing.allocator, drv.asDriver(), infos);

    // The junction exists under its declared name — and under neither name
    // the no-through derivation would invent.
    var link_cols = try getExistingColumns(std.testing.allocator, drv.asDriver(), "zt_link");
    defer freeExistingColumns(std.testing.allocator, &link_cols);
    try std.testing.expectEqual(@as(usize, 3), link_cols.items.len); // id + the two pair columns
    var phantom_a = try getExistingColumns(std.testing.allocator, drv.asDriver(), "zm_member_zm_tag");
    defer freeExistingColumns(std.testing.allocator, &phantom_a);
    try std.testing.expectEqual(@as(usize, 0), phantom_a.items.len);
    var phantom_b = try getExistingColumns(std.testing.allocator, drv.asDriver(), "zm_tag_zm_member");
    defer freeExistingColumns(std.testing.allocator, &phantom_b);
    try std.testing.expectEqual(@as(usize, 0), phantom_b.items.len);

    // Junction write path: the create builder's m2m AddEdge inserts into
    // `zt_link` (it used to aim at `zm_member_zm_tag`).
    const root = client_mod.makeClient(infos, std.testing.allocator, drv.asDriver());
    var tag_ids: [2]i64 = undefined;
    for ([_][]const u8{ "red", "blue" }, 0..) |label, i| {
        var b = try root.zm_tag.Create();
        defer b.deinit();
        _ = try b.setFieldValue("label", label);
        var row = try b.Save();
        defer deinitEntity(infos, tag_info, &row, std.testing.allocator);
        tag_ids[i] = row.id;
    }
    const member_id = id: {
        var b = try root.zm_member.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "alice");
        _ = try b.AddEdge("tags", &tag_ids);
        var row = try b.Save();
        defer deinitEntity(infos, member_info, &row, std.testing.allocator);
        break :id row.id;
    };
    // And the rows are literally in `zt_link` — nothing referenced a
    // short-name junction anywhere on the write path.
    {
        var rows = try drv.query("SELECT COUNT(*) FROM zt_link", &.{});
        defer rows.deinit();
        const row = rows.next() orelse return error.NoRow;
        try std.testing.expectEqual(@as(i64, 2), row.getInt(0).?);
    }

    // Adjacency read: the eager load joins `zt_link` and reads both tags back.
    {
        var q = root.zm_member.Query();
        defer q.deinit();
        _ = try q.WithEdge("tags");
        const members = try q.All();
        defer {
            for (members.items) |*e| deinitEntity(infos, member_info, e, std.testing.allocator);
            members.deinit();
        }
        try std.testing.expectEqual(@as(usize, 1), members.items.len);
        const tags = members.items[0].edges.tags.?;
        try std.testing.expectEqual(@as(usize, 2), tags.len);
        var got_ids = [_]i64{ tags[0].id, tags[1].id };
        std.mem.sort(i64, &got_ids, {}, std.sort.asc(i64));
        var want_ids = tag_ids;
        std.mem.sort(i64, &want_ids, {}, std.sort.asc(i64));
        try std.testing.expectEqualSlices(i64, &want_ids, &got_ids);
    }

    // The update path writes the same junction through buildEdgeStep: remove
    // one tag, and the adjacency read answers one.
    {
        var u = root.zm_member.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", "alice2");
        _ = try u.Where(.{root.zm_member.predicates.idEQ(.{ .int = member_id })});
        _ = try u.RemoveEdgeIDs("tags", &.{tag_ids[0]});
        try std.testing.expectEqual(@as(usize, 1), try u.Save());
    }
    {
        var q = root.zm_member.Query();
        defer q.deinit();
        _ = try q.WithEdge("tags");
        const members = try q.All();
        defer {
            for (members.items) |*e| deinitEntity(infos, member_info, e, std.testing.allocator);
            members.deinit();
        }
        try std.testing.expectEqual(@as(usize, 1), members.items.len);
        const tags = members.items[0].edges.tags.?;
        try std.testing.expectEqual(@as(usize, 1), tags.len);
        try std.testing.expectEqual(tag_ids[1], tags[0].id);
        try std.testing.expectEqualStrings("blue", tags[0].label);
    }

    // The through entity is checked under its declared table name and the
    // junction loop skips through edges — zero drift on both faces.
    const drifts = try checkSchema(std.testing.allocator, drv.asDriver(), infos);
    defer freeSchemaDrift(std.testing.allocator, drifts);
    try std.testing.expectEqual(@as(usize, 0), drifts.len);
    try assertSchema(std.testing.allocator, drv.asDriver(), infos, .any);
}

test "getExistingViews reads the stored definition and answers an empty list otherwise (SQLite)" {
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE vw_src (id INTEGER PRIMARY KEY, flag TEXT NOT NULL)", &.{});
    _ = try drv.exec("CREATE VIEW vw_flag_view AS SELECT id, flag FROM vw_src WHERE flag = 'on'", &.{});

    var views = try getExistingViews(std.testing.allocator, drv.asDriver(), "vw_flag_view");
    defer freeExistingViews(std.testing.allocator, &views);
    try std.testing.expectEqual(@as(usize, 1), views.items.len);
    try std.testing.expectEqualStrings("vw_flag_view", views.items[0].name);
    // SQLite keeps the statement text, so what comes back is the whole
    // `CREATE VIEW …`, not `view_sql` — which is exactly why nothing compares
    // the two strings (see `getExistingViews`).
    try std.testing.expect(std.mem.indexOf(u8, views.items[0].definition, "CREATE VIEW") != null);
    try std.testing.expect(std.mem.indexOf(u8, views.items[0].definition, "SELECT id, flag FROM vw_src") != null);

    // A table of that name is not a view …
    var table_named = try getExistingViews(std.testing.allocator, drv.asDriver(), "vw_src");
    defer freeExistingViews(std.testing.allocator, &table_named);
    try std.testing.expectEqual(@as(usize, 0), table_named.items.len);

    // … and a name that is not there is an empty answer, not an error.
    var absent = try getExistingViews(std.testing.allocator, drv.asDriver(), "vw_absent");
    defer freeExistingViews(std.testing.allocator, &absent);
    try std.testing.expectEqual(@as(usize, 0), absent.items.len);

    // The name is bound, never interpolated: a name carrying the quote that
    // would close a literal answers an empty list instead of becoming statement
    // text. (`PRAGMA` is where this dialect cannot bind; this query is an
    // ordinary `sqlite_master` SELECT, so it can.)
    var hostile = try getExistingViews(std.testing.allocator, drv.asDriver(), "vw_flag_view' OR 1=1 --");
    defer freeExistingViews(std.testing.allocator, &hostile);
    try std.testing.expectEqual(@as(usize, 0), hostile.items.len);
}

test "MySQL's server-side type names compare equal to the declared family; PostgreSQL and SQLite keep their spellings" {
    // MySQL stores BOOLEAN as `tinyint(1)` and REAL as DOUBLE, and
    // `information_schema.columns.data_type` answers with the storage name
    // (`tinyint`, `double`) whatever the DDL said — MariaDB the same. The
    // comparison used to read those spellings literally, so every table with a
    // bool or a float reported a false `.type_mismatch`, and an
    // `allow_data_loss` plan then planned an ALTER TYPE to "repair" it and died
    // on `MySQLTypeChangeUnsafe`.
    var schema_buf: [128]u8 = undefined;
    var db_buf: [128]u8 = undefined;

    const schema_bool = try normalizeSqlType("BOOLEAN", &schema_buf, Dialect.mysql);
    const db_tinyint = try normalizeSqlType("tinyint", &db_buf, Dialect.mysql);
    try std.testing.expectEqualStrings(schema_bool, db_tinyint);

    // A real difference survives the mapping: zent's `.int` is stored as `int`,
    // and a genuine `tinyint` column is still not an `.int`.
    const db_int = try normalizeSqlType("int", &db_buf, Dialect.mysql);
    try std.testing.expect(!std.mem.eql(u8, schema_bool, db_int));

    const schema_float = try normalizeSqlType("REAL", &schema_buf, Dialect.mysql);
    const db_double = try normalizeSqlType("double", &db_buf, Dialect.mysql);
    try std.testing.expectEqualStrings(schema_float, db_double);

    // The aliases are MySQL's, not a general relaxation: PostgreSQL reports the
    // declared spelling, where `real` (4 bytes) and `double precision` (8) are
    // genuinely different types — and SQLite reads its declared type back
    // verbatim.
    const pg_real = try normalizeSqlType("REAL", &schema_buf, Dialect.postgres);
    const pg_double = try normalizeSqlType("double", &db_buf, Dialect.postgres);
    try std.testing.expectEqualStrings("real", pg_real);
    try std.testing.expectEqualStrings("double precision", pg_double);
    try std.testing.expect(!std.mem.eql(u8, pg_real, pg_double));

    const pg_bool = try normalizeSqlType("BOOLEAN", &schema_buf, Dialect.postgres);
    const pg_bool_db = try normalizeSqlType("boolean", &db_buf, Dialect.postgres);
    try std.testing.expectEqualStrings(pg_bool, pg_bool_db);

    const sqlite_bool = try normalizeSqlType("BOOLEAN", &schema_buf, Dialect.sqlite);
    try std.testing.expectEqualStrings("boolean", sqlite_bool);
}

test "a declared type longer than the stack buffer is still compared" {
    // `catch null` used to make the whole comparison vanish for a type longer
    // than 128 bytes, and "no type_mismatch reported" cannot be told apart from
    // "the types agree" — a drift check must never fake that. A long declared
    // type reaches the comparison through a hand-built TableDef or a synthetic
    // `sql_type`, which is how a consumer with a long `ENUM`/`CHARSET`
    // declaration gets one.
    const alloc = std.testing.allocator;

    var long_buf: [256]u8 = undefined;
    @memset(&long_buf, 'x');

    var schema_buf: [128]u8 = undefined;
    var db_buf: [128]u8 = undefined;

    // Short types still use the stack buffer, so the common path allocates
    // nothing. (SQLite adds no aliases of its own, so this is the plain
    // spelling-level comparison.)
    const short = try normalizeTypeForCompare(alloc, "VARCHAR(255)", &schema_buf, Dialect.sqlite);
    defer short.deinit(alloc);
    try std.testing.expect(short.owned == null);
    try std.testing.expectEqualStrings("varchar", short.text);

    // A long one is normalized on the heap instead of being skipped.
    const long = try normalizeTypeForCompare(alloc, &long_buf, &schema_buf, Dialect.sqlite);
    defer long.deinit(alloc);
    try std.testing.expect(long.owned != null);
    try std.testing.expectEqual(@as(usize, 256), long.text.len);

    // The comparison therefore still happens, and still reports a difference.
    const db = try normalizeTypeForCompare(alloc, "INTEGER", &db_buf, Dialect.sqlite);
    defer db.deinit(alloc);
    try std.testing.expect(!std.mem.eql(u8, long.text, db.text));
}

test "migrateSchema adds the unique index a column-level UNIQUE needs on an existing table" {
    // The declaration is inline in `CREATE TABLE` and `ALTER TABLE ADD COLUMN`
    // cannot carry it, so a table created before the field was marked unique
    // never gets the constraint. With no unique index the statement
    // `SaveOrUpdateOn` builds is rejected outright — "ON CONFLICT clause does
    // not match any PRIMARY KEY or UNIQUE constraint" on SQLite and PostgreSQL
    // — so every upsert call site against that table fails at runtime while the
    // schema says it works. The duplicate insert at the end is the proof that
    // the migration closed it.
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;
    const allocator = std.testing.allocator;

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    // The table as a database that predates the `Unique()` has it: nullable and
    // unconstrained.
    _ = try drv.exec("CREATE TABLE uq_fix_item (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT NOT NULL)", &.{});

    const UqFixItem = schema("UqFixItem", .{ .fields = &.{field.String("email").Unique()} });
    const info = comptime fromSchema(UqFixItem);
    const infos = &[_]TypeInfo{info};

    // Before: the drift is real, and `assertSchema(.any)` is the only mode that
    // reports it (`breaksReads` is false — a duplicate row is a write the
    // database accepts, not a broken read).
    try std.testing.expectError(error.SchemaDrift, assertSchema(allocator, drv.asDriver(), infos, .any));

    try migrateSchema(allocator, drv.asDriver(), infos);

    const after = try checkSchema(allocator, drv.asDriver(), infos);
    defer freeSchemaDrift(allocator, after);
    try std.testing.expectEqual(@as(usize, 0), after.len);

    _ = try drv.exec("INSERT INTO uq_fix_item (email) VALUES ('a@example.test')", &.{});
    try std.testing.expectError(
        error.UniqueViolation,
        drv.exec("INSERT INTO uq_fix_item (email) VALUES ('a@example.test')", &.{}),
    );

    // Idempotent: a second run finds the index and plans nothing.
    try migrateSchema(allocator, drv.asDriver(), infos);
    const again = try checkSchema(allocator, drv.asDriver(), infos);
    defer freeSchemaDrift(allocator, again);
    try std.testing.expectEqual(@as(usize, 0), again.len);
}

test "checkSchema names a junction table whose name is a declared entity's table" {
    // `<a>_<b>` is a name any entity can take, and `junctionTableForEdge` does
    // not know about it. Both the junction and the entity are created with
    // `CREATE TABLE IF NOT EXISTS`, and `migrateSchema` creates entities first,
    // so the junction's CREATE is a no-op and the M2M relation query selects its
    // columns from the other table — every traversal of that edge reads the
    // wrong thing, and the shape drifts it produces (`missing_column` and the
    // rest) name the symptom rather than the cause.
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const edge = @import("../../core/edge.zig");
    const buildGraph = @import("../../codegen/graph.zig").buildGraph;
    const allocator = std.testing.allocator;

    // The derived junction name for two M2M sides is `<left>_<right>`, sorted,
    // so this entity's table name is exactly the collision.
    const Left = schema("CnLeft", .{ .fields = &.{field.String("name")} });
    const Right = schema("CnRight", .{ .fields = &.{field.String("name")} });
    const Sides = struct {
        pub const schema_name = "CnLeft";
        pub const fields = Left.fields;
        pub const edges = &.{edge.To("rights", Right)};
        pub const indexes = Left.indexes;
    };
    const Other = struct {
        pub const schema_name = "CnRight";
        pub const fields = Right.fields;
        pub const edges = &.{edge.To("lefts", Sides)};
        pub const indexes = Right.indexes;
    };
    const Unfortunate = schema("CnLeftCnRight", .{
        .table_name = "cn_left_cn_right",
        .fields = &.{field.String("payload")},
    });

    const graph = comptime buildGraph(&.{ Sides, Other, Unfortunate });
    const infos = graph.types;

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    try migrateSchema(allocator, drv.asDriver(), infos);

    const drifts = try checkSchema(allocator, drv.asDriver(), infos);
    defer freeSchemaDrift(allocator, drifts);

    try std.testing.expectEqual(@as(usize, 1), drifts.len);
    try std.testing.expectEqual(SchemaDrift.Kind.junction_name_collision, drifts[0].kind);
    try std.testing.expectEqualStrings("cn_left_cn_right", drifts[0].table);
    // The report names both surfaces: the pair that derived the name, and the
    // entity that answers to it.
    try std.testing.expect(std.mem.indexOf(u8, drifts[0].index_detail, "cn_left <-> cn_right") != null);
    try std.testing.expect(std.mem.indexOf(u8, drifts[0].index_detail, "the entity CnLeftCnRight") != null);
    // A detail borrowed from comptime literals, not owned (see ownsIndexDetail).
    try std.testing.expect(!ownsIndexDetail(drifts[0].kind));

    // Read-breaking, and deliberately so: the relation query reads a table that
    // does not have the junction's columns. A deploy gate therefore stops on it
    // rather than printing a warning nobody reads.
    try std.testing.expect(drifts[0].breaksReads());
    try std.testing.expectError(error.SchemaDrift, assertSchema(allocator, drv.asDriver(), infos, .read_breaking_only));

    // And the shape questions are *not* asked on top of it: with the cause
    // reported, three consequences would only bury it.
    for (drifts) |d| {
        try std.testing.expect(d.kind != .missing_column);
        try std.testing.expect(d.kind != .junction_pair_uniqueness);
    }
}

test "the ALTER builders refuse a dialect name they do not know" {
    // The dispatch used to be on `dialect.name[0]`, so a hand-built name like
    // `"sqlserver"` took the SQLite arm and got SQLite's DROP COLUMN — SQL the
    // library cannot vouch for, sent to a server it has never spoken to. The
    // three named dialects still produce their own statement, and anything else
    // is refused by name.
    const allocator = std.testing.allocator;
    const sqlserver = Dialect{ .name = "sqlserver" };

    try std.testing.expectError(error.UnsupportedDialect, dropColumnSQL(allocator, "t", "c", sqlserver));
    try std.testing.expectError(error.UnsupportedDialect, alterColumnTypeSQL(allocator, "t", "c", "TEXT", sqlserver));
    try std.testing.expectError(error.UnsupportedDialect, alterColumnNullabilitySQL(allocator, "t", "c", true, sqlserver));

    // The dialects themselves are unchanged.
    const pg = try dropColumnSQL(allocator, "t", "c", Dialect.postgres);
    defer allocator.free(pg);
    try std.testing.expectEqualStrings("ALTER TABLE \"t\" DROP COLUMN \"c\" CASCADE", pg);
    const my = try dropColumnSQL(allocator, "t", "c", Dialect.mysql);
    defer allocator.free(my);
    try std.testing.expectEqualStrings("ALTER TABLE `t` DROP COLUMN `c`", my);
    const sq = try dropColumnSQL(allocator, "t", "c", Dialect.sqlite);
    defer allocator.free(sq);
    try std.testing.expectEqualStrings("ALTER TABLE \"t\" DROP COLUMN \"c\"", sq);
    // SQLite has no ALTER COLUMN, and MySQL's is the unsafe one — unchanged.
    try std.testing.expectError(error.UnsupportedDialect, alterColumnTypeSQL(allocator, "t", "c", "TEXT", Dialect.sqlite));
    try std.testing.expectError(error.MySQLTypeChangeUnsafe, alterColumnTypeSQL(allocator, "t", "c", "TEXT", Dialect.mysql));
}

test "an edge FK references the target's declared primary key (SQLite)" {
    // `tableFromTypeInfoCrossRef` hardcoded the referenced column to "id" on
    // the From-edge half, while the query side resolved the same edge through
    // `graph.pkColumn`. A target that declares `.pk = "fid"` — a supported
    // shape (core/schema.zig's `pk`) — then got a fresh child table whose
    // FOREIGN KEY names a column the parent does not have, and on SQLite,
    // where foreign keys are enforced, the child's first INSERT fails with
    // `foreign key mismatch - "child" referencing "parent"`.
    const allocator = std.testing.allocator;
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const edge = @import("../../core/edge.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const buildGraph = @import("../../codegen/graph.zig").buildGraph;

    const UploadFile = schema("UploadFile", .{
        .table_name = "xdaofood_upload_file",
        .pk = "fid",
        .fields = &.{ field.Int("fid"), field.String("path") },
    });
    const OrderProduct = schema("OrderProduct", .{
        .table_name = "xdaofood_order_product",
        .fields = &.{ field.Int("image_id"), field.String("title") },
        .edges = &.{edge.From("file", UploadFile).Field("image_id")},
    });

    const graph = comptime buildGraph(&.{ OrderProduct, UploadFile });
    const infos = graph.types;

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    try migrateSchema(allocator, drv.asDriver(), infos);

    // The child's foreign key names the declared table and the declared pk.
    var meta = try drv.query(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'xdaofood_order_product'",
        &.{},
    );
    defer meta.deinit();
    const row = meta.next() orelse return error.NoTableRow;
    const ddl = row.getText(0).?;
    try std.testing.expect(std.mem.indexOf(u8, ddl, "REFERENCES \"xdaofood_upload_file\" (\"fid\")") != null);
    // The parent has no `id` column at all, so the old literal was an FK to a
    // column that does not exist; it must be gone, not merely joined by "fid".
    try std.testing.expect(std.mem.indexOf(u8, ddl, "(\"id\")") == null);

    // End to end, foreign keys on (SQLiteDriver.open sets and verifies the
    // pragma): a child row over a real parent row inserts, and a dangling
    // parent id is rejected — the constraint fires, not a mismatch.
    _ = try drv.exec("INSERT INTO \"xdaofood_upload_file\" (\"fid\", \"path\") VALUES (7, '/a.png')", &.{});
    _ = try drv.exec("INSERT INTO \"xdaofood_order_product\" (\"image_id\", \"title\") VALUES (7, 'p')", &.{});
    try std.testing.expectError(
        error.ForeignKeyViolation,
        drv.exec("INSERT INTO \"xdaofood_order_product\" (\"image_id\", \"title\") VALUES (999, 'p')", &.{}),
    );
}

test "an edge FK references a StorageKey-renamed id column (SQLite)" {
    // The second shape of the same defect: the target keeps the default pk
    // *name* (`id`) but stores it under another column via `StorageKey`, so
    // the physical primary key — the only column a foreign key can name — is
    // `file_uid`, not "id".
    const allocator = std.testing.allocator;
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const edge = @import("../../core/edge.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const buildGraph = @import("../../codegen/graph.zig").buildGraph;

    const UploadFile = schema("UploadFile", .{
        .table_name = "xdaofood_upload_file",
        .fields = &.{ field.Int("id").StorageKey("file_uid"), field.String("path") },
    });
    const OrderProduct = schema("OrderProduct", .{
        .table_name = "xdaofood_order_product",
        .fields = &.{ field.Int("image_id"), field.String("title") },
        .edges = &.{edge.From("file", UploadFile).Field("image_id")},
    });

    const graph = comptime buildGraph(&.{ OrderProduct, UploadFile });
    const infos = graph.types;

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    try migrateSchema(allocator, drv.asDriver(), infos);

    var meta = try drv.query(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'xdaofood_order_product'",
        &.{},
    );
    defer meta.deinit();
    const row = meta.next() orelse return error.NoTableRow;
    const ddl = row.getText(0).?;
    try std.testing.expect(std.mem.indexOf(u8, ddl, "REFERENCES \"xdaofood_upload_file\" (\"file_uid\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "(\"id\")") == null);

    // The reference resolves: the parent over file_uid, the child over image_id.
    _ = try drv.exec("INSERT INTO \"xdaofood_upload_file\" (\"file_uid\", \"path\") VALUES (1, '/a.png')", &.{});
    _ = try drv.exec("INSERT INTO \"xdaofood_order_product\" (\"image_id\", \"title\") VALUES (1, 'p')", &.{});
}

test "a cross-referenced To edge FK references the target's pk too (SQLite)" {
    // The other half of the same fix: when Owner declares To("files", UploadFile)
    // and UploadFile has no inverse From edge, the FK column auto-added to the
    // upload_file table referenced a literal "id" as well — wrong for a target
    // with a custom pk, with the same first-INSERT failure on SQLite.
    const allocator = std.testing.allocator;
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const edge = @import("../../core/edge.zig");
    const schema = @import("../../core/schema.zig").Schema;

    const UploadFile = schema("UploadFile", .{
        .table_name = "xdaofood_upload_file",
        .fields = &.{field.String("path")}, // deliberately no inverse From edge
    });
    const Owner = schema("Owner", .{
        .table_name = "xdaofood_owner",
        .pk = "oid",
        .fields = &.{ field.Int("oid"), field.String("label") },
        .edges = &.{edge.To("files", UploadFile)},
    });

    // Raw per-entity infos, not buildGraph: buildGraph's addEdgeFieldsToAll
    // injects the incoming To edge's FK column into upload_file's fields
    // itself, and the cross-reference branch then finds the column already
    // present and pairs no constraint with it. A hand-built `fromSchema` list
    // is the shape where this branch owns both the column and its FK — the
    // shape a caller migrating a raw TypeInfo list uses.
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;
    const owner_info = comptime fromSchema(Owner);
    const file_info = comptime fromSchema(UploadFile);
    const infos = &[_]TypeInfo{ owner_info, file_info };

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    try migrateSchema(allocator, drv.asDriver(), infos);

    // Here the auto-added child column is upload_file.owner_id.
    var meta = try drv.query(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'xdaofood_upload_file'",
        &.{},
    );
    defer meta.deinit();
    const row = meta.next() orelse return error.NoTableRow;
    const ddl = row.getText(0).?;
    try std.testing.expect(std.mem.indexOf(u8, ddl, "REFERENCES \"xdaofood_owner\" (\"oid\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "(\"id\")") == null);

    _ = try drv.exec("INSERT INTO \"xdaofood_owner\" (\"oid\", \"label\") VALUES (1, 'o')", &.{});
    _ = try drv.exec("INSERT INTO \"xdaofood_upload_file\" (\"path\", \"owner_id\") VALUES ('/a.png', 1)", &.{});
}

test "junctionTableForEdge derives the ends' declared table names and pks" {
    // The implicit-junction path (`.relation == .m2m`, no `Through`) used to
    // derive the target side from `toSnakeCase(target_name)` and reference a
    // literal "id" on both ends — the same short-name defect the entity-table
    // FKs carried before v0.84.0. A target declaring `table_name` and `.pk`
    // got a junction whose columns and REFERENCES named a table the entity
    // does not live in and a column it does not have.
    const allocator = std.testing.allocator;
    const field = @import("../../core/field.zig");
    const edge = @import("../../core/edge.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const buildGraph = @import("../../codegen/graph.zig").buildGraph;

    const XfTagBase = schema("XfTag", .{
        .table_name = "xdaofood_tag",
        .pk = "tid",
        .fields = &.{ field.Int("tid"), field.String("label") },
    });
    const XfMemberBase = schema("XfMember", .{ .fields = &.{field.String("name")} });
    const XfMember = struct {
        pub const schema_name = XfMemberBase.schema_name;
        pub const fields = XfMemberBase.fields;
        // Both sides declare the edge — that is what makes the relation M2M
        // without a `Through`, the shape `junctionTableForEdge` serves.
        pub const edges = &.{edge.To("tags", XfTagBase)};
        pub const indexes = XfMemberBase.indexes;
    };
    const XfTag = struct {
        pub const schema_name = XfTagBase.schema_name;
        // Forward the overrides too: a composed type that drops them loses
        // `table_name`/`pk` exactly the way the withEdges copies in the
        // examples do, and the junction would silently fall back to the
        // short name and "id".
        pub const table_name = XfTagBase.table_name;
        pub const pk = XfTagBase.pk;
        pub const fields = XfTagBase.fields;
        pub const edges = &.{edge.To("members", XfMemberBase)};
        pub const indexes = XfTagBase.indexes;
    };
    const graph = comptime buildGraph(&.{ XfMember, XfTag });
    const infos = graph.types;

    const member_info = comptime graph.types[0];
    const member_edge = comptime member_info.edges[0];
    comptime std.debug.assert(member_edge.relation == .m2m and member_edge.through == null);

    const jtable = comptime junctionTableForEdge(member_edge, member_info, infos);

    // `xdaofood_tag` sorts before `xf_member`, so the *target* side is first:
    // the declared table name wins over the `xf_tag` short name everywhere —
    // junction name, column names, and the FK's referenced table.
    try std.testing.expectEqualStrings("xdaofood_tag_xf_member", jtable.name);
    try std.testing.expectEqual(@as(usize, 2), jtable.columns.len);
    try std.testing.expectEqualStrings("xdaofood_tag_id", jtable.columns[0].name);
    try std.testing.expectEqualStrings("xf_member_id", jtable.columns[1].name);
    try std.testing.expectEqual(@as(usize, 2), jtable.primary_keys.len);
    try std.testing.expectEqualStrings("xdaofood_tag_id", jtable.primary_keys[0]);
    try std.testing.expectEqualStrings("xf_member_id", jtable.primary_keys[1]);

    try std.testing.expectEqual(@as(usize, 2), jtable.foreign_keys.len);
    // The target end references its declared table and its declared pk.
    try std.testing.expectEqualStrings("xdaofood_tag_id", jtable.foreign_keys[0].columns[0]);
    try std.testing.expectEqualStrings("xdaofood_tag", jtable.foreign_keys[0].ref_table);
    try std.testing.expectEqualStrings("tid", jtable.foreign_keys[0].ref_columns[0]);
    // The source end references the declared table it was given and its pk.
    try std.testing.expectEqualStrings("xf_member_id", jtable.foreign_keys[1].columns[0]);
    try std.testing.expectEqualStrings("xf_member", jtable.foreign_keys[1].ref_table);
    try std.testing.expectEqualStrings("id", jtable.foreign_keys[1].ref_columns[0]);

    // The rendered CREATE TABLE carries the same shape.
    const sql = try createTableSQLAlloc(allocator, jtable, Dialect.sqlite);
    defer allocator.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "REFERENCES \"xdaofood_tag\" (\"tid\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "REFERENCES \"xf_member\" (\"id\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "xf_tag") == null);

    // Out of the graph the target end has no table name to name, so that half
    // of the pair is a column and a primary-key entry and **no constraint** —
    // a derived name is a guess, and a rejected `CREATE TABLE` is worse than
    // no key at all (see `tableFromTypeInfoCrossRef`).
    const lone_infos = comptime &[_]TypeInfo{member_info};
    const fallback = comptime junctionTableForEdge(member_edge, member_info, lone_infos);
    try std.testing.expectEqualStrings("xf_member_xf_tag", fallback.name);
    try std.testing.expectEqual(@as(usize, 2), fallback.columns.len);
    try std.testing.expectEqual(@as(usize, 2), fallback.primary_keys.len);
    try std.testing.expectEqual(@as(usize, 1), fallback.foreign_keys.len);
    // What survives is the end this graph can resolve, and only that one.
    try std.testing.expectEqualStrings("xf_member_id", fallback.foreign_keys[0].columns[0]);
    try std.testing.expectEqualStrings("xf_member", fallback.foreign_keys[0].ref_table);

    const fallback_sql = try createTableSQLAlloc(allocator, fallback, Dialect.sqlite);
    defer allocator.free(fallback_sql);
    try std.testing.expect(std.mem.indexOf(u8, fallback_sql, "REFERENCES \"xf_member\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fallback_sql, "REFERENCES \"xf_tag\"") == null);
}

test "an implicit M2M junction references each end's declared table and pk (SQLite)" {
    // Reachable through the public API: two mutual `To` edges without a
    // `Through` resolve to `.m2m` (`resolveGraphEdges`), `migrateSchema`
    // creates the junction `junctionTableForEdge` derives, and the relation
    // query reads that table. With a target declaring `table_name` and
    // `.pk`, the junction has to name the declared table and pk on both
    // ends — under enforced foreign keys, not just in the DDL text.
    const allocator = std.testing.allocator;
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const edge = @import("../../core/edge.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const buildGraph = @import("../../codegen/graph.zig").buildGraph;

    const ZtTagBase = schema("ZtTag", .{
        .table_name = "zt_tag_xref",
        .pk = "tid",
        .fields = &.{ field.Int("tid"), field.String("label") },
    });
    const ZtMemberBase = schema("ZtMember", .{ .fields = &.{field.String("name")} });
    const ZtMember = struct {
        pub const schema_name = ZtMemberBase.schema_name;
        pub const fields = ZtMemberBase.fields;
        pub const edges = &.{edge.To("tags", ZtTagBase)};
        pub const indexes = ZtMemberBase.indexes;
    };
    const ZtTag = struct {
        pub const schema_name = ZtTagBase.schema_name;
        // Forward the overrides — same rule as the unit test above.
        pub const table_name = ZtTagBase.table_name;
        pub const pk = ZtTagBase.pk;
        pub const fields = ZtTagBase.fields;
        pub const edges = &.{edge.To("members", ZtMemberBase)};
        pub const indexes = ZtTagBase.indexes;
    };
    const graph = comptime buildGraph(&.{ ZtMember, ZtTag });
    const infos = graph.types;

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    try migrateSchema(allocator, drv.asDriver(), infos);

    // The junction `migrateSchema` created names each end's declared table
    // and pk: `zt_tag_xref` ("tid") for the target end, `zt_member` ("id")
    // for the source one — the same junction name the relation query derives.
    var meta = try drv.query(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'zt_member_zt_tag_xref'",
        &.{},
    );
    defer meta.deinit();
    const row = meta.next() orelse return error.NoTableRow;
    const ddl = row.getText(0).?;
    try std.testing.expect(std.mem.indexOf(u8, ddl, "REFERENCES \"zt_tag_xref\" (\"tid\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "REFERENCES \"zt_member\" (\"id\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "\"zt_tag\"") == null);

    // Migrated schema and check agree: the derived junction shape is the
    // created one — columns, pair key and both foreign keys included.
    const agreeing = try checkSchema(allocator, drv.asDriver(), infos);
    defer freeSchemaDrift(allocator, agreeing);
    try std.testing.expectEqual(@as(usize, 0), agreeing.len);

    // End to end, foreign keys on (`SQLiteDriver.open` sets and verifies the
    // pragma): both parent rows insert, the pair over them joins, and a
    // dangling end is rejected — the constraints fire, not a mismatch.
    _ = try drv.exec("INSERT INTO \"zt_member\" (\"id\", \"name\") VALUES (1, 'm')", &.{});
    _ = try drv.exec("INSERT INTO \"zt_tag_xref\" (\"tid\", \"label\") VALUES (7, 't')", &.{});
    _ = try drv.exec("INSERT INTO \"zt_member_zt_tag_xref\" (\"zt_member_id\", \"zt_tag_xref_id\") VALUES (1, 7)", &.{});
    try std.testing.expectError(
        error.ForeignKeyViolation,
        drv.exec("INSERT INTO \"zt_member_zt_tag_xref\" (\"zt_member_id\", \"zt_tag_xref_id\") VALUES (1, 999)", &.{}),
    );
    try std.testing.expectError(
        error.ForeignKeyViolation,
        drv.exec("INSERT INTO \"zt_member_zt_tag_xref\" (\"zt_member_id\", \"zt_tag_xref_id\") VALUES (999, 7)", &.{}),
    );
}

test "an edge to a target outside the graph contributes its column and no constraint" {
    // The decision `warnOutOfGraphEdgeRefs` exists to make visible: a From edge
    // whose target is not in `all_infos` still gets the historical fallback —
    // `toSnakeCase(target_name)` and a literal "id" — rather than an error or a
    // drift kind. That is deliberate: a multi-database deployment migrates each
    // graph on its own, so the referenced table may live in another database (or
    // be created later), and only the *migration* is visible to a consumer that
    // never generates a Client. `junctionTableForEdge`'s twin is already pinned
    // in "junctionTableForEdge derives the ends' declared table names and pks";
    // this is the entity-table half, which had no pin.
    const allocator = std.testing.allocator;
    const field = @import("../../core/field.zig");
    const edge = @import("../../core/edge.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const buildGraph = @import("../../codegen/graph.zig").buildGraph;

    const UploadFile = schema("UploadFile", .{
        .table_name = "xdaofood_upload_file",
        .pk = "fid",
        .fields = &.{ field.Int("fid"), field.String("path") },
    });
    const OrderProduct = schema("OrderProduct", .{
        .fields = &.{ field.Int("image_id"), field.String("title") },
        .edges = &.{edge.From("file", UploadFile).Field("image_id")},
    });

    // UploadFile deliberately omitted: this edge crosses the graph. The graph
    // still builds — only the query/CRUD surface (`edgeTargetInfo`) refuses it.
    const graph = comptime buildGraph(&.{OrderProduct});
    const infos = graph.types;
    const info = comptime graph.types[0];
    comptime std.debug.assert(info.edges[0].relation == .m2o);

    const table = comptime tableFromTypeInfoCrossRef(info, infos);

    // The column is there — the query side reads `image_id` whether or not the
    // target is in this graph — and the constraint is not. The target's declared
    // `table_name` (`xdaofood_upload_file`) is unknowable out here, and the
    // derived short name it used to reference (`upload_file`) is a name nothing
    // creates: PostgreSQL rejects the `CREATE TABLE` outright (`relation
    // "upload_file" does not exist`), so a chunked migration failed on every
    // retry. Omitting the key leaves the reference for the pass that has the
    // whole graph.
    try std.testing.expectEqual(@as(usize, 0), table.foreign_keys.len);
    var has_image_id = false;
    for (table.columns) |col| {
        if (std.mem.eql(u8, col.name, "image_id")) has_image_id = true;
    }
    try std.testing.expect(has_image_id);

    const sql = try createTableSQLAlloc(allocator, table, Dialect.sqlite);
    defer allocator.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "REFERENCES") == null);
}

const WarnCapture = struct {
    var buf: [2048]u8 = undefined;
    var len: usize = 0;

    fn sink(_: zent_log.Level, message: []const u8) void {
        const n = @min(message.len, buf.len - len);
        if (n == 0) return;
        @memcpy(buf[len..][0..n], message[0..n]);
        len += n;
        if (len < buf.len) {
            buf[len] = '\n';
            len += 1;
        }
    }

    fn reset() void {
        len = 0;
    }

    fn occurrences(needle: []const u8) usize {
        return std.mem.count(u8, buf[0..len], needle);
    }
};

test "migrateSchema warns once about an edge that crosses the graph (SQLite)" {
    // On the migration-only path a cross-graph edge is *visible*, not fatal: no
    // error and no drift kind are added, and the key the graph cannot name is
    // left out of the DDL rather than guessed. The warning is the whole
    // deliverable, and it is assertable in-tree through `zent_log.setSink` —
    // the library's own sink, documented for exactly this, not the root
    // module's `logFn` — so it is asserted here rather than left to a code read.
    const allocator = std.testing.allocator;
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const edge = @import("../../core/edge.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const buildGraph = @import("../../codegen/graph.zig").buildGraph;

    const UploadFile = schema("UploadFile", .{
        .table_name = "xdaofood_upload_file",
        .fields = &.{ field.Int("id"), field.String("path") },
    });
    const OrderProduct = schema("OrderProduct", .{
        .fields = &.{ field.Int("image_id"), field.String("title") },
        .edges = &.{edge.From("file", UploadFile).Field("image_id")},
    });

    const graph = comptime buildGraph(&.{OrderProduct});
    const infos = graph.types;

    WarnCapture.reset();
    zent_log.setSink(WarnCapture.sink);
    defer zent_log.setSink(null);

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    try migrateSchema(allocator, drv.asDriver(), infos);

    // One line for the one crossing edge — the dedup the shared planner gives
    // (it rebuilds the table definition in both steps and still warns once).
    // Counted by a distinctive phrase so an unrelated warning cannot inflate it.
    try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences("is not in this graph's infos"));
    // The three names the database error never carries: the edge, the source and
    // the target. `"targets UploadFile"` rather than `"UploadFile"`, which the
    // closing suggestion repeats.
    try std.testing.expect(WarnCapture.occurrences("'file'") == 1);
    try std.testing.expect(WarnCapture.occurrences("OrderProduct") == 1);
    try std.testing.expect(WarnCapture.occurrences("targets UploadFile") == 1);
    try std.testing.expect(WarnCapture.occurrences("Z16") == 1);

    // And the table is created without a constraint it could not name: the
    // column is there (the query side reads `image_id`), `REFERENCES` is not.
    // That is what makes a chunked migration survive — a derived name the
    // server cannot resolve used to reject the whole `CREATE TABLE`.
    var meta = try drv.query(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'order_product'",
        &.{},
    );
    defer meta.deinit();
    const row = meta.next() orelse return error.NoTableRow;
    try std.testing.expect(std.mem.indexOf(u8, row.getText(0).?, "image_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, row.getText(0).?, "REFERENCES") == null);
}

// ------------------------------------------------------------------
// Declared extension types: the PostgreSQL pre-check
// ------------------------------------------------------------------

test "a declared PostgreSQL extension type maps to its extension, and an unknown name maps to nothing" {
    // The known pairs, in the spellings a declaration can carry: a dimension
    // (`vector(1536)` is what `field.Vector` emits), a schema qualifier, an
    // array marker, and case.
    for ([_][]const u8{ "vector", "vector(1536)", "vector[]", "VECTOR(3)", "public.vector" }) |declared| {
        try std.testing.expectEqualStrings("vector", postgresExtensionForDeclaredType(declared).?);
    }
    try std.testing.expectEqualStrings("citext", postgresExtensionForDeclaredType("public.citext").?);
    try std.testing.expectEqualStrings("hstore", postgresExtensionForDeclaredType("hstore").?);
    try std.testing.expectEqualStrings("ltree", postgresExtensionForDeclaredType("ltree").?);
    try std.testing.expectEqualStrings("postgis", postgresExtensionForDeclaredType("geometry").?);
    // PostGIS's own spelling of a type with a modifier: the bare name is what
    // the table is keyed on.
    try std.testing.expectEqualStrings("postgis", postgresExtensionForDeclaredType("geography(Point, 4326)").?);

    // Everything else is silence, including the two shapes that must never be
    // guessed at: a name that merely *starts* like a known type, and
    // PostgreSQL's own built-ins (a wrong extension here would refuse a
    // migration that had nothing to do with extensions).
    try std.testing.expect(postgresExtensionForDeclaredType("tsvector") == null);
    try std.testing.expect(postgresExtensionForDeclaredType("int4range") == null);
    try std.testing.expect(postgresExtensionForDeclaredType("inet") == null);
    try std.testing.expect(postgresExtensionForDeclaredType("text") == null);
    try std.testing.expect(postgresExtensionForDeclaredType("varchar(120)") == null);
    try std.testing.expect(postgresExtensionForDeclaredType("vectorize") == null);
    try std.testing.expect(postgresExtensionForDeclaredType("") == null);
    try std.testing.expect(postgresExtensionForDeclaredType("  ") == null);
}

test "a large graph does not trip the comptime quota the migration helpers evaluate under" {
    // A consumer with 154 tables hit "evaluation exceeded … backwards branches"
    // inside these helpers, which are private — so the caller's own
    // `@setEvalBranchQuota` cannot reach them, and the budget has to be decided
    // here. Two shapes are pinned: the functions *evaluate* on a graph far
    // larger than any test graph (200 tables × 16 fields), and the budget they
    // evaluate under scales with that graph rather than being a constant that a
    // bigger schema outgrows. This does not reproduce the exact branch count of
    // the reported schema (its fields carry extension-type overrides, which cost
    // more per field than the plain `Int` fields below), so it is a size
    // regression guard, not a replay of that graph.
    const field = @import("../../core/field.zig");
    const Schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    const QuotaTables = 200;
    const Fields = struct {
        const list = blk: {
            var out: []const @TypeOf(field.Int("x")) = &.{};
            for (0..16) |i| {
                const name = std.fmt.comptimePrint("f{d}", .{i});
                out = out ++ &[_]@TypeOf(field.Int("x")){field.Int(name)};
            }
            break :blk out;
        };
    };

    const infos = comptime blk: {
        var out: []const TypeInfo = &.{};
        for (0..QuotaTables) |i| {
            const S = Schema(std.fmt.comptimePrint("QuotaDoc{d}", .{i}), .{
                .table_name = std.fmt.comptimePrint("quota_doc_{d}", .{i}),
                .fields = Fields.list,
            });
            out = out ++ &[_]TypeInfo{fromSchema(S)};
        }
        break :blk out;
    };

    try std.testing.expectEqual(@as(usize, QuotaTables), infos.len);

    // A fixed budget is what the report was about: 50_000 is what
    // `tableFromTypeInfoCrossRef` used to set, and it is not enough for a
    // 154-table graph. The scaled one is above it by construction.
    try std.testing.expect(evalQuotaFor(infos) > 50_000);

    // No declared extension type, so the answer is empty — the point is that it
    // is *computed* rather than aborting the compilation.
    const needed = comptime requiredPostgresExtensions(infos);
    try std.testing.expectEqual(@as(usize, 0), needed.len);

    // And the cross-reference table builder, whose budget is per table × table.
    // 16 declared fields plus the `id` primary key the table builder adds when
    // the schema declares none.
    const last = comptime tableFromTypeInfoCrossRef(infos[QuotaTables - 1], infos);
    try std.testing.expectEqual(@as(usize, 17), last.columns.len);
    try std.testing.expectEqualStrings("quota_doc_199", last.name);
}

test "requiredPostgresExtensions lists a graph's declared extension types, once each" {
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const buildGraph = @import("../../codegen/graph.zig").buildGraph;

    // Three declaration shapes: the `field.Vector` kind, an explicit
    // `.SqlType(…)` override (`field.Other` is the same field underneath), and
    // a second column declaring the same extension again.
    const Doc = schema("ExtProbeDoc", .{
        .fields = &.{
            field.Int("id"),
            field.Vector("embedding", 1536),
            field.Text("handle").SqlType("citext"),
            field.Other("tags", "int4range").Optional(),
        },
    });
    const Second = schema("ExtProbeSecond", .{
        .fields = &.{ field.Int("id"), field.Other("alias", "citext").Optional() },
    });
    // A graph whose declarations are all built-in types: the answer that keeps
    // the catalog unasked.
    const Plain = schema("ExtProbePlain", .{
        .fields = &.{ field.Int("id"), field.String("name"), field.JSONValue("doc").Optional() },
    });

    const needed = comptime requiredPostgresExtensions(buildGraph(&.{ Doc, Second }).types);
    // Deduplicated in first-seen order, and `int4range` is not an extension
    // type at all.
    try std.testing.expectEqual(@as(usize, 2), needed.len);
    try std.testing.expectEqualStrings("vector", needed[0]);
    try std.testing.expectEqualStrings("citext", needed[1]);

    const none = comptime requiredPostgresExtensions(buildGraph(&.{Plain}).types);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

/// A driver whose whole catalog is "which extensions are installed", plus the
/// `pg_class` gate that decides whether that catalog may be read at all.
///
/// The check is a read by contract, so `exec` fails outright — and counts the
/// call, so an entry point can assert "not one statement reached the server"
/// instead of inferring it from which error came back. Any statement that is
/// neither the gate nor the `pg_extension` read is counted in `unmatched`, so a
/// probe the stub never modelled cannot come back as "nothing is installed" and
/// be mistaken for the check working.
const ExtensionStub = struct {
    dialect_value: Dialect = Dialect.postgres,
    installed: []const []const u8 = &.{},
    /// What the `pg_extension` probe answers instead of a row set. `null` means
    /// it answers `installed`.
    ///
    /// `error.ExecFailed` is a statement refusal as `sql_driver.classify` sees
    /// it, and `error.DriverFailed` is the *same* refusal as PostgreSQL's
    /// driver reports it (SQLSTATE 42P01 goes through `toDriverError`, whose
    /// `else` arm is `DriverFailed`) — both are `postgresStatementRefused` and
    /// both are pinned below, because the second is the one a real server
    /// produces. Anything else must propagate.
    probe_error: ?sql_driver.Error = null,
    /// What the `pg_class` capability gate answers: whether the relation it asks
    /// about is listed. `false` is the shape the gate exists for — a
    /// wire-compatible server that answers 0 for `pg_extension` (HeliosDB Nano)
    /// while still providing the type the schema declares.
    lists_catalogs: bool = true,
    queries: usize = 0,
    /// How many of `queries` were the capability gate. Counted separately so a
    /// test can say "the catalog was asked exactly once" without the gate
    /// making that number two.
    probes: usize = 0,
    exec_calls: usize = 0,
    unmatched: usize = 0,
    /// The answer the live cursor walks, and how far along it is.
    current: []const []const u8 = &.{},
    pos: usize = 0,
    /// What the live row's `getText(0)` reads — borrowed exactly as a driver's
    /// row buffer is, so the check cannot keep a name past `next()`.
    row_text: ?[]const u8 = null,
    /// What the live row's `getInt(0)` reads: the gate's `count(*)`, which is
    /// not a name and must not be answered as one.
    row_int: ?i64 = null,

    fn asDriver(self: *ExtensionStub) sql_driver.Driver {
        return .{ .ptr = self, .vtable = &driver_vtable };
    }

    fn answering(self: *ExtensionStub, names: []const []const u8) sql_driver.Rows {
        self.current = names;
        self.pos = 0;
        return .{ .ptr = self, .vtable = &rows_vtable };
    }

    const driver_vtable = sql_driver.Driver.VTable{
        .exec = stubExec,
        .query = stubQuery,
        .beginTx = stubBeginTx,
        .close = stubClose,
        .dialect = stubDialect,
        .ping = stubPing,
        .inTransaction = stubInTransaction,
        .beginSavepoint = stubBeginSavepoint,
    };

    const rows_vtable = sql_driver.Rows.VTable{
        .next = rowsNext,
        .deinit = rowsDeinit,
    };

    const row_vtable = sql_driver.Row.VTable{
        .columnCount = rowColumnCount,
        .columnName = rowColumnName,
        .getBool = rowGetBool,
        .getInt = rowGetInt,
        .getFloat = rowGetFloat,
        .getText = rowGetText,
        .getBlob = rowGetBlob,
        .isNull = rowIsNull,
    };

    fn stubExec(ptr: *anyopaque, _: ?*const sql_driver.ExecutionContext, _: []const u8, _: []const Value) sql_driver.Error!sql_driver.Result {
        // The check must never execute anything; reaching here means it did —
        // and the call is counted, so an entry point can assert "not one DDL
        // statement" rather than infer it from what the returned error was.
        const self: *ExtensionStub = @ptrCast(@alignCast(ptr));
        self.exec_calls += 1;
        return error.ExecFailed;
    }

    fn stubQuery(ptr: *anyopaque, _: ?*const sql_driver.ExecutionContext, query_sql: []const u8, _: []const Value) sql_driver.Error!sql_driver.Rows {
        const self: *ExtensionStub = @ptrCast(@alignCast(ptr));
        self.queries += 1;
        // The capability gate first: it asks `pg_class` for a `count(*)`, so a
        // stub that answered it out of `installed` would read a name as an
        // integer and report every configured extension as unlisted. Answered
        // deliberately instead, from `lists_catalogs`.
        if (std.mem.indexOf(u8, query_sql, pg_relation_probe_prefix) != null) {
            self.probes += 1;
            self.row_int = if (self.lists_catalogs) 1 else 0;
            self.row_text = null;
            return self.answering(&.{"1"});
        }
        if (std.mem.indexOf(u8, query_sql, "pg_extension") != null) {
            self.row_int = null;
            if (self.probe_error) |e| return e;
            return self.answering(self.installed);
        }
        self.unmatched += 1;
        return self.answering(&.{});
    }

    fn rowsNext(ptr: *anyopaque) ?sql_driver.Row {
        const self: *ExtensionStub = @ptrCast(@alignCast(ptr));
        if (self.pos >= self.current.len) return null;
        self.row_text = self.current[self.pos];
        self.pos += 1;
        return .{ .ptr = self, .vtable = &row_vtable };
    }

    fn rowsDeinit(_: *anyopaque) void {}

    fn rowColumnCount(_: *anyopaque) usize {
        return 1;
    }

    fn rowColumnName(_: *anyopaque, _: usize) []const u8 {
        return "extname";
    }

    fn rowGetBool(_: *anyopaque, _: usize) ?bool {
        return null;
    }

    fn rowGetInt(ptr: *anyopaque, index: usize) ?i64 {
        if (index != 0) return null;
        const self: *ExtensionStub = @ptrCast(@alignCast(ptr));
        return self.row_int;
    }

    fn rowGetFloat(_: *anyopaque, _: usize) ?f64 {
        return null;
    }

    fn rowGetText(ptr: *anyopaque, index: usize) ?[]const u8 {
        if (index != 0) return null;
        const self: *ExtensionStub = @ptrCast(@alignCast(ptr));
        return self.row_text;
    }

    fn rowGetBlob(_: *anyopaque, _: usize) ?[]const u8 {
        return null;
    }

    fn rowIsNull(ptr: *anyopaque, index: usize) bool {
        return rowGetText(ptr, index) == null;
    }

    fn stubBeginTx(_: *anyopaque) sql_driver.Error!sql_driver.Tx {
        return error.TxFailed;
    }

    fn stubBeginSavepoint(_: *anyopaque, _: []const u8) sql_driver.Error!sql_driver.Tx {
        return error.TxFailed;
    }

    fn stubClose(_: *anyopaque) void {}

    fn stubDialect(ptr: *anyopaque) Dialect {
        const self: *ExtensionStub = @ptrCast(@alignCast(ptr));
        return self.dialect_value;
    }

    fn stubPing(_: *anyopaque) sql_driver.Error!void {}

    fn stubInTransaction(_: *anyopaque) bool {
        return false;
    }
};

test "the PostgreSQL extension check refuses a missing extension, and asks nothing when nothing is needed" {
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const buildGraph = @import("../../codegen/graph.zig").buildGraph;

    const Doc = schema("ExtCheckDoc", .{ .fields = &.{ field.Int("id"), field.Vector("embedding", 3) } });
    const Plain = schema("ExtCheckPlain", .{ .fields = &.{ field.Int("id"), field.String("name") } });
    const with_vector = comptime buildGraph(&.{Doc}).types;
    const without = comptime buildGraph(&.{Plain}).types;

    WarnCapture.reset();
    zent_log.setSink(WarnCapture.sink);
    defer zent_log.setSink(null);

    // Installed: the check passes, and the catalog was asked exactly once —
    // behind the `pg_class` gate, which is the statement before it.
    var present = ExtensionStub{ .installed = &.{ "plpgsql", "vector" } };
    try checkPostgresExtensions(present.asDriver(), with_vector);
    try std.testing.expectEqual(@as(usize, 1), present.probes);
    try std.testing.expectEqual(@as(usize, 2), present.queries);
    try std.testing.expectEqual(@as(usize, 0), present.unmatched);
    try std.testing.expectEqual(@as(usize, 0), WarnCapture.occurrences("CREATE EXTENSION"));

    // Missing: a named error, and a line that names the extension *and* the
    // statement that fixes it — which is the whole deliverable, since the
    // server's own `type "vector" does not exist` says neither.
    WarnCapture.reset();
    var missing = ExtensionStub{ .installed = &.{"plpgsql"} };
    try std.testing.expectError(error.MissingPostgresExtension, checkPostgresExtensions(missing.asDriver(), with_vector));
    try std.testing.expectEqual(@as(usize, 1), missing.probes);
    try std.testing.expectEqual(@as(usize, 2), missing.queries);
    try std.testing.expectEqual(@as(usize, 0), missing.unmatched);
    try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences("PostgreSQL extension 'vector'"));
    try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences("`CREATE EXTENSION IF NOT EXISTS vector;`"));

    // A case-insensitive comparison: the catalog stores the extension's name in
    // the case `CREATE EXTENSION` was given, not in the one the schema wrote.
    var upper = ExtensionStub{ .installed = &.{"VECTOR"} };
    try checkPostgresExtensions(upper.asDriver(), with_vector);
    try std.testing.expectEqual(@as(usize, 2), upper.queries);

    // No declared extension type: not one statement. The probe is conditional,
    // the same rule `graphHasMySqlTextDefault` follows, and the reason a
    // statement-modelling stub never has to claim a query the schema did not
    // warrant.
    WarnCapture.reset();
    var plain = ExtensionStub{ .installed = &.{} };
    try checkPostgresExtensions(plain.asDriver(), without);
    try std.testing.expectEqual(@as(usize, 0), plain.queries);
    try std.testing.expectEqual(@as(usize, 0), WarnCapture.occurrences("extension"));

    // And another dialect is not this check's business at all — `pg_extension`
    // is PostgreSQL's own catalog.
    var sqlite_stub = ExtensionStub{ .dialect_value = Dialect.sqlite, .installed = &.{} };
    try checkPostgresExtensions(sqlite_stub.asDriver(), with_vector);
    try std.testing.expectEqual(@as(usize, 0), sqlite_stub.queries);
}

test "a server without pg_extension is not refused, and says so once" {
    // `pg_extension` is PostgreSQL's own catalog, and a server that speaks the
    // wire protocol is not obliged to carry it — HeliosDB Nano has neither
    // `pg_extension` nor `pg_available_extensions`, and provides `vector`
    // natively. Refusing the migration there would reject a schema the server
    // would execute, so neither the gate nor a *statement-level* rejection of
    // the read is an error: each is a warning and the run continues, and the
    // declared types go to the server as declared. A server that cannot provide
    // them answers its own, louder error at the DDL.
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const buildGraph = @import("../../codegen/graph.zig").buildGraph;

    const Doc = schema("ExtAbsentDoc", .{ .fields = &.{ field.Int("id"), field.Vector("embedding", 3) } });
    const with_vector = comptime buildGraph(&.{Doc}).types;

    WarnCapture.reset();
    zent_log.setSink(WarnCapture.sink);
    defer zent_log.setSink(null);

    // The gate, which is the path a wire-compatible server takes: `pg_class`
    // answers that it does not list `pg_extension`, so the read is never sent —
    // the statement would be refused, and a refused statement leaves the
    // caller's transaction unusable, which is a much larger failure than the
    // unknown capability this is about. One line, no error, and the catalog
    // read is not among the statements made.
    WarnCapture.reset();
    var unlisted = ExtensionStub{ .lists_catalogs = false };
    try checkPostgresExtensions(unlisted.asDriver(), with_vector);
    try std.testing.expectEqual(@as(usize, 1), unlisted.probes);
    // Only the gate: the read it would have gated was never sent.
    try std.testing.expectEqual(@as(usize, 1), unlisted.queries);
    try std.testing.expectEqual(@as(usize, 0), unlisted.exec_calls);
    try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences("does not list `pg_extension`"));
    try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences("(vector)"));
    try std.testing.expectEqual(@as(usize, 0), WarnCapture.occurrences("SELECT extname FROM pg_extension"));
    // Not "the extension is missing": that is a claim about the server this
    // could not establish, and neither line may make it.
    try std.testing.expectEqual(@as(usize, 0), WarnCapture.occurrences("CREATE EXTENSION"));

    // The safety net behind the gate: the catalog *is* listed and the server
    // refuses the read anyway. Both spellings of that refusal are tolerated, in
    // one loop: the classification-level one (`ExecFailed`) and the one
    // PostgreSQL's driver actually produces (`DriverFailed` — SQLSTATE 42P01
    // through `toDriverError`'s `else` arm). A tolerance that only knew the
    // first would be dead code against the server it was written for.
    for ([_]sql_driver.Error{ error.ExecFailed, error.DriverFailed }) |refusal| {
        WarnCapture.reset();
        var absent = ExtensionStub{ .probe_error = refusal };
        try checkPostgresExtensions(absent.asDriver(), with_vector);
        // No error, one line, and the gate plus the refused read are the only
        // statements made.
        try std.testing.expectEqual(@as(usize, 1), absent.probes);
        try std.testing.expectEqual(@as(usize, 2), absent.queries);
        try std.testing.expectEqual(@as(usize, 0), absent.exec_calls);
        try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences("SELECT extname FROM pg_extension"));
        try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences("(vector)"));
        // Not "the extension is missing": that is a claim about the server this
        // could not establish, and the line must not make it.
        try std.testing.expectEqual(@as(usize, 0), WarnCapture.occurrences("CREATE EXTENSION"));
    }

    // A failure that is neither a refusal nor a lost connection still
    // propagates. The tolerance is for "this server has no such catalog", never
    // for "no answer" — proceeding on one would turn a protocol error into a
    // migration that fails somewhere less informative.
    WarnCapture.reset();
    var broken = ExtensionStub{ .probe_error = error.ProtocolError };
    try std.testing.expectError(error.ProtocolError, checkPostgresExtensions(broken.asDriver(), with_vector));
    try std.testing.expectEqual(@as(usize, 2), broken.queries);
    try std.testing.expectEqual(@as(usize, 0), WarnCapture.occurrences("pg_extension"));

    // And the entry point really does carry on: `exec` is the stub's answer to
    // every DDL statement, so *reaching* one is the proof that the check no
    // longer stops the run — the mirror image of the test above, which pins the
    // opposite direction on a server that answers the catalog.
    WarnCapture.reset();
    var through_create = ExtensionStub{ .probe_error = error.DriverFailed };
    try std.testing.expectError(
        error.ExecFailed,
        createAllTables(std.testing.allocator, through_create.asDriver(), with_vector),
    );
    try std.testing.expect(through_create.exec_calls > 0);
    try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences("SELECT extname FROM pg_extension"));
}

/// A transaction handle over a stub driver, counting the three calls a
/// migration entry point must *not* make when it is handed a caller's
/// transaction.
///
/// The statics are the point: a `Tx` is three function pointers plus an opaque
/// pointer, so a hand-built one records what a real driver's would, without a
/// connection.
const TxProbe = struct {
    var commits: usize = 0;
    var rollbacks: usize = 0;
    var deinits: usize = 0;

    fn reset() void {
        commits = 0;
        rollbacks = 0;
        deinits = 0;
    }

    fn commitFn(_: *anyopaque) sql_driver.Error!void {
        commits += 1;
    }

    fn rollbackFn(_: *anyopaque) sql_driver.Error!void {
        rollbacks += 1;
    }

    fn deinitFn(_: *anyopaque) void {
        deinits += 1;
    }
};

test "every migration entry point refuses a missing extension before its first statement" {
    // The claim is stronger than "an error came back": `exec` returns
    // `error.ExecFailed` on this stub, so a run that had reached any DDL would
    // fail with that instead — and `exec_calls` pins it a second time. The
    // entry points are checked one by one because each is a separate place the
    // check has to be wired, and only `migrateSchemaWithOptions` is exercised by
    // the PG integration case.
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const buildGraph = @import("../../codegen/graph.zig").buildGraph;

    const Doc = schema("ExtEntryDoc", .{ .fields = &.{ field.Int("id"), field.Vector("embedding", 3) } });
    const infos = comptime buildGraph(&.{Doc}).types;

    // `createAllTables` — the legacy entry point, before its MySQL server probe
    // and before `createTables`' first statement.
    var for_create = ExtensionStub{ .installed = &.{"plpgsql"} };
    try std.testing.expectError(
        error.MissingPostgresExtension,
        createAllTables(std.testing.allocator, for_create.asDriver(), infos),
    );
    try std.testing.expectEqual(@as(usize, 0), for_create.exec_calls);
    // The gate, then the catalog read: both are reads, neither is DDL.
    try std.testing.expectEqual(@as(usize, 1), for_create.probes);
    try std.testing.expectEqual(@as(usize, 2), for_create.queries);
    try std.testing.expectEqual(@as(usize, 0), for_create.unmatched);

    // `migrateSchemaWithOptions` — after the migration lock, before the history
    // table (which is DDL too, and is why a refused run leaves no trace at all).
    // Locking is off so the stub is not asked for a `pg_try_advisory_lock` it
    // has no answer to; that statement is not DDL either way.
    var for_migrate = ExtensionStub{ .installed = &.{"plpgsql"} };
    try std.testing.expectError(
        error.MissingPostgresExtension,
        migrateSchemaWithOptions(std.testing.allocator, for_migrate.asDriver(), infos, .{ .lock_timeout_ms = 0 }),
    );
    try std.testing.expectEqual(@as(usize, 0), for_migrate.exec_calls);
    try std.testing.expectEqual(@as(usize, 1), for_migrate.probes);
    try std.testing.expectEqual(@as(usize, 2), for_migrate.queries);
    try std.testing.expectEqual(@as(usize, 0), for_migrate.unmatched);

    // `migrateSchemaInTx` — and the caller's transaction is untouched: the
    // refused call neither commits, rolls back nor deinitialises it, which is
    // the boundary the entry point exists to hand back.
    TxProbe.reset();
    var for_tx = ExtensionStub{ .installed = &.{"plpgsql"} };
    const tx = sql_driver.Tx{
        .inner = for_tx.asDriver(),
        .commitFn = TxProbe.commitFn,
        .rollbackFn = TxProbe.rollbackFn,
        .deinitFn = TxProbe.deinitFn,
        .ptr = @ptrCast(&for_tx),
    };
    try std.testing.expectError(
        error.MissingPostgresExtension,
        migrateSchemaInTx(std.testing.allocator, tx, infos, .{ .lock_timeout_ms = 0 }),
    );
    try std.testing.expectEqual(@as(usize, 0), for_tx.exec_calls);
    try std.testing.expectEqual(@as(usize, 1), for_tx.probes);
    try std.testing.expectEqual(@as(usize, 2), for_tx.queries);
    try std.testing.expectEqual(@as(usize, 0), for_tx.unmatched);
    try std.testing.expectEqual(@as(usize, 0), TxProbe.commits);
    try std.testing.expectEqual(@as(usize, 0), TxProbe.rollbacks);
    try std.testing.expectEqual(@as(usize, 0), TxProbe.deinits);
}

/// A server that answers every read until the migration commits, and refuses
/// every read after that.
///
/// The shape it pins is the one measured against HeliosDB Nano: an error raised
/// *after* the transaction is gone must not release the transaction a second
/// time. `migrateSchemaWithOptions` reports nullability last, and the report
/// reads the database again — after the commit — so a server that starts
/// refusing reads at that point drives the error path the double release lived
/// on. The counters stand in for the heap on purpose: a second release of a
/// real driver's handle is a segfault, not a failed assertion, so what a test
/// can hold to is the number of releases.
const PostCommitRefusalStub = struct {
    /// Set by `commit`, and the whole rule: reads that happen after the
    /// transaction is over are refused.
    committed: bool = false,
    queries: usize = 0,
    execs: usize = 0,
    commits: usize = 0,
    rollbacks: usize = 0,
    deinits: usize = 0,

    fn asDriver(self: *PostCommitRefusalStub) sql_driver.Driver {
        return .{ .ptr = self, .vtable = &driver_vtable };
    }

    const driver_vtable = sql_driver.Driver.VTable{
        .exec = stubExec,
        .query = stubQuery,
        .beginTx = stubBeginTx,
        .close = stubClose,
        .dialect = stubDialect,
        .ping = stubPing,
        .inTransaction = stubInTransaction,
        .beginSavepoint = stubBeginSavepoint,
    };

    const rows_vtable = sql_driver.Rows.VTable{
        .next = rowsNext,
        .deinit = rowsDeinit,
    };

    fn stubExec(ptr: *anyopaque, _: ?*const sql_driver.ExecutionContext, _: []const u8, _: []const Value) sql_driver.Error!sql_driver.Result {
        const self: *PostCommitRefusalStub = @ptrCast(@alignCast(ptr));
        self.execs += 1;
        return .{ .rows_affected = 0, .last_insert_id = null };
    }

    fn stubQuery(ptr: *anyopaque, _: ?*const sql_driver.ExecutionContext, _: []const u8, _: []const Value) sql_driver.Error!sql_driver.Rows {
        const self: *PostCommitRefusalStub = @ptrCast(@alignCast(ptr));
        self.queries += 1;
        if (self.committed) return error.DriverFailed;
        return .{ .ptr = self, .vtable = &rows_vtable };
    }

    fn rowsNext(_: *anyopaque) ?sql_driver.Row {
        return null;
    }

    fn rowsDeinit(_: *anyopaque) void {}

    fn commitFn(ptr: *anyopaque) sql_driver.Error!void {
        const self: *PostCommitRefusalStub = @ptrCast(@alignCast(ptr));
        self.commits += 1;
        self.committed = true;
    }

    fn rollbackFn(ptr: *anyopaque) sql_driver.Error!void {
        const self: *PostCommitRefusalStub = @ptrCast(@alignCast(ptr));
        self.rollbacks += 1;
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *PostCommitRefusalStub = @ptrCast(@alignCast(ptr));
        self.deinits += 1;
    }

    fn stubBeginTx(ptr: *anyopaque) sql_driver.Error!sql_driver.Tx {
        return .{
            .inner = @as(*PostCommitRefusalStub, @ptrCast(@alignCast(ptr))).asDriver(),
            .commitFn = commitFn,
            .rollbackFn = rollbackFn,
            .deinitFn = deinitFn,
            .ptr = ptr,
        };
    }

    fn stubBeginSavepoint(_: *anyopaque, _: []const u8) sql_driver.Error!sql_driver.Tx {
        return error.TxFailed;
    }

    fn stubClose(_: *anyopaque) void {}

    fn stubDialect(_: *anyopaque) Dialect {
        return Dialect.postgres;
    }

    fn stubPing(_: *anyopaque) sql_driver.Error!void {}

    fn stubInTransaction(_: *anyopaque) bool {
        return false;
    }
};

test "an error raised after the commit releases the migration's transaction exactly once" {
    // The regression this pins: `migrateSchemaWithOptions` used to release its
    // own transaction with `errdefer tx.deinit()` *and* an explicit `tx.deinit()`
    // before the nullability report. An `errdefer` is armed against any later
    // error return, so a report that failed released the same handle twice — on
    // HeliosDB Nano that was a use-after-free that took the process down with a
    // segfault. The schema needs no extension type, so the only statements this
    // stub answers with anything but "no rows" are the DDL the planner emits.
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const buildGraph = @import("../../codegen/graph.zig").buildGraph;

    const Doc = schema("TxReleaseDoc", .{ .fields = &.{ field.Int("id"), field.String("name") } });
    const infos = comptime buildGraph(&.{Doc}).types;

    var stub = PostCommitRefusalStub{};
    try std.testing.expectError(
        error.DriverFailed,
        migrateSchemaWithOptions(std.testing.allocator, stub.asDriver(), infos, .{ .lock_timeout_ms = 0 }),
    );

    // The plan ran and committed, so the refused read is the post-commit
    // report — and the transaction was released once, by the `defer`.
    try std.testing.expect(stub.execs > 0);
    try std.testing.expectEqual(@as(usize, 1), stub.commits);
    try std.testing.expectEqual(@as(usize, 0), stub.rollbacks);
    try std.testing.expectEqual(@as(usize, 1), stub.deinits);
}

// ------------------------------------------------------------------
// A wire-compatible server without PostgreSQL's access-method catalog
// ------------------------------------------------------------------

/// One row of a stubbed catalog answer: `text[i]` is what `getText(i)` reads, a
/// `null` is a NULL column, and `int[i]` is what `getInt(i)` reads. The two
/// arrays are one per *column position*, so a row can carry only what the
/// query reads — the second row of an index in the `pg_index` shapes has no
/// integers at all, because they are read when the name changes and not again.
const CatalogStubRow = struct {
    text: []const ?[]const u8 = &.{},
    int: []const ?i64 = &.{},
};

/// A PostgreSQL catalog where `information_schema.columns` and the
/// `pg_index`/`pg_class`/`pg_attribute` join answer but the access-method table
/// may not exist.
///
/// That is the shape of a server that speaks libpq's wire protocol without
/// carrying PostgreSQL's whole catalog (HeliosDB Nano refuses `pg_am` with
/// SQLSTATE 42P01), and the two failure modes are modelled separately because
/// `getPostgresIndexes` answers them differently: `without_pg_am` refuses only
/// the statement that joins `pg_am` — the retry must therefore succeed — and
/// `refuse_all` refuses every statement, which is a server whose index catalog
/// cannot be read at all.
const PostgresIndexCatalogStub = struct {
    columns_rows: []const CatalogStubRow = &.{},
    /// The full query's rows: `relname`, `indisunique`, `indisvalid`,
    /// `indpred IS NOT NULL`, `indnatts <> indnkeyatts`, `indnkeyatts`,
    /// `amname`, `attname` at 0..7.
    full_rows: []const CatalogStubRow = &.{},
    /// The retry's rows: the same minus `amname`, so `attname` sits at 6.
    degraded_rows: []const CatalogStubRow = &.{},
    without_pg_am: bool = false,
    /// What the `pg_class` gate answers: whether `pg_am` is listed. `null`
    /// follows `without_pg_am`, so a test says one of the two unless it is
    /// deliberately inconsistent — `lists_access_method = true` *with*
    /// `without_pg_am = true` is the server that answers the gate and refuses
    /// the query anyway, which is the case the retry is still there for.
    lists_access_method: ?bool = null,
    /// What the same gate answers for `pg_proc`, which is the relation
    /// `getPostgresForeignKeys` needs (`generate_subscripts` is a function).
    /// `null` means "listed" — the full-PostgreSQL shape, which is what every
    /// index test here models.
    lists_pg_proc: ?bool = null,
    refuse_all: bool = false,
    /// How a refused statement is refused: `error.ExecFailed` is the
    /// classification-level shape `sql_driver.classify` reads as `.client`,
    /// `error.DriverFailed` is what PostgreSQL's driver actually returns for a
    /// rejected statement (SQLSTATE 42P01 lands in `toDriverError`'s `else`
    /// arm). Both are `postgresStatementRefused`, and both are pinned below.
    refuse_error: sql_driver.Error = error.ExecFailed,
    queries: usize = 0,
    /// How many of `queries` were the `pg_class` gate, counted separately so a
    /// test can assert which read answered without the gate inflating it.
    probes: usize = 0,
    /// Statements this stub had no answer for. Counted rather than answered
    /// with "nothing": a probe it never modelled must not come back as an empty
    /// catalog and be mistaken for the real answer.
    unmatched: usize = 0,
    rows: []const CatalogStubRow = &.{},
    pos: usize = 0,
    row: ?CatalogStubRow = null,

    fn asDriver(self: *PostgresIndexCatalogStub) sql_driver.Driver {
        return .{ .ptr = self, .vtable = &driver_vtable };
    }

    fn answering(self: *PostgresIndexCatalogStub, next: []const CatalogStubRow) sql_driver.Rows {
        self.rows = next;
        self.pos = 0;
        self.row = null;
        return .{ .ptr = self, .vtable = &rows_vtable };
    }

    const driver_vtable = sql_driver.Driver.VTable{
        .exec = stubExec,
        .query = stubQuery,
        .beginTx = stubBeginTx,
        .close = stubClose,
        .dialect = stubDialect,
        .ping = stubPing,
        .inTransaction = stubInTransaction,
        .beginSavepoint = stubBeginSavepoint,
    };

    const rows_vtable = sql_driver.Rows.VTable{
        .next = rowsNext,
        .deinit = rowsDeinit,
    };

    const row_vtable = sql_driver.Row.VTable{
        .columnCount = rowColumnCount,
        .columnName = rowColumnName,
        .getBool = rowGetBool,
        .getInt = rowGetInt,
        .getFloat = rowGetFloat,
        .getText = rowGetText,
        .getBlob = rowGetBlob,
        .isNull = rowIsNull,
    };

    /// Introspection is a read by contract; a statement that reaches here is
    /// one no helper was supposed to execute.
    fn stubExec(_: *anyopaque, _: ?*const sql_driver.ExecutionContext, _: []const u8, _: []const Value) sql_driver.Error!sql_driver.Result {
        return error.ExecFailed;
    }

    fn stubQuery(ptr: *anyopaque, _: ?*const sql_driver.ExecutionContext, query_sql: []const u8, _: []const Value) sql_driver.Error!sql_driver.Rows {
        const self: *PostgresIndexCatalogStub = @ptrCast(@alignCast(ptr));
        self.queries += 1;
        // The capability gate first, and before the `pg_am` match below on
        // purpose: the gate's statement *mentions* `pg_am` (it asks whether
        // `pg_class` lists that relation), so a stub that classified it by that
        // substring would model the gate as the query it gates.
        if (std.mem.indexOf(u8, query_sql, pg_relation_probe_prefix) != null) {
            self.probes += 1;
            if (self.refuse_all) return self.refuse_error;
            // Which relation was asked about decides which answer applies, and
            // the two are separate knobs because the reads they gate degrade
            // separately: the index read asks about `pg_am`, the foreign-key
            // read about `pg_proc` (a server can have one and not the other —
            // HeliosDB Nano has neither, and real PostgreSQL has both).
            const listed = if (std.mem.indexOf(u8, query_sql, "pg_proc") != null)
                (self.lists_pg_proc orelse true)
            else
                (self.lists_access_method orelse !self.without_pg_am);
            // One row either way, because the gate reads a `count(*)`: the
            // "not listed" answer is a zero, not an absent row.
            return self.answering(if (listed) &.{.{ .int = &.{1} }} else &.{.{ .int = &.{0} }});
        }
        // `pg_am` next: it is what distinguishes the two shapes, and the full
        // query mentions `pg_index` as well. `ExecFailed` is the class a
        // refused statement lands in (`sql_driver.classify`), which is the
        // condition the retry is written against — not a generic failure.
        const joins_access_method = std.mem.indexOf(u8, query_sql, "pg_am") != null;
        if (self.refuse_all or (self.without_pg_am and joins_access_method)) return self.refuse_error;
        if (joins_access_method) return self.answering(self.full_rows);
        if (std.mem.indexOf(u8, query_sql, "pg_index") != null) return self.answering(self.degraded_rows);
        if (std.mem.indexOf(u8, query_sql, "information_schema.columns") != null) return self.answering(self.columns_rows);
        self.unmatched += 1;
        return self.answering(&.{});
    }

    fn rowsNext(ptr: *anyopaque) ?sql_driver.Row {
        const self: *PostgresIndexCatalogStub = @ptrCast(@alignCast(ptr));
        if (self.pos >= self.rows.len) return null;
        self.row = self.rows[self.pos];
        self.pos += 1;
        return .{ .ptr = self, .vtable = &row_vtable };
    }

    fn rowsDeinit(_: *anyopaque) void {}

    fn rowColumnCount(ptr: *anyopaque) usize {
        const self: *PostgresIndexCatalogStub = @ptrCast(@alignCast(ptr));
        const row = self.row orelse return 0;
        return @max(row.text.len, row.int.len);
    }

    fn rowColumnName(_: *anyopaque, _: usize) []const u8 {
        return "";
    }

    fn rowGetBool(_: *anyopaque, _: usize) ?bool {
        return null;
    }

    fn rowGetInt(ptr: *anyopaque, index: usize) ?i64 {
        const self: *PostgresIndexCatalogStub = @ptrCast(@alignCast(ptr));
        const row = self.row orelse return null;
        if (index >= row.int.len) return null;
        return row.int[index];
    }

    fn rowGetFloat(_: *anyopaque, _: usize) ?f64 {
        return null;
    }

    fn rowGetText(ptr: *anyopaque, index: usize) ?[]const u8 {
        const self: *PostgresIndexCatalogStub = @ptrCast(@alignCast(ptr));
        const row = self.row orelse return null;
        if (index >= row.text.len) return null;
        return row.text[index];
    }

    fn rowGetBlob(_: *anyopaque, _: usize) ?[]const u8 {
        return null;
    }

    fn rowIsNull(ptr: *anyopaque, index: usize) bool {
        return rowGetText(ptr, index) == null;
    }

    fn stubBeginTx(_: *anyopaque) sql_driver.Error!sql_driver.Tx {
        return error.TxFailed;
    }

    fn stubBeginSavepoint(_: *anyopaque, _: []const u8) sql_driver.Error!sql_driver.Tx {
        return error.TxFailed;
    }

    fn stubClose(_: *anyopaque) void {}

    fn stubDialect(_: *anyopaque) Dialect {
        return Dialect.postgres;
    }

    fn stubPing(_: *anyopaque) sql_driver.Error!void {}

    fn stubInTransaction(_: *anyopaque) bool {
        return false;
    }
};

/// The table the index tests introspect: one declared two-key index, and a
/// second index the stub's catalog has that the schema does not declare (a
/// database-only index, which no comparison may report).
const PgIdxDoc = blk: {
    const field = @import("../../core/field.zig");
    const index_mod = @import("../../core/index.zig");
    const Schema = @import("../../core/schema.zig").Schema;
    break :blk Schema("PgIdxDoc", .{
        .table_name = "pg_idx_doc",
        .fields = &.{ field.Int("tenant_id"), field.String("title") },
        .indexes = &.{index_mod.Named("idx_pg_idx_doc_pair", &.{ "tenant_id", "title" })},
    });
};

/// `information_schema.columns` for the table both index tests introspect:
/// `column_name`, `data_type`, `is_nullable` at 0/1/2, in the shape
/// `getExistingColumns` reads on PostgreSQL (`udt_name` is column 4 and is not
/// needed — an empty answer there is not a mismatch).
const pg_idx_columns_rows = [_]CatalogStubRow{
    // `integer`, not `bigint`: `field.Int` is emitted `INTEGER` and the
    // auto-increment rewrite makes the primary key a `SERIAL`, which
    // `information_schema.columns` also reports as `integer`. A stub that said
    // `bigint` would report two `type_mismatch` drifts of its own and the
    // zero-drift assertion below would never reach the index.
    .{ .text = &.{ "id", "integer", "NO" } },
    .{ .text = &.{ "tenant_id", "integer", "NO" } },
    .{ .text = &.{ "title", "text", "NO" } },
};

/// The `pg_index` join's rows as a server *with* `pg_am` delivers them, in key
/// order: the declared two-key index over `(tenant_id, title)`, then a
/// database-only one-key index the schema does not declare. `btree` and a key
/// count that adds up make both comparable, which is the answer the retry must
/// never produce.
const pg_idx_full_rows = [_]CatalogStubRow{
    .{ .text = &.{ "idx_pg_idx_doc_pair", null, null, null, null, null, "btree", "tenant_id" }, .int = &.{ null, 0, 1, 0, 0, 2 } },
    .{ .text = &.{ "idx_pg_idx_doc_pair", null, null, null, null, null, "btree", "title" } },
    .{ .text = &.{ "idx_pg_idx_doc_title", null, null, null, null, null, "btree", "title" }, .int = &.{ null, 0, 1, 0, 0, 1 } },
};

/// The retry's rows: the same two indexes without the access-method column.
/// `attname` sits at 6 here, so a parse that kept reading column 7 would find
/// nothing — and the test asserts the columns come back empty *and* not
/// comparable, which is the point of the degraded shape: the key list is
/// unknown, not "btree over these columns".
const pg_idx_degraded_rows = [_]CatalogStubRow{
    .{ .text = &.{ "idx_pg_idx_doc_pair", null, null, null, null, null, "tenant_id" }, .int = &.{ null, 0, 1, 0, 0, 2 } },
    .{ .text = &.{ "idx_pg_idx_doc_title", null, null, null, null, null, "title" }, .int = &.{ null, 0, 1, 0, 0, 1 } },
};

// A plain PostgreSQL server — `pg_am` answers — is read by the first query
// alone, unchanged: one statement, the key list compared, `btree` honoured.
// This is the guard on "nothing changed for PostgreSQL" that the two
// degradation cases are the exception to.
test "an index read that has pg_am is unchanged and comparable" {
    const allocator = std.testing.allocator;

    var stub = PostgresIndexCatalogStub{
        .columns_rows = &pg_idx_columns_rows,
        .full_rows = &pg_idx_full_rows,
    };

    var indexes = try getPostgresIndexes(allocator, stub.asDriver(), "pg_idx_doc");
    defer freeExistingIndexes(allocator, &indexes);

    // The gate, then the read it selected — and no retry: the access method was
    // listed, so the statement that joins it was accepted.
    try std.testing.expectEqual(@as(usize, 1), stub.probes);
    try std.testing.expectEqual(@as(usize, 2), stub.queries);
    try std.testing.expectEqual(@as(usize, 0), stub.unmatched);
    try std.testing.expectEqual(@as(usize, 2), indexes.items.len);

    const pair = getExistingIndexByName(indexes.items, "idx_pg_idx_doc_pair").?;
    try std.testing.expect(pair.columns_comparable);
    try std.testing.expectEqual(@as(usize, 2), pair.columns.len);
    try std.testing.expectEqualStrings("tenant_id", pair.columns[0]);
    try std.testing.expectEqualStrings("title", pair.columns[1]);

    const single = getExistingIndexByName(indexes.items, "idx_pg_idx_doc_title").?;
    try std.testing.expect(single.columns_comparable);
    try std.testing.expectEqual(@as(usize, 1), single.columns.len);
}

test "an index read survives a server without pg_am, by name and uniqueness" {
    const allocator = std.testing.allocator;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    const info = comptime fromSchema(PgIdxDoc);
    const infos = &[_]TypeInfo{info};

    WarnCapture.reset();
    zent_log.setSink(WarnCapture.sink);
    defer zent_log.setSink(null);

    var stub = PostgresIndexCatalogStub{
        .columns_rows = &pg_idx_columns_rows,
        .degraded_rows = &pg_idx_degraded_rows,
        .without_pg_am = true,
    };

    var indexes = try getPostgresIndexes(allocator, stub.asDriver(), "pg_idx_doc");
    defer freeExistingIndexes(allocator, &indexes);

    // The gate, then the read that goes without the access-method join: the
    // statement joining `pg_am` is never sent, which is the point — sending it
    // would be refused, and a refused statement leaves the migration's
    // transaction unusable. Nothing else was asked.
    try std.testing.expectEqual(@as(usize, 1), stub.probes);
    try std.testing.expectEqual(@as(usize, 2), stub.queries);
    try std.testing.expectEqual(@as(usize, 0), stub.unmatched);

    // The names and the uniqueness flags survive — they need no access method.
    try std.testing.expectEqual(@as(usize, 2), indexes.items.len);
    try std.testing.expectEqualStrings("idx_pg_idx_doc_pair", indexes.items[0].name);
    try std.testing.expectEqualStrings("idx_pg_idx_doc_title", indexes.items[1].name);
    try std.testing.expect(!indexes.items[0].unique);
    try std.testing.expect(!indexes.items[1].unique);

    // The key lists do not: an unknown access method is not `btree`, so every
    // index comes back not comparable with no keys rather than compared against
    // the declared list.
    for (indexes.items) |idx| {
        try std.testing.expect(!idx.columns_comparable);
        try std.testing.expectEqual(@as(usize, 0), idx.columns.len);
    }

    // And the name is what the planner decides on: an index the catalog knows
    // is not emitted as `CREATE INDEX` again, which is the false "missing
    // index" this degradation exists to prevent.
    try std.testing.expect(indexExists(indexes.items, "idx_pg_idx_doc_pair"));

    // Exactly one line, naming the table and why the key lists cannot be
    // compared — not one per index.
    try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences("no `pg_am`"));
    try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences("not listed in its catalog"));
    try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences("pg_idx_doc"));
    try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences("are not compared"));

    // The retry is still behind the gate, for the shape where the server says
    // `pg_am` is listed and refuses the query anyway — and with the refusal
    // spelled the way PostgreSQL's driver actually spells it: SQLSTATE 42P01
    // becomes `error.DriverFailed` through `toDriverError`'s `else` arm, so a
    // retry that only knew `.client` would never fire against a real server.
    // One `DriverFailed` is not a reason to give up — the retry is the test.
    WarnCapture.reset();
    var pg_shaped = PostgresIndexCatalogStub{
        .degraded_rows = &pg_idx_degraded_rows,
        .without_pg_am = true,
        // Listed, so the gate selects the full read, and the server refuses it.
        .lists_access_method = true,
        .refuse_error = error.DriverFailed,
    };
    var pg_shaped_indexes = try getPostgresIndexes(allocator, pg_shaped.asDriver(), "pg_idx_doc");
    defer freeExistingIndexes(allocator, &pg_shaped_indexes);

    try std.testing.expectEqual(@as(usize, 1), pg_shaped.probes);
    // The gate, the refused full read, then the retry: three statements, and
    // the third is the one that answered.
    try std.testing.expectEqual(@as(usize, 3), pg_shaped.queries);
    try std.testing.expectEqual(@as(usize, 2), pg_shaped_indexes.items.len);
    try std.testing.expect(indexExists(pg_shaped_indexes.items, "idx_pg_idx_doc_pair"));
    for (pg_shaped_indexes.items) |idx| {
        try std.testing.expect(!idx.columns_comparable);
        try std.testing.expectEqual(@as(usize, 0), idx.columns.len);
    }
    // Named this time, because there was an error to name — the line says
    // something different on the gate's path and the same thing on both.
    try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences("no `pg_am`"));
    try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences("(DriverFailed)"));

    // The whole drift report agrees: the declared index is present by name and
    // its key list is simply not compared, so nothing at all is reported. A
    // comparable answer here would have produced an `index_columns` drift (the
    // stub's key count is 2, the schema's too, but a *reported* drift would
    // mean the comparison ran, which is the guess this refuses).
    WarnCapture.reset();
    const drifts = try checkSchema(allocator, stub.asDriver(), infos);
    defer freeSchemaDrift(allocator, drifts);
    try std.testing.expectEqual(@as(usize, 0), drifts.len);
}

test "a server with no index catalog at all answers one named error" {
    const allocator = std.testing.allocator;

    WarnCapture.reset();
    zent_log.setSink(WarnCapture.sink);
    defer zent_log.setSink(null);

    // Both spellings of the refusal, because a server that has no catalog at
    // all refuses every statement either way.
    for ([_]sql_driver.Error{ error.ExecFailed, error.DriverFailed }) |refusal| {
        WarnCapture.reset();
        var stub = PostgresIndexCatalogStub{ .refuse_all = true, .refuse_error = refusal };

        try std.testing.expectError(
            error.IndexCatalogUnavailable,
            getPostgresIndexes(allocator, stub.asDriver(), "pg_idx_doc"),
        );

        // The gate was asked and refused too, so the read it fell back to was
        // the only other statement — and exactly one line was emitted: the
        // degradation warning is for a read that *worked*.
        try std.testing.expectEqual(@as(usize, 1), stub.probes);
        try std.testing.expectEqual(@as(usize, 2), stub.queries);
        try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences("no PostgreSQL index catalog"));
        try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences("pg_idx_doc"));
        try std.testing.expectEqual(@as(usize, 0), WarnCapture.occurrences("no `pg_am`"));
    }
}

/// `information_schema.columns` rows for the foreign-key case below: one row per
/// column the child declares, so `checkSchema` reaches the foreign-key half —
/// that half runs only for a table the database already has.
const pg_fk_columns_rows = [_]CatalogStubRow{
    .{ .text = &.{ "id", "integer", "NO" } },
    .{ .text = &.{ "parent_id", "integer", "NO" } },
    .{ .text = &.{ "title", "text", "NO" } },
};

/// The child of the foreign-key case: a `From` edge with an explicit column, so
/// the graph carries a declared key whose presence `checkSchema` asks about.
const PgFkSchemas = struct {
    const field = @import("../../core/field.zig");
    const edge = @import("../../core/edge.zig");
    const Schema = @import("../../core/schema.zig").Schema;

    const Parent = Schema("PgFkParent", .{
        .table_name = "pg_fk_parent",
        .fields = &.{ field.Int("id"), field.String("name") },
    });
    const Child = Schema("PgFkChild", .{
        .table_name = "pg_fk_child",
        .fields = &.{ field.Int("id"), field.Int("parent_id"), field.String("title") },
        .edges = &.{edge.From("parent", Parent).Field("parent_id")},
    });
};

test "a server without pg_proc reports no foreign key rather than a missing one" {
    // `generate_subscripts` is what makes the foreign-key read one statement,
    // and it lives in `pg_proc` — a catalog a wire-compatible server is not
    // obliged to carry (HeliosDB Nano answers 0 for it, and refuses the
    // statement that would have used it). The read is therefore gated, and the
    // gate's two answers are pinned against each other: with the catalog the
    // declared key is reported missing (the stub has no `pg_constraint` answer),
    // without it the same schema is *not* reported, because "unknown" must never
    // reach the planner as "absent" — that is how a duplicate `ADD CONSTRAINT`
    // gets planned.
    const allocator = std.testing.allocator;
    const buildGraph = @import("../../codegen/graph.zig").buildGraph;

    const infos = comptime buildGraph(&.{ PgFkSchemas.Parent, PgFkSchemas.Child }).types;

    WarnCapture.reset();
    zent_log.setSink(WarnCapture.sink);
    defer zent_log.setSink(null);

    // `pg_proc` not listed: the foreign-key statement is never sent, and the
    // declared key is left alone.
    var gated = PostgresIndexCatalogStub{
        .columns_rows = &pg_fk_columns_rows,
        .lists_pg_proc = false,
    };
    const quiet = try checkSchema(allocator, gated.asDriver(), infos);
    defer freeSchemaDrift(allocator, quiet);

    for (quiet) |d| try std.testing.expect(d.kind != .missing_foreign_key);
    try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences("does not list `pg_proc`"));
    try std.testing.expectEqual(@as(usize, 0), gated.unmatched);

    // Listed: the same read runs, the stub's empty answer is "no such key", and
    // that is the drift the pair above is the exception to.
    WarnCapture.reset();
    var open = PostgresIndexCatalogStub{ .columns_rows = &pg_fk_columns_rows };
    const loud = try checkSchema(allocator, open.asDriver(), infos);
    defer freeSchemaDrift(allocator, loud);

    var missing: usize = 0;
    for (loud) |d| {
        if (d.kind == .missing_foreign_key) missing += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), missing);
    try std.testing.expectEqual(@as(usize, 0), WarnCapture.occurrences("does not list `pg_proc`"));
    try std.testing.expectEqual(@as(usize, 1), open.unmatched);
}

// ------------------------------------------------------------------
// Column-level type degradation: warning where the index path already did
// ------------------------------------------------------------------

test "declaredTypeRewrite answers only for a declaration this dialect cannot emit" {
    const vector = ColumnDef{
        .name = "embedding",
        .sql_type = "TEXT",
        .logical_type = .vector,
        .vector_sql = field_mod.vectorSQL(3),
    };
    // PostgreSQL gets the declared type, so nothing is rewritten there.
    try std.testing.expect(declaredTypeRewrite(vector, Dialect.postgres) == null);
    const on_sqlite = declaredTypeRewrite(vector, Dialect.sqlite).?;
    try std.testing.expectEqualStrings("vector(3)", on_sqlite.declared);
    try std.testing.expectEqualStrings("TEXT", on_sqlite.emitted);
    const on_mysql = declaredTypeRewrite(vector, Dialect.mysql).?;
    try std.testing.expectEqualStrings("vector(3)", on_mysql.declared);
    try std.testing.expectEqualStrings("TEXT", on_mysql.emitted);

    // `.SqlType(s)` / `field.Other(name, s)`: emitted verbatim on PostgreSQL,
    // dropped for the field kind's mapping everywhere else — so it is a
    // rewrite on two dialects and none on the third.
    const override = ColumnDef{
        .name = "handle",
        .sql_type = "TEXT",
        .logical_type = .text,
        .sql_type_override = "citext",
    };
    try std.testing.expect(declaredTypeRewrite(override, Dialect.postgres) == null);
    try std.testing.expectEqualStrings("citext", declaredTypeRewrite(override, Dialect.mysql).?.declared);
    try std.testing.expectEqualStrings("citext", declaredTypeRewrite(override, Dialect.sqlite).?.declared);

    // A kind mapping is *not* a rewrite: `field.String` is TEXT on
    // PostgreSQL/SQLite and VARCHAR(255) on MySQL, `field.Json` is JSONB or
    // TEXT — the schema declared a kind and the dialect rendered it. Warning
    // here would warn on every schema.
    const plain = ColumnDef{ .name = "name", .sql_type = "TEXT", .logical_type = .string };
    try std.testing.expect(declaredTypeRewrite(plain, Dialect.postgres) == null);
    try std.testing.expect(declaredTypeRewrite(plain, Dialect.mysql) == null);
    try std.testing.expect(declaredTypeRewrite(plain, Dialect.sqlite) == null);
    const json_col = ColumnDef{ .name = "doc", .sql_type = "TEXT", .logical_type = .json };
    try std.testing.expect(declaredTypeRewrite(json_col, Dialect.postgres) == null);
    try std.testing.expect(declaredTypeRewrite(json_col, Dialect.sqlite) == null);
    const bytes = ColumnDef{ .name = "payload", .sql_type = "BLOB", .logical_type = .bytes };
    try std.testing.expect(declaredTypeRewrite(bytes, Dialect.postgres) == null);
    // A hand-built descriptor with neither an override nor a vector kind has
    // nothing declared *as a type*, so there is nothing to report either.
    const synthetic = ColumnDef{ .name = "id", .sql_type = "INTEGER", .logical_type = .int };
    try std.testing.expect(declaredTypeRewrite(synthetic, Dialect.sqlite) == null);

    // A `field.Vector` whose dimension was not declared is still a declared
    // vector type: `field.sqlType`'s `.vector` arm spells it `TEXT`, and the
    // warning should say `vector` rather than stay silent about it.
    const dimless = ColumnDef{ .name = "v", .sql_type = "TEXT", .logical_type = .vector };
    try std.testing.expectEqualStrings("vector", declaredTypeRewrite(dimless, Dialect.sqlite).?.declared);

    // A declaration that *is* what gets emitted stays silent even when the kind
    // could not have been: a hand-built `sql_type` equal to the override.
    const equal = ColumnDef{ .name = "x", .sql_type = "citext", .sql_type_override = "citext" };
    try std.testing.expect(declaredTypeRewrite(equal, Dialect.sqlite) == null);
}

test "warnDegradedColumnTypes names table, column and both types, once per column" {
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const buildGraph = @import("../../codegen/graph.zig").buildGraph;

    const Doc = schema("ZentDegradedDoc", .{
        .fields = &.{
            field.Int("id"),
            field.Vector("embedding", 1536),
            field.Text("handle").SqlType("citext"),
            // The control: a plain string is a mapping, not a degradation, and
            // must not be reported beside the two that are.
            field.String("title"),
        },
    });
    const graph = comptime buildGraph(&.{Doc});
    const table = comptime tableFromTypeInfo(graph.types[0]);

    WarnCapture.reset();
    zent_log.setSink(WarnCapture.sink);
    defer zent_log.setSink(null);

    // MySQL: two declared types it has no column type for.
    warnDegradedColumnTypes(table, Dialect.mysql);
    try std.testing.expectEqual(@as(usize, 2), WarnCapture.occurrences(" declares the "));
    try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences(
        "zent_degraded_doc.embedding declares the vector(1536) type, which MySQL has no column type for, so the column is emitted as TEXT",
    ));
    try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences(
        "zent_degraded_doc.handle declares the citext type, which MySQL has no column type for, so the column is emitted as TEXT",
    ));
    // The consequence is stated, not just the difference.
    try std.testing.expectEqual(@as(usize, 2), WarnCapture.occurrences("stored and read as text"));
    try std.testing.expectEqual(@as(usize, 0), WarnCapture.occurrences("zent_degraded_doc.title"));

    // SQLite: the same two, spelled with the dialect it is — and each line
    // still names its own column, so the two are told apart rather than
    // counted together.
    WarnCapture.reset();
    warnDegradedColumnTypes(table, Dialect.sqlite);
    try std.testing.expectEqual(@as(usize, 2), WarnCapture.occurrences(" declares the "));
    try std.testing.expectEqual(@as(usize, 2), WarnCapture.occurrences("which SQLite has no column type for"));
    try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences(
        "zent_degraded_doc.embedding declares the vector(1536) type, which SQLite has no column type for, so the column is emitted as TEXT",
    ));
    try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences(
        "zent_degraded_doc.handle declares the citext type, which SQLite has no column type for, so the column is emitted as TEXT",
    ));

    // PostgreSQL: the declared types are what it creates, so it says nothing.
    WarnCapture.reset();
    warnDegradedColumnTypes(table, Dialect.postgres);
    try std.testing.expectEqual(@as(usize, 0), WarnCapture.occurrences(" declares the "));
}

test "migrateSchema warns once per degraded column, vector and .SqlType override alike (SQLite)" {
    // The wiring, end to end: the warn is emitted by the migration entry point
    // once per table (structurally, like `warnOutOfGraphEdgeRefs`), even though
    // the planner rebuilds the table definition in both of its steps — and the
    // DDL that results really is the type the line describes, for both shapes a
    // declaration can take: `field.Vector`'s kind and a `.SqlType(…)` override.
    const allocator = std.testing.allocator;
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const buildGraph = @import("../../codegen/graph.zig").buildGraph;

    const Doc = schema("ZentVectorDoc", .{
        .fields = &.{
            field.Int("id"),
            field.Vector("embedding", 3),
            field.Text("handle").SqlType("citext"),
            field.String("title"),
        },
    });
    const graph = comptime buildGraph(&.{Doc});
    const infos = graph.types;

    WarnCapture.reset();
    zent_log.setSink(WarnCapture.sink);
    defer zent_log.setSink(null);

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    try migrateSchema(allocator, drv.asDriver(), infos);

    try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences(
        "zent_vector_doc.embedding declares the vector(3) type, which SQLite has no column type for, so the column is emitted as TEXT",
    ));
    // The override is rewritten on this dialect too — `citext` becomes the
    // kind's `TEXT` — and that rewrite is reported the same way, which is the
    // half `columnSQLType` documents as "PostgreSQL only".
    try std.testing.expectEqual(@as(usize, 1), WarnCapture.occurrences(
        "zent_vector_doc.handle declares the citext type, which SQLite has no column type for, so the column is emitted as TEXT",
    ));
    // Exactly the two: the plain string column beside them is a kind mapping,
    // not a degradation, and the migration's other warnings have nothing to say.
    try std.testing.expectEqual(@as(usize, 2), WarnCapture.occurrences(" declares the "));

    // What the warnings claim is what the table got — `citext` is *not* the
    // column's type here, and would not have been even before this warning
    // existed.
    var meta = try drv.query(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'zent_vector_doc'",
        &.{},
    );
    defer meta.deinit();
    const row = meta.next() orelse return error.NoTableRow;
    const ddl = row.getText(0).?;
    try std.testing.expect(std.mem.indexOf(u8, ddl, "\"embedding\" TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "\"handle\" TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "citext") == null);

    // Re-running is a no-op for the schema and still exactly two lines — the
    // dedup is per migration run, not tracked state that could drift.
    WarnCapture.reset();
    try migrateSchema(allocator, drv.asDriver(), infos);
    try std.testing.expectEqual(@as(usize, 2), WarnCapture.occurrences(" declares the "));
}
