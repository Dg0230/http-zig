# Zig HTTP 服务器

一个用 Zig 语言实现的简单而高效的 HTTP 服务器。

## 特性

- 🚀 **高性能**: 基于 Zig 的零成本抽象和手动内存管理
- 🔧 **模块化设计**: 清晰的模块分离，易于扩展
- 🛣️ **路由系统**: 支持 GET、POST、PUT、DELETE 等 HTTP 方法
- 🧵 **多线程**: 每个连接在独立线程中处理
- 📝 **请求解析**: 完整的 HTTP 请求解析功能
- 📤 **响应构建**: 灵活的 HTTP 响应构建系统
- 🍪 **Cookie 支持**: 内置 Cookie 设置和管理
- 🔀 **中间件**: 支持中间件模式（使用 struct 模拟闭包）
- 📁 **路由组**: 支持路由分组管理

## 项目结构

```
Zig-HTTP/
├── .gitignore             # Git 忽略配置
├── README.md              # 项目说明文档
├── build.zig              # 构建配置文件
└── src/
    ├── buffer.zig         # 缓冲区管理模块
    ├── config.zig         # 服务器配置模块
    ├── context.zig        # 请求上下文管理
    ├── http_engine.zig    # HTTP 引擎核心
    ├── main.zig           # 程序入口点
    ├── middleware.zig     # 中间件框架
    ├── middleware/
    │   ├── cors.zig       # CORS 中间件
    │   ├── error_handler.zig # 错误处理中间件
    │   └── logger.zig     # 日志记录中间件
    ├── request.zig        # HTTP 请求解析模块
    ├── response.zig       # HTTP 响应构建模块
    ├── router.zig         # 路由管理模块
    └── server.zig         # HTTP 服务器核心实现
```

## 快速开始

### 前置要求

- Zig 0.14.1 或更高版本

### 编译和运行

```bash
# 编译项目
zig build

# 运行服务器
zig build run

# 或者直接运行
zig run src/main.zig
```

服务器将在 `http://127.0.0.1:8080` 启动。

### 基本使用示例

```zig
const std = @import("std");
const HttpServer = @import("server.zig").HttpServer;
const ServerConfig = @import("server.zig").ServerConfig;
const Context = @import("context.zig").Context;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 服务器配置
    const config = ServerConfig{
        .port = 8080,
        .max_connections = 1000,
        .read_timeout_ms = 5000,
        .write_timeout_ms = 5000,
    };

    var server = try HttpServer.initWithConfig(allocator, config);
    defer server.deinit();

    // 添加中间件
    try server.use(loggerMiddleware);
    try server.use(corsMiddleware);

    // 设置路由
    _ = try server.get("/", handleHome);
    _ = try server.get("/hello", handleHello);
    _ = try server.post("/echo", handleEcho);

    // 启动服务器
    try server.listen();
}

fn handleHome(ctx: *Context) !void {
    try ctx.response.setTextBody("Welcome to Zig HTTP Server!");
}

fn handleHello(ctx: *Context) !void {
    try ctx.response.setJsonBody(.{ .message = "Hello, Zig!" });
}

fn handleEcho(ctx: *Context) !void {
    if (ctx.request.body) |body| {
        try ctx.response.setTextBody(body);
    } else {
        try ctx.response.setTextBody("No body received");
    }
}
```

### 测试 API

```bash
# 访问首页
curl http://127.0.0.1:8080/

# 访问 Hello API
curl http://127.0.0.1:8080/hello

# 测试 Echo 服务
curl -X POST -d "Hello Zig!" http://127.0.0.1:8080/echo

# 测试 API 路由
curl http://127.0.0.1:8080/api/info
curl http://127.0.0.1:8080/api/time

# 测试用户 API
curl http://127.0.0.1:8080/api/users/
curl http://127.0.0.1:8080/api/users/123
```

## 核心概念

### 1. 使用 Struct 模拟闭包

由于 Zig 没有闭包，我们使用 struct 来模拟闭包的功能：

```zig
// 路由器结构体包含状态和方法
pub const Router = struct {
    allocator: Allocator,
    routes: ArrayList(Route),

    // 方法可以访问和修改结构体的状态
    pub fn addRoute(self: *Self, method: []const u8, path: []const u8, handler: HandlerFn) !void {
        // 实现逻辑...
    }
};
```

### 2. 中间件模式

```zig
// 中间件函数签名
pub const MiddlewareFn = *const fn (*Context, NextFn) anyerror!void;

// 添加全局中间件
try server.use(loggerMiddleware);
try server.use(corsMiddleware);
try server.use(errorHandlerMiddleware);

// 为特定路由添加中间件
const route = try server.get("/protected", handleProtected);
try route.use(authMiddleware);
```

### 3. 路由组

```zig
// 创建路由组
const api_group = try server.group("/api");
_ = try api_group.get("/info", handleApiInfo);
_ = try api_group.get("/time", handleApiTime);

// 嵌套路由组
const users_group = try api_group.group("/users");
_ = try users_group.get("/", handleListUsers);
_ = try users_group.get("/:id", handleGetUser);
_ = try users_group.post("/", handleCreateUser);
```

## API 示例

### 默认路由

- `GET /` - 首页，返回 HTML 欢迎页面
- `GET /hello` - 返回 JSON 格式的问候消息
- `POST /echo` - 回显服务，返回请求体内容

### API 路由

- `GET /api/info` - 返回服务器信息
- `GET /api/time` - 返回当前时间
- `GET /api/users/` - 获取用户列表
- `GET /api/users/:id` - 获取指定用户信息
- `POST /api/users/` - 创建新用户
- `PUT /api/users/:id` - 更新用户信息
- `DELETE /api/users/:id` - 删除用户

### 扩展路由

你可以通过 Router 的方法添加更多路由：

```zig
// 使用便捷方法添加路由
_ = try router.get("/", handleHome);
_ = try router.get("/hello", handleHello);
_ = try router.post("/echo", handleEcho);

// 或者使用 addRoute 方法
_ = try router.addRoute(.GET, "/api/users", handleUsers);
_ = try router.addRoute(.POST, "/api/users", createUser);
_ = try router.addRoute(.PUT, "/api/users/{id}", updateUser);
_ = try router.addRoute(.DELETE, "/api/users/{id}", deleteUser);
```

## 内存管理

项目使用 Zig 的手动内存管理：

- 使用 `GeneralPurposeAllocator` 进行内存分配
- 每个模块负责清理自己分配的内存
- 使用 `defer` 确保资源正确释放

## 性能特性

- **零成本抽象**: Zig 的编译时计算和内联优化
- **手动内存管理**: 避免垃圾回收的性能开销
- **多线程处理**: 每个连接独立处理，提高并发性能
- **最小运行时**: 生成的二进制文件小巧高效

## 开发和调试

```bash
# 运行测试
zig build test

# 调试模式编译
zig build -Doptimize=Debug

# 发布模式编译
zig build -Doptimize=ReleaseFast
```

## 扩展功能

### 添加静态文件服务

```zig
// 在路由器中添加静态文件支持
try self.router.addStaticRoute("/static/", handleStaticFiles);
```

### 添加 JSON 解析

```zig
// 在请求处理中解析 JSON
const json_data = try std.json.parseFromSlice(MyStruct, allocator, request.body.?);
```

### 添加数据库支持

可以集成 SQLite 或其他数据库驱动来添加持久化功能。

## 贡献

欢迎提交 Issue 和 Pull Request！

## 许可证

MIT License