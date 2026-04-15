# Zig 复刻 ent 项目规划方案

## 1. 项目目标

复刻 [ent](https://entgo.io/) —— Facebook/Meta 开源的 Go 实体框架（Entity Framework），用 Zig 语言实现一个**Schema-as-Code、静态类型安全、支持图遍历查询**的 ORM/实体框架。

### 1.1 为什么要复刻 ent
- ent 是 Go 生态中最先进的 ORM 之一，采用**代码生成**而非反射来实现静态类型安全
- 其**图模型（Graph-based）**设计对关系型数据库的关联查询抽象非常优雅
- Zig 的 `comptime` 元编程能力有机会将 ent 的“运行时代码生成”模式转化为“编译时生成”，减少工具链复杂度

### 1.2 核心复刻原则
1. **Schema 即代码**：用 Zig 代码直接定义实体、字段、边、索引
2. **完全静态类型**：所有查询构造器、变更构造器在编译期即类型安全
3. **SQL 优先**：第一阶段聚焦 SQL 方言（SQLite/PostgreSQL/MySQL），暂不实现 Gremlin
4. **分阶段迭代**：先实现最小可用核心（MVP），再逐步添加高级特性

---

## 2. 原 ent 架构深度分析

### 2.1 核心抽象层

```
┌─────────────────────────────────────────────────────────────┐
│  用户层 (User Code)                                          │
│  - schema/user.zig 定义 Fields/Edges/Indexes                │
│  - client.User.Create().SetName("foo").Save(ctx)            │
├─────────────────────────────────────────────────────────────┤
│  生成的类型安全 API (Generated Code)                         │
│  - Client, Tx                                               │
│  - UserCreate, UserUpdate, UserDelete                       │
│  - UserQuery (Where/Order/Limit/Edge Traversal)             │
│  - UserMutation, predicate.User, user.OrderOption           │
├─────────────────────────────────────────────────────────────┤
│  Schema 加载与图模型 (entc/load + entc/gen)                  │
│  - 解析 Go AST/反射获取 Schema 描述                         │
│  - 构建 Graph → Type → Field → Edge 内部模型               │
│  - 通过 Go template 生成上述代码                            │
├─────────────────────────────────────────────────────────────┤
│  存储抽象层 (dialect)                                        │
│  - dialect.Driver (Exec/Query/Tx/Close/Dialect)             │
│  - dialect/sql: SQL builder, Scanner, Driver wrapper        │
│  - dialect/sql/sqlgraph: 图遍历的 SQL 实现层                │
│  - dialect/sql/schema: 基于 Atlas 的迁移引擎                │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 代码生成产物（以 `examples/start` 为例）

一个 `User` schema 会生成以下文件：

| 文件 | 职责 |
|------|------|
| `client.go` | Client 根入口，管理所有实体 Client 和事务 |
| `user.go` | `User` struct 定义 |
| `user_create.go` | `UserCreate` builder（字段 setter、edge adder、Save/Exec） |
| `user_update.go` | `UserUpdate` / `UserUpdateOne` builder |
| `user_delete.go` | `UserDelete` / `UserDeleteOne` builder |
| `user_query.go` | `UserQuery` builder（Where/Order/Limit/All/First/Only/IDs/Count/Exist/Edge traversal） |
| `user/user.go` | 元数据常量（Table/FieldID/EdgeCars/Column 列表/OrderOption/Validators） |
| `user/where.go` | 所有 predicate 函数（`NameEQ`, `NameContains`, `AgeGT` 等） |
| `mutation.go` | 统一的 `Mutation` 接口和所有具体 `UserMutation` 实现 |
| `ent.go` | 公共类型别名（Hook/Policy/Querier/Error types）、排序/聚合辅助函数 |
| `tx.go` | 事务包装器 |
| `migrate/schema.go` | 数据库表结构定义（用于迁移） |
| `hook/hook.go` | Hook 辅助类型和函数 |

### 2.3 关键设计模式

1. **Builder 链式调用**：所有 Create/Update/Query 都返回自身类型，支持 fluent API
2. **Mutation 作为中间态**：所有变更操作先写入 `UserMutation`，再统一翻译成 `sqlgraph.CreateNode/UpdateNode`
3. **Predicate 函数作为一等公民**：`Where` 接收 `predicate.User` 函数类型，实现对 `sql.Selector` 的修改
4. **Edge 的图抽象**：内部使用 `sqlgraph.Step` 描述跨表关系，支持 O2O/O2M/M2M 的 SQL JOIN/子查询
5. **Template 驱动代码生成**：大量使用 Go 的 `text/template`，模板位于 `entc/gen/template/*.tmpl`

---

## 3. Zig 复刻的设计决策

### 3.1 核心差异：Zig comptime 能做什么？

| ent (Go) | Zig 复刻方案 |
|----------|-------------|
| 运行时通过 AST/反射解析 Schema | **编译时通过 `comptime` 解析 Schema struct** |
| 用 Go template 生成 `.go` 文件 | **用 `comptime` 直接生成类型和函数，无需外部代码生成工具** |
| `any` 类型的 Value/Mutation 接口 | **用 `union` 或泛型替代，避免动态类型** |
| 运行时 Hook/Interceptor 链 | **编译期函数指针数组或 vtable** |
| 依赖 `golang.org/x/tools` 做 AST 分析 | **直接用 Zig 的内省能力（`@typeInfo`）分析 Schema 定义** |

### 3.2 但 Zig 也有挑战

- **无运行时反射**：加载用户 Schema 的逻辑不能照搬 Go 的 `packages.Load` + AST 遍历，必须完全依赖 `comptime`
- **无泛型方法/接口**：Go 的 `ent.Query any`、`ent.Mutation interface` 在 Zig 中需要用 `anyopaque` + vtable 或编译期单态化替代
- **无垃圾回收**：需要显式管理内存（Arena/Pool 模式），这在 Query builder 和结果扫描中需要特别注意
- **生态不成熟**：没有 Zig 版的 `atlas` 迁移引擎，需要自研或简化

### 3.3 总体架构（Zig 版）

```
┌─────────────────────────────────────────────────────────────┐
│  用户层                                                       │
│  const UserSchema = schema.Struct({                          │
│    .fields = &.{ field.int("age"), field.string("name") },  │
│    .edges = &.{ edge.to("cars", CarSchema) },               │
│  });                                                          │
├─────────────────────────────────────────────────────────────┤
│  comptime 层（框架核心）                                      │
│  - 解析 Schema struct，生成 Type/Field/Edge 元数据          │
│  - 生成实体 struct、Client、Builder、Predicate 函数         │
│  - 生成迁移所需的表结构定义                                   │
├─────────────────────────────────────────────────────────────┤
│  运行时层                                                     │
│  - SQL Builder（拼接 SQL 语句）                              │
│  - Driver 抽象（SQLite/Postgres/MySQL）                      │
│  - SQLGraph（将图遍历转换为 JOIN/子查询）                    │
│  - Migration Engine（表创建/变更）                           │
│  - Hook/Interceptor 执行链                                   │
└─────────────────────────────────────────────────────────────┘
```

---

## 4. 模块划分与目录结构

```
.
├── build.zig                    # 构建入口
├── src/
│   ├── core/
│   │   ├── schema.zig           # Schema 定义 comptime API
│   │   ├── field.zig            # Field builder (int, string, time, json, enum, ...)
│   │   ├── edge.zig             # Edge builder (O2O, O2M, M2M)
│   │   ├── index.zig            # Index builder
│   │   ├── mixin.zig            # Mixin 机制
│   │   ├── annotation.zig       # Annotation 元数据系统
│   │   └── config.zig           # Schema/Entity 配置
│   │
│   ├── codegen/
│   │   ├── graph.zig            # Graph/Type/Field/Edge 内部模型（comptime）
│   │   ├── type.zig             # 单实体代码生成逻辑
│   │   ├── client.zig           # Client/Tx 代码生成
│   │   ├── builder/
│   │   │   ├── create.zig       # Create builder 生成
│   │   │   ├── update.zig       # Update builder 生成
│   │   │   ├── delete.zig       # Delete builder 生成
│   │   │   └── query.zig        # Query builder 生成
│   │   ├── predicate.zig        # Where predicate 生成
│   │   ├── meta.zig             # 常量/元数据包生成
│   │   └── migrate.zig          # 迁移 schema 生成
│   │
│   ├── sql/
│   │   ├── builder.zig          # SQL AST builder (SELECT/INSERT/UPDATE/DELETE)
│   │   ├── dialect.zig          # Dialect 接口 (MySQL/Postgres/SQLite)
│   │   ├── driver.zig           # Driver 接口 (Exec/Query/Tx)
│   │   ├── scan.zig             # 结果扫描到 Zig struct
│   │   └── schema/
│   │       ├── migrate.zig      # 迁移引擎核心
│   │       ├── mysql.zig        # MySQL 方言 specifics
│   │       ├── postgres.zig     # PostgreSQL 方言 specifics
│   │       └── sqlite.zig       # SQLite 方言 specifics
│   │
│   ├── graph/
│   │   ├── step.zig             # sqlgraph.Step 等价物
│   │   ├── neighbors.zig        # 边遍历查询生成
│   │   └── predicate.zig        # 图级别 predicate 组合
│   │
│   ├── runtime/
│   │   ├── client.zig           # 运行时 Client 基础类型
│   │   ├── tx.zig               # 运行时事务管理
│   │   ├── hook.zig             # Hook/Interceptor 运行时支持
│   │   ├── mutation.zig         # Mutation 运行时接口
│   │   ├── error.zig            # 错误类型 (NotFound, NotSingular, Validation)
│   │   └── context.zig          # QueryContext 等运行时状态
│   │
│   ├── privacy/
│   │   └── policy.zig           # Privacy Policy 框架（可选阶段）
│   │
│   └── entql/
│       └── parser.zig           # EntQL 查询语言（可选阶段）
│
├── examples/
│   └── start/                   # 对标 ent/examples/start
│       ├── schema/
│       │   ├── user.zig
│       │   ├── car.zig
│       │   └── group.zig
│       └── main.zig
│
└── tests/
    └── integration/             # 集成测试
```

---

## 5. 分阶段实施计划

### Phase 0: 基础设施（预计 2-3 周）

**目标**：搭建项目骨架，实现 SQL Builder 和基础 Driver 抽象

- [ ] 项目初始化 (`build.zig`, CI, 测试框架)
- [ ] `src/sql/builder.zig`：实现 SQL AST 拼接
  - `Select`, `Insert`, `Update`, `Delete`
  - `Table`, `Column`, `Join`, `Where`, `Order`, `GroupBy`, `Limit/Offset`
- [ ] `src/sql/dialect.zig`：Dialect 接口与参数占位符差异（`?` vs `$1`）
- [ ] `src/sql/driver.zig`：Driver / Tx 抽象
- [ ] `src/sql/scan.zig`：将 `sqlite3`/`libpq` 结果行扫描到 Zig struct/原始类型
- [ ] 接入 `zig-sqlite` 或 C 绑定，完成 SQLite Driver 实现

**验收标准**：
```zig
const sql = @import("zent/sql");
const query = sql.Select(sql.Table("users").C("id"), sql.Table("users").C("name"))
    .From(sql.Table("users"))
    .Where(sql.EQ("age", 30));
// query.Query() -> "SELECT "id", "name" FROM "users" WHERE "age" = ?", [30]
```

### Phase 1: comptime Schema 解析（预计 3-4 周）

**目标**：实现 Schema 定义的 comptime API，能从 Zig struct/声明中提取元数据

- [ ] 设计 `schema.Struct` / `field.String` / `edge.To` / `index.Fields` 的 comptime API
- [ ] 实现 `src/codegen/graph.zig`：遍历 Schema 声明，构建 comptime Graph/Type/Field/Edge 模型
- [ ] 字段类型系统映射：Zig 类型 ↔ SQL 类型（`i32`→`INT`, `[]const u8`→`TEXT`, `time.Timestamp`→`TIMESTAMP`）
- [ ] 支持基础约束：`Unique`, `Optional`/`Required`, `Default`, `Immutable`, `Nillable`, `Validators`
- [ ] 支持基础 Edge 关系：O2M, O2O, M2M（含 inverse edge）

**Schema 定义示例（目标 API）**：
```zig
const zent = @import("zent");

pub const User = zent.schema.Struct(.{
    .fields = &.{
        zent.field.Int("age").Positive(),
        zent.field.String("name").Default("unknown"),
    },
    .edges = &.{
        zent.edge.To("cars", Car),
        zent.edge.From("groups", Group).Ref("users"),
    },
});
```

### Phase 2: 代码生成层 - 实体与 Builder（预计 4-5 周）

**目标**：基于 comptime Graph 模型，生成类型安全的运行时代码

- [ ] `src/codegen/type.zig`：生成实体 struct（如 `User` struct，含字段和可能的 loaded edges）
- [ ] `src/codegen/builder/create.zig`：生成 `UserCreate` builder
  - 字段 setter（`SetAge`, `SetName`）
  - Edge adder（`AddCars`, `AddGroups`）
  - `Save(ctx)` → 调用 `sqlgraph.CreateNode`
- [ ] `src/codegen/builder/update.zig`：生成 `UserUpdate` / `UserUpdateOne`
- [ ] `src/codegen/builder/delete.zig`：生成 `UserDelete` / `UserDeleteOne`
- [ ] `src/codegen/builder/query.zig`：生成 `UserQuery`
  - `Where`, `Order`, `Limit`, `Offset`, `Unique`
  - 终端操作：`All`, `First`, `Only`, `IDs`, `Count`, `Exist`
  - Edge traversal：`QueryCars`, `QueryGroups`
- [ ] `src/codegen/predicate.zig`：生成 `where` 包中的 predicate 函数
- [ ] `src/codegen/meta.zig`：生成元数据常量（Table, FieldID, Columns, OrderOptions）
- [ ] `src/codegen/client.zig`：生成 `Client` 和 `Tx` 入口

**关键设计问题**：
- Query builder 在 Zig 中如何存储可变数量的 predicate？
  - **方案**：使用 ArenaAllocator + `std.ArrayList(predicate.User)`
- Edge traversal 的类型安全如何保证？
  - **方案**：`QueryCars()` 返回的 `CarQuery` 类型在 comptime 中由 Edge.Type 确定

### Phase 3: SQLGraph 与图遍历（预计 3-4 周）

**目标**：实现 ent 最核心的“图遍历”能力，将 Edge 查询翻译为 SQL

- [ ] `src/graph/step.zig`：定义 `Step`（From/To/Edge）
- [ ] `src/graph/neighbors.zig`：
  - `SetNeighbors`：生成 JOIN 或子查询获取关联节点
  - `OrderByNeighborsCount` / `OrderByNeighborTerms`
- [ ] 实现 Edge 加载策略：
  - Eager loading（`WithCars` 类似功能）
  - Lazy loading（通过已查询的节点继续 traversal）
- [ ] O2M / O2O / M2M 的 SQL 生成正确性验证

### Phase 4: 迁移引擎（预计 2-3 周）

**目标**：实现自动化的 Schema → Database 表结构同步

- [ ] `src/sql/schema/migrate.zig`：迁移引擎核心
  - 从 comptime Schema 生成 `Table` / `Column` / `ForeignKey` / `Index` 描述
  - 对比当前数据库状态与目标状态（简化版：仅支持创建，暂不支持 ALTER）
- [ ] 方言 specifics：MySQL/Postgres/SQLite 的类型映射和语法差异
- [ ] `client.Schema.Create(ctx)` 入口

**策略**：第一阶段只做 **Create-Only Migration**（对标 ent 的 `Schema.Create`），不做复杂的 diff & alter。

### Phase 5: 高级特性（可选，视进度而定）

按优先级排序：

1. **Hooks & Interceptors**
   - Mutation hooks（Create/Update/Delete 前后拦截）
   - Query interceptors / traversers
2. **Mixin 机制**
   - 可复用的字段/边/钩子组合（如 TimeMixin：created_at/updated_at）
3. **Privacy Policy**
   - 基于 Policy 接口的查询/变更权限控制
4. **JSON / Enum / UUID / Other 字段类型**
5. **Edge Schema（M2M 中间表显式建模）**
6. **Views（只读实体）**
7. **EntQL（类 GraphQL 的查询语言）**
8. **PostgreSQL / MySQL 完整支持**

---

## 6. 关键技术挑战与应对

### 6.1 comptime 代码生成的边界

**问题**：Zig 的 `comptime` 不能直接“写入文件生成新代码”，它只能生成类型和函数供当前编译单元使用。

**应对**：
- 采用**单文件入口模式**：用户在一个 `ent.zig` 中声明所有 Schema，通过 `comptime` 展开所有类型
- 不追求“生成可独立 import 的文件树”，而是让框架在编译期直接实例化所有 builder 类型
- 必要时可用 `build.zig` 或小型代码生成脚本（Zig 编写）预处理模板文件

### 6.2 Predicate 系统的类型安全

**问题**：ent 的 `Where(predicate.User)` 本质上是 `func(*sql.Selector)`。Zig 没有函数类型的 interface，也没有闭包。

**应对**：
- 定义统一的 `Predicate` 结构体：
  ```zig
  pub const Predicate = struct {
      apply: *const fn (self: *const Predicate, selector: *sql.Selector) void,
      context: *const anyopaque,
  };
  ```
- 每个 predicate 函数（如 `NameEQ`）返回一个携带具体 context 的 `Predicate` 实例
- 或使用 `comptime` 单态化：让 `Where` 接受任意实现了 `apply` 函数的类型

### 6.3 内存管理

**问题**：Query builder 需要动态收集 predicates/orders/with edges，Zig 需要显式 allocator。

**应对**：
- 所有 builder（Create/Update/Query）都持有一个 `*std.mem.Allocator`
- Client 初始化时注入 allocator（或 Arena），builder 的 `Save/All` 方法负责释放中间态
- 扫描结果时，字符串/BLOB 类型由调用方决定所有权（复制或借用）

### 6.4 数据库 C 绑定选择

| 数据库 | 推荐绑定 |
|--------|----------|
| SQLite | [zig-sqlite](https://github.com/vrischmann/zig-sqlite) 或直接用 `libsqlite3` C API |
| PostgreSQL | `libpq` C binding（Zig 可直接 import `libpq-fe.h`）|
| MySQL | `libmysqlclient` 或 `mariadb-connector-c` |

---

## 7. 与原版 ent 的功能对标

| 功能 | ent (Go) | Zig 复刻目标 |
|------|----------|-------------|
| Schema As Code | ✅ | ✅ 核心目标 |
| 静态类型 API | ✅ 代码生成 | ✅ comptime 生成 |
| SQL Builder | ✅ | ✅ 自研 |
| SQLGraph | ✅ | ✅ 自研 |
| Auto Migration | ✅ (Atlas) | ⚠️ 简化版，先做 Create-only |
| MySQL/Postgres/SQLite | ✅ | ⚠️ SQLite 优先，其余后续 |
| Gremlin | ✅ | ❌ 暂不实现 |
| Hooks | ✅ | ⚠️ Phase 5 |
| Interceptors | ✅ | ⚠️ Phase 5 |
| Privacy | ✅ | ⚠️ Phase 5 |
| Mixin | ✅ | ⚠️ Phase 5 |
| EntQL | ✅ | ❌ 远期目标 |
| Edge Schema | ✅ | ⚠️ Phase 5 |
| Views | ✅ | ⚠️ Phase 5 |
| Global IDs | ✅ | ❌ 暂不实现 |
| Snapshot / Versioning | ✅ | ❌ 暂不实现 |

---

## 8. 下一步行动建议

1. **确认本方案**：请审查上述模块划分和阶段规划，确认范围与优先级
2. **创建项目骨架**：初始化 `build.zig`，建立 `src/sql/builder.zig` 并开始实现基础 SQL 拼接
3. **设计 Schema API**：细化 `schema.Struct` / `field.*` / `edge.*` 的 comptime 接口设计
4. **选定 SQLite 绑定**：调研 `zig-sqlite` 是否满足需求，或决定直接用 C API
5. **编写第一个示例**：从 `examples/start` 的 User/Car/Group 三表关系入手，驱动核心功能实现

---

## 9. 参考资源

- 原项目：`/Users/cborli/ws_zig/zent/_ref/ent` (entgo.io/ent)
- 关键源码目录：
  - `ent.go` — 核心接口定义
  - `entc/` — 代码生成器
  - `schema/` — Schema DSL
  - `dialect/sql/` — SQL 构建器与驱动
  - `dialect/sql/sqlgraph/` — 图遍历 SQL 实现
  - `examples/start/` — 入门示例
