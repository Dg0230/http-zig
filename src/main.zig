const std = @import("std");
const HttpServer = @import("server.zig").HttpServer;
const ServerConfig = @import("server.zig").ServerConfig;
const Context = @import("context.zig").Context;
const loggerMiddleware = @import("middleware.zig").loggerMiddleware;
const corsMiddleware = @import("middleware.zig").corsMiddleware;
const errorHandlerMiddleware = @import("middleware.zig").errorHandlerMiddleware;
const requestIdMiddleware = @import("middleware.zig").requestIdMiddleware;
const cacheControlMiddleware = @import("middleware.zig").cacheControlMiddleware;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("启动 Zig HTTP 服务器...\n", .{});

    // 服务器配置
    const config = ServerConfig{
        .port = 8080,
        // .address = "127.0.0.1",
        .max_connections = 1000,
        .read_timeout_ms = 5000,
        .write_timeout_ms = 5000,
        // .buffer_size = 8192,
    };

    var server = try HttpServer.initWithConfig(allocator, config);
    defer server.deinit();

    // 添加全局中间件
    try server.use(loggerMiddleware);
    try server.use(corsMiddleware);
    try server.use(errorHandlerMiddleware);
    try server.use(requestIdMiddleware);

    // 设置路由
    _ = try server.get("/", handleHome);
    _ = try server.get("/hello", handleHello);
    _ = try server.post("/echo", handleEcho);

    // API 路由组
    const api_group = try server.group("/api");
    _ = try api_group.get("/info", handleApiInfo);
    _ = try api_group.get("/time", handleApiTime);

    // 用户 API 路由组
    const users_group = try api_group.group("/users");
    _ = try users_group.get("/", handleListUsers);
    _ = try users_group.get("/:id", handleGetUser);
    _ = try users_group.post("/", handleCreateUser);
    _ = try users_group.put("/:id", handleUpdateUser);
    _ = try users_group.delete("/:id", handleDeleteUser);

    // 静态文件路由
    _ = try server.get("/static/*", handleStaticFiles);
    // 注意：中间件应该在路由定义之前添加到服务器

    // 启动服务器
    try server.listen("127.0.0.1", 8080);
}

// 首页处理函数
fn handleHome(ctx: *Context) !void {
    try ctx.html(
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\    <title>Zig HTTP 服务器</title>
        \\    <meta charset="utf-8">
        \\    <style>
        \\        body { font-family: Arial, sans-serif; max-width: 800px; margin: 0 auto; padding: 20px; }
        \\        h1 { color: #333; }
        \\        .nav { background: #f5f5f5; padding: 10px; border-radius: 5px; }
        \\        .nav a { margin-right: 15px; color: #0066cc; text-decoration: none; }
        \\        .nav a:hover { text-decoration: underline; }
        \\        .content { margin-top: 20px; }
        \\    </style>
        \\</head>
        \\<body>
        \\    <h1>欢迎使用 Zig HTTP 服务器!</h1>
        \\    <div class="nav">
        \\        <a href="/">首页</a>
        \\        <a href="/hello">Hello API</a>
        \\        <a href="/api/info">服务器信息</a>
        \\        <a href="/api/time">当前时间</a>
        \\        <a href="/api/users">用户列表</a>
        \\    </div>
        \\    <div class="content">
        \\        <h2>这是一个用 Zig 语言实现的简单 HTTP 服务器</h2>
        \\        <p>特性：</p>
        \\        <ul>
        \\            <li>路由系统支持 GET、POST、PUT、DELETE 等方法</li>
        \\            <li>支持路由参数提取（如 /api/users/:id）</li>
        \\            <li>中间件系统支持请求处理流程定制</li>
        \\            <li>路由分组功能便于 API 组织</li>
        \\            <li>内置常用中间件（日志、CORS、错误处理等）</li>
        \\        </ul>
        \\        <h3>测试 API:</h3>
        \\        <pre>curl -X POST -d "Hello Zig!" http://localhost:8080/echo</pre>
        \\    </div>
        \\</body>
        \\</html>
    );
}

// Hello API 处理函数
fn handleHello(ctx: *Context) !void {
    const timestamp = std.time.timestamp();
    const json_response = try std.fmt.allocPrint(ctx.allocator, "{{\"message\":\"Hello from Zig HTTP Server!\",\"timestamp\":{d}}}", .{timestamp});
    defer ctx.allocator.free(json_response);

    try ctx.json(json_response);
}

// Echo 服务处理函数
fn handleEcho(ctx: *Context) !void {
    if (ctx.request.body) |body| {
        try ctx.text(body);
    } else {
        try ctx.text("No body received");
    }
}

// API 信息处理函数
fn handleApiInfo(ctx: *Context) !void {
    const info = try std.fmt.allocPrint(ctx.allocator, "{{\"server\":\"Zig HTTP Server\",\"version\":\"1.0.0\",\"language\":\"Zig\",\"author\":\"Zig Developer\"}}", .{});
    defer ctx.allocator.free(info);

    try ctx.json(info);
}

// API 时间处理函数
fn handleApiTime(ctx: *Context) !void {
    const timestamp = std.time.timestamp();
    const time_json = try std.fmt.allocPrint(ctx.allocator, "{{\"timestamp\":{d},\"iso\":\"2023-01-01T00:00:00Z\"}}", .{timestamp});
    defer ctx.allocator.free(time_json);

    try ctx.json(time_json);
}

// 模拟用户数据
const User = struct {
    id: u32,
    name: []const u8,
    email: []const u8,
};

const users = [_]User{
    .{ .id = 1, .name = "张三", .email = "zhangsan@example.com" },
    .{ .id = 2, .name = "李四", .email = "lisi@example.com" },
    .{ .id = 3, .name = "王五", .email = "wangwu@example.com" },
};

// 列出所有用户
fn handleListUsers(ctx: *Context) !void {
    var users_json = std.ArrayList(u8).init(ctx.allocator);
    defer users_json.deinit();

    try users_json.appendSlice("[");

    for (users, 0..) |user, i| {
        const user_json = try std.fmt.allocPrint(ctx.allocator, "{{\"id\":{d},\"name\":\"{s}\",\"email\":\"{s}\"}}", .{ user.id, user.name, user.email });
        defer ctx.allocator.free(user_json);

        try users_json.appendSlice(user_json);

        if (i < users.len - 1) {
            try users_json.appendSlice(",");
        }
    }

    try users_json.appendSlice("]");

    try ctx.json(users_json.items);
}

// 获取单个用户
fn handleGetUser(ctx: *Context) !void {
    const id_str = ctx.getParam("id") orelse {
        ctx.status(.bad_request);
        try ctx.json("{\"error\":\"Missing user ID\"}");
        return;
    };

    const id = std.fmt.parseInt(u32, id_str, 10) catch {
        ctx.status(.bad_request);
        try ctx.json("{\"error\":\"Invalid user ID\"}");
        return;
    };

    // 查找用户
    for (users) |user| {
        if (user.id == id) {
            const user_json = try std.fmt.allocPrint(ctx.allocator, "{{\"id\":{d},\"name\":\"{s}\",\"email\":\"{s}\"}}", .{ user.id, user.name, user.email });
            defer ctx.allocator.free(user_json);

            try ctx.json(user_json);
            return;
        }
    }

    // 用户未找到
    ctx.status(.not_found);
    try ctx.json("{\"error\":\"User not found\"}");
}

// 创建用户（模拟）
fn handleCreateUser(ctx: *Context) !void {
    if (ctx.request.body == null) {
        ctx.status(.bad_request);
        try ctx.json("{\"error\":\"Missing request body\"}");
        return;
    }

    // 简化实现，实际应该解析 JSON
    std.debug.print("创建用户: {s}\n", .{ctx.request.body.?});

    // 模拟创建成功
    const response = try std.fmt.allocPrint(ctx.allocator, "{{\"id\":{d},\"message\":\"用户创建成功\"}}", .{users.len + 1});
    defer ctx.allocator.free(response);

    ctx.status(.created);
    try ctx.json(response);
}

// 更新用户（模拟）
fn handleUpdateUser(ctx: *Context) !void {
    const id_str = ctx.getParam("id") orelse {
        ctx.status(.bad_request);
        try ctx.json("{\"error\":\"缺少用户 ID\"}");
        return;
    };

    if (ctx.request.body == null) {
        ctx.status(.bad_request);
        try ctx.json("{\"error\":\"缺少请求体\"}");
        return;
    }

    // 简化实现，实际应该解析 JSON 并更新用户
    std.debug.print("更新用户 {s}: {s}\n", .{ id_str, ctx.request.body.? });

    // 模拟更新成功
    const response = try std.fmt.allocPrint(ctx.allocator, "{{\"id\":{s},\"message\":\"用户更新成功\"}}", .{id_str});
    defer ctx.allocator.free(response);

    try ctx.json(response);
}

// 删除用户（模拟）
fn handleDeleteUser(ctx: *Context) !void {
    const id_str = ctx.getParam("id") orelse {
        ctx.status(.bad_request);
        try ctx.json("{\"error\":\"缺少用户 ID\"}");
        return;
    };

    // 简化实现，实际应该从数据库删除
    std.debug.print("删除用户 {s}\n", .{id_str});

    // 模拟删除成功
    const response = try std.fmt.allocPrint(ctx.allocator, "{{\"id\":{s},\"message\":\"用户删除成功\"}}", .{id_str});
    defer ctx.allocator.free(response);

    try ctx.json(response);
}

// 静态文件处理（模拟）
fn handleStaticFiles(ctx: *Context) !void {
    // 在实际应用中，应该从文件系统读取文件
    // 这里简化实现，返回模拟内容

    const path = ctx.request.path;

    if (std.mem.endsWith(u8, path, ".css")) {
        try ctx.response.setHeader("Content-Type", "text/css");
        try ctx.text("/* 这是一个模拟的 CSS 文件 */\nbody { font-family: Arial, sans-serif; }");
    } else if (std.mem.endsWith(u8, path, ".js")) {
        try ctx.response.setHeader("Content-Type", "application/javascript");
        try ctx.text("// 这是一个模拟的 JavaScript 文件\nconsole.log('Hello from Zig HTTP Server!');");
    } else if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) {
        try ctx.response.setHeader("Content-Type", "image/jpeg");
        ctx.status(.not_implemented);
        try ctx.text("图片文件未实现");
    } else if (std.mem.endsWith(u8, path, ".png")) {
        try ctx.response.setHeader("Content-Type", "image/png");
        ctx.status(.not_implemented);
        try ctx.text("图片文件未实现");
    } else {
        try ctx.response.setHeader("Content-Type", "text/plain");
        try ctx.text("未知的静态文件类型");
    }
}
