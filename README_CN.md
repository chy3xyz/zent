# zent

Zig 语言实现的实体框架（Entity Framework），复刻自 [ent](https://entgo.io/)。

[English Version](README.md)

## 特性

- **Schema 即代码**：用 Zig 代码直接定义实体、字段、边、索引
- **完全静态类型安全**：所有查询构造器、变更构造器在编译期即类型安全
- **Comptime 驱动**：利用 Zig 的 comptime 元编程能力，无需外部代码生成工具
- **SQL 优先**：SQLite 为一等支持，同时提供 PostgreSQL/MySQL 驱动
- **图遍历查询**：优雅的关系型数据库关联查询抽象
- **Fluent API**：链式调用，简洁易用
- **Hooks 系统**：用于操作前后的运行时钩子
- **隐私策略**：用于访问控制的灵活策略框架
- **连接池**：基于 Mutex 的预热连接池，支持借出时健康检查

## 快速开始

### 环境要求

- Zig 0.17.0 或更高版本
- SQLite3 开发库

### 安装

```bash
git clone https://github.com/chy3xyz/zent.git
cd zent
```

### 运行示例

```bash
zig build run-start    # Schema 内省 + CRUD 冒烟测试
zig build run-complex  # 电商高级 SQL 操作演示
zig build run-pool     # 连接池使用演示
```

### 运行测试

```bash
zig build test
```

## 使用示例

### 定义 Schema

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

// 定义关系
pub const UserWithEdges = struct {
    pub const schema_name = User.schema_name;
    pub const fields = User.fields;
    pub const edges = &.{edge.To("cars", Car)};
    pub const indexes = User.indexes;
};
```

### 使用 Client

```zig
const std = @import("std");
const zent = @import("zent");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // 打开数据库连接
    var drv = try zent.sql_sqlite.SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    // 构建 Schema 图
    const graph = comptime zent.codegen.graph.buildGraph(&.{ UserWithEdges, Car });
    
    // 创建表
    try zent.sql_schema.migrateSchema(allocator, drv.asDriver(), graph.types);

    // 创建 Client
    var client = zent.codegen.client.makeClient(graph.types, allocator, drv.asDriver());

    // 创建用户
    var create_builder = client.user.Create();
    defer create_builder.deinit();
    _ = create_builder.setFieldValue("name", "Alice")
        .setFieldValue("age", 30)
        .setFieldValue("status", "active");
    const alice = try create_builder.Save();

    // 查询用户
    var qbuilder = client.user.Query();
    defer qbuilder.deinit();
    _ = qbuilder.Where(.{client.user.predicates.ageEQ(.{ .int = 30 })});
    var users = try qbuilder.All();
    defer users.deinit();
}
```

## 项目结构

```
zent/
├── src/
│   ├── core/           # Schema 定义 API
│   │   ├── schema.zig
│   │   ├── field.zig
│   │   ├── edge.zig
│   │   └── ...
│   ├── codegen/        # Comptime 代码生成
│   │   ├── graph.zig
│   │   ├── entity.zig
│   │   ├── client.zig
│   │   └── ...
│   ├── sql/            # SQL 构建器和驱动
│   │   ├── builder.zig
│   │   ├── driver.zig
│   │   ├── sqlite.zig
│   │   ├── postgres.zig
│   │   ├── mysql.zig
│   │   └── ...
│   ├── runtime/        # 运行时支持
│   │   └── hook.zig
│   ├── privacy/        # 隐私策略框架
│   │   └── policy.zig
│   └── root.zig        # 模块入口
├── examples/
│   └── start/          # 入门示例
├── build.zig           # Zig 构建文件
└── README.md
```

## 开发计划

- [x] Phase 0: SQL 构建器和基础驱动抽象
- [x] Phase 1: Comptime Schema 解析
- [x] Phase 2: 代码生成 - 实体与 Builder
- [x] Phase 3: SQLGraph 与图遍历
- [x] Phase 4: 迁移引擎
- [x] PostgreSQL 支持（占位符）
- [x] MySQL 支持（占位符）
- [x] Hooks 系统框架
- [x] 隐私策略框架
- [ ] 完整的 PostgreSQL 驱动实现
- [ ] 完整的 MySQL 驱动实现
- [ ] 更多高级特性

## 与 ent 的对比

| 功能 | ent (Go) | zent (Zig) |
|------|-----------|------------|
| Schema As Code | ✅ | ✅ |
| 静态类型 API | ✅ 代码生成 | ✅ comptime 生成 |
| SQL Builder | ✅ | ✅ |
| SQLGraph | ✅ | ✅ |
| 自动迁移 | ✅ (Atlas) | ✅ Create-only |
| SQLite | ✅ | ✅ |
| PostgreSQL/MySQL | ✅ | ✅ (占位符) |

## 贡献

欢迎贡献！请参阅 [CONTRIBUTING.md](CONTRIBUTING.md) 了解详细信息。

## 许可证

MIT License - 详见 [LICENSE](LICENSE) 文件。

## 致谢

- 灵感来自 [ent](https://entgo.io/) - Facebook/Meta 开源的 Go 实体框架
