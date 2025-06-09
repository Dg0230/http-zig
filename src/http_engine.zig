const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.net;
const Thread = std.Thread;

const HttpConfig = @import("config.zig").HttpConfig;
const Router = @import("router.zig").Router;
const HttpRequest = @import("request.zig").HttpRequest;
const HttpResponse = @import("response.zig").HttpResponse;
const Context = @import("context.zig").Context;
const BufferPool = @import("buffer.zig").BufferPool;

pub const HttpEngine = struct {
    allocator: Allocator,
    router: *Router,
    buffer_pool: BufferPool,
    config: HttpConfig,
    running: bool,

    const Self = @This();

    pub fn init(allocator: Allocator, config: HttpConfig) !*Self {
        const engine = try allocator.create(Self);

        engine.* = Self{
            .allocator = allocator,
            .router = try Router.init(allocator),
            .buffer_pool = try BufferPool.init(allocator, config.buffer_size, config.max_buffers),
            .config = config,
            .running = false,
        };

        return engine;
    }

    pub fn deinit(self: *Self) void {
        self.router.deinit();
        self.buffer_pool.deinit();
        self.allocator.destroy(self);
    }

    pub fn listen(self: *Self, address: []const u8, port: u16) !void {
        const addr = try net.Address.parseIp(address, port);
        var server = try net.StreamServer.init(.{
            .reuse_address = true,
        });
        defer server.deinit();

        try server.listen(addr);

        std.debug.print("HTTP 服务器正在监听 {s}:{d}\n", .{ address, port });

        self.running = true;

        var connection_count: usize = 0;

        while (self.running) {
            const connection = server.accept() catch |err| {
                std.debug.print("接受连接失败: {any}\n", .{err});
                continue;
            };

            if (connection_count >= self.config.max_connections) {
                std.debug.print("达到最大连接数，拒绝连接\n", .{});
                connection.stream.close();
                continue;
            }

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

    fn handleConnectionWrapper(self: *Self, connection: net.StreamServer.Connection, connection_count: *usize) void {
        defer {
            connection.stream.close();
            _ = @atomicRmw(usize, connection_count, .Sub, 1, .monotonic);
        }

        self.handleConnection(connection.stream) catch |err| {
            std.debug.print("处理连接时出错: {any}\n", .{err});
        };
    }

    fn handleConnection(self: *Self, stream: net.Stream) !void {
        // 设置读取超时
        try stream.setReadTimeout(self.config.read_timeout_ms * std.time.ns_per_ms);

        // 从缓冲区池获取缓冲区
        const buffer = try self.buffer_pool.acquire();
        defer self.buffer_pool.release(buffer) catch {};

        // 读取请求数据
        const bytes_read = try stream.read(buffer.data);
        if (bytes_read == 0) {
            return;
        }

        buffer.len = bytes_read;
        const request_data = buffer.data[0..bytes_read];

        // 解析请求
        var request = HttpRequest.parseFromBuffer(self.allocator, request_data) catch |err| {
            std.debug.print("解析请求失败: {any}\n", .{err});
            try self.sendErrorResponse(stream, .bad_request, "Bad Request");
            return;
        };
        defer request.deinit();

        // 创建响应对象
        var response = HttpResponse.init(self.allocator);
        defer response.deinit();

        // 创建上下文
        var ctx = try Context.init(self.allocator, &request, &response);
        defer ctx.deinit();

        // 路由处理
        self.router.handleRequest(&ctx) catch |err| {
            switch (err) {
                error.NotFound => {
                    ctx.status(.not_found);
                    try ctx.json("{\"error\":\"Not Found\"}");
                },
                else => {
                    std.debug.print("处理请求时出错: {any}\n", .{err});
                    ctx.status(.internal_server_error);
                    try ctx.json("{\"error\":\"Internal Server Error\"}");
                },
            }
        };

        // 设置写入超时
        try stream.setWriteTimeout(self.config.write_timeout_ms * std.time.ns_per_ms);

        // 发送响应
        try self.sendResponse(stream, &response);
    }

    fn sendResponse(self: *Self, stream: net.Stream, response: *HttpResponse) !void {
        const response_data = try response.build();
        defer self.allocator.free(response_data);

        var bytes_written: usize = 0;
        while (bytes_written < response_data.len) {
            bytes_written += try stream.write(response_data[bytes_written..]);
        }
    }

    fn sendErrorResponse(self: *Self, stream: net.Stream, status: Context.StatusCode, message: []const u8) !void {
        var response = HttpResponse.init(self.allocator);
        defer response.deinit();

        response.setStatus(status);
        try response.setHeader("Content-Type", "application/json");

        const body = try std.fmt.allocPrint(self.allocator, "{{\"error\":\"{s}\"}}", .{message});
        defer self.allocator.free(body);

        try response.setBody(body);

        try self.sendResponse(stream, &response);
    }
};
