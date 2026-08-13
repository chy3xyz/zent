# 贡献指南

感谢你对 zent 项目的关注！我们欢迎各种形式的贡献。

## 行为准则

参与本项目请保持尊重和友善，避免任何形式的骚扰或不尊重行为。

## 如何贡献

### 报告问题

如果你发现了 bug 或有功能建议，请：

1. 先搜索现有 [Issues](../../issues)，避免重复报告
2. 创建新 Issue，使用清晰的标题和详细的描述
3. 提供复现步骤（如果是 bug）
4. 说明你的环境（Zig 版本、操作系统等）

### 提交代码

1. Fork 本仓库
2. 创建你的特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交你的更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启一个 Pull Request

## 开发设置

### 环境要求

- Zig 0.17.0 或更高版本
- SQLite3 开发库

### 克隆项目

```bash
git clone https://github.com/chy3xyz/zent.git
cd zent
```

### 构建项目

```bash
zig build
```

### 运行测试

```bash
zig build test
```

### 运行示例

```bash
zig build run-start
```

## 代码风格

- 遵循 Zig 官方代码风格
- 使用 `zig fmt` 格式化代码
- 保持代码简洁和可读
- 添加必要的注释

## 提交信息规范

使用清晰的提交信息，格式建议：

```
<type>(<scope>): <subject>

<body>
```

类型：
- `feat`: 新功能
- `fix`: 修复 bug
- `docs`: 文档更新
- `style`: 代码格式调整
- `refactor`: 重构
- `test`: 测试相关
- `chore`: 构建/工具相关

## Pull Request 流程

1. 确保你的代码通过所有测试
2. 更新相关文档（如果需要）
3. 在 PR 描述中说明你的更改
4. 等待代码审查
5. 根据审查意见进行修改
6. PR 被合并！

## 获得帮助

如果你有问题或需要帮助，可以：
- 查看 [README.md](README.md)
- 查看 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) 了解架构设计
- 创建 Issue 提问

## 许可证

通过贡献代码，你同意你的贡献将在 MIT 许可证下发布。

再次感谢你的贡献！
