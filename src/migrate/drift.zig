//! Drift: what the schema declares and the database does not have.
//!
//! One traversal per entity — columns, indexes, foreign keys, junction tables,
//! views — producing `SchemaDrift` values that `assertSchema` can gate a deploy
//! on and `reportNullability` can summarise. Reads nothing itself: it sits on
//! `migrate/introspect.zig` (the catalog) and `migrate/types.zig` (the
//! comparison rules), which is what lets a drift case be tested with a stub
//! driver instead of a database.

const std = @import("std");

const Dialect = @import("../base/dialect.zig").Dialect;
const zent_log = @import("../base/log.zig");
const sql_driver = @import("../sql/driver.zig");
const field_mod = @import("../core/field.zig");
const TypeInfo = @import("../codegen/graph.zig").TypeInfo;
const EdgeInfo = @import("../codegen/graph.zig").EdgeInfo;

const types = @import("types.zig");
const ddl = @import("ddl.zig");
const introspect = @import("introspect.zig");

const ColumnDef = types.ColumnDef;
const TableDef = types.TableDef;
const ForeignKeyDef = types.ForeignKeyDef;
const IndexDef = types.IndexDef;
const normalizeSqlType = types.normalizeSqlType;
const columnSQLType = types.columnSQLType;
const dialectDisplayName = types.dialectDisplayName;
const getExistingColumns = introspect.getExistingColumns;
const getExistingIndexes = introspect.getExistingIndexes;
const getExistingForeignKeys = introspect.getExistingForeignKeys;
const getExistingViews = introspect.getExistingViews;
const freeExistingColumns = introspect.freeExistingColumns;
const freeExistingIndexes = introspect.freeExistingIndexes;
const freeExistingForeignKeys = introspect.freeExistingForeignKeys;
const freeExistingViews = introspect.freeExistingViews;
const ExistingColumn = introspect.ExistingColumn;
const ExistingIndex = introspect.ExistingIndex;
const ExistingForeignKey = introspect.ExistingForeignKey;
const getExistingColumnByName = introspect.getExistingColumnByName;
const getExistingIndexByName = introspect.getExistingIndexByName;
const tableFromTypeInfoCrossRef = ddl.tableFromTypeInfoCrossRef;
const junctionTableForEdge = ddl.junctionTableForEdge;
const edgeRefTarget = ddl.edgeRefTarget;
const edgeFKUsesRefTarget = ddl.edgeFKUsesRefTarget;
const normalizeTypeForCompare = types.normalizeTypeForCompare;
const pgInternalSpelling = types.pgInternalSpelling;
const pgUdtBaseName = types.pgUdtBaseName;
const NormalizedType = types.NormalizedType;
const declaredPgType = types.declaredPgType;
const DeclaredPgType = types.DeclaredPgType;

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
pub fn appendJunctionRelationDrifts(
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
pub fn appendJunctionShapeDrifts(
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
pub fn wantsUniqueColumnCheck(table: TableDef) bool {
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
pub fn uniqueColumnChecked(col: ColumnDef, table: TableDef) bool {
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
pub fn hasUnreadableUniqueIndex(indexes: []const ExistingIndex) bool {
    for (indexes) |idx| {
        if (idx.unique and !idx.columns_comparable) return true;
    }
    return false;
}

/// Whether some unique index forces exactly `column`, and nothing else, to be
/// unique. A composite `UNIQUE (a, b)` does **not**: two rows may share `a`.
pub fn indexForcesColumnAlone(indexes: []const ExistingIndex, column: []const u8) bool {
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
pub fn indexForcesPairAlone(indexes: []const ExistingIndex, a: []const u8, b: []const u8) bool {
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
pub fn foreignKeyPresent(existing: []const ExistingForeignKey, fk: ForeignKeyDef) bool {
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
pub const uniqueColumnDriftDetail = "schema declares the column UNIQUE, database has no unique constraint covering it";

/// The `.missing_view` report in one sentence. A `const` literal — nothing is
/// allocated for this kind (see `ownsIndexDetail`).
///
/// It says the two things the reader has to know and cannot see from the drift
/// kind alone: which statement on the schema side produced the expectation, and
/// the boundary of this check — the definition is never compared, so a stale
/// `view_sql` is invisible *here* even after the view is created.
pub const missingViewDriftDetail = "schema declares the view, database has no relation of that name; view_sql is never compared, so a stale definition is not reported either";

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
pub fn missingJunctionTableDetail(comptime info: TypeInfo, comptime edge: EdgeInfo, comptime all_infos: []const TypeInfo) []const u8 {
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
pub fn junctionNameOwner(comptime infos: []const TypeInfo, comptime jtable: TableDef) ?TypeInfo {
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
pub fn junctionNameCollisionDetail(comptime info: TypeInfo, comptime edge: EdgeInfo, comptime owner: TypeInfo, comptime all_infos: []const TypeInfo) []const u8 {
    comptime {
        return junctionShapeClause(info, edge, all_infos) ++
            ", but that name is the table of the entity " ++ owner.name ++
            " (schema '" ++ owner.name ++ "'); both are created with IF NOT EXISTS and entities are created first, " ++
            "so the junction's CREATE is a no-op and the relation query reads the other table's columns — " ++
            "give the entity a different table name or rename the edge's target";
    }
}

pub fn junctionShapeClause(comptime info: TypeInfo, comptime edge: EdgeInfo, comptime all_infos: []const TypeInfo) []const u8 {
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
pub fn missingJunctionColumnDetail(comptime info: TypeInfo, comptime edge: EdgeInfo, comptime column: []const u8, comptime all_infos: []const TypeInfo) []const u8 {
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
pub fn junctionPairUniquenessDetail(comptime info: TypeInfo, comptime edge: EdgeInfo, comptime all_infos: []const TypeInfo) []const u8 {
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
pub fn foreignKeyDetailAlloc(allocator: std.mem.Allocator, fk: ForeignKeyDef) ![]const u8 {
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

pub fn columnsEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |a_col, b_col| {
        if (!std.mem.eql(u8, a_col, b_col)) return false;
    }
    return true;
}

/// "schema wants (a, b), database has (a)" — the difference in one sentence,
/// because a drift report that only says "the columns differ" sends the reader
/// back to the database to find out how.
pub fn indexColumnsDetailAlloc(allocator: std.mem.Allocator, schema_columns: []const []const u8, db_columns: []const []const u8) ![]const u8 {
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
pub fn indexUniquenessDetailAlloc(allocator: std.mem.Allocator, schema_unique: bool, db_unique: bool) ![]const u8 {
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
pub fn ownsIndexDetail(kind: SchemaDrift.Kind) bool {
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
pub fn freeDriftOwnedFields(allocator: std.mem.Allocator, d: SchemaDrift) void {
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
pub fn appendOwnedDrift(
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
pub fn db_nullableOf(col: ExistingColumn) bool {
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
pub fn reportNullabilityDrift(drifts: []const NullabilityDrift) void {
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
pub fn columnTypesAgree(
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
