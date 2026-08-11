# zent

A Zig language implementation of an Entity Framework, inspired by [ent](https://entgo.io/).

[中文版本](README_CN.md)

Current release: **v0.29.5** (package version synced to tags; see `scripts/release.sh`).

## Features

- **Schema as Code**: Define entities, fields, edges, and indexes directly in Zig code
- **Full Static Type Safety**: All query and mutation builders are type-safe at compile time
- **Comptime Driven**: Leverages Zig's comptime meta-programming capabilities, no external code generation tools needed
- **SQL First**: SQLite (first-class), PostgreSQL and MySQL drivers also supported
- **Graph Traversal Queries**: Elegant abstraction for relational database relationship queries
- **Fluent API**: Chainable calls, clean and easy to use
- **Hooks System**: Runtime hooks for before/after operations
- **Privacy Policy**: Flexible policy framework for access control
- **Connection Pool**: Mutex-backed pool with warmup and on-borrow health checks

## Quick Start

### Prerequisites

- Zig 0.17.0 or later
- SQLite3 development libraries

### Installation

```bash
git clone https://github.com/chy3xyz/zent.git
cd zent
```

### Run Examples

```bash
zig build run-start    # schema introspection + CRUD smoke test
zig build run-complex  # e-commerce demo with advanced SQL
zig build run-pool     # connection-pool usage demo
zig build benchmark    # micro-benchmarks
```

### Run Tests

```bash
zig build test
```

## Documentation

- [docs/BEST_PRACTICES.md](docs/BEST_PRACTICES.md) — best-practice patterns and pitfalls
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — layer map + memory contract
- [docs/UPGRADING.md](docs/UPGRADING.md) — version upgrades

## Usage Example

### Define Schema

```zig
const zent = @import("zent");
const field = zent.core.field;
const edge = zent.core.edge;
const Schema = zent.core.schema.Schema;

const UserSettings = struct {
    theme: []const u8,
    notifications: bool,
};

const User = Schema("User", .{
    .fields = &.{
        field.Int("age").Positive(),
        field.String("name").Default("unknown"),
        field.Enum("status", &.{ "active", "inactive" }),
        field.JSON("settings", UserSettings),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

const Car = Schema("Car", .{
    .fields = &.{
        field.String("model"),
        field.Time("registered_at"),
    },
});

// Define relationships
pub const UserWithEdges = struct {
    pub const schema_name = User.schema_name;
    pub const fields = User.fields;
    pub const edges = &.{edge.To("cars", Car)};
    pub const indexes = User.indexes;
};
```

### Using Client

```zig
const std = @import("std");
const zent = @import("zent");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Open database connection
    var drv = try zent.sql_sqlite.SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    // Build Schema graph
    const graph = comptime zent.codegen.graph.buildGraph(&.{ UserWithEdges, Car });
    
    // Create tables
    try zent.sql_schema.migrateSchema(allocator, drv.asDriver(), graph.types);

    // Create Client
    var client = zent.codegen.client.makeClient(graph.types, allocator, drv.asDriver());

    // Create user
    var create_builder = try client.user.Create();
    defer create_builder.deinit();
    _ = try create_builder.setFieldValue("name", "Alice");
    _ = try create_builder.setFieldValue("age", 30);
    _ = try create_builder.setFieldValue("status", "active");
    _ = try create_builder.setFieldValue("settings", UserSettings{ .theme = "dark", .notifications = true });
    _ = try create_builder.Save();

    // Query users
    var qbuilder = client.user.Query();
    defer qbuilder.deinit();
    _ = try qbuilder.Where(.{client.user.predicates.ageEQ(.{ .int = 30 })});
    var users = try qbuilder.All();
    defer {
        // Each entity owns its string fields; release them per row, then
        // the slice. `graph.types[0]` is the UserWithEdges TypeInfo.
        for (users.items) |*u| zent.codegen.deinitEntity(graph.types, graph.types[0], u, allocator);
        users.deinit();
    }
}
```

### Ergonomic Helpers & Schema Tooling

```zig
// 1. One-line CRUD Helpers
var u = try zent.crud_helpers.get(client.user, 100);
if (try zent.crud_helpers.exists(client.user, .{ preds.emailEQ("alice@example.com") })) { ... }
var p1 = try zent.crud_helpers.paginated(client.category, .{ preds.statusEQ(1) }, 1, 20);

// 2. Export Mermaid ER Diagram
const diagram = try zent.graph.mermaid.toMermaid(allocator, graph.types);
defer allocator.free(diagram);

// 3. Export Markdown Data Dictionary
const doc = try zent.graph.doc_exporter.toMarkdownDoc(allocator, graph.types, .{ .title = "DB Schema" });
defer allocator.free(doc);
```

## Project Structure

```
zent/
├── src/
│   ├── core/           # Schema definition API
│   │   ├── schema.zig
│   │   ├── field.zig
│   │   ├── edge.zig
│   │   └── ...
│   ├── codegen/        # Comptime code generation
│   │   ├── graph.zig
│   │   ├── entity.zig
│   │   ├── client.zig
│   │   └── ...
│   ├── sql/            # SQL builder and driver
│   │   ├── builder.zig
│   │   ├── driver.zig
│   │   ├── sqlite.zig
│   │   ├── postgres.zig
│   │   ├── mysql.zig
│   │   └── ...
│   ├── runtime/        # Runtime support
│   │   └── hook.zig
│   ├── privacy/        # Privacy policy framework
│   │   └── policy.zig
│   └── root.zig        # Module entry point
├── examples/
│   └── start/          # Getting started example
├── build.zig           # Zig build file
└── README.md
```

## Roadmap

- [x] Phase 0: SQL builder and basic driver abstraction
- [x] Phase 1: Comptime Schema parsing
- [x] Phase 2: Code generation - entities and builders
- [x] Phase 3: SQLGraph and graph traversal
- [x] Phase 4: Migration engine
- [x] PostgreSQL driver (basic)
- [x] MySQL driver (basic)
- [x] Hooks system framework
- [x] Privacy Policy framework
- [ ] Cross-dialect mutation parity (junction inserts, RETURNING, UPSERT)
- [ ] CLI tool for SQL→Zig schema generation
- [ ] More advanced features

## Comparison with ent

| Feature | ent (Go) | zent (Zig) |
|---------|-----------|------------|
| Schema As Code | ✅ | ✅ |
| Statically typed API | ✅ code generation | ✅ comptime generation |
| SQL Builder | ✅ | ✅ |
| SQLGraph | ✅ | ✅ |
| Auto migration | ✅ (Atlas) | ✅ Create-only |
| SQLite | ✅ | ✅ |
| PostgreSQL/MySQL | ✅ | ✅ (basic; some mutation paths SQLite-only) |

## Consumer wiring

Add zent as a dependency and link the driver **you** use — the library never
forces C linkage on consumers:

```zig
// build.zig.zon
.zent = .{
    // Prefer the git dependency: GitHub tarball archives are not stable
    // across fetches on zig 0.17-dev (hash churn), while a pinned commit
    // ref always resolves to the same content.
    .url = "git+https://github.com/chy3xyz/zent.git#v0.29.5",
    .hash = "…", // run `zig fetch --save <url>` to fill this in
},

// build.zig
const zent = b.dependency("zent", .{ .target = target, .optimize = optimize });
mod.addImport("zent", zent.module("zent"));
mod.linkSystemLibrary("sqlite3", .{}); // or libpq / mariadb-connector-c
```

After every zent release the pinned hash must be refreshed:

```bash
zig fetch --save git+https://github.com/chy3xyz/zent.git#vX.Y.Z
```

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Inspired by [ent](https://entgo.io/) - Facebook/Meta's open source Go entity framework
