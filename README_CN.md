# zent

Zig 语言实现的实体框架（Entity Framework），复刻自 [ent](https://entgo.io/)。

[English Version](README.md)

当前发布：**v0.32.2**（包内版本与 tag 已同步；发版走 `scripts/release.sh`）。

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

- Zig 0.17-dev —— CI 锁定 `0.17.0-dev.1567+f0354179a`。dev 快照之间 ABI 不稳定，
  若更新快照后编译失败，请使用该精确 commit（用 `zig env` 查看你的版本）。
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
    var create_builder = try client.user.Create();
    defer create_builder.deinit();
    _ = try create_builder.setFieldValue("name", "Alice");
    _ = try create_builder.setFieldValue("age", 30);
    _ = try create_builder.setFieldValue("status", "active");
    _ = try create_builder.setFieldValue("settings", UserSettings{ .theme = "dark", .notifications = true });
    _ = try create_builder.Save();

    // 查询用户
    var qbuilder = client.user.Query();
    defer qbuilder.deinit();
    _ = try qbuilder.Where(.{client.user.predicates.ageEQ(.{ .int = 30 })});
    var users = try qbuilder.All();
    defer {
        // 每个实体拥有自己的字符串字段，需逐行释放后再释放切片。
        // graph.types[0] 是 UserWithEdges 的 TypeInfo。
        for (users.items) |*u| zent.codegen.deinitEntity(graph.types, graph.types[0], u, allocator);
        users.deinit();
    }
}
```

### 业务极简 Helper 与 Schema 工具链

```zig
// 1. 单行极简 CRUD Helper
var u = try zent.crud_helpers.get(client.user, 100);
if (try zent.crud_helpers.exists(client.user, .{ preds.emailEQ("alice@example.com") })) { ... }
var p1 = try zent.crud_helpers.paginated(client.category, .{ preds.statusEQ(1) }, 1, 20);

// 2. 导出 Mermaid ER 架构图
const diagram = try zent.graph.mermaid.toMermaid(allocator, graph.types);
defer allocator.free(diagram);

// 3. 导出 Markdown 数据字典
const doc = try zent.graph.doc_exporter.toMarkdownDoc(allocator, graph.types, .{ .title = "数据库数据字典" });
defer allocator.free(doc);
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
- [x] Phase 4: 迁移引擎（差异式：增/删列、可选 ALTER TYPE）
- [x] PostgreSQL 驱动
- [x] MySQL 驱动
- [x] Hooks 系统框架
- [x] 隐私策略框架
- [x] 跨方言 mutation 对齐（RETURNING / UPSERT / savepoint 三方言全覆盖）
- [x] Interceptors（查询拦截 / 透明改写）
- [ ] SQL→Zig schema 反向生成 CLI
- [ ] 更多高级特性

## 与 ent 的对比

| 功能 | ent (Go) | zent (Zig) |
|------|-----------|------------|
| Schema As Code | ✅ | ✅ |
| 静态类型 API | ✅ 代码生成 | ✅ comptime 生成 |
| SQL Builder | ✅ | ✅ |
| SQLGraph | ✅ | ✅ |
| 自动迁移 | ✅ (Atlas) | ✅ 差异式（增/删列、可选 ALTER TYPE、历史表） |
| SQLite | ✅ | ✅ |
| PostgreSQL/MySQL | ✅ | ✅ |

## 消费者接线

把 zent 作为依赖加入，并自行链接你要用的驱动——库本身不会强制消费者链接 C：

```zig
// build.zig.zon
.zent = .{
    // 优先使用 git 依赖：GitHub tarball 归档在 zig 0.17-dev 上跨 fetch 不稳定
    // （hash 会漂移），而 pin 到某个 commit ref 始终解析到相同内容。
    .url = "git+https://github.com/chy3xyz/zent.git#v0.32.2",
    .hash = "…", // 用 `zig fetch --save <url>` 自动填充
},

// build.zig
const zent = b.dependency("zent", .{ .target = target, .optimize = optimize });
mod.addImport("zent", zent.module("zent"));
mod.linkSystemLibrary("sqlite3", .{}); // 或 libpq / mariadb-connector-c
```

每次 zent 发版后需要刷新锁定 hash：

```bash
zig fetch --save git+https://github.com/chy3xyz/zent.git#vX.Y.Z
```

## 贡献

欢迎贡献！请参阅 [CONTRIBUTING.md](CONTRIBUTING.md) 了解详细信息。

## 许可证

MIT License - 详见 [LICENSE](LICENSE) 文件。

## 致谢

- 灵感来自 [ent](https://entgo.io/) - Facebook/Meta 开源的 Go 实体框架
