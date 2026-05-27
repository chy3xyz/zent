# zent

A Zig language implementation of an Entity Framework, inspired by [ent](https://entgo.io/).

[中文版本](README_CN.md)

## Features

- **Schema as Code**: Define entities, fields, edges, and indexes directly in Zig code
- **Full Static Type Safety**: All query and mutation builders are type-safe at compile time
- **Comptime Driven**: Leverages Zig's comptime meta-programming capabilities, no external code generation tools needed
- **SQL First**: SQLite support (current), PostgreSQL/MySQL support (placeholder)
- **Graph Traversal Queries**: Elegant abstraction for relational database relationship queries
- **Fluent API**: Chainable calls, clean and easy to use
- **Hooks System**: Runtime hooks for before/after operations
- **Privacy Policy**: Flexible policy framework for access control

## Quick Start

### Prerequisites

- Zig 0.17.0 or later
- SQLite3 development libraries

### Installation

```bash
git clone https://github.com/chy3xyz/zent.git
cd zent
```

### Run Example

```bash
zig build run-start
```

### Run Tests

```bash
zig build test
```

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
    var create_builder = client.user.Create();
    defer create_builder.deinit();
    _ = create_builder.setFieldValue("name", "Alice")
        .setFieldValue("age", 30)
        .setFieldValue("status", "active");
    const alice = try create_builder.Save();

    // Query users
    var qbuilder = client.user.Query();
    defer qbuilder.deinit();
    _ = qbuilder.Where(.{client.user.predicates.ageEQ(.{ .int = 30 })});
    var users = try qbuilder.All();
    defer users.deinit();
}
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
- [x] PostgreSQL support (placeholder)
- [x] MySQL support (placeholder)
- [x] Hooks system framework
- [x] Privacy Policy framework
- [ ] Full PostgreSQL driver implementation
- [ ] Full MySQL driver implementation
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
| PostgreSQL/MySQL | ✅ | ✅ (placeholder) |

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Inspired by [ent](https://entgo.io/) - Facebook/Meta's open source Go entity framework
