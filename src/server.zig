const std = @import("std");
const net = std.net;
const Allocator = std.mem.Allocator;
const Thread = std.Thread;

const HttpRequest = @import("request.zig").HttpRequest;
const HttpResponse = @import("response.zig").HttpResponse;
const Context = @import("context.zig").Context;
const Router = @import("router.zig").Router;
const MiddlewareFn = @import("middleware.zig").MiddlewareFn;

/// HTTP 服务器配置
pub const ServerConfig = struct {
    port: u16 = 8080,
    host: []const u8 = "127.0.0.1",
    max_connections: usize = 100,
    read_timeout_ms: u32 = 5000,
    write_timeout_ms: u32 = 5000,
};

/// HTTP 服务器
pub const HttpServer = struct {
    allocator: Allocator,
    config: ServerConfig,
    router: *Router,
    running: bool,

    const Self = @This();

    /// 初始化 HTTP 服务器
    pub fn init(allocator: Allocator) !Self {
        return Self{
            .allocator = allocator,
            .config = ServerConfig{},
            .router = try Router.init(allocator),
            .running = false,
        };
    }

    /// 初始化带配置的 HTTP 服务器
    pub fn initWithConfig(allocator: Allocator, config: ServerConfig) !Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .router = try Router.init(allocator),
            .running = false,
        };
    }

    /// 清理资源
    pub fn deinit(self: *Self) void {
        self.router.deinit();
    }

    /// 添加全局中间件
    pub fn use(self: *Self, middleware: MiddlewareFn) !void {
        try self.router.use(middleware);
    }

    /// 添加 GET 路由
    pub fn get(self: *Self, pattern: []const u8, handler: @import("router.zig").HandlerFn) !void {
        _ = try self.router.get(pattern, handler);
    }

    /// 添加 POST 路由
    pub fn post(self: *Self, pattern: []const u8, handler: @import("router.zig").HandlerFn) !void {
        _ = try self.router.post(pattern, handler);
    }

    /// 创建路由组
    pub fn group(self: *Self, prefix: []const u8) !*@import("router.zig").RouterGroup {
        return try self.router.group(prefix);
    }

    /// 添加 PUT 路由
    pub fn put(self: *Self, pattern: []const u8, handler: @import("router.zig").HandlerFn) !void {
        try self.router.put(pattern, handler);
    }

    /// 添加 DELETE 路由
    pub fn delete(self: *Self, pattern: []const u8, handler: @import("router.zig").HandlerFn) !void {
        try self.router.delete(pattern, handler);
    }

    /// 添加静态文件路由
    pub fn static(self: *Self, prefix: []const u8, handler: @import("router.zig").HandlerFn) !void {
        try self.router.static(prefix, handler);
    }

    /// 启动服务器
    pub fn listen(self: *Self, host: []const u8, port: u16) !void {
        self.config.host = host;
        self.config.port = port;

        const address = try net.Address.parseIp(host, port);
        var server = try address.listen(.{
            .reuse_address = true,
        });
        defer server.deinit();

        std.debug.print("🚀 HTTP 服务器启动在 http://{s}:{d}\n", .{ host, port });
        self.running = true;

        // 连接计数
        var connection_count: usize = 0;

        while (self.running) {
            // 检查是否达到最大连接数
            if (connection_count >= self.config.max_connections) {
                std.time.sleep(10 * std.time.ns_per_ms);
                continue;
            }

            // 接受新连接
            const connection = server.accept() catch |err| {
                std.debug.print("接受连接失败: {any}\n", .{err});
                continue;
            };

            connection_count += 1;

            // 在新线程中处理连接
            const thread = Thread.spawn(.{}, handleConnectionWrapper, .{ self, connection, &connection_count }) catch |err| {
                std.debug.print("创建线程失败: {any}\n", .{err});
                connection.stream.close();
                connection_count -= 1;
                continue;
            };

            thread.detach();
        }
    }

    /// 停止服务器
    pub fn stop(self: *Self) void {
        self.running = false;
    }

    /// 线程包装函数
    fn handleConnectionWrapper(self: *Self, connection: net.Server.Connection, connection_count: *usize) void {
        defer {
            connection.stream.close();
            connection_count.* -= 1;
        }

        self.handleConnection(connection.stream) catch |err| {
            std.debug.print("处理连接错误: {any}\n", .{err});
        };
    }

    /// 处理单个连接
    fn handleConnection(self: *Self, stream: net.Stream) !void {
        // 注意：Zig 0.14中net.Stream没有setReadTimeout方法

        // 读取请求数据
        var buffer: [8192]u8 = undefined;
        const bytes_read = try stream.read(&buffer);
        if (bytes_read == 0) {
            return;
        }

        const request_data = buffer[0..bytes_read];

        // 解析请求
        var request = HttpRequest.parseFromBuffer(self.allocator, request_data) catch |err| {
            std.debug.print("解析请求失败: {any}\n", .{err});
            try self.sendErrorResponse(stream, 400, "Bad Request");
            return;
        };
        defer request.deinit();

        // 创建响应
        var response = HttpResponse{
            .allocator = self.allocator,
            .status = .ok,
            .headers = std.StringHashMap([]const u8).init(self.allocator),
            .body = null,
            .cookies = std.ArrayList(HttpResponse.Cookie).init(self.allocator),
        };
        defer response.deinit();

        // 创建上下文
        var ctx = Context.init(self.allocator, &request, &response);
        defer ctx.deinit();

        // 路由处理
        self.router.handleRequest(&ctx) catch |err| {
            switch (err) {
                error.NotFound => {
                    response.setStatus(.not_found);
                    try response.setTextBody("404 Not Found");
                },
                else => {
                    std.debug.print("处理请求失败: {any}\n", .{err});
                    response.setStatus(.internal_server_error);
                    try response.setTextBody("500 Internal Server Error");
                },
            }
        };

        // 注意：Zig 0.14中net.Stream不支持setWriteTimeout
        // try stream.setWriteTimeout(self.config.write_timeout_ms * std.time.ns_per_ms);

        // 发送响应
        const response_data = try response.build();
        defer self.allocator.free(response_data);

        _ = try stream.write(response_data);
    }

    /// 发送错误响应
    fn sendErrorResponse(self: *Self, stream: net.Stream, status_code: u16, message: []const u8) !void {
        var response = HttpResponse{
            .allocator = self.allocator,
            .status = @enumFromInt(status_code),
            .headers = std.StringHashMap([]const u8).init(self.allocator),
            .body = null,
            .cookies = std.ArrayList(HttpResponse.Cookie).init(self.allocator),
        };
        defer response.deinit();

        try response.setTextBody(message);

        const response_data = try response.build();
        defer self.allocator.free(response_data);

        _ = try stream.write(response_data);
    }
};
