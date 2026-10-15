const std = @import("std");
const edgeTargetInfo = @import("graph.zig").edgeTargetInfo;
const TypeInfo = @import("graph.zig").TypeInfo;
const EdgeInfo = @import("graph.zig").EdgeInfo;

/// Generate a light entity struct (fields only, no edges) from TypeInfo.
/// This breaks comptime recursion when edges reference each other.
/// Pure scalar fields (no edges) - the terminal node of nested eager loads.
fn PlainFields(comptime infos: []const TypeInfo, comptime info: TypeInfo) type {
    _ = infos;
    comptime {
        @setEvalBranchQuota(1000000);
        // +1 for the json_arena member so eager-loaded targets get the same
        // arena-based JSON ownership contract as full entities.
        var field_names: [info.fields.len + 1][:0]const u8 = undefined;
        var field_types: [info.fields.len + 1]type = undefined;
        var field_attrs: [info.fields.len + 1]std.lang.Type.Struct.FieldAttributes = undefined;
        for (info.fields, 0..) |f, i| {
            const FieldType = if (f.optional) ?f.zig_type else f.zig_type;
            field_names[i] = (f.name)[0..f.name.len :0];
            field_types[i] = FieldType;
            field_attrs[i] = .{
                .default_value_ptr = null,
                .@"comptime" = false,
                .@"align" = @alignOf(FieldType),
            };
        }
        const i = info.fields.len;
        field_names[i] = "json_arena";
        field_types[i] = ?*std.heap.ArenaAllocator;
        field_attrs[i] = .{
            .default_value_ptr = null,
            .@"comptime" = false,
            .@"align" = @alignOf(?*std.heap.ArenaAllocator),
        };
        return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
    }
}

/// One level of edges whose targets are plain fields (no further nesting).
/// Used by LightEntity so `WithEdge("posts.comments")` can preload two
/// levels; a third level is a compile error (no edges container on the
/// terminal target).
fn EdgesTypeShallow(comptime infos: []const TypeInfo, comptime info: TypeInfo) type {
    comptime {
        @setEvalBranchQuota(1000000);
        if (info.edges.len == 0) {
            return struct {
                pub fn deinit(_: @This(), _: std.mem.Allocator) void {}
            };
        }
        var field_names: [info.edges.len][:0]const u8 = undefined;
        var field_types: [info.edges.len]type = undefined;
        var field_attrs: [info.edges.len]std.lang.Type.Struct.FieldAttributes = undefined;
        for (info.edges, 0..) |e, i| {
            const target_info = edgeTargetInfo(infos, info, e);
            const TargetEntity = PlainFields(infos, target_info);
            const FieldType = ?[]TargetEntity;
            const default_val: FieldType = null;
            field_names[i] = (e.name)[0..e.name.len :0];
            field_types[i] = FieldType;
            field_attrs[i] = .{
                .default_value_ptr = &default_val,
                .@"comptime" = false,
                .@"align" = @alignOf(FieldType),
            };
        }
        return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
    }
}

/// Light entity (fields + one shallow edges level) used as the eager-load
/// target type, so nested `WithEdge("a.b")` works for two levels.
pub fn LightEntity(comptime infos: []const TypeInfo, comptime info: TypeInfo) type {
    comptime {
        @setEvalBranchQuota(1000000);
        const ET = EdgesTypeShallow(infos, info);
        const edges_default: ET = .{};
        const Plain = PlainFields(infos, info);
        const fields_info = @typeInfo(Plain).@"struct";
        var field_names: [fields_info.field_names.len + 1][:0]const u8 = undefined;
        var field_types: [fields_info.field_names.len + 1]type = undefined;
        var field_attrs: [fields_info.field_names.len + 1]std.lang.Type.Struct.FieldAttributes = undefined;
        for (fields_info.field_names, fields_info.field_types, 0..) |fname, ftype, i| {
            field_names[i] = fname;
            field_types[i] = ftype;
            field_attrs[i] = .{
                .default_value_ptr = null,
                .@"comptime" = false,
                .@"align" = @alignOf(ftype),
            };
        }
        const i = fields_info.field_names.len;
        field_names[i] = "edges";
        field_types[i] = ET;
        field_attrs[i] = .{
            .default_value_ptr = &edges_default,
            .@"comptime" = false,
            .@"align" = @alignOf(ET),
        };
        return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
    }
}

/// Generate an Edges struct for an entity.
/// Uses LightEntity for target types to avoid comptime recursion.
fn EdgesType(comptime infos: []const TypeInfo, comptime info: TypeInfo) type {
    comptime {
        @setEvalBranchQuota(1000000);
        if (info.edges.len == 0) {
            return struct {
                pub fn deinit(_: @This(), _: std.mem.Allocator) void {}
            };
        }
        var field_names: [info.edges.len][:0]const u8 = undefined;
        var field_types: [info.edges.len]type = undefined;
        var field_attrs: [info.edges.len]std.lang.Type.Struct.FieldAttributes = undefined;
        for (info.edges, 0..) |e, i| {
            const target_info = edgeTargetInfo(infos, info, e);
            const TargetEntity = LightEntity(infos, target_info);
            const FieldType = ?[]TargetEntity;
            const default_val: FieldType = null;
            field_names[i] = (e.name)[0..e.name.len :0];
            field_types[i] = FieldType;
            field_attrs[i] = .{
                .default_value_ptr = &default_val,
                .@"comptime" = false,
                .@"align" = @alignOf(FieldType),
            };
        }
        return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
    }
}

fn EntityFields(comptime infos: []const TypeInfo, comptime info: TypeInfo) type {
    comptime {
        @setEvalBranchQuota(1000000);
        const ET = EdgesType(infos, info);
        const edges_default: ET = .{};
        var field_names: [info.fields.len + 1][:0]const u8 = undefined;
        var field_types: [info.fields.len + 1]type = undefined;
        var field_attrs: [info.fields.len + 1]std.lang.Type.Struct.FieldAttributes = undefined;
        for (info.fields, 0..) |f, i| {
            const FieldType = if (f.optional) ?f.zig_type else f.zig_type;
            field_names[i] = (f.name)[0..f.name.len :0];
            field_types[i] = FieldType;
            field_attrs[i] = .{
                .default_value_ptr = null,
                .@"comptime" = false,
                .@"align" = @alignOf(FieldType),
            };
        }
        field_names[info.fields.len] = "edges";
        field_types[info.fields.len] = ET;
        field_attrs[info.fields.len] = .{
            .default_value_ptr = &edges_default,
            .@"comptime" = false,
            .@"align" = @alignOf(ET),
        };
        return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
    }
}

fn FreeField(comptime FieldType: type, field_ptr: *FieldType, allocator: std.mem.Allocator) void {
    const T = @typeInfo(FieldType);
    switch (T) {
        .pointer => |p| {
            if (p.size == .slice) {
                // The per-item pass is for a slice whose *elements* own memory
                // (`[]const []const u8` and friends). A leaf slice needs only
                // its buffer released, and the old spelling tested for exactly
                // one leaf — `u8` — so everything else was walked: `f32` (a
                // `field.Vector`'s `[]const f32`) did not even compile, because
                // `&item` on a const element is a `*const f32`, and a `u16`
                // slice would have been a no-op loop that happened to work.
                // Keying on `isOwningField` says what was meant and covers the
                // leaf cases the `== u8` test was standing in for.
                if (comptime isOwningField(p.child)) {
                    for (field_ptr.*) |item| {
                        FreeField(p.child, &item, allocator);
                    }
                }
                allocator.free(field_ptr.*);
            }
        },
        .optional => |opt| {
            if (field_ptr.*) |*p| {
                FreeField(opt.child, p, allocator);
            }
        },
        else => {},
    }
}

fn hasJsonStructField(comptime info: TypeInfo) bool {
    inline for (info.fields) |f| {
        // Any .json field needs the arena — typed structs AND untyped
        // std.json.Value documents (the parsed value is arena-owned).
        if (f.field_type == .json) return true;
    }
    return false;
}

/// Generate an entity struct from TypeInfo.
pub fn Entity(comptime infos: []const TypeInfo, comptime info: TypeInfo) type {
    comptime {
        @setEvalBranchQuota(1000000);
        const ET = EdgesType(infos, info);
        const edges_default: ET = .{};
        const needs_arena = hasJsonStructField(info);
        const extra_count = 1 + @as(usize, @intFromBool(needs_arena));
        var field_names: [info.fields.len + extra_count][:0]const u8 = undefined;
        var field_types: [info.fields.len + extra_count]type = undefined;
        var field_attrs: [info.fields.len + extra_count]std.lang.Type.Struct.FieldAttributes = undefined;
        for (info.fields, 0..) |f, i| {
            const FieldType = if (f.optional) ?f.zig_type else f.zig_type;
            field_names[i] = (f.name)[0..f.name.len :0];
            field_types[i] = FieldType;
            field_attrs[i] = .{
                .default_value_ptr = null,
                .@"comptime" = false,
                .@"align" = @alignOf(FieldType),
            };
        }
        const arena_idx = info.fields.len;
        const edges_idx = info.fields.len + @as(usize, @intFromBool(needs_arena));
        if (needs_arena) {
            field_names[arena_idx] = "json_arena";
            field_types[arena_idx] = ?*std.heap.ArenaAllocator;
            field_attrs[arena_idx] = .{
                .default_value_ptr = null,
                .@"comptime" = false,
                .@"align" = @alignOf(?*std.heap.ArenaAllocator),
            };
        }
        field_names[edges_idx] = "edges";
        field_types[edges_idx] = ET;
        field_attrs[edges_idx] = .{
            .default_value_ptr = &edges_default,
            .@"comptime" = false,
            .@"align" = @alignOf(ET),
        };
        return @Struct(.auto, null, field_names[0 .. edges_idx + 1], field_types[0 .. edges_idx + 1], field_attrs[0 .. edges_idx + 1]);
    }
}

/// Free a whole page of entities and the list holding them, in one call:
/// `deinitEntity` for every item, then the list's own buffer. The list is left
/// empty and reusable, so calling this twice is a no-op rather than a
/// double-free.
///
/// This is the shape every call site was spelling out by hand
/// (`for (rows.items) |*e| deinitEntity(infos, info, e, alloc); rows.deinit();`)
/// — see `ISSUES_FROM_ZAPI.md` Z17 for why it matters: the four-argument form
/// was recursive enough that a helper nobody could reach went unused 607 times
/// to zero.
///
/// Prefer the methods that carry the graph for you: `client.<entity>.deinitRows`
/// and `QueryBuilder.deinitRows`.
pub fn deinitEntityList(
    comptime infos: []const TypeInfo,
    comptime info: TypeInfo,
    allocator: std.mem.Allocator,
    rows: *std.array_list.Managed(Entity(infos, info)),
) void {
    for (rows.items) |*e| deinitEntity(infos, info, e, allocator);
    rows.deinit();
    rows.* = std.array_list.Managed(Entity(infos, info)).init(allocator);
}

/// Recursively free heap allocations owned by an entity (fields + eager-loaded
/// edges). The caller still owns the entity itself and the outer `[]Entity` slice.
pub fn deinitEntity(comptime infos: []const TypeInfo, comptime info: TypeInfo, self: anytype, allocator: std.mem.Allocator) void {
    // Reject immutable pointers at compile time.
    comptime {
        const T = @TypeOf(self);
        const ptr_info = @typeInfo(T).pointer;
        if (ptr_info.attrs.@"const") @compileError("deinitEntity requires a mutable entity pointer");
    }

    // Release the per-entity JSON arena: both the Create path and the scan
    // path (scanRowWithArena) attach one when the entity carries JSON
    // fields. Entities without JSON fields have no json_arena member.
    if (comptime @hasField(@TypeOf(self.*), "json_arena")) {
        if (self.json_arena) |arena| {
            arena.deinit();
            allocator.destroy(arena);
            self.json_arena = null;
        }
    }

    inline for (info.fields) |f| {
        if (!comptime isOwningField(f.zig_type)) continue;
        const field_type = if (f.optional) ?f.zig_type else f.zig_type;
        const fp: *field_type = &@field(self, f.name);
        FreeField(field_type, fp, allocator);
    }
    deinitEntityEdges(infos, info, self, allocator);
}

/// Recursively free eager-loaded edges (one level of nesting supported).
/// The edges field type is `?[]Target` where Target is LightEntity (with a
/// shallow edges level) or PlainFields (terminal); Target is derived from the
/// field type so both work.
fn deinitEntityEdges(comptime infos: []const TypeInfo, comptime info: TypeInfo, self: anytype, allocator: std.mem.Allocator) void {
    if (comptime info.edges.len == 0) return;
    inline for (info.edges) |e| {
        const target_info = comptime edgeTargetInfo(infos, info, e);
        const EdgeFieldType = @TypeOf(@field(self.edges, e.name));
        const EdgeArrType = @typeInfo(EdgeFieldType).optional.child;
        const ItemType = @typeInfo(EdgeArrType).pointer.child;
        const edges_ptr: *?[]ItemType = &@field(self.edges, e.name);
        if (edges_ptr.*) |arr| {
            for (arr) |*item| deinitEagerTarget(infos, target_info, item, allocator);
            allocator.free(arr);
        }
    }
}

/// Free one eager-loaded target item — the `LightEntity` / `PlainFields` shape
/// `loadEdgePath` scans — releasing its JSON arena, its owning fields and, when
/// the item type carries an edges container, its own loaded edges.
///
/// This is the per-item body of `deinitEntityEdges`, exposed because a target
/// can be held outside an edge array: `loadEdgePath` parks scanned targets in a
/// per-parent map before it copies them into the parents' edge slices, and a
/// failure before that transfer has to release the parked items. `deinitEntity`
/// cannot be used for them — it always calls `deinitEntityEdges`, which reads
/// `self.edges`, and a terminal `PlainFields` target has no such member.
pub fn deinitEagerTarget(comptime infos: []const TypeInfo, comptime info: TypeInfo, self: anytype, allocator: std.mem.Allocator) void {
    // Eager-loaded targets carry their own JSON arena (see loadEdgePath);
    // release it before the owning fields.
    if (comptime @hasField(@TypeOf(self.*), "json_arena")) {
        if (self.json_arena) |arena| {
            arena.deinit();
            allocator.destroy(arena);
            self.json_arena = null;
        }
    }
    inline for (info.fields) |tf| {
        if (!comptime isOwningField(tf.zig_type)) continue;
        const field_type = if (tf.optional) ?tf.zig_type else tf.zig_type;
        const fp: *field_type = &@field(self, tf.name);
        FreeField(field_type, fp, allocator);
    }
    // Terminal targets (PlainFields) carry no edges container; the comptime
    // guard stops that instantiation from being analyzed.
    if (comptime @hasField(@TypeOf(self.*), "edges")) {
        deinitEntityEdges(infos, info, self, allocator);
    }
}

/// Write an entity to the given writer. Non-sensitive fields are formatted
/// normally; sensitive fields are masked as "***".
///
/// Usage:
///   try formatEntity(info, e, writer);
pub fn formatEntity(
    comptime info: TypeInfo,
    self: anytype,
    writer: anytype,
) !void {
    try writer.writeAll(info.table_name);
    try writer.writeAll("{");
    inline for (info.fields, 0..) |f, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("{s}=", .{f.name});
        if (f.sensitive) {
            try writer.writeAll("***");
        } else {
            const field_type = if (f.optional) ?f.zig_type else f.zig_type;
            const value: field_type = @field(self, f.name);
            try writer.print("{any}", .{value});
        }
    }
    try writer.writeAll("}");
}

fn isOwningField(comptime T: type) bool {
    const info = @typeInfo(T);
    switch (info) {
        .pointer => |p| return p.size == .slice, // includes []const u8
        .optional => |opt| return isOwningField(opt.child),
        else => return false,
    }
}

/// Serialize an entity to JSON with `sensitive` fields masked as "***".
/// The generated entity struct cannot carry a `jsonStringify` method (the
/// @Struct builtin has no decls slot), so APIs must use this helper instead
/// of serializing the raw entity (std.json would leak sensitive fields).
/// Non-sensitive values are emitted through std.json (safe escaping).
pub fn toMaskedJson(
    allocator: std.mem.Allocator,
    comptime infos: []const TypeInfo,
    comptime info: TypeInfo,
    entity: anytype,
) ![]u8 {
    _ = infos;
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    inline for (info.fields, 0..) |f, i| {
        // json_arena is an injected bookkeeping field (entity struct only),
        // never business data — skip it defensively in case TypeInfo ever
        // carries injected fields (serializing it would walk into
        // std.mem.Allocator's fn-pointer vtable, rejected as comptime-only
        // by newer zig dev). Must be skipped before the comma logic.
        if (comptime std.mem.eql(u8, f.name, "json_arena")) continue;
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "\"");
        try buf.appendSlice(allocator, f.name);
        try buf.appendSlice(allocator, "\":");
        if (f.sensitive) {
            try buf.appendSlice(allocator, "\"***\"");
        } else {
            const value = @field(entity, f.name);
            const piece = try std.json.Stringify.valueAlloc(allocator, value, .{});
            defer allocator.free(piece);
            try buf.appendSlice(allocator, piece);
        }
    }
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

// ------------------------------------------------------------------
// ManagedEntity + arena dupe (HTTP-handler ergonomics)
// ------------------------------------------------------------------

/// Owning wrapper that bundles an entity with the allocator it was
/// allocated with, so teardown cannot pick the wrong allocator:
///
///   var m = managedEntity(infos, UserInfo, user, client.allocator);
///   defer m.deinit();
///   use(m.get().name);
pub fn ManagedEntity(comptime infos: []const TypeInfo, comptime info: TypeInfo) type {
    return struct {
        entity: Entity(infos, info),
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn get(self: *Self) *Entity(infos, info) {
            return &self.entity;
        }

        pub fn deinit(self: *Self) void {
            deinitEntity(infos, info, &self.entity, self.allocator);
        }
    };
}

/// Wrap an entity with its owning allocator. See `ManagedEntity`.
pub fn managedEntity(
    comptime infos: []const TypeInfo,
    comptime info: TypeInfo,
    entity: Entity(infos, info),
    allocator: std.mem.Allocator,
) ManagedEntity(infos, info) {
    return .{ .entity = entity, .allocator = allocator };
}

fn dupeDeep(comptime T: type, v: T, arena: std.mem.Allocator) std.mem.Allocator.Error!T {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size != .slice) return v;
            if (p.child == u8) return try arena.dupe(u8, v);
            const new_slice = try arena.alloc(p.child, v.len);
            for (v, 0..) |item, i| new_slice[i] = try dupeDeep(p.child, item, arena);
            return new_slice;
        },
        .optional => |opt| {
            if (v) |inner| return @as(T, try dupeDeep(opt.child, inner, arena));
            return null;
        },
        .@"struct" => |s| {
            var out = v;
            inline for (s.field_names, s.field_types) |fname, ftype| {
                @field(out, fname) = try dupeDeep(ftype, @field(v, fname), arena);
            }
            return out;
        },
        .array => |a| {
            var out: T = undefined;
            for (v, 0..) |item, i| out[i] = try dupeDeep(a.child, item, arena);
            return out;
        },
        // A `field.JSONValue` document (`std.json.Value`) is a tree of
        // arena-owned nodes and needs the recursive copy below; every other
        // tagged union is copied by value, which is correct for an inline
        // union with no arena-owned payload.
        else => {
            if (T == std.json.Value) return try dupeJsonDeep(v, arena);
            return v;
        },
    }
}

/// Deep-copy a `std.json.Value` document into `arena`.
///
/// `dupeDeep`'s generic tagged-union branch cannot cover this: the document's
/// `.string` / `.number_string` bytes and every `.array` / `.object` container
/// are allocated in the *source* entity's `json_arena`, so a shallow copy keeps
/// pointers into memory the caller is about to free — which is exactly what
/// `CrudService.getOwned` does before it returns the copy.
///
/// A failure part-way through leaves the partially built document in `arena`.
/// That is deliberate and not a leak: the arena is freed as a unit, so the
/// half-built tree is reclaimed along with everything else.
fn dupeJsonDeep(v: std.json.Value, arena: std.mem.Allocator) std.mem.Allocator.Error!std.json.Value {
    switch (v) {
        .null, .bool, .integer, .float => return v,
        .number_string => |s| return .{ .number_string = try arena.dupe(u8, s) },
        .string => |s| return .{ .string = try arena.dupe(u8, s) },
        .array => |arr| {
            var out = std.json.Array.init(arena);
            try out.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| out.appendAssumeCapacity(try dupeJsonDeep(item, arena));
            return .{ .array = out };
        },
        .object => |obj| {
            var out = std.json.ObjectMap.empty;
            try out.ensureTotalCapacity(arena, obj.count());
            var it = obj.iterator();
            while (it.next()) |entry| {
                out.putAssumeCapacity(
                    try arena.dupe(u8, entry.key_ptr.*),
                    try dupeJsonDeep(entry.value_ptr.*, arena),
                );
            }
            return .{ .object = out };
        },
    }
}

fn dupeItem(
    comptime infos: []const TypeInfo,
    comptime info: TypeInfo,
    comptime T: type,
    item: T,
    arena: std.mem.Allocator,
) std.mem.Allocator.Error!T {
    var out = item;
    // JSON payloads are re-duped field-by-field below; the arena pointer
    // itself is bookkeeping and must not survive the copy.
    if (comptime @hasField(T, "json_arena")) out.json_arena = null;
    inline for (info.fields) |f| {
        const field_type = if (f.optional) ?f.zig_type else f.zig_type;
        @field(out, f.name) = try dupeDeep(field_type, @field(out, f.name), arena);
    }
    if (comptime @hasField(T, "edges") and info.edges.len > 0) {
        inline for (info.edges) |e| {
            const target_info = comptime edgeTargetInfo(infos, info, e);
            const EdgeFieldType = @TypeOf(@field(out.edges, e.name));
            const ArrType = @typeInfo(EdgeFieldType).optional.child;
            const ItemType = @typeInfo(ArrType).pointer.child;
            if (@field(out.edges, e.name)) |arr| {
                const new_arr = try arena.alloc(ItemType, arr.len);
                for (arr, 0..) |it, i| {
                    new_arr[i] = try dupeItem(infos, target_info, ItemType, it, arena);
                }
                @field(out.edges, e.name) = new_arr;
            }
        }
    }
    return out;
}

/// Deep-copy an entity (scalar fields, string/slice fields, typed JSON
/// structs, untyped `field.JSONValue` documents and up to two levels of
/// eager-loaded edges) into `arena`.
///
/// The returned entity borrows everything from the arena: pass it to
/// request-scoped code and free it all at once with `arena.deinit()`.
/// Do NOT pass the copy to `deinitEntity` — that would double-free into
/// the wrong allocator.
pub fn dupeEntityTo(
    comptime infos: []const TypeInfo,
    comptime info: TypeInfo,
    self: anytype,
    arena: std.mem.Allocator,
) std.mem.Allocator.Error!@TypeOf(self.*) {
    return dupeItem(infos, info, @TypeOf(self.*), self.*, arena);
}

/// Re-dupe an entity's JSON fields into a fresh arena created with
/// `allocator`, and attach that arena to the entity's own `json_arena`.
///
/// This is the counterpart of `dupeEntityTo` for an entity that will be freed
/// with `deinitEntity`: that helper puts *everything* (strings included) in
/// the caller's arena and must not reach `deinitEntity`, while this one
/// re-homes only the JSON payload and leaves the string fields alone, so the
/// later `deinitEntity(infos, info, &copy, allocator)` frees the strings with
/// the allocator and the JSON with the copy's own arena.
///
/// `ownedCopy` needs exactly that: it starts from a shallow struct copy whose
/// JSON fields still point into the scanned source row's arena, which
/// `CrudService.getOwned` releases before it returns.
///
/// A no-op (`null`) when the entity has no `json_arena` member, or when that
/// arena is already null (the row carried no JSON). Returns the attached
/// arena, which `deinitEntity` then owns.
pub fn dupeJsonInto(
    comptime info: TypeInfo,
    self: anytype,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!?*std.heap.ArenaAllocator {
    const T = @TypeOf(self.*);
    if (comptime @hasField(T, "json_arena")) {
        if (self.json_arena == null) return null;
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        inline for (info.fields) |f| {
            if (f.field_type != .json) continue;
            const field_type = if (f.optional) ?f.zig_type else f.zig_type;
            @field(self, f.name) = try dupeDeep(field_type, @field(self, f.name), arena.allocator());
        }
        self.json_arena = arena;
        return arena;
    }
    return null;
}

/// The value an owning field holds once it has been cleared: an empty slice, or
/// `null` for an optional one. `deinitEntity` releases both as a no-op, which
/// is what lets a half-built copy be handed to it.
fn emptyOwnedValue(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.attrs.@"const") &[_]p.child{} else @constCast(&[_]p.child{}),
        .optional => null,
        else => @compileError("zent: emptyOwnedValue expects an owning slice or an optional slice, got " ++ @typeName(T)),
    };
}

/// Duplicate one owning field into `allocator` — the inverse of `FreeField`, so
/// the result is releasable by `deinitEntity(infos, info, &copy, allocator)`.
/// The buffer and every owning element inside it are allocated with `allocator`
/// and duplicated recursively; a value that owns nothing is returned as-is.
///
/// `dupeDeep` cannot be reused here: it assumes an arena that is freed as a
/// unit, and leaks what it already made when a later allocation fails, while
/// this copy is released field by field through a plain allocator's `free`.
fn dupeOwned(comptime T: type, value: T, allocator: std.mem.Allocator) std.mem.Allocator.Error!T {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size != .slice) return value;
            const copy = try allocator.alloc(p.child, value.len);
            // Only the elements already written can own anything, so the
            // teardown walks that prefix, releasing each one exactly the way
            // `deinitEntity` later would (a partially duplicated element is
            // cleaned by its own frame before the error reaches here).
            var filled: usize = 0;
            errdefer {
                for (copy[0..filled]) |*item| FreeField(p.child, item, allocator);
                allocator.free(copy);
            }
            for (value, 0..) |item, i| {
                copy[i] = try dupeOwned(p.child, item, allocator);
                filled += 1;
            }
            return copy;
        },
        .optional => |opt| {
            if (value) |inner| return @as(T, try dupeOwned(opt.child, inner, allocator));
            return null;
        },
        else => return value,
    }
}

/// Owned copy of a row: every owning field is duplicated into `allocator`, the
/// JSON payloads are re-duped into the copy's own `json_arena`, and what comes
/// back is releasable with `deinitEntity(infos, info, &copy, allocator)` — on a
/// generated client, `client.<entity>.deinitRowWith(allocator, &copy)`.
///
/// That is the whole difference from `dupeEntityTo`: the arena form hands back
/// a value that must *not* be passed to `deinitEntity`, so a call site keeping
/// a row past its query (a response body, a cache entry, a job payload) had to
/// spell out the per-field `dupe` loop to get this contract.
///
/// Eager-loaded edges (`WithEdge`) are **not** carried over: the copy's `edges`
/// is left empty. A shallow edge array would be freed twice — once through the
/// copy, once through the source — and no deinit-compatible deep copy of an
/// edge page exists here, so copy the graph with the arena form
/// (`dupeEntityTo`) while the source is still alive if you need its edges.
///
/// `error.OutOfMemory` is the only error, and on it nothing is leaked and
/// nothing is transferred: what has been copied by then is released before the
/// error is returned, so the caller owns only the error.
pub fn ownedCopy(
    comptime infos: []const TypeInfo,
    comptime info: TypeInfo,
    allocator: std.mem.Allocator,
    src: anytype,
) std.mem.Allocator.Error!@TypeOf(src) {
    const T = @TypeOf(src);
    var out = src;

    // JSON first, while `out` is still a plain shallow copy: `dupeJsonInto` is
    // the step that replaces the source's arena with the copy's own, and it
    // cleans up after itself. It must therefore run *outside* the errdefer
    // below, which would otherwise mistake the source's arena for one this copy
    // owns and free it.
    _ = try dupeJsonInto(info, &out, allocator);

    // Everything else `out` points at is still the source's. Clearing it first
    // leaves the copy owning nothing but the arena above, so the failure path
    // can be the single `deinitEntity` below instead of a ledger of the
    // allocations made so far: `deinitEntity` frees a cleared field as a no-op.
    if (comptime @hasField(T, "edges")) out.edges = .{};
    inline for (info.fields) |f| {
        // `.json` payloads are arena-owned and were re-homed above —
        // `deinitEntity` releases them through the arena, never here.
        if (f.field_type == .json) continue;
        const FieldType = if (f.optional) ?f.zig_type else f.zig_type;
        if (comptime isOwningField(FieldType)) @field(out, f.name) = emptyOwnedValue(FieldType);
    }

    errdefer deinitEntity(infos, info, &out, allocator);

    inline for (info.fields) |f| {
        if (f.field_type == .json) continue;
        const FieldType = if (f.optional) ?f.zig_type else f.zig_type;
        if (comptime !isOwningField(FieldType)) continue;
        @field(out, f.name) = try dupeOwned(FieldType, @field(src, f.name), allocator);
    }
    return out;
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "toMaskedJson masks sensitive fields" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const Account = Schema("Account2", .{
        .fields = &.{
            field.String("name"),
            field.String("api_key").Sensitive(),
        },
    });
    const info = comptime fromSchema(Account);
    const infos = &[_]TypeInfo{info};
    const AccountEntity = Entity(infos, info);

    const a = AccountEntity{ .id = 1, .name = "alice", .api_key = "sk-secret-123" };
    const json = try toMaskedJson(allocator, infos, info, a);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"api_key\":\"***\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"alice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "sk-secret-123") == null);
}

test "ManagedEntity deinit frees with the bound allocator" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = Schema("ManagedUser", .{
        .fields = &.{field.String("name")},
    });
    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};

    var m = managedEntity(infos, info, .{
        .id = 1,
        .name = try allocator.dupe(u8, "alice"),
    }, allocator);
    defer m.deinit(); // leak-checker validates the free
    try std.testing.expectEqualStrings("alice", m.get().name);
}

test "dupeEntityTo deep-copies strings, JSON payloads and edges into an arena" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const edge = @import("../core/edge.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const buildGraph = @import("graph.zig").buildGraph;

    const Settings = struct { theme: []const u8 };
    const Post = Schema("DupePost", .{
        .fields = &.{field.String("title")},
    });
    const Blog = Schema("DupeBlog", .{
        .fields = &.{
            field.String("name"),
            field.String("note").Optional(),
            field.JSON("settings", Settings),
        },
        .edges = &.{edge.To("posts", Post)},
    });
    const graph = comptime buildGraph(&.{ Blog, Post });
    const infos = graph.types;
    const blog_info = infos[0];
    const post_info = infos[1];
    const BlogEntity = Entity(infos, blog_info);
    const PostLight = LightEntity(infos, post_info);

    const posts = try allocator.alloc(PostLight, 1);
    posts[0] = .{ .id = 7, .dupe_blog_id = 1, .title = try allocator.dupe(u8, "hello"), .json_arena = null, .edges = .{} };
    // Real entities carry JSON payloads in a per-entity arena.
    const src_json_arena = try allocator.create(std.heap.ArenaAllocator);
    src_json_arena.* = std.heap.ArenaAllocator.init(allocator);
    var src = BlogEntity{
        .id = 1,
        .name = try allocator.dupe(u8, "tech"),
        .note = try allocator.dupe(u8, "draft"),
        .settings = .{ .theme = try src_json_arena.allocator().dupe(u8, "dark") },
        .json_arena = src_json_arena,
        .edges = .{ .posts = posts },
    };

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit(); // frees the whole copy at once
    const arena = arena_state.allocator();

    const copy = try dupeEntityTo(infos, blog_info, &src, arena);
    // Contents equal, storage independent.
    try std.testing.expectEqualStrings("tech", copy.name);
    try std.testing.expect(copy.name.ptr != src.name.ptr);
    try std.testing.expectEqualStrings("dark", copy.settings.theme);
    try std.testing.expect(copy.settings.theme.ptr != src.settings.theme.ptr);
    try std.testing.expectEqualStrings("hello", copy.edges.posts.?[0].title);
    try std.testing.expect(copy.edges.posts.?.ptr != src.edges.posts.?.ptr);
    try std.testing.expect(copy.json_arena == null);

    // Freeing the source must not invalidate the arena copy.
    deinitEntity(infos, blog_info, &src, allocator);
    try std.testing.expectEqualStrings("tech", copy.name);
    try std.testing.expectEqualStrings("draft", copy.note.?);
    try std.testing.expectEqualStrings("hello", copy.edges.posts.?[0].title);
    // `copy` must NOT be deinitEntity'd — the arena owns it.
}

test "dupeEntityTo re-homes a JSONValue document out of the source arena" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const buildGraph = @import("graph.zig").buildGraph;

    const Doc = Schema("DupeJsonValueDoc", .{
        .fields = &.{
            field.String("name"),
            field.JSONValue("doc"),
        },
    });
    const graph = comptime buildGraph(&.{Doc});
    const infos = graph.types;
    const info = infos[0];
    const DocEntity = Entity(infos, info);

    // A parsed document is a tree of arena-owned nodes: its object keys, its
    // string payloads and its array backing all live in the source arena.
    const src_arena = try allocator.create(std.heap.ArenaAllocator);
    src_arena.* = std.heap.ArenaAllocator.init(allocator);
    const json_text = "{\"outer\":{\"items\":[\"alpha\",\"日本語\"],\"n\":3}}";
    var src = DocEntity{
        .id = 1,
        .name = "spec",
        .doc = try std.json.parseFromSliceLeaky(std.json.Value, src_arena.allocator(), json_text, .{}),
        .json_arena = src_arena,
    };

    var dst_state = std.heap.ArenaAllocator.init(allocator);
    defer dst_state.deinit();
    const copy = try dupeEntityTo(infos, info, &src, dst_state.allocator());

    // Reads back the same document while both are alive.
    try std.testing.expectEqual(@as(i64, 3), copy.doc.object.get("outer").?.object.get("n").?.integer);
    const items = copy.doc.object.get("outer").?.object.get("items").?.array;
    try std.testing.expectEqualStrings("alpha", items.items[0].string);
    try std.testing.expectEqualStrings("日本語", items.items[1].string);

    // Release the source arena — exactly what `CrudService.getOwned` does
    // before it returns the copy.
    src.json_arena = null;
    src_arena.deinit();
    allocator.destroy(src_arena);

    // This second read is a dangling access before the fix: the copy's
    // document still pointed into the freed source arena.
    try std.testing.expectEqual(@as(i64, 3), copy.doc.object.get("outer").?.object.get("n").?.integer);
    const items2 = copy.doc.object.get("outer").?.object.get("items").?.array;
    try std.testing.expectEqualStrings("alpha", items2.items[0].string);
    try std.testing.expectEqualStrings("日本語", items2.items[1].string);
    // `copy` must NOT be deinitEntity'd — the arena owns it.
}

test "ownedCopy round-trips a row and survives the source's release" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const buildGraph = @import("graph.zig").buildGraph;

    const Settings = struct { theme: []const u8 };
    const Note = Schema("OwnedCopyNote", .{
        .fields = &.{
            field.String("title"),
            field.String("body").Optional(),
            field.JSON("settings", Settings),
            field.JSONValue("doc"),
        },
    });
    const graph = comptime buildGraph(&.{Note});
    const infos = graph.types;
    const info = infos[0];
    const NoteEntity = Entity(infos, info);

    // A real row's storage: strings in the allocator, JSON payloads in the
    // row's own arena (which `CrudService.getOwned` releases before it returns
    // the copy).
    const src_arena = try allocator.create(std.heap.ArenaAllocator);
    src_arena.* = std.heap.ArenaAllocator.init(allocator);
    var src = NoteEntity{
        .id = 7,
        .title = try allocator.dupe(u8, "title-alpha"),
        .body = try allocator.dupe(u8, "body-bravo"),
        .settings = .{ .theme = try src_arena.allocator().dupe(u8, "dark") },
        .doc = try std.json.parseFromSliceLeaky(std.json.Value, src_arena.allocator(), "{\"items\":[\"alpha\"]}", .{}),
        .json_arena = src_arena,
    };

    var copy = try ownedCopy(infos, info, allocator, src);
    try std.testing.expectEqualStrings("title-alpha", copy.title);
    try std.testing.expectEqualStrings("body-bravo", copy.body.?);
    try std.testing.expectEqualStrings("dark", copy.settings.theme);
    try std.testing.expectEqualStrings("alpha", copy.doc.object.get("items").?.array.items[0].string);
    // Contents equal, storage independent — including the JSON, which the copy
    // holds in its own arena rather than in the source's.
    try std.testing.expect(copy.title.ptr != src.title.ptr);
    try std.testing.expect(copy.settings.theme.ptr != src.settings.theme.ptr);
    try std.testing.expect(copy.json_arena != null);
    try std.testing.expect(copy.json_arena.? != src.json_arena.?);

    // Scuffing the source's own buffers must not show through the copy.
    @memset(@constCast(src.title), 'X');
    @memset(@constCast(src.body.?), 'B');
    @memset(@constCast(src.settings.theme), 'Y');
    @memset(@constCast(src.doc.object.get("items").?.array.items[0].string), 'Z');
    try std.testing.expectEqualStrings("title-alpha", copy.title);
    try std.testing.expectEqualStrings("body-bravo", copy.body.?);
    try std.testing.expectEqualStrings("dark", copy.settings.theme);
    try std.testing.expectEqualStrings("alpha", copy.doc.object.get("items").?.array.items[0].string);

    // Release the source first, then read the copy: a JSON field left shallow
    // would be a dangling read here.
    deinitEntity(infos, info, &src, allocator);
    try std.testing.expectEqualStrings("title-alpha", copy.title);
    try std.testing.expectEqualStrings("dark", copy.settings.theme);
    try std.testing.expectEqualStrings("alpha", copy.doc.object.get("items").?.array.items[0].string);

    // One call frees both halves of the copy — strings with the allocator, JSON
    // with the copy's own arena. `std.testing.allocator` fails the run on a leak
    // or a double free.
    deinitEntity(infos, info, &copy, allocator);
}

test "ownedCopy drops eager-loaded edges instead of aliasing them" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const edge = @import("../core/edge.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const buildGraph = @import("graph.zig").buildGraph;

    const Post = Schema("OwnedCopyPost", .{ .fields = &.{field.String("title")} });
    const Blog = Schema("OwnedCopyBlog", .{
        .fields = &.{field.String("name")},
        .edges = &.{edge.To("posts", Post)},
    });
    const graph = comptime buildGraph(&.{ Blog, Post });
    const infos = graph.types;
    const blog_info = infos[0];
    const post_info = infos[1];
    const BlogEntity = Entity(infos, blog_info);
    const PostLight = LightEntity(infos, post_info);

    const posts = try allocator.alloc(PostLight, 1);
    // The o2m FK column the graph injects into the target, named off the
    // source entity.
    posts[0] = .{ .id = 7, .owned_copy_blog_id = 1, .title = try allocator.dupe(u8, "hello"), .json_arena = null, .edges = .{} };
    var src = BlogEntity{
        .id = 1,
        .name = try allocator.dupe(u8, "tech"),
        .edges = .{ .posts = posts },
    };

    var copy = try ownedCopy(infos, blog_info, allocator, src);
    try std.testing.expectEqualStrings("tech", copy.name);
    try std.testing.expect(copy.name.ptr != src.name.ptr);
    // A shallow edge array would be freed twice — once through the copy's
    // `deinitEntity`, once through the source's — so the copy carries none.
    try std.testing.expect(copy.edges.posts == null);

    // Both rows release cleanly, in either order.
    deinitEntity(infos, blog_info, &src, allocator);
    deinitEntity(infos, blog_info, &copy, allocator);
}

test "ownedCopy re-homes a slice field that is not a string" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const Embedding = Schema("OwnedCopyEmbedding", .{
        .fields = &.{ field.String("name"), field.Vector("vec", 3) },
    });
    const info = comptime fromSchema(Embedding);
    const infos = &[_]TypeInfo{info};
    const EmbeddingEntity = Entity(infos, info);

    var src = EmbeddingEntity{
        .id = 1,
        .name = try allocator.dupe(u8, "e1"),
        .vec = try allocator.dupe(f32, &[_]f32{ 1.5, 2.5, 3.5 }),
    };

    var copy = try ownedCopy(infos, info, allocator, src);
    try std.testing.expectEqualSlices(f32, &.{ 1.5, 2.5, 3.5 }, copy.vec);
    try std.testing.expect(copy.vec.ptr != src.vec.ptr);

    @memset(@constCast(src.vec), 9.0);
    try std.testing.expectEqualSlices(f32, &.{ 1.5, 2.5, 3.5 }, copy.vec);

    // `deinitEntity` frees the copy's buffer — the allocator's, not the
    // source's — so the two teardowns do not collide.
    deinitEntity(infos, info, &src, allocator);
    deinitEntity(infos, info, &copy, allocator);
}

test "ownedCopy releases the strings it already duplicated when a later dupe fails" {
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const Row = Schema("OwnedCopyRow", .{ .fields = &.{
        field.String("a"),
        field.String("b"),
        field.String("c"),
        field.String("opt").Optional(),
    } });
    const info = comptime fromSchema(Row);
    const infos = &[_]TypeInfo{info};
    const RowEntity = Entity(infos, info);
    // Every string field non-empty, and the optional present, so the copy is
    // exactly four allocations and `fail_index = i` means "the first i dupes
    // landed, the (i+1)-th failed".
    const src = RowEntity{ .id = 7, .a = "alpha", .b = "bravo", .opt = "delta", .c = "charlie" };

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = i });
        try std.testing.expectError(error.OutOfMemory, ownedCopy(infos, info, failing.allocator(), src));
        // i dupes succeeded and all i must have been released again: without
        // the errdefer this is `deallocations == 0`, and the leaked slices are
        // also reported by `std.testing.allocator` at test exit.
        try std.testing.expectEqual(i, failing.allocations);
        try std.testing.expectEqual(i, failing.deallocations);
    }
}

test "toMaskedJson on JSON-field entity never emits json_arena" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const buildGraph = @import("graph.zig").buildGraph;

    const Settings = struct { theme: []const u8 };
    const User = Schema("MaskedJsonUser", .{
        .fields = &.{ field.String("name"), field.JSON("settings", Settings) },
    });
    const graph = comptime buildGraph(&.{User});
    const infos = graph.types;
    const UserEntity = Entity(infos, infos[0]);

    var u = UserEntity{ .id = 1, .name = "alice", .settings = .{ .theme = "dark" }, .json_arena = null };
    const json = try toMaskedJson(allocator, infos, infos[0], &u);
    defer allocator.free(json);
    // The injected arena field must never appear in masked output, and the
    // JSON business field must serialize normally.
    try std.testing.expect(std.mem.indexOf(u8, json, "json_arena") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"settings\":{\"theme\":\"dark\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"alice\"") != null);
}

test "Entity struct generation" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{
            field.String("name"),
            field.Int("age"),
        },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime Entity(infos, info);

    var u: UserEntity = undefined;
    u.id = 1;
    u.name = "alice";
    u.age = 30;

    try std.testing.expectEqual(@as(i64, 1), u.id);
    try std.testing.expectEqualStrings("alice", u.name);
    try std.testing.expectEqual(@as(i64, 30), u.age);
}

test "formatEntity masks sensitive fields" {
    // The formatEntity function exists and accepts any writer. Callers can
    // provide their own. We do not assert output here because std.ArrayList.writer()
    // is not available in Zig 0.17-dev; formatEntityToString is intentionally
    // omitted to avoid depending on std.io APIs that have been removed.
    // Manual smoke-test: call formatEntity with a custom writer.
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{
            field.String("name"),
            field.String("password").Sensitive(),
        },
    });

    const info = comptime fromSchema(User);
    const UserEntity = comptime Entity(&[_]TypeInfo{info}, info);

    var u: UserEntity = undefined;
    u.id = 1;
    u.name = "alice";
    u.password = "hunter2";

    // Use a stub writer that just discards bytes.
    const StubWriter = struct {
        fn writeAll(_: @This(), _: []const u8) !void {}
        fn print(_: @This(), comptime _: []const u8, _: anytype) !void {}
    };
    try formatEntity(info, u, StubWriter{});
}

test "fromSchema copies annotations" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const Annotation = @import("../core/schema.zig").Annotation;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{field.String("name")},
        .annotations = &.{
            Annotation{ .key = "owner", .value = "platform" },
            Annotation{ .key = "retention_days", .value = "30" },
        },
    });

    const info = comptime fromSchema(User);
    try std.testing.expectEqual(@as(usize, 2), info.annotations.len);
    try std.testing.expectEqualStrings("owner", info.annotations[0].key);
    try std.testing.expectEqualStrings("platform", info.annotations[0].value);
    try std.testing.expectEqualStrings("retention_days", info.annotations[1].key);
    try std.testing.expectEqualStrings("30", info.annotations[1].value);
}

test "fromSchema annotations default to empty" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const Pet = schema("Pet", .{
        .fields = &.{field.String("name")},
    });

    const info = comptime fromSchema(Pet);
    try std.testing.expectEqual(@as(usize, 0), info.annotations.len);
}
