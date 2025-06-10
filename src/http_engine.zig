const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const net = std.net;
const Thread = std.Thread;
const atomic = std.atomic;

const HttpConfig = @import("config.zig").HttpConfig;
const Router = @import("router.zig").Router;
const HttpRequest = @import("request.zig").HttpRequest;
const HttpResponse = @import("response.zig").HttpResponse;
const Context = @import("context.zig").Context;
const StatusCode = @import("context.zig").StatusCode;
const BufferPool = @import("buffer.zig").BufferPool;

/// HTTP服务器引擎，支持高并发和线程安全
pub const HttpEngine = struct {
    allocator: Allocator,
    router: *Router,
    buffer_pool: BufferPool,
    config: HttpConfig,
    running: atomic.Value(bool), // 原子运行状态
    connection_count: atomic.Value(usize), // 原子连接计数

    const Self = @This();

    /// 使用默认配置创建引擎
    pub fn init(allocator: Allocator) !*Self {
        return try Self.initWithConfig(allocator, HttpConfig{});
    }

    /// 使用自定义配置创建引擎
    pub fn initWithConfig(allocator: Allocator, config: HttpConfig) !*Self {
        const engine = try allocator.create(Self);

        engine.* = Self{
            .allocator = allocator,
            .router = try Router.init(allocator),
            .buffer_pool = try BufferPool.init(allocator, config.buffer_size, config.max_buffers),
            .config = config,
            .running = atomic.Value(bool).init(false),
            .connection_count = atomic.Value(usize).init(0),
        };

        return engine;
    }

    /// 释放资源
    pub fn deinit(self: *Self) void {
        self.router.deinit();
        self.allocator.destroy(self.router);
        self.buffer_pool.deinit();
        self.allocator.destroy(self);
    }

    /// 启动服务器
    pub fn listen(self: *Self) !void {
        return try self.listenOn(self.config.address, self.config.port);
    }

    /// 在指定地址和端口启动服务器
    pub fn listenOn(self: *Self, address: []const u8, port: u16) !void {
        const addr = try net.Address.parseIp(address, port);
        var server = try addr.listen(.{
            .reuse_address = true,
        });
        defer server.deinit();

        std.debug.print("HTTP 服务器正在监听 {s}:{d}\n", .{ address, port });

        self.running.store(true, .monotonic);

        while (self.running.load(.monotonic)) {
            const connection = server.accept() catch |err| {
                std.debug.print("接受连接失败: {any}\n", .{err});
                continue;
            };

            const current_connections = self.connection_count.load(.monotonic);
            if (current_connections >= self.config.max_connections) {
                std.debug.print("达到最大连接数，拒绝连接\n", .{});
                connection.stream.close();
                continue;
            }

            _ = self.connection_count.fetchAdd(1, .monotonic);

            const thread = Thread.spawn(.{}, handleConnectionWrapper, .{ self, connection }) catch |err| {
                std.debug.print("创建线程失败: {any}\n", .{err});
                connection.stream.close();
                _ = self.connection_count.fetchSub(1, .monotonic);
                continue;
            };
            thread.detach();
        }
    }

    /// 连接处理包装
    fn handleConnectionWrapper(self: *Self, connection: net.Server.Connection) void {
        defer {
            connection.stream.close();
            _ = self.connection_count.fetchSub(1, .monotonic);
        }

        self.handleConnection(connection.stream) catch |err| {
            std.debug.print("处理连接时出错: {any}\n", .{err});
        };
    }

    /// 处理连接
    fn handleConnection(self: *Self, stream: net.Stream) !void {
        const buffer = try self.buffer_pool.acquire();
        defer self.buffer_pool.release(buffer) catch {};

        const bytes_read = try stream.read(buffer.data);
        if (bytes_read == 0) {
            return;
        }

        buffer.len = bytes_read;
        const request_data = buffer.data[0..bytes_read];

        var request = HttpRequest.parseFromBuffer(self.allocator, request_data) catch |err| {
            std.debug.print("解析请求失败: {any}\n", .{err});
            try self.sendErrorResponse(stream, .bad_request, "Bad Request");
            return;
        };
        defer request.deinit();

        var response = HttpResponse{
            .allocator = self.allocator,
            .status = .ok,
            .headers = StringHashMap([]const u8).init(self.allocator),
            .body = null,
            .cookies = ArrayList(HttpResponse.Cookie).init(self.allocator),
        };
        defer response.deinit();

        var ctx = Context.init(self.allocator, &request, &response);
        defer ctx.deinit();
        self.router.handleRequest(&ctx) catch |err| {
            switch (err) {
                error.NotFound => {
                    ctx.status(.not_found);
                    try self.sendNotFoundResponse(&ctx);
                },
                error.BadRequest => {
                    ctx.status(.bad_request);
                    try self.sendBadRequestResponse(&ctx);
                },
                else => {
                    std.debug.print("处理请求时出错: {any}\n", .{err});
                    ctx.status(.internal_server_error);
                    try self.sendInternalErrorResponse(&ctx);
                },
            }
        };

        try self.sendResponse(stream, &response);
    }

    /// 发送响应
    fn sendResponse(self: *Self, stream: net.Stream, response: *HttpResponse) !void {
        const response_data = try response.build();
        defer self.allocator.free(response_data);

        var bytes_written: usize = 0;
        while (bytes_written < response_data.len) {
            bytes_written += try stream.write(response_data[bytes_written..]);
        }
    }

    /// 发送错误响应
    fn sendErrorResponse(self: *Self, stream: net.Stream, status: StatusCode, message: []const u8) !void {
        var response = HttpResponse{
            .allocator = self.allocator,
            .status = status,
            .headers = StringHashMap([]const u8).init(self.allocator),
            .body = null,
            .cookies = ArrayList(HttpResponse.Cookie).init(self.allocator),
        };
        defer response.deinit();

        response.setStatus(status);
        try response.setHeader("Content-Type", "application/json");

        const body = try std.fmt.allocPrint(self.allocator, "{{\"error\":\"{s}\"}}", .{message});
        defer self.allocator.free(body);

        try response.setBody(body);

        try self.sendResponse(stream, &response);
    }

    // === 错误响应处理方法 ===

    /// 发送 404 页面
    fn sendNotFoundResponse(self: *Self, ctx: *Context) !void {
        _ = self;
        const accept_header = ctx.request.getHeader("Accept") orelse "";

        if (std.mem.indexOf(u8, accept_header, "application/json") != null) {
            try ctx.json("{\"error\":\"Not Found\",\"message\":\"The requested resource was not found\"}");
        } else {
            try ctx.html(
                \\<!DOCTYPE html>
                \\<html>
                \\<head>
                \\    <meta charset="utf-8">
                \\    <title>404 - 页面未找到</title>
                \\    <style>
                \\        body { font-family: Arial, sans-serif; text-align: center; padding: 50px; }
                \\        h1 { font-size: 36px; color: #333; }
                \\        p { font-size: 18px; color: #666; }
                \\        a { color: #0066cc; text-decoration: none; }
                \\        a:hover { text-decoration: underline; }
                \\    </style>
                \\</head>
                \\<body>
                \\    <h1>404 - 页面未找到</h1>
                \\    <p>您请求的页面不存在。</p>
                \\    <p><a href="/">返回首页</a></p>
                \\</body>
                \\</html>
            );
        }
    }

    /// 发送 400 页面
    fn sendBadRequestResponse(self: *Self, ctx: *Context) !void {
        _ = self;
        const accept_header = ctx.request.getHeader("Accept") orelse "";

        if (std.mem.indexOf(u8, accept_header, "application/json") != null) {
            try ctx.json("{\"error\":\"Bad Request\",\"message\":\"The request was malformed\"}");
        } else {
            try ctx.html(
                \\<!DOCTYPE html>
                \\<html>
                \\<head>
                \\    <meta charset="utf-8">
                \\    <title>400 - 请求错误</title>
                \\    <style>
                \\        body { font-family: Arial, sans-serif; text-align: center; padding: 50px; }
                \\        h1 { font-size: 36px; color: #333; }
                \\        p { font-size: 18px; color: #666; }
                \\        a { color: #0066cc; text-decoration: none; }
                \\        a:hover { text-decoration: underline; }
                \\    </style>
                \\</head>
                \\<body>
                \\    <h1>400 - 请求错误</h1>
                \\    <p>您的请求格式不正确。</p>
                \\    <p><a href="/">返回首页</a></p>
                \\</body>
                \\</html>
            );
        }
    }

    /// 发送 500 页面
    fn sendInternalErrorResponse(self: *Self, ctx: *Context) !void {
        _ = self;
        const accept_header = ctx.request.getHeader("Accept") orelse "";

        if (std.mem.indexOf(u8, accept_header, "application/json") != null) {
            try ctx.json("{\"error\":\"Internal Server Error\",\"message\":\"An unexpected error occurred\"}");
        } else {
            try ctx.html(
                \\<!DOCTYPE html>
                \\<html>
                \\<head>
                \\    <meta charset="utf-8">
                \\    <title>500 - 服务器错误</title>
                \\    <style>
                \\        body { font-family: Arial, sans-serif; text-align: center; padding: 50px; }
                \\        h1 { font-size: 36px; color: #333; }
                \\        p { font-size: 18px; color: #666; }
                \\        a { color: #0066cc; text-decoration: none; }
                \\        a:hover { text-decoration: underline; }
                \\    </style>
                \\</head>
                \\<body>
                \\    <h1>500 - 服务器错误</h1>
                \\    <p>服务器处理请求时发生错误。</p>
                \\    <p><a href="/">返回首页</a></p>
                \\</body>
                \\</html>
            );
        }
    }

    // === 路由和中间件 ===

    pub fn use(self: *Self, middleware: @import("middleware.zig").MiddlewareFn) !void {
        try self.router.use(middleware);
    }

    pub fn get(self: *Self, pattern: []const u8, handler: @import("router.zig").HandlerFn) !void {
        _ = try self.router.get(pattern, handler);
    }

    pub fn post(self: *Self, pattern: []const u8, handler: @import("router.zig").HandlerFn) !void {
        _ = try self.router.post(pattern, handler);
    }

    pub fn put(self: *Self, pattern: []const u8, handler: @import("router.zig").HandlerFn) !void {
        _ = try self.router.put(pattern, handler);
    }

    pub fn delete(self: *Self, pattern: []const u8, handler: @import("router.zig").HandlerFn) !void {
        _ = try self.router.delete(pattern, handler);
    }

    pub fn group(self: *Self, prefix: []const u8) !*@import("router.zig").RouterGroup {
        return try self.router.group(prefix);
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .monotonic);
    }

    // === 配置管理 ===

    pub fn setPort(self: *Self, port: u16) void {
        self.config.port = port;
    }

    pub fn setAddress(self: *Self, address: []const u8) void {
        self.config.address = address;
    }

    pub fn setMaxConnections(self: *Self, max_connections: usize) void {
        self.config.max_connections = max_connections;
    }

    pub fn getConfig(self: *Self) HttpConfig {
        return self.config;
    }

    pub fn isRunning(self: *Self) bool {
        return self.running.load(.monotonic);
    }

    /// 获取连接数
    pub fn getConnectionCount(self: *Self) usize {
        return self.connection_count.load(.monotonic);
    }

    /// 获取缓冲区池统计
    pub fn getBufferPoolStats(self: *Self) @import("buffer.zig").BufferPoolStats {
        return self.buffer_pool.getStats();
    }
};
