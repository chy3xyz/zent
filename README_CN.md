# zent

Zig 语言实现的实体框架（Entity Framework），复刻自 [ent](https://entgo.io/)。

[English Version](README.md)

当前发布：**v0.84.0**（包内版本与 tag 已同步；发版走 `scripts/release.sh`）。

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
- **高级 SQL 工具集**：带参原始谓词（`sql.RawArgs`）、聚合助手（`SumOrZero`/`AggregateOne`/`AggregateText`/`AggregateBy`）、Upsert 更新表达式（`SaveOrUpdateOnWith`）、行锁变体（`ForUpdateWith`）、原始查询 DTO 扫描（`sql_scan.queryAll`/`queryOne`）

## 快速开始

### 环境要求

- Zig `0.17.0`（正式版）或更新 —— CI 安装的正是一个 0.17.0 工具链，`build.zig.zon` 的
  `minimum_zig_version` 也写上它，所以更旧的构建会在构建一开始就被拒绝
  （“zig version … does not satisfy”），而不是编到一半报奇怪的错；0.17.0
  之前的 dev 快照之间 ABI 不稳定，要升级就一次性改
  CI、`minimum_zig_version`、这份 README 与 `AGENTS.md`（用 `zig env` 查看你的版本）。
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
    .url = "git+https://github.com/chy3xyz/zent.git#v0.84.0",
    .hash = "…", // 用 `zig fetch --save <url>` 自动填充
},

// build.zig
const zent_dep = b.dependency("zent", .{ .target = target, .optimize = optimize });
mod.addImport("zent", zent_dep.module("zent"));

// 用 zent 自己的发现逻辑链接它翻译过的驱动 —— 包含下面的交叉编译规则，
// 消费方不必再实现一遍（正是那份镜像副本把 macOS 归档塞进了 Linux 链接）：
const zent_build = b.lazyImport(@This(), "zent").?;
zent_build.linkDrivers(b, mod, target, .{}); // 只链 SQLite：.{ .pg = false }
```

每次 zent 发版后需要刷新锁定 hash：

```bash
zig fetch --save git+https://github.com/chy3xyz/zent.git#vX.Y.Z
```

### 交叉编译

驱动发现问的是**目标**，永远不是构建机。`pg_config`、`pkg-config` 与 Homebrew
前缀只在目标**就是**本机时才会被查询 —— 因为 Linux 链接行上的
`-L /opt/homebrew/…` 就是一个交给 `ld` 的 Mach-O 归档（一条错路径换几百条 `ld`
报错）。给交叉构建指向目标自己的 root：

```bash
XCOMPILE_ROOT=/path/to/sysroot zig build -Dtarget=aarch64-linux-gnu
```

`XCOMPILE_ROOT`（或 `ZENT_XROOT`）下会查找头文件 `usr/include[/postgresql]`、
`usr/include[/mariadb]`，以及库 `usr/lib/<multiarch>`（`aarch64-linux-gnu`、
`x86_64-linux-gnu` …）、`lib/<multiarch>`、`usr/lib64`、`usr/lib`。单个驱动可以用
`ZENT_PG_INCLUDE_DIR` / `ZENT_PG_LIB_DIR`、`ZENT_MYSQL_INCLUDE_DIR` /
`ZENT_MYSQL_LIB_DIR` 覆盖。root 有两条通道：环境变量（`XCOMPILE_ROOT`、`ZENT_XROOT`），
或父构建脚本转发过来的**选项** —— `b.dependency("zent", .{ .target = target,
.optimize = optimize, .xroot = root })`；CLI 的 `-D` 到不了依赖方，因为它只对**根包**
声明的选项校验，依赖只能收到父包传的值（转发 `xroot` 以前会得到 `invalid option`）。
`linkDrivers` 用同一份 root：`.\{ .root = … \}`。MySQL 的库名会在解析出的
lib 目录里探测 —— 先 `libmariadb` 再 `libmysqlclient` —— 所以 Debian sysroot 需要
`libmariadb-dev`，而不是它的 `mysqlclient` 兼容包。

既没有 root 也没有覆盖项的交叉构建会警告一次"已跳过 host 发现"。找不到的驱动绑定
随之缺失，表现为首次使用时的 `no module named sqlite3_c/pg_c/mysql_c` —— 这个错误
本身就说清了问题。

### 构建成本，以及在小机器上如何压缩

消费者**首次**构建的大头不是 zent 的代码生成，而是对驱动头文件跑的 `translate-c`
——每个驱动一个进程，而 zent 会为机器上装了头文件的每个驱动各跑一次。实测（80 实体的
消费方项目、macOS/arm64、清空 `ZIG_GLOBAL_CACHE_DIR`）：

| 步骤 | 墙钟 | 峰值内存 |
|---|---|---|
| `translate-c`，单个驱动（sqlite3、libpq 或 mariadb-connector-c） | ~26 s | ~590 MB |
| 消费方自己的编译——zent 为 80 个实体做代码生成 | ~4 s | ~440 MB |

全局缓存热时同一次构建约 13 s / 384 MB，而代码生成那半基本线性：**每实体约 +1.4 MB、
+0.1 s**（20 / 40 / 80 实体实测 7.8 s / 298 MB、9.0 s / 319 MB、12.6 s / 384 MB）。
所以内存紧张的构建机上，真正被拖垮的是头文件翻译，不是 comptime。

三个旋钮，按收益排序：

1. **只翻译你要链接的驱动。** 每个启用的驱动是一个 `translate-c` 进程，且它们会并发，
   所以三套头文件齐全的机器要同时承受三份峰值。通过依赖项把开关传进去：

   ```zig
   const zent = b.dependency("zent", .{
       .target = target,
       .optimize = optimize,
       .sqlite = false, // 例如 PostgreSQL-only 部署
       .mysql = false,
   });
   ```

   默认行为不变（机器上有头文件就翻译）；把**你确实在用的**驱动关掉，会在首次使用时
   报 `no module named 'pg_c'`（或 `sqlite3_c` / `mysql_c`），错误直接点名。

2. **保留全局缓存。** 把 `ZIG_GLOBAL_CACHE_DIR` 放在持久卷上，翻译就从"每次构建"
   变成"每台机器一次"（一套驱动约 75 MB）；无缓存时那 87 s 首次构建里约 60 s 是构建
   系统自身的工作。

3. **限制并发**：内存紧张时用 `zig build -j2`（或 `-j1`）。上面的峰值是**每进程**的，
   小 VM 撑不住的是总和。慢一些，但能跑完。

另一件顺带值得知道的事：本仓库自身的 `zig build test` 峰值约 **1 GB**（它一次编译所有
测试根）。这属于 CI 的活，不要放在发布机器上。

## 贡献

欢迎贡献！请参阅 [CONTRIBUTING.md](CONTRIBUTING.md) 了解详细信息。

## 许可证

MIT License - 详见 [LICENSE](LICENSE) 文件。

## 致谢

- 灵感来自 [ent](https://entgo.io/) - Facebook/Meta 开源的 Go 实体框架
