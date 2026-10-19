//! The `comptime` branch budget schema-shaped helpers evaluate under.
//!
//! **Why one place.** Zig gives every `comptime` evaluation a branch quota
//! (`1000` by default, `5000` inside `inline` loops) and *aborts the
//! compilation* when a loop exceeds it — the failure every consumer sees as
//! `error: evaluation exceeded N backwards branches` pointing at a function
//! they have never read. Two properties make that budget a library concern
//! rather than a detail:
//!
//!   - the **innermost** `@setEvalBranchQuota` on an evaluation path wins, so a
//!     caller's own quota cannot rescue a helper that sets none: the abort
//!     happens inside the library, naming library code;
//!   - the budget a two-table test graph needs and the one a 154-table schema
//!     needs differ by orders of magnitude, so **no constant is right**. Measured
//!     on that 154-table consumer: the default `1000` tripped in
//!     `requiredPostgresExtensions` (which set nothing) and a fixed `50_000`
//!     tripped in `tableFromTypeInfoCrossRef`.
//!
//! The quota is a ceiling, never work: raising it costs nothing when it is not
//! reached, which is why the base is generous rather than tuned to today's graph
//! sizes. Before this module the number was written out at 31 call sites as
//! `1000000`, plus `50_000`/`10_000_000` elsewhere — the same decision made
//! repeatedly, with the graph-shaped ones getting it wrong.
//!
//! Use [`graph`] whenever the helper's work is shaped by the schema (per table ×
//! per field, or per table × per table for the cross-reference helpers) and
//! [`flat`] when it is not.

/// The budget for an evaluation that is not shaped by a table count.
pub const flat: u32 = 4_000_000;

/// The budget for an evaluation shaped by the graph: per table × per field, and
/// per table × per table for the helpers that resolve one table against all of
/// them. `tables` is a `comptime` value (`infos.len`), never a runtime one.
pub fn graph(comptime tables: usize) u32 {
    return flat + @as(u32, @intCast(tables)) * 20_000;
}
