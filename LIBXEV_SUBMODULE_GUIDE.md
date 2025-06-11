# libxev Submodule 使用指南

## 📋 概述

本项目使用 git submodule 管理 libxev 依赖，固定到特定版本 `58507577fc87b89471809a1a23415bee1d81814d`，避免国内网络环境下 `zig fetch` 的问题。

## 🔧 设置步骤

### 1. 克隆项目（包含 submodule）

```bash
# 克隆项目并初始化 submodule
git clone --recursive https://github.com/your-repo/zig-http.git

# 或者先克隆，再初始化 submodule
git clone https://github.com/your-repo/zig-http.git
cd zig-http
git submodule update --init --recursive
```

### 2. 更新 libxev 到指定版本

```bash
# 进入 libxev 目录
cd libxev

# 切换到指定的 commit
git checkout 58507577fc87b89471809a1a23415bee1d81814d

# 返回项目根目录
cd ..
```

### 3. 构建和运行

```bash
# 构建所有目标
zig build

# 运行 libxev HTTP 服务器
zig build run-libxev

# 运行基础测试
zig build run-test

# 运行 libxev 基础测试
zig build run-libxev-test
```

## 📁 项目结构

```
zig-http/
├── build.zig              # 构建配置
├── build.zig.zon          # 依赖配置（指向本地 libxev）
├── libxev/                 # libxev submodule
│   ├── src/
│   ├── build.zig
│   └── ...
├── src/
│   ├── libxev_http_engine.zig  # 增强版 libxev HTTP 服务器
│   ├── libxev_basic_test.zig   # libxev 基础测试
│   └── ...
└── README.md
```

## ⚙️ 配置说明

### build.zig.zon
```zig
.{
    .name = "zig_http",
    .version = "0.1.0",
    .minimum_zig_version = "0.14.0",

    .dependencies = .{
        .libxev = .{
            .path = "libxev",  // 指向本地 submodule
        },
    },

    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "libxev",
    },
}
```

### build.zig 中的依赖配置
```zig
// 添加 libxev 依赖 (使用本地 submodule)
const libxev_dep = b.dependency("libxev", .{
    .target = target,
    .optimize = optimize,
});

// 为可执行文件添加 libxev 模块
libxev_http.root_module.addImport("xev", libxev_dep.module("xev"));
```

## 🚀 功能特性

### libxev HTTP 服务器
- **高性能异步架构**: 基于 libxev 事件循环
- **完整 HTTP 协议支持**: 请求解析、响应构建、路由系统
- **生产级特性**: 连接管理、错误处理、日志记录
- **路由功能**:
  - `GET /` - 主页
  - `GET /api/status` - 服务器状态
  - `GET /api/health` - 健康检查
  - `POST /api/echo` - 回显服务
  - `GET /users/:id` - 用户信息
  - `GET /users/:id/profile` - 用户资料

### 测试端点
```bash
# 主页
curl http://localhost:8080/

# API 状态
curl http://localhost:8080/api/status | jq .

# 用户信息
curl http://localhost:8080/users/123 | jq .

# 回显测试
curl -X POST -d '{"test":"data"}' \
     -H "Content-Type: application/json" \
     http://localhost:8080/api/echo | jq .
```

## 🔄 更新 libxev

如果需要更新到新版本的 libxev：

```bash
# 进入 libxev 目录
cd libxev

# 拉取最新代码
git fetch origin

# 切换到新的 commit 或 tag
git checkout <new-commit-hash>

# 返回项目根目录并提交更改
cd ..
git add libxev
git commit -m "Update libxev to <new-version>"
```

## 🐛 故障排除

### 1. submodule 未初始化
```bash
git submodule update --init --recursive
```

### 2. libxev 版本不正确
```bash
cd libxev
git checkout 58507577fc87b89471809a1a23415bee1d81814d
cd ..
```

### 3. 构建错误
```bash
# 清理构建缓存
rm -rf zig-cache zig-out

# 重新构建
zig build
```

## 📝 优势

1. **网络友好**: 避免 `zig fetch` 的网络问题
2. **版本固定**: 确保所有开发者使用相同版本的 libxev
3. **离线开发**: 一旦克隆完成，无需网络连接即可构建
4. **版本控制**: libxev 版本变更有明确的 git 历史记录
5. **构建稳定**: 不依赖外部网络服务的可用性

## 🎯 总结

通过使用 git submodule 管理 libxev 依赖，我们实现了：
- ✅ 避免国内网络环境的 `zig fetch` 问题
- ✅ 固定到稳定的 libxev 版本
- ✅ 保持构建系统的简洁性
- ✅ 支持离线开发和构建
- ✅ 版本管理的透明性和可控性
