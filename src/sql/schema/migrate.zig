const std = @import("std");
const field_mod = @import("../../core/field.zig");
const TypeInfo = @import("../../codegen/graph.zig").TypeInfo;
const FieldInfo = @import("../../codegen/graph.zig").FieldInfo;
const EdgeInfo = @import("../../codegen/graph.zig").EdgeInfo;
const Dialect = @import("../dialect.zig").Dialect;
const sql_driver = @import("../driver.zig");
const Value = @import("../builder.zig").Value;

extern fn time(time_t: [*c]c_long) c_long;

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
/// Current Unix timestamp in seconds.
/// Uses libc `time()` because Zig 0.17 removed `std.time.timestamp()`;
/// `applied_at` is informational and not used by migration logic.
fn unixTimestamp() i64 {
    return @as(i64, @intCast(time(null)));
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
    /// `ownsIndexDetail` is the single place that decides which is which. Every
    /// other kind leaves it empty.
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
        /// `migrateSchema` never adds one — an `ALTER TABLE ADD CONSTRAINT`
        /// against a table that already holds rows can fail, and it is
        /// deliberately non-destructive — so a table created before the edge
        /// existed never gets the constraint, and every dangling reference the
        /// application expects the database to reject is accepted.
        ///
        /// Compared **by shape, never by name**: PostgreSQL and MySQL invent the
        /// names (`t_col_fkey`, `t_ibfk_1`) and SQLite keeps none at all.
        /// `ON DELETE` / `ON UPDATE` are **not** compared (see `checkSchema`).
        ///
        /// The reverse direction — a foreign key the database has and the schema
        /// does not — is deliberately **not** reported; see `checkSchema`.
        missing_foreign_key,
    };

    /// Whether this drift makes a *read* fail — the kinds worth blocking a
    /// deploy over, as opposed to cosmetic agreement.
    ///
    /// A missing table, column or **view** fails every query that mentions it
    /// (the failure mode behind "the endpoint quietly returned an empty list for
    /// months"), and a column the database makes nullable while the schema
    /// declares it non-optional fails on the first row that actually holds a
    /// NULL. A view whose relation is absent is grouped with the first of those
    /// and not with the constraints below: `SELECT … FROM the_view` does not
    /// return fewer rows, it errors outright — so `read_breaking_only` must
    /// catch it, exactly as it catches `missing_table`. An extra column and a
    /// type difference do not fail reads by themselves.
    ///
    /// None of the four constraint kinds does either: a different key list
    /// changes how fast a query runs, a different uniqueness changes whether a
    /// *write* is rejected, a missing column constraint changes whether a
    /// duplicate is rejected, and a missing foreign key changes whether an
    /// orphan is rejected — a read returns the rows it always returned. So none
    /// of them may fail `DriftStrictness.read_breaking_only`: that mode exists
    /// to stop a deploy that would break reads, and widening it into "every
    /// constraint must match" would convert a performance note, or a write that
    /// now fails loudly, into an outage. They fail only under `.any`.
    pub fn breaksReads(self: SchemaDrift) bool {
        return switch (self.kind) {
            .missing_table, .missing_column, .missing_view => true,
            .nullability => !self.schema_optional and self.db_nullable,
            .extra_column,
            .type_mismatch,
            .index_columns,
            .index_uniqueness,
            .unique_constraint,
            .missing_foreign_key,
            => false,
        };
    }
};

/// Every entity, compared against the live database: a missing table, a missing
/// or extra column, a type or nullability difference, a **column** the schema
/// declares UNIQUE with nothing enforcing it, a **foreign key** the schema
/// declares the database does not have, a **view** the schema declares with no
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
/// and neither are `ON DELETE` / `ON UPDATE`, which `migrateSchema` does not
/// converge and this does not read: **the actions are not compared at all.**
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
    errdefer drifts.deinit();
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
                        // exactly this comparison (the ALTER TYPE path uses it).
                        var schema_buf: [128]u8 = undefined;
                        var db_buf: [128]u8 = undefined;
                        const schema_norm = try normalizeTypeForCompare(allocator, columnSQLType(col, dialect), &schema_buf);
                        defer schema_norm.deinit(allocator);
                        const db_norm = try normalizeTypeForCompare(allocator, db_col.sql_type, &db_buf);
                        defer db_norm.deinit(allocator);
                        if (!std.mem.eql(u8, schema_norm.text, db_norm.text)) {
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
                    try drifts.append(.{
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
                    var existing_idxs = try getExistingIndexes(allocator, driver, table.name);
                    defer freeExistingIndexes(allocator, &existing_idxs);

                    if (comptime info.indexes.len > 0) {
                        inline for (info.indexes) |idx| {
                            if (getExistingIndexByName(existing_idxs.items, idx.name)) |db_idx| {
                                if (db_idx.columns_comparable and !columnsEqual(db_idx.columns, idx.columns)) {
                                    try drifts.append(.{
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
                                    try drifts.append(.{
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

            // Foreign keys the schema declares and the database does not have.
            // Shape, not name (see `foreignKeyPresent`), and only in that
            // direction: a constraint the database has and the schema does not
            // can only reject writes the schema never promised, so reporting it
            // would turn a table somebody hardened by hand into a red deploy.
            if (comptime table.foreign_keys.len > 0) {
                if (existing.items.len > 0) {
                    var existing_fks = try getExistingForeignKeys(allocator, driver, table.name);
                    defer freeExistingForeignKeys(allocator, &existing_fks);

                    inline for (table.foreign_keys) |fk| {
                        if (!foreignKeyPresent(existing_fks.items, fk)) {
                            try drifts.append(.{
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
    return drifts.toOwnedSlice();
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
/// runtime. `.unique_constraint` and `.missing_view` point the field at a
/// `const` literal instead and must not be freed; every other kind leaves it
/// empty.
fn ownsIndexDetail(kind: SchemaDrift.Kind) bool {
    return switch (kind) {
        .index_columns, .index_uniqueness, .missing_foreign_key => true,
        else => false,
    };
}

/// Frees the slice, the `.extra_column` names it duplicated, and the detail
/// carried by the kinds `ownsIndexDetail` names; every other entry borrows from
/// `infos` or from comptime literals (see `SchemaDrift.column_owned` /
/// `SchemaDrift.index_detail`).
pub fn freeSchemaDrift(allocator: std.mem.Allocator, drifts: []SchemaDrift) void {
    for (drifts) |d| {
        if (d.column_owned) allocator.free(d.column);
        if (ownsIndexDetail(d.kind)) allocator.free(d.index_detail);
    }
    allocator.free(drifts);
}

/// Assert that the schema and the database agree, for a startup step or a CI
/// job (`migrateSchema`'s own report never runs for a consumer whose DDL is a
/// set of `.sql` files).
pub fn assertSchema(
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
    comptime infos: []const TypeInfo,
    strictness: DriftStrictness,
) (sql_driver.Error || error{ SchemaDrift, UnsupportedDialect, InvalidTableName })!void {
    const drifts = try checkSchema(allocator, driver, infos);
    defer freeSchemaDrift(allocator, drifts);
    for (drifts) |d| {
        if (strictness == .read_breaking_only and !d.breaksReads()) continue;
        std.log.warn("zent: schema drift on {s}.{s}: {s}{s}{s}", .{
            d.table,
            if (d.column.len > 0)
                d.column
            else if (d.index_name.len > 0)
                d.index_name
            else if (d.kind == .missing_view)
                "(view)"
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

pub const NullabilityError = sql_driver.Error || error{ NullabilityDrift, UnsupportedDialect, InvalidTableName };

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
        std.log.debug(
            "zent: nullability drift on {s}.{s}: schema says {s}, database says {s}",
            .{
                d.table,
                d.column,
                if (d.schema_optional) "NULL allowed" else "NOT NULL",
                if (d.db_nullable) "NULL allowed" else "NOT NULL",
            },
        );
    }
    std.log.warn(
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
/// Each caller passes exactly what its statement contains:
/// `createTableSQLAlloc` passes the table's columns and no indexes (a table
/// statement never emits `table.indexes`, and rejecting a table that already
/// exists because of an index it will not create would turn a no-op into a
/// failed deploy), and `createIndexSQLForTableAlloc` passes the one index it
/// is about to emit. That keeps the check honest about the SQL it precedes.
pub fn findMySqlTextRestriction(table: TableDef, indexes: []const IndexDef, dialect: Dialect) ?MySqlTextRestriction {
    if (!std.mem.eql(u8, dialect.name, "mysql")) return null;

    for (table.columns) |col| {
        const sql_type = columnSQLType(col, dialect);
        if (!isMySqlBlobTextJsonType(sql_type)) continue;
        const kind: MySqlTextRestriction.Kind = if (col.default_value != null)
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

/// Log what the error name cannot carry — which table, which column, which
/// type, and why MySQL refuses — and return the matching named error.
///
/// `warn` and not `err`, so a consumer whose log handling treats `err` as
/// fatal does not die on a diagnostic the caller is about to see as a returned
/// error anyway.
fn reportMySqlTextRestriction(restriction: MySqlTextRestriction) MySqlTextError {
    switch (restriction.kind) {
        .default_value => std.log.warn(
            "zent: MySQL rejects a DEFAULT on {s}.{s} ({s}, errno 1101: BLOB/TEXT/JSON cannot have a default value); use field.String (VARCHAR(255) on MySQL) or drop the default",
            .{ restriction.table, restriction.column, restriction.sql_type },
        ),
        .unique => std.log.warn(
            "zent: MySQL cannot index {s}.{s} ({s}, errno 1170: BLOB/TEXT/JSON key specification without a key length), so its UNIQUE constraint has no DDL; use field.String (VARCHAR(255) on MySQL) or drop the uniqueness",
            .{ restriction.table, restriction.column, restriction.sql_type },
        ),
        .primary_key => std.log.warn(
            "zent: MySQL cannot index {s}.{s} ({s}, errno 1170: BLOB/TEXT/JSON key specification without a key length), so it cannot be a PRIMARY KEY; use field.String or a narrower type",
            .{ restriction.table, restriction.column, restriction.sql_type },
        ),
        .index => std.log.warn(
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
    const suffix: []const u8 = if (std.mem.eql(u8, dialect.name, "postgres"))
        " ON CONFLICT (version) DO NOTHING"
    else if (std.mem.eql(u8, dialect.name, "mysql"))
        ""
    else
        " ON CONFLICT (version) DO NOTHING";
    const mysql_suffix: []const u8 = if (std.mem.eql(u8, dialect.name, "mysql"))
        " ON DUPLICATE KEY UPDATE applied_at = applied_at"
    else
        "";
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
    const name = drv.dialect().name;
    if (std.mem.eql(u8, name, "sqlite")) return false;

    if (std.mem.eql(u8, name, "postgres")) {
        var sql_buf: [128]u8 = undefined;
        const sql = std.fmt.bufPrint(&sql_buf, "SELECT pg_try_advisory_lock({d})", .{advisory_lock_key}) catch return false;
        const poll_ms: u32 = 25;
        var waited: u32 = 0;
        while (true) {
            var rows = drv.query(sql, &.{}) catch |err| {
                std.log.warn("zent migrations: pg advisory lock unavailable ({s}); continuing without lock", .{@errorName(err)});
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
    }

    if (std.mem.eql(u8, name, "mysql")) {
        var sql_buf: [160]u8 = undefined;
        // GET_LOCK timeouts are whole seconds; a sub-second request rounds up
        // to 1 so a small test timeout does not become "wait forever".
        const secs: u32 = @max(1, timeout_ms / 1000);
        const sql = std.fmt.bufPrint(&sql_buf, "SELECT GET_LOCK('{s}', {d})", .{ mysql_lock_name, secs }) catch return false;
        var rows = drv.query(sql, &.{}) catch |err| {
            std.log.warn("zent migrations: MySQL GET_LOCK unavailable ({s}); continuing without lock", .{@errorName(err)});
            return false;
        };
        defer rows.deinit();
        const row = rows.next() orelse return false;
        if (row.getInt(0)) |v| {
            if (v == 1) return true;
            if (v == 0) return error.MigrationLockTimeout;
        }
        std.log.warn("zent migrations: MySQL GET_LOCK returned NULL; continuing without lock", .{});
        return false;
    }

    // Unknown dialect: no external lock (same reasoning as SQLite).
    return false;
}

/// Best-effort release of the lock taken by `lockMigration`.
fn unlockMigration(drv: sql_driver.Driver) void {
    const name = drv.dialect().name;
    if (std.mem.eql(u8, name, "postgres")) {
        var sql_buf: [128]u8 = undefined;
        const sql = std.fmt.bufPrint(&sql_buf, "SELECT pg_advisory_unlock({d})", .{advisory_lock_key}) catch return;
        _ = drv.exec(sql, &.{}) catch |err| {
            std.log.warn("zent migrations: pg advisory unlock failed ({s})", .{@errorName(err)});
        };
    } else if (std.mem.eql(u8, name, "mysql")) {
        var sql_buf: [160]u8 = undefined;
        const sql = std.fmt.bufPrint(&sql_buf, "SELECT RELEASE_LOCK('{s}')", .{mysql_lock_name}) catch return;
        _ = drv.exec(sql, &.{}) catch |err| {
            std.log.warn("zent migrations: MySQL RELEASE_LOCK failed ({s})", .{@errorName(err)});
        };
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
                    std.log.warn(
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
    primary_key: bool = false,
    not_null: bool = false,
    unique: bool = false,
    default_value: ?[]const u8 = null,
    auto_increment: bool = false,
};

fn columnSQLType(column: ColumnDef, dialect: Dialect) []const u8 {
    if (column.logical_type) |logical_type| {
        return switch (logical_type) {
            inline else => |field_type| field_mod.sqlType(field_type, dialect),
        };
    }
    return column.sql_type;
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
    if (std.mem.eql(u8, dialect.name, "postgres")) return "(EXTRACT(EPOCH FROM now())::bigint)";
    if (std.mem.eql(u8, dialect.name, "mysql")) return "(UNIX_TIMESTAMP())";
    return "(unixepoch())";
}

/// Normalize a SQL type name for dialect-agnostic comparison by:
/// - Lowercasing
/// - Stripping size/precision modifiers: `varchar(255)` → `varchar`
/// - Canonicalizing aliases: `character varying` → `varchar`, `int` → `integer`
/// - Trimming whitespace
fn normalizeSqlType(sql_type: []const u8, buf: []u8) ![]u8 {
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

    if (canonical) |canon| {
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
};

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
        var columns: []const ColumnDef = &.{};

        // Generate columns from fields. DDL uses the physical column name
        // (`StorageKey`), not the Zig field name.
        for (info.fields) |f| {
            const col = ColumnDef{
                .name = f.column_name,
                .sql_type = f.sql_type,
                .logical_type = f.field_type,
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
                // e.g., Car.owner -> User (owner_id column in car table)
                // Column name is edge_name + "_id"
                const fk_col_name = e.name ++ "_id";
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
pub fn junctionTableForEdge(comptime edge: EdgeInfo, comptime source_info: TypeInfo) TableDef {
    comptime {
        const source_table = source_info.table_name;
        const target_table = toSnakeCase(edge.target_name);

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
        const ref1 = if (a_first) source_table else target_table;
        const ref2 = if (a_first) target_table else source_table;

        return TableDef{
            .name = table_name,
            .columns = &.{
                ColumnDef{ .name = col1, .sql_type = "INTEGER", .not_null = true },
                ColumnDef{ .name = col2, .sql_type = "INTEGER", .not_null = true },
            },
            .primary_keys = &.{ col1, col2 },
            .foreign_keys = &.{
                ForeignKeyDef{
                    .columns = &[_][]const u8{col1},
                    .ref_table = ref1,
                    .ref_columns = &[_][]const u8{"id"},
                },
                ForeignKeyDef{
                    .columns = &[_][]const u8{col2},
                    .ref_table = ref2,
                    .ref_columns = &[_][]const u8{"id"},
                },
            },
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
pub fn createTableSQLAlloc(allocator: std.mem.Allocator, table: TableDef, dialect: Dialect) ![]const u8 {
    if (findMySqlTextRestriction(table, &.{}, dialect)) |restriction| {
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
        if (col.auto_increment and std.mem.eql(u8, dialect.name, "postgres")) {
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
                std.mem.eql(u8, dialect.name, "mysql") and
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
pub fn createIndexSQLAlloc(allocator: std.mem.Allocator, index: IndexDef, table_name: []const u8, dialect: Dialect) ![]const u8 {
    var buf = try std.array_list.Managed(u8).initCapacity(allocator, 256);
    defer buf.deinit();

    try buf.appendSlice("CREATE ");
    if (index.unique) try buf.appendSlice("UNIQUE ");
    if (std.mem.eql(u8, dialect.name, "mysql")) {
        try buf.appendSlice("INDEX ");
    } else {
        try buf.appendSlice("INDEX IF NOT EXISTS ");
    }
    try quoteIdentToBuffer(dialect, &buf, index.name);
    try buf.appendSlice(" ON ");
    try quoteIdentToBuffer(dialect, &buf, table_name);
    try buf.appendSlice(" (");

    for (index.columns, 0..) |col, i| {
        if (i > 0) try buf.appendSlice(", ");
        try quoteIdentToBuffer(dialect, &buf, col);
    }
    try buf.appendSlice(")");

    return allocator.dupe(u8, buf.items);
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
pub fn createIndexSQLForTableAlloc(allocator: std.mem.Allocator, index: IndexDef, table: TableDef, dialect: Dialect) ![]const u8 {
    if (findMySqlTextRestriction(table, &.{index}, dialect)) |restriction| {
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

    if (std.mem.eql(u8, dialect.name, "sqlite3")) {
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
fn createTables(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, comptime infos: []const TypeInfo) !void {
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
            const sql = try createTableSQLAlloc(allocator, table, dialect);
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
                const jtable = comptime junctionTableForEdge(e, info);
                const sql = try createTableSQLAlloc(allocator, jtable, dialect);
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
    try createTables(allocator, driver_drv, infos);

    inline for (infos) |info| {
        if (info.is_view or info.indexes.len == 0) continue;

        var existing_mysql_indexes: ?std.array_list.Managed(ExistingIndex) = null;
        if (std.mem.eql(u8, dialect.name, "mysql")) {
            existing_mysql_indexes = getExistingIndexes(allocator, driver_drv, info.table_name) catch |err| switch (err) {
                error.UnsupportedDialect => unreachable, // The dialect was checked immediately above.
                error.InvalidTableName => unreachable, // SQLite-only, and the dialect was checked immediately above.
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
            const idx_def = IndexDef{
                .name = idx.name,
                .columns = idx.columns,
                .unique = idx.unique,
            };
            const already_exists = if (existing_mysql_indexes) |indexes|
                indexExists(indexes.items, idx_def.name)
            else
                false;
            if (!already_exists) {
                const sql = try createIndexSQLForTableAlloc(allocator, idx_def, table, dialect);
                defer allocator.free(sql);
                _ = try driver_drv.exec(sql, &.{});
            }
        }
    }
}

/// Like tableFromTypeInfo, but also adds FK columns from cross-referenced To edges.
/// For example, if User has a To("cars", Car) O2M edge, this adds a "user_id" FK column
/// to the Car table pointing back to User.
fn tableFromTypeInfoCrossRef(comptime info: TypeInfo, comptime all_infos: []const TypeInfo) TableDef {
    comptime {
        var columns: []const ColumnDef = &.{};
        var foreign_keys: []const ForeignKeyDef = &.{};

        // Generate columns from fields. DDL uses the physical column name
        // (`StorageKey`), not the Zig field name.
        for (info.fields) |f| {
            const col = ColumnDef{
                .name = f.column_name,
                .sql_type = f.sql_type,
                .logical_type = f.field_type,
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
                const fk_col_name = e.name ++ "_id";
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

                const fk = ForeignKeyDef{
                    .columns = &[_][]const u8{fk_col_name},
                    .ref_table = toSnakeCase(e.target_name),
                    .ref_columns = &[_][]const u8{"id"},
                };
                foreign_keys = foreign_keys ++ &[_]ForeignKeyDef{fk};
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
                                .ref_columns = &[_][]const u8{"id"},
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
    const quote: u8 = if (std.mem.eql(u8, dialect.name, "mysql")) '`' else '"';
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
    return std.mem.eql(u8, dialect.name, "sqlite3");
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

fn toSnakeCase(name: []const u8) []const u8 {
    comptime {
        var result: []const u8 = "";
        for (name, 0..) |c, i| {
            if (std.ascii.isUpper(c) and i > 0) {
                result = result ++ "_";
            }
            result = result ++ &[_]u8{std.ascii.toLower(c)};
        }
        return result;
    }
}

/// A column as the *database* reports it. Owned: `name` and `sql_type` are
/// allocated, release the list with `freeExistingColumns`.
pub const ExistingColumn = struct {
    name: []const u8,
    sql_type: []const u8,
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
const IntrospectionError = sql_driver.Error || error{ UnsupportedDialect, InvalidTableName };

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

/// The error carries no payload, so the name it refused is logged instead —
/// `warn`, because this is a diagnostic the caller is about to see as a
/// returned error, not a failed statement of its own.
fn reportUnusableSqliteName(pragma: []const u8, table_name: []const u8) void {
    std.log.warn(
        "zent: refusing to build SQLite PRAGMA {s} for table {s} — the name contains a quote or NUL that would end the statement early; rename the table or reach it through a dialect that binds the name",
        .{ pragma, table_name },
    );
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

    const dialect = driver_drv.dialect();
    const is_sqlite = std.mem.eql(u8, dialect.name, "sqlite3");
    const is_postgres = std.mem.eql(u8, dialect.name, "postgres");
    const is_mysql = std.mem.eql(u8, dialect.name, "mysql");

    if (is_sqlite and !sqlitePragmaNameUsable(table_name)) {
        reportUnusableSqliteName("table_info", table_name);
        return error.InvalidTableName;
    }

    const sql_text = if (is_sqlite)
        try std.fmt.allocPrint(allocator, "PRAGMA table_info(\"{s}\")", .{table_name})
    else if (is_postgres)
        try allocator.dupe(u8, "SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_name = $1 AND table_schema = current_schema()")
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
        const not_null = if (is_sqlite)
            (row.getInt(3) orelse 0) != 0
        else
            std.ascii.eqlIgnoreCase(row.getText(2) orelse "YES", "NO");
        const pk = is_sqlite and (row.getInt(5) orelse 0) != 0;

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_type = try allocator.alloc(u8, sql_type.len);
        errdefer allocator.free(owned_type);
        for (sql_type, owned_type) |byte, *dest| dest.* = std.ascii.toLower(byte);

        try result.append(.{
            .name = owned_name,
            .sql_type = owned_type,
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
    const dialect = driver_drv.dialect();
    if (std.mem.eql(u8, dialect.name, "sqlite3")) return getSQLiteIndexes(allocator, driver_drv, table_name);
    if (std.mem.eql(u8, dialect.name, "postgres")) return getPostgresIndexes(allocator, driver_drv, table_name);
    if (std.mem.eql(u8, dialect.name, "mysql")) return getMySQLIndexes(allocator, driver_drv, table_name);
    return error.UnsupportedDialect;
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
fn getMySQLIndexes(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingIndex) {
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
            try result.append(.{
                .name = try allocator.dupe(u8, name),
                .unique = (row.getInt(1) orelse 1) == 0,
            });
            current = result.items.len - 1;
            comparable = true;
        }
        if (row.getText(2)) |column| {
            try keys.append(try allocator.dupe(u8, column));
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
fn getPostgresIndexes(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingIndex) {
    var result = std.array_list.Managed(ExistingIndex).init(allocator);
    errdefer freeExistingIndexes(allocator, &result);

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

    var rows = try driver_drv.query(sql_text, &.{.{ .string = table_name }});
    defer rows.deinit();

    var keys = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit();
    }

    var current: ?usize = null;
    var comparable = true;
    var expected_keys: i64 = 0;
    var seen_keys: i64 = 0;
    while (rows.next()) |row| {
        const name = row.getText(0) orelse continue;
        if (current == null or !std.mem.eql(u8, result.items[current.?].name, name)) {
            try closeExistingIndex(&result, current, &keys, comparable and seen_keys == expected_keys);
            try result.append(.{
                .name = try allocator.dupe(u8, name),
                .unique = (row.getInt(1) orelse 0) != 0,
            });
            current = result.items.len - 1;
            comparable = (row.getInt(2) orelse 0) != 0 // indisvalid
            and (row.getInt(3) orelse 1) == 0 // indpred IS NULL
            and (row.getInt(4) orelse 1) == 0 // indnatts == indnkeyatts (no INCLUDE)
            and std.mem.eql(u8, row.getText(6) orelse "", "btree");
            expected_keys = row.getInt(5) orelse 0;
            seen_keys = 0;
        }
        seen_keys += 1;
        if (comparable) {
            // A NULL attname is an expression key (attnum 0), which no
            // declared column list can be equal to.
            if (row.getText(7)) |column| {
                try keys.append(try allocator.dupe(u8, column));
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
        const list_sql = try std.fmt.allocPrint(allocator, "PRAGMA index_list(\"{s}\")", .{table_name});
        defer allocator.free(list_sql);
        var rows = try driver_drv.query(list_sql, &.{});
        defer rows.deinit();
        while (rows.next()) |row| {
            const name = row.getText(1) orelse continue;
            // Column 4 is `partial`, available since SQLite 3.16; a partial
            // index has no equivalent in an IndexDef, so it is never compared.
            const partial = row.columnCount() > 4 and (row.getInt(4) orelse 0) != 0;
            try result.append(.{
                .name = try allocator.dupe(u8, name),
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
        const info_sql = try std.fmt.allocPrint(allocator, "PRAGMA index_info({s})", .{quoted.items});
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
            try keys.append(try allocator.dupe(u8, column.?));
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
    const dialect = driver_drv.dialect();
    if (std.mem.eql(u8, dialect.name, "sqlite3")) return getSQLiteForeignKeys(allocator, driver_drv, table_name);
    if (std.mem.eql(u8, dialect.name, "postgres")) return getPostgresForeignKeys(allocator, driver_drv, table_name);
    if (std.mem.eql(u8, dialect.name, "mysql")) return getMySQLForeignKeys(allocator, driver_drv, table_name);
    return error.UnsupportedDialect;
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
            try result.append(.{
                .columns = &.{},
                .ref_table = try allocator.dupe(u8, row.getText(1) orelse ""),
            });
            current = result.items.len - 1;
            comparable = true;
        }
        if (row.getText(0)) |column| {
            try cols.append(try allocator.dupe(u8, column));
        } else {
            comparable = false; // no local column: not a shape to compare
        }
        if (row.getText(2)) |ref_column| {
            try refs.append(try allocator.dupe(u8, ref_column));
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
fn getPostgresForeignKeys(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingForeignKey) {
    var result = std.array_list.Managed(ExistingForeignKey).init(allocator);
    errdefer freeExistingForeignKeys(allocator, &result);

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
            try result.append(.{
                .columns = &.{},
                .ref_table = try allocator.dupe(u8, row.getText(2) orelse ""),
            });
            current = result.items.len - 1;
            comparable = true;
        }
        if (row.getText(1)) |column| {
            try cols.append(try allocator.dupe(u8, column));
        } else {
            comparable = false;
        }
        if (row.getText(3)) |ref_column| {
            try refs.append(try allocator.dupe(u8, ref_column));
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

    const sql_text = try std.fmt.allocPrint(allocator, "PRAGMA foreign_key_list(\"{s}\")", .{table_name});
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
            try result.append(.{
                .columns = &.{},
                .ref_table = try allocator.dupe(u8, row.getText(2) orelse ""),
            });
            current = result.items.len - 1;
            comparable = true;
        }
        if (row.getText(3)) |column| {
            try cols.append(try allocator.dupe(u8, column));
        } else {
            comparable = false;
        }
        if (row.getText(4)) |ref_column| {
            try refs.append(try allocator.dupe(u8, ref_column));
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
    const dialect = driver_drv.dialect();
    if (std.mem.eql(u8, dialect.name, "sqlite3")) return getSQLiteViews(allocator, driver_drv, view_name);
    if (std.mem.eql(u8, dialect.name, "postgres")) return getPostgresViews(allocator, driver_drv, view_name);
    if (std.mem.eql(u8, dialect.name, "mysql")) return getMySQLViews(allocator, driver_drv, view_name);
    return error.UnsupportedDialect;
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
fn alterTableAddColumnSQL(
    allocator: std.mem.Allocator,
    table_name: []const u8,
    col: ColumnDef,
    dialect: Dialect,
    converge_not_null: bool,
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
        .not_null = col.not_null,
        .default_value = col.default_value,
    };
    if (findMySqlTextRestriction(.{ .name = table_name, .columns = &.{emitted}, .primary_keys = &.{} }, &.{}, dialect)) |restriction| {
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
            std.log.warn(
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
    return switch (dialect.name[0]) {
        's' => std.fmt.allocPrint(allocator, "ALTER TABLE \"{s}\" DROP COLUMN \"{s}\"", .{ table_name, column_name }),
        'p' => std.fmt.allocPrint(allocator, "ALTER TABLE \"{s}\" DROP COLUMN \"{s}\" CASCADE", .{ table_name, column_name }),
        'm' => std.fmt.allocPrint(allocator, "ALTER TABLE `{s}` DROP COLUMN `{s}`", .{ table_name, column_name }),
        else => error.UnsupportedDialect,
    };
}

/// `normalizeSqlType` into a caller-provided stack buffer, falling back to the
/// heap when the declared type does not fit.
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
) error{OutOfMemory}!NormalizedType {
    if (normalizeSqlType(sql_type, stack_buf)) |norm| {
        return .{ .text = norm, .owned = null };
    } else |err| switch (err) {
        error.NoSpaceLeft => {},
    }

    const heap = try allocator.alloc(u8, sql_type.len);
    if (normalizeSqlType(sql_type, heap)) |norm| {
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
    return switch (dialect.name[0]) {
        's' => error.UnsupportedDialect,
        'p' => std.fmt.allocPrint(allocator, "ALTER TABLE \"{s}\" ALTER COLUMN \"{s}\" TYPE {s} USING \"{s}\"::{s}", .{ table_name, column_name, new_type, column_name, new_type }),
        'm' => error.MySQLTypeChangeUnsafe,
        else => error.UnsupportedDialect,
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
    return switch (dialect.name[0]) {
        'p' => std.fmt.allocPrint(
            allocator,
            "ALTER TABLE \"{s}\" ALTER COLUMN \"{s}\" {s} NOT NULL",
            .{ table_name, column_name, if (not_null) "SET" else "DROP" },
        ),
        'm' => error.MySQLNullabilityChangeUnsafe,
        else => error.UnsupportedDialect,
    };
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
    const loose = try alterTableAddColumnSQL(alloc, "t", col, Dialect.sqlite, false);
    defer alloc.free(loose);
    try std.testing.expectEqualStrings(
        "ALTER TABLE \"t\" ADD COLUMN \"status\" TEXT DEFAULT 'pending'",
        loose,
    );

    // Opted in: the default is what the rows already in the table take.
    const strict = try alterTableAddColumnSQL(alloc, "t", col, Dialect.sqlite, true);
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
    const audit_sql = try alterTableAddColumnSQL(alloc, "t", audit, Dialect.sqlite, true);
    defer alloc.free(audit_sql);
    try std.testing.expectEqualStrings(
        "ALTER TABLE \"t\" ADD COLUMN \"created_at\" BIGINT NOT NULL DEFAULT (unixepoch())",
        audit_sql,
    );

    // An optional column has nothing to converge: no NOT NULL, no backfill.
    var optional_col = col;
    optional_col.not_null = false;
    optional_col.default_value = null;
    const optional_sql = try alterTableAddColumnSQL(alloc, "t", optional_col, Dialect.sqlite, true);
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
        alterTableAddColumnSQL(std.testing.allocator, "t", col, Dialect.sqlite, true),
    );

    // Without the option the column is still added — the old behaviour is only
    // ever left behind by an explicit decision.
    const sql = try alterTableAddColumnSQL(std.testing.allocator, "t", col, Dialect.sqlite, false);
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

/// Migrate schema: create missing tables, add missing columns, create missing
/// indexes, and — when requested via `opts` — drop orphaned columns, alter
/// column types, and/or converge nullability.
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
///
/// Concurrency: a cross-process advisory lock (`opts.lock_timeout_ms`, see
/// `lockMigration`) is taken before any introspection so two instances
/// deploying at once cannot both pass the "table missing" checks and race on
/// DDL. Checksums are not verified here because schema-diff migrations record
/// NULL; files are verified by `migrateFromFilesWithOptions`.
pub fn migrateSchemaWithOptions(
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
    comptime infos: []const TypeInfo,
    opts: MigrateOptions,
) !void {
    const dialect = driver.dialect();

    // Dry-run: collect all generated SQL and print without executing.
    if (opts.dry_run) {
        var sqls = std.array_list.Managed([]const u8).init(allocator);
        defer {
            for (sqls.items) |s| allocator.free(s);
            sqls.deinit();
        }

        // Each SQL string is owned by `sqls` and freed with `allocator` above;
        // the `*Alloc` helpers allocate from the same allocator.
        // CREATE TABLE for non-view entities.
        inline for (infos) |info| {
            if (!info.is_view) {
                const table = comptime tableFromTypeInfoCrossRef(info, infos);
                try sqls.append(try createTableSQLAlloc(allocator, table, dialect));
            }
        }

        // CREATE VIEW.
        inline for (infos) |info| {
            if (info.is_view) {
                try sqls.append(try createViewSQLAlloc(allocator, info, dialect));
            }
        }

        // M2M junction tables.
        inline for (infos) |info| {
            if (info.is_view) continue;
            inline for (info.edges) |e| {
                if (e.relation == .m2m and e.through == null) {
                    const jtable = comptime junctionTableForEdge(e, info);
                    try sqls.append(try createTableSQLAlloc(allocator, jtable, dialect));
                }
            }
        }

        // CREATE INDEX for non-view entities.
        inline for (infos) |info| {
            if (info.is_view or info.indexes.len == 0) continue;
            const table = comptime tableFromTypeInfoCrossRef(info, infos);
            inline for (info.indexes) |idx| {
                const idx_def = IndexDef{
                    .name = idx.name,
                    .columns = idx.columns,
                    .unique = idx.unique,
                };
                try sqls.append(try createIndexSQLForTableAlloc(allocator, idx_def, table, dialect));
            }
        }

        // Print collected SQL.
        for (sqls.items) |s| {
            std.debug.print("{s};\n", .{s});
        }
        return;
    }

    // Cross-process mutual exclusion: without it, two instances starting at
    // once both see a table/column as missing (TOCTOU on the introspection
    // checks) and race on the same DDL. Held for the whole run; on any error
    // path the `defer` still releases it.
    const lock_held = try lockMigration(driver, opts.lock_timeout_ms);
    defer if (lock_held) unlockMigration(driver);

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

    var tx = try driver.beginTx();
    errdefer tx.deinit();

    // Tx.inner is a Driver value type, so every existing helper that
    // accepts a Driver can run inside the transaction unchanged.
    const tx_drv = tx.inner;

    // Step 1: create tables, views, and M2M junction tables. CREATE TABLE
    // IF NOT EXISTS keeps this safe even on a partial previous run.
    //
    // The schema state (table/column/index existence) is the authoritative
    // gate — we always re-check the database before applying each change.
    // `zent_schema_migrations` is an audit trail: `recordMigration` uses
    // `ON CONFLICT DO NOTHING` / `ON DUPLICATE KEY UPDATE`, so re-recording
    // a version (e.g. after a table was dropped out-of-band) never produces
    // duplicates.
    //
    // When a version is already in `applied`, we still verify the table
    // actually exists: if it was dropped out-of-band, the `applied` entry is
    // stale and we must re-create the table.
    inline for (infos) |info| {
        if (info.is_view) {
            const version = computeMigrationVersion(info.table_name, "create_view", "");
            if (!versionContains(applied, version)) {
                const sql = try createViewSQLAlloc(allocator, info, dialect);
                defer allocator.free(sql);
                _ = try tx_drv.exec(sql, &.{});
                try recordMigration(tx_drv, version, null);
            } else {
                // Version is recorded but the view may have been dropped
                // out-of-band. If the view no longer exists, re-create it.
                var existing = try getExistingColumns(allocator, tx_drv, info.table_name);
                if (existing.items.len == 0) {
                    existing.deinit();
                    const sql = try createViewSQLAlloc(allocator, info, dialect);
                    defer allocator.free(sql);
                    _ = try tx_drv.exec(sql, &.{});
                    try recordMigration(tx_drv, version, null);
                } else {
                    freeExistingColumns(allocator, &existing);
                }
            }
        } else {
            const table = comptime tableFromTypeInfoCrossRef(info, infos);
            const version = computeMigrationVersion(info.table_name, "create_table", "");
            if (!versionContains(applied, version)) {
                const sql = try createTableSQLAlloc(allocator, table, dialect);
                defer allocator.free(sql);
                _ = try tx_drv.exec(sql, &.{});
                try recordMigration(tx_drv, version, null);
            } else {
                // Version is recorded but the table may have been dropped
                // out-of-band. If the table no longer exists, re-create it.
                var existing = try getExistingColumns(allocator, tx_drv, table.name);
                if (existing.items.len == 0) {
                    // Table does not exist — re-create it.
                    existing.deinit();
                    const sql = try createTableSQLAlloc(allocator, table, dialect);
                    defer allocator.free(sql);
                    _ = try tx_drv.exec(sql, &.{});
                    try recordMigration(tx_drv, version, null);
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
                const jtable = comptime junctionTableForEdge(e, info);
                const version = computeMigrationVersion(jtable.name, "create_junction", "");
                if (!versionContains(applied, version)) {
                    const sql = try createTableSQLAlloc(allocator, jtable, dialect);
                    defer allocator.free(sql);
                    _ = try tx_drv.exec(sql, &.{});
                    try recordMigration(tx_drv, version, null);
                } else {
                    // Version is recorded but the junction table may have been
                    // dropped out-of-band. Re-create it if missing.
                    var existing = try getExistingColumns(allocator, tx_drv, jtable.name);
                    if (existing.items.len == 0) {
                        existing.deinit();
                        const sql = try createTableSQLAlloc(allocator, jtable, dialect);
                        defer allocator.free(sql);
                        _ = try tx_drv.exec(sql, &.{});
                        try recordMigration(tx_drv, version, null);
                    } else {
                        freeExistingColumns(allocator, &existing);
                    }
                }
            }
        }
    }

    // Step 2: for each non-view entity, add missing columns and indexes.
    // The live schema (introspected via information_schema / PRAGMA) is
    // the authoritative gate: we always add a column or index if it is
    // absent, even if a prior `zent_schema_migrations` row claimed the
    // work was done. This handles the common case of a table being
    // dropped or truncated out-of-band — the migration must still bring
    // the schema back to the declared shape. The `recordMigration` INSERT
    // itself is idempotent (`ON CONFLICT DO NOTHING`), so re-recording a
    // version never produces duplicate history rows.
    inline for (infos) |info| {
        if (info.is_view) continue;

        const table = comptime tableFromTypeInfoCrossRef(info, infos);

        var existing_cols = try getExistingColumns(allocator, tx_drv, table.name);
        defer freeExistingColumns(allocator, &existing_cols);

        inline for (table.columns) |col| {
            const version = computeMigrationVersion(info.table_name, "add_column", col.name);
            if (!columnExists(existing_cols.items, col.name)) {
                const sql = try alterTableAddColumnSQL(allocator, table.name, col, dialect, opts.allow_nullability_change);
                defer allocator.free(sql);
                _ = try tx_drv.exec(sql, &.{});
                try recordMigration(tx_drv, version, null);
            }
        }

        // Phase 3 Task 12 — DROP COLUMN: remove columns that exist in
        // the database but not in the schema. Guarded by opts.drop_columns
        // to avoid accidental data loss.
        // No version recording: column names are runtime data from
        // introspection, and DROP COLUMN is naturally idempotent
        // (re-running on an already-dropped column is a no-op error
        // that we silently tolerate).
        if (opts.drop_columns) {
            for (existing_cols.items) |existing_col| {
                if (!columnExistsTableDef(table, existing_col.name)) {
                    const sql = try dropColumnSQL(allocator, table.name, existing_col.name, dialect);
                    defer allocator.free(sql);
                    _ = try tx_drv.exec(sql, &.{});
                }
            }
        }

        // Phase 3 Task 12 — ALTER TYPE: change column types that differ
        // between the database and the schema. Guarded by
        // opts.allow_data_loss; SQLite is skipped (unsupported).
        if (opts.allow_data_loss) {
            inline for (table.columns) |col| {
                if (columnExists(existing_cols.items, col.name)) {
                    const existing_col = getExistingColumnByName(existing_cols.items, col.name) orelse unreachable;
                    const schema_type_upper = columnSQLType(col, dialect);
                    var schema_buf: [128]u8 = undefined;
                    var db_buf: [128]u8 = undefined;
                    const schema_norm = try normalizeSqlType(schema_type_upper, &schema_buf);
                    const db_norm = try normalizeSqlType(existing_col.sql_type, &db_buf);

                    if (!std.mem.eql(u8, db_norm, schema_norm)) {
                        // Skip ALTER TYPE on SQLite (unsupported natively).
                        if (dialect.name[0] != 's') {
                            const version = computeMigrationVersion(info.table_name, "alter_type", col.name);
                            if (!versionContains(applied, version)) {
                                const sql = try alterColumnTypeSQL(allocator, table.name, col.name, col.sql_type, dialect);
                                defer allocator.free(sql);
                                _ = try tx_drv.exec(sql, &.{});
                                try recordMigration(tx_drv, version, null);
                            }
                        }
                    }
                }
            }
        }

        // Nullability of an **existing** column. `migrateSchema` used to leave
        // it alone whatever the schema said, so the two stayed disagreed for the
        // life of the deployment; `checkNullability` reports it, and this is the
        // opt-in that fixes it. Gated next to `drop_columns`/`allow_data_loss`
        // because `SET NOT NULL` fails on the rows that already hold a NULL —
        // which way the data goes is the caller's decision.
        //
        // SQLite is skipped: it has no `ALTER COLUMN` at all, so the drift stays
        // and the `check_nullability` report at the end of the run names it.
        if (opts.allow_nullability_change and dialect.name[0] != 's') {
            inline for (table.columns) |col| {
                if (getExistingColumnByName(existing_cols.items, col.name)) |existing_col| {
                    if (db_nullableOf(existing_col) != !col.not_null) {
                        const sql = try alterColumnNullabilitySQL(allocator, table.name, col.name, col.not_null, dialect);
                        defer allocator.free(sql);
                        _ = try tx_drv.exec(sql, &.{});
                    }
                }
            }
        }

        var existing_idxs = try getExistingIndexes(allocator, tx_drv, table.name);
        defer freeExistingIndexes(allocator, &existing_idxs);

        inline for (info.indexes) |idx| {
            const idx_def = IndexDef{
                .name = idx.name,
                .columns = idx.columns,
                .unique = idx.unique,
            };
            if (!indexExists(existing_idxs.items, idx_def.name)) {
                const version = computeMigrationVersion(info.table_name, "create_index", idx.name);
                const sql = try createIndexSQLForTableAlloc(allocator, idx_def, table, dialect);
                defer allocator.free(sql);
                _ = try tx_drv.exec(sql, &.{});
                try recordMigration(tx_drv, version, null);
            }
        }
    }

    try tx.commit();
    tx.deinit();

    if (opts.check_nullability) {
        const drifts = try checkNullability(allocator, driver, infos);
        defer freeNullabilityDrift(allocator, drifts);
        reportNullabilityDrift(drifts);
    }
}

/// Backward-compatible entry point: calls `migrateSchemaWithOptions` with
/// default `MigrateOptions{}` (no drops, no type changes). All existing callers
/// continue to work without modification.
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
    const suffix = try std.fmt.allocPrint(std.heap.page_allocator, ".{s}.sql", .{direction});
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
    return try std.fmt.allocPrint(allocator, "{x:0>8}", .{crc});
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
                try statements.append(try allocator.dupe(u8, stmt));
            }
            start = i + 1;
        }
    }
    const last = std.mem.trim(u8, sql[start..], " \t\r\n");
    if (last.len > 0) {
        try statements.append(try allocator.dupe(u8, last));
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
    const down_name = try std.fmt.allocPrint(allocator, "{s}.down.sql", .{stem});
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
    errdefer tx.deinit();
    const tx_drv = tx.inner;

    for (files) |f| {
        if (versionContains(applied, f.version)) continue;
        try executeMigrationSql(allocator, tx_drv, f.up_sql);
        try recordMigration(tx_drv, f.version, f.checksum);
    }

    try tx.commit();
    tx.deinit();
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
    errdefer tx.deinit();
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
    tx.deinit();
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

test "MySQL ALTER ADD COLUMN refuses a BLOB/TEXT DEFAULT" {
    const mysql = Dialect{ .name = "mysql" };

    // The shape the CREATE-side guard never sees: the table already exists, so
    // `createTableSQLAlloc` is skipped and this ALTER is the only statement
    // that would reach the server — as errno 1101, with no way out named.
    const text_default = ColumnDef{ .name = "body", .sql_type = "TEXT", .default_value = "'x'" };
    try std.testing.expectError(
        error.MySQLTextColumnCannotHaveDefault,
        alterTableAddColumnSQL(std.testing.allocator, "article", text_default, mysql, false),
    );

    // `allow_nullability_change` takes the NOT NULL branch, which emits the
    // same DEFAULT for a different reason; the restriction is the type and the
    // default, and it does not care which branch asked for it.
    const not_null_default = ColumnDef{ .name = "body", .sql_type = "TEXT", .default_value = "'x'", .not_null = true };
    try std.testing.expectError(
        error.MySQLTextColumnCannotHaveDefault,
        alterTableAddColumnSQL(std.testing.allocator, "article", not_null_default, mysql, true),
    );

    // `field.Bytes` is BLOB on MySQL and carries errno 1101 like TEXT does.
    // (`field.JSON` is TEXT there, not MySQL's JSON type — see `field.sqlType`.)
    for ([_][]const u8{ "BLOB", "TINYBLOB", "MEDIUMBLOB", "LONGBLOB", "JSON" }) |sql_type| {
        const blob_default = ColumnDef{ .name = "payload", .sql_type = sql_type, .default_value = "'{}'" };
        try std.testing.expectError(
            error.MySQLTextColumnCannotHaveDefault,
            alterTableAddColumnSQL(std.testing.allocator, "article", blob_default, mysql, false),
        );
    }

    // Everything the server accepts still renders: the guard is about the type
    // carrying a DEFAULT, not about the ALTER.
    const varchar_default = ColumnDef{ .name = "title", .sql_type = "VARCHAR(255)", .default_value = "'t'" };
    const ok = try alterTableAddColumnSQL(std.testing.allocator, "article", varchar_default, mysql, false);
    defer std.testing.allocator.free(ok);
    try std.testing.expectEqualStrings("ALTER TABLE `article` ADD COLUMN `title` VARCHAR(255) DEFAULT 't'", ok);

    // A TEXT column without a default is legal, and is what the schema gets.
    const text_plain = ColumnDef{ .name = "body", .sql_type = "TEXT" };
    const plain = try alterTableAddColumnSQL(std.testing.allocator, "article", text_plain, mysql, false);
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("ALTER TABLE `article` ADD COLUMN `body` TEXT", plain);

    // PostgreSQL and SQLite have no such restriction and must still generate
    // the statement — the check is dialect-gated, not a blanket refusal.
    for ([_]Dialect{ Dialect.sqlite, Dialect.postgres }) |dialect| {
        const sql = try alterTableAddColumnSQL(std.testing.allocator, "article", text_default, dialect, false);
        defer std.testing.allocator.free(sql);
        try std.testing.expectEqualStrings("ALTER TABLE \"article\" ADD COLUMN \"body\" TEXT DEFAULT 'x'", sql);
    }

    // UNIQUE is deliberately not part of this statement (see the note above the
    // return), so the check is not handed it either: a unique TEXT column is
    // added as a TEXT column. What the ALTER would silently not enforce is the
    // constraint — not the DEFAULT this guard exists for — and the CREATE-side
    // guard is where a schema declaring it is refused.
    const unique_text = ColumnDef{ .name = "body", .sql_type = "TEXT", .unique = true };
    const unique_sql = try alterTableAddColumnSQL(std.testing.allocator, "article", unique_text, mysql, false);
    defer std.testing.allocator.free(unique_sql);
    try std.testing.expectEqualStrings("ALTER TABLE `article` ADD COLUMN `body` TEXT", unique_sql);
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
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    const FkOwner = schema("FkOwner", .{ .fields = &.{field.String("name")} });
    const FkCar = schema("FkCar", .{
        .fields = &.{field.String("model")},
        .edges = &.{edge.From("owner", FkOwner)},
    });
    const info = comptime fromSchema(FkCar);
    const infos = &[_]TypeInfo{info};

    // The legacy table: the column the edge generated is there, the constraint
    // is not. This is the shape a table created before the edge existed has, and
    // `migrateSchema` will never add the constraint to it.
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
    // nothing.
    const short = try normalizeTypeForCompare(alloc, "VARCHAR(255)", &schema_buf);
    defer short.deinit(alloc);
    try std.testing.expect(short.owned == null);
    try std.testing.expectEqualStrings("varchar", short.text);

    // A long one is normalized on the heap instead of being skipped.
    const long = try normalizeTypeForCompare(alloc, &long_buf, &schema_buf);
    defer long.deinit(alloc);
    try std.testing.expect(long.owned != null);
    try std.testing.expectEqual(@as(usize, 256), long.text.len);

    // The comparison therefore still happens, and still reports a difference.
    const db = try normalizeTypeForCompare(alloc, "INTEGER", &db_buf);
    defer db.deinit(alloc);
    try std.testing.expect(!std.mem.eql(u8, long.text, db.text));
}
