// libxev 高性能异步 HTTP 服务器
const std = @import("std");
const xev = @import("xev");
const net = std.net;
const log = std.log;

// HTTP 引擎核心模块
const HttpRequest = @import("request.zig").HttpRequest;
const HttpResponse = @import("response.zig").HttpResponse;
const Context = @import("context.zig").Context;
const StatusCode = @import("context.zig").StatusCode;
const Router = @import("router.zig").Router;
const HttpConfig = @import("config.zig").HttpConfig;
const BufferPool = @import("buffer.zig").BufferPool;

// 服务器配置
const ProductionConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    max_connections: u32 = 1000,
    read_timeout_ms: u32 = 30000,
    write_timeout_ms: u32 = 30000,
    max_request_size: usize = 8192,
    buffer_size: usize = 8192,
    max_buffers: usize = 200,
    enable_keep_alive: bool = false,
    enable_compression: bool = false,
    enable_cors: bool = true,
    max_header_size: usize = 8192,
    max_uri_length: usize = 2048,
};

// 连接状态
const ConnectionState = enum {
    reading_request,
    processing_request,
    writing_response,
    closing,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = ProductionConfig{};

    log.info("🚀 启动 libxev HTTP 服务器...", .{});
    log.info("配置: {s}:{}, 最大连接数: {}", .{ config.host, config.port, config.max_connections });

    // 事件循环
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    // TCP 服务器
    const address = try net.Address.parseIp(config.host, config.port);
    var server = try xev.TCP.init(address);
    try server.bind(address);
    try server.listen(128);

    log.info("✅ 服务器监听 {s}:{}", .{ config.host, config.port });

    // 服务器上下文
    var server_ctx = try ServerContext.init(allocator, config);
    defer server_ctx.deinit();

    // 注册路由
    try setupRoutes(server_ctx.router);

    // 接受连接
    var accept_completion: xev.Completion = .{};
    server.accept(&loop, &accept_completion, ServerContext, &server_ctx, acceptCallback);

    // 运行事件循环
    try loop.run(.until_done);

    log.info("🎯 服务器已停止", .{});
}

// 服务器上下文
const ServerContext = struct {
    allocator: std.mem.Allocator,
    config: ProductionConfig,
    router: *Router,
    buffer_pool: BufferPool,
    connection_count: std.atomic.Value(u32),
    active_connections: std.atomic.Value(u32),
    total_requests: std.atomic.Value(u64),

    fn init(allocator: std.mem.Allocator, config: ProductionConfig) !ServerContext {
        const router = try Router.init(allocator);
        const buffer_pool = try BufferPool.init(allocator, config.buffer_size, config.max_buffers);
        return ServerContext{
            .allocator = allocator,
            .config = config,
            .router = router,
            .buffer_pool = buffer_pool,
            .connection_count = std.atomic.Value(u32).init(0),
            .active_connections = std.atomic.Value(u32).init(0),
            .total_requests = std.atomic.Value(u64).init(0),
        };
    }

    fn deinit(self: *ServerContext) void {
        self.router.deinit();
        self.allocator.destroy(self.router);
        self.buffer_pool.deinit();
    }

    fn shouldAcceptConnection(self: *ServerContext) bool {
        return self.active_connections.load(.acquire) < self.config.max_connections;
    }

    fn incrementConnection(self: *ServerContext) u32 {
        _ = self.active_connections.fetchAdd(1, .acq_rel);
        return self.connection_count.fetchAdd(1, .acq_rel) + 1;
    }

    fn decrementConnection(self: *ServerContext) void {
        _ = self.active_connections.fetchSub(1, .acq_rel);
    }

    fn incrementRequests(self: *ServerContext) void {
        _ = self.total_requests.fetchAdd(1, .acq_rel);
    }
};

fn acceptCallback(userdata: ?*ServerContext, loop: *xev.Loop, completion: *xev.Completion, result: anyerror!xev.TCP) xev.CallbackAction {
    _ = completion;
    const server_ctx = userdata.?;

    const client = result catch |err| {
        log.err("接受连接失败: {any}", .{err});
        return .rearm;
    };

    // 连接数限制检查
    if (!server_ctx.shouldAcceptConnection()) {
        log.warn("达到最大连接数限制", .{});
        return .rearm;
    }

    const connection_id = server_ctx.incrementConnection();
    log.info("接受连接 {d} (活跃: {d})", .{ connection_id, server_ctx.active_connections.load(.acquire) });

    // 创建连接上下文
    const conn_ctx = ConnectionContext.init(server_ctx.allocator, server_ctx, client, connection_id) orelse {
        log.err("分配连接上下文失败", .{});
        server_ctx.decrementConnection();
        return .rearm;
    };

    // 开始读取请求
    startReadRequest(conn_ctx, loop);

    return .rearm;
}

// 连接上下文
const ConnectionContext = struct {
    allocator: std.mem.Allocator,
    server_ctx: *ServerContext,
    client: xev.TCP,
    connection_id: u32,
    state: ConnectionState,
    read_completion: xev.Completion,
    write_completion: xev.Completion,
    read_buffer: [8192]u8,
    write_buffer: [4096]u8,
    bytes_read: usize,
    bytes_to_write: usize,
    timeout_completion: xev.Completion,
    response_data: ?[]u8 = null,

    fn init(allocator: std.mem.Allocator, server_ctx: *ServerContext, client: xev.TCP, connection_id: u32) ?*ConnectionContext {
        const ctx = allocator.create(ConnectionContext) catch return null;
        ctx.* = ConnectionContext{
            .allocator = allocator,
            .server_ctx = server_ctx,
            .client = client,
            .connection_id = connection_id,
            .state = .reading_request,
            .read_completion = .{},
            .write_completion = .{},
            .timeout_completion = .{},
            .read_buffer = undefined,
            .write_buffer = undefined,
            .bytes_read = 0,
            .bytes_to_write = 0,
            .response_data = null,
        };
        return ctx;
    }

    fn deinit(self: *ConnectionContext) void {
        log.info("清理连接 {d} 资源", .{self.connection_id});
        if (self.response_data) |data| {
            self.allocator.free(data);
        }
        self.server_ctx.decrementConnection();
        self.allocator.destroy(self);
    }

    fn startRead(self: *ConnectionContext, loop: *xev.Loop) void {
        self.state = .reading_request;
        self.client.read(loop, &self.read_completion, .{ .slice = self.read_buffer[self.bytes_read..] }, ConnectionContext, self, readCallback);

        // TODO: 实现超时功能
        _ = &self.timeout_completion;
    }
};

fn startReadRequest(conn_ctx: *ConnectionContext, loop: *xev.Loop) void {
    conn_ctx.startRead(loop);
}

fn readCallback(userdata: ?*ConnectionContext, loop: *xev.Loop, completion: *xev.Completion, socket: xev.TCP, buffer: xev.ReadBuffer, result: anyerror!usize) xev.CallbackAction {
    _ = completion;
    _ = socket;
    _ = buffer;

    const conn_ctx = userdata.?;

    const bytes_read = result catch |err| {
        log.err("连接 {d} 读取错误: {any}", .{ conn_ctx.connection_id, err });
        conn_ctx.deinit();
        return .disarm;
    };

    if (bytes_read == 0) {
        log.info("连接 {d} 客户端关闭", .{conn_ctx.connection_id});
        conn_ctx.deinit();
        return .disarm;
    }

    conn_ctx.bytes_read += bytes_read;

    // 检查完整 HTTP 请求
    const request_data = conn_ctx.read_buffer[0..conn_ctx.bytes_read];
    if (std.mem.indexOf(u8, request_data, "\r\n\r\n")) |_| {
        processHttpRequest(conn_ctx, loop, request_data) catch |err| {
            log.err("连接 {d} 处理请求失败: {any}", .{ conn_ctx.connection_id, err });
            sendErrorResponse(conn_ctx, loop, .internal_server_error, "Internal Server Error");
            return .disarm;
        };
        return .disarm;
    }

    // 请求过大检查
    if (conn_ctx.bytes_read >= conn_ctx.read_buffer.len) {
        log.err("连接 {d} 请求过大", .{conn_ctx.connection_id});
        sendErrorResponse(conn_ctx, loop, .payload_too_large, "Request Too Large");
        return .disarm;
    }

    return .rearm;
}

fn writeCallback(userdata: ?*ConnectionContext, loop: *xev.Loop, completion: *xev.Completion, socket: xev.TCP, buffer: xev.WriteBuffer, result: anyerror!usize) xev.CallbackAction {
    _ = loop;
    _ = completion;
    _ = socket;
    _ = buffer;

    const conn_ctx = userdata.?;

    const bytes_written = result catch |err| {
        log.err("连接 {d} 写入错误: {any}", .{ conn_ctx.connection_id, err });
        conn_ctx.deinit();
        return .disarm;
    };

    log.info("连接 {d} 响应发送成功: {d} 字节", .{ conn_ctx.connection_id, bytes_written });
    log.info("连接 {d} 处理完成", .{conn_ctx.connection_id});

    conn_ctx.deinit();
    return .disarm;
}

fn processHttpRequest(conn_ctx: *ConnectionContext, loop: *xev.Loop, request_data: []const u8) !void {
    log.info("连接 {d} 处理 HTTP 请求", .{conn_ctx.connection_id});

    // 解析请求
    var request = HttpRequest.parseFromBuffer(conn_ctx.allocator, request_data) catch |err| {
        log.err("解析请求失败: {any}", .{err});
        sendErrorResponse(conn_ctx, loop, .bad_request, "Bad Request");
        return;
    };
    defer request.deinit();

    conn_ctx.server_ctx.incrementRequests();

    // 创建响应
    var response = HttpResponse{
        .allocator = conn_ctx.allocator,
        .status = .ok,
        .headers = std.StringHashMap([]const u8).init(conn_ctx.allocator),
        .body = null,
        .cookies = std.ArrayList(HttpResponse.Cookie).init(conn_ctx.allocator),
    };
    defer response.deinit();

    // 默认响应头
    try response.setHeader("Server", "libxev-http/2.0");
    try response.setHeader("Connection", "close");

    // CORS 头
    if (conn_ctx.server_ctx.config.enable_cors) {
        try response.setHeader("Access-Control-Allow-Origin", "*");
        try response.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
        try response.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
    }

    // 创建上下文
    var ctx = Context.init(conn_ctx.allocator, &request, &response);
    defer ctx.deinit();

    // 路由处理
    conn_ctx.server_ctx.router.handleRequest(&ctx) catch |err| {
        switch (err) {
            error.NotFound => {
                ctx.status(.not_found);
                try ctx.json("{\"error\":\"Not Found\",\"message\":\"The requested resource was not found\"}");
            },
            else => {
                log.err("处理请求时出错: {any}", .{err});
                ctx.status(.internal_server_error);
                try ctx.json("{\"error\":\"Internal Server Error\",\"message\":\"An unexpected error occurred\"}");
            },
        }
    };

    // 构建响应数据
    const response_data = try response.build();
    conn_ctx.response_data = response_data;

    if (response_data.len > conn_ctx.write_buffer.len) {
        conn_ctx.bytes_to_write = response_data.len;
    } else {
        @memcpy(conn_ctx.write_buffer[0..response_data.len], response_data);
        conn_ctx.bytes_to_write = response_data.len;
        conn_ctx.allocator.free(response_data);
        conn_ctx.response_data = null;
    }

    startWrite(conn_ctx, loop);
}

fn sendErrorResponse(conn_ctx: *ConnectionContext, loop: *xev.Loop, status: StatusCode, message: []const u8) void {
    var response = HttpResponse{
        .allocator = conn_ctx.allocator,
        .status = status,
        .headers = std.StringHashMap([]const u8).init(conn_ctx.allocator),
        .body = null,
        .cookies = std.ArrayList(HttpResponse.Cookie).init(conn_ctx.allocator),
    };
    defer response.deinit();

    response.setHeader("Content-Type", "application/json") catch {};
    response.setHeader("Server", "libxev-http/2.0") catch {};
    response.setHeader("Connection", "close") catch {};

    const body = std.fmt.allocPrint(conn_ctx.allocator, "{{\"error\":\"{s}\"}}", .{message}) catch {
        conn_ctx.deinit();
        return;
    };
    defer conn_ctx.allocator.free(body);

    response.setBody(body) catch {};

    const response_data = response.build() catch {
        conn_ctx.deinit();
        return;
    };
    conn_ctx.response_data = response_data;
    conn_ctx.bytes_to_write = response_data.len;

    startWrite(conn_ctx, loop);
}

fn startWrite(conn_ctx: *ConnectionContext, loop: *xev.Loop) void {
    conn_ctx.state = .writing_response;

    const data_slice = if (conn_ctx.response_data) |data|
        data[0..conn_ctx.bytes_to_write]
    else
        conn_ctx.write_buffer[0..conn_ctx.bytes_to_write];

    conn_ctx.client.write(loop, &conn_ctx.write_completion, .{ .slice = data_slice }, ConnectionContext, conn_ctx, writeCallback);
}

// 路由设置
fn setupRoutes(router: *Router) !void {
    _ = try router.get("/", indexHandler);
    _ = try router.get("/api/status", statusHandler);
    _ = try router.get("/api/health", healthHandler);
    _ = try router.post("/api/echo", echoHandler);
    _ = try router.get("/users/:id", userHandler);
    _ = try router.get("/users/:id/profile", userProfileHandler);
    _ = try router.get("/static/*", staticFileHandler);
}

// 路由处理函数
fn indexHandler(ctx: *Context) !void {
    try ctx.html(
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\    <meta charset="utf-8">
        \\    <title>libxev HTTP Server</title>
        \\    <style>
        \\        body { font-family: Arial, sans-serif; text-align: center; padding: 50px; background: #f5f5f5; }
        \\        .container { max-width: 800px; margin: 0 auto; background: white; padding: 40px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        \\        h1 { color: #333; margin-bottom: 30px; }
        \\        .feature { background: #f8f9fa; padding: 20px; margin: 20px 0; border-radius: 5px; border-left: 4px solid #007bff; }
        \\        .api-links { margin-top: 30px; }
        \\        .api-links a { display: inline-block; margin: 10px; padding: 10px 20px; background: #007bff; color: white; text-decoration: none; border-radius: 5px; }
        \\        .api-links a:hover { background: #0056b3; }
        \\    </style>
        \\</head>
        \\<body>
        \\    <div class="container">
        \\        <h1>🚀 libxev HTTP Server</h1>
        \\        <div class="feature">
        \\            <h3>高性能异步架构</h3>
        \\            <p>基于 libxev 事件循环，支持高并发连接处理</p>
        \\        </div>
        \\        <div class="feature">
        \\            <h3>完整的 HTTP 协议支持</h3>
        \\            <p>支持路由、中间件、请求解析和响应构建</p>
        \\        </div>
        \\        <div class="feature">
        \\            <h3>生产级特性</h3>
        \\            <p>内存池管理、错误处理、日志记录和性能监控</p>
        \\        </div>
        \\        <div class="api-links">
        \\            <a href="/api/status">服务器状态</a>
        \\            <a href="/api/health">健康检查</a>
        \\            <a href="/users/123">用户信息</a>
        \\        </div>
        \\    </div>
        \\</body>
        \\</html>
    );
}

fn statusHandler(ctx: *Context) !void {
    const status_json =
        \\{
        \\  "status": "ok",
        \\  "server": "libxev-http",
        \\  "version": "2.0.0",
        \\  "features": [
        \\    "async_io",
        \\    "routing",
        \\    "middleware",
        \\    "buffer_pool",
        \\    "error_handling"
        \\  ],
        \\  "timestamp": "2024-01-01T00:00:00Z"
        \\}
    ;
    try ctx.json(status_json);
}

fn healthHandler(ctx: *Context) !void {
    try ctx.json("{\"health\":\"ok\",\"uptime\":\"running\"}");
}

fn echoHandler(ctx: *Context) !void {
    const body = ctx.request.body orelse "";
    const response = try std.fmt.allocPrint(ctx.allocator, "{{\"echo\":\"{s}\",\"length\":{d}}}", .{ body, body.len });
    defer ctx.allocator.free(response);
    try ctx.json(response);
}

fn userHandler(ctx: *Context) !void {
    const user_id = ctx.getParam("id") orelse "unknown";
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\{{"user_id":"{s}","name":"User {s}","email":"user{s}@example.com"}}
    , .{ user_id, user_id, user_id });
    defer ctx.allocator.free(response);
    try ctx.json(response);
}

fn userProfileHandler(ctx: *Context) !void {
    const user_id = ctx.getParam("id") orelse "unknown";
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\{{"user_id":"{s}","profile":{{"bio":"This is user {s}","location":"Earth","website":"https://example.com"}}}}
    , .{ user_id, user_id });
    defer ctx.allocator.free(response);
    try ctx.json(response);
}

fn staticFileHandler(ctx: *Context) !void {
    ctx.status(.not_found);
    try ctx.json("{\"error\":\"Static file serving not implemented\"}");
}
