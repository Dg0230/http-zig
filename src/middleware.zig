const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Context = @import("context.zig").Context;

/// 下一个中间件函数类型
pub const NextFn = *const fn (*Context) anyerror!void;

/// 中间件函数类型
pub const MiddlewareFn = *const fn (*Context, NextFn) anyerror!void;

/// 中间件栈
pub const MiddlewareStack = struct {
    allocator: Allocator,
    middlewares: ArrayList(MiddlewareFn),

    const Self = @This();

    /// 初始化中间件栈
    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .middlewares = ArrayList(MiddlewareFn).init(allocator),
        };
    }

    /// 添加中间件
    pub fn use(self: *Self, middleware: MiddlewareFn) !void {
        try self.middlewares.append(middleware);
    }

    /// 执行中间件栈
    pub fn execute(self: *Self, ctx: *Context) !void {
        if (self.middlewares.items.len == 0) {
            return;
        }

        // 简化实现：顺序执行所有中间件
        for (self.middlewares.items) |middleware| {
            const next_fn = struct {
                fn next(ctx2: *Context) !void {
                    _ = ctx2; // 简化实现，不做任何事
                }
            }.next;

            try middleware(ctx, next_fn);
        }
    }

    /// 清理资源
    pub fn deinit(self: *Self) void {
        self.middlewares.deinit();
    }
};

/// 日志中间件
pub fn loggerMiddleware(ctx: *Context, next: NextFn) !void {
    const start_time = std.time.milliTimestamp();

    std.debug.print("[{s}] {s} - 开始处理\n", .{ ctx.request.method, ctx.request.path });

    try next(ctx);

    const end_time = std.time.milliTimestamp();
    const duration = end_time - start_time;

    std.debug.print("[{s}] {s} - {d} - {d}ms\n", .{ ctx.request.method, ctx.request.path, @intFromEnum(ctx.response.status), duration });
}

/// CORS 中间件
pub fn corsMiddleware(ctx: *Context, next: NextFn) !void {
    try ctx.response.setHeader("Access-Control-Allow-Origin", "*");
    try ctx.response.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    try ctx.response.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");

    // 处理预检请求
    if (std.mem.eql(u8, ctx.request.method, "OPTIONS")) {
        ctx.status(.no_content);
        return;
    }

    try next(ctx);
}

/// 错误处理中间件
pub fn errorHandlerMiddleware(ctx: *Context, next: NextFn) !void {
    next(ctx) catch |err| {
        switch (err) {
            error.NotFound => {
                ctx.status(.not_found);
                try ctx.html(
                    \\<!DOCTYPE html>
                    \\<html>
                    \\<head>
                    \\    <title>404 - 页面未找到</title>
                    \\    <style>
                    \\        body { font-family: Arial, sans-serif; text-align: center; padding: 50px; }
                    \\        h1 { font-size: 36px; color: #333; }
                    \\        p { font-size: 18px; color: #666; }
                    \\    </style>
                    \\</head>
                    \\<body>
                    \\    <h1>404 - 页面未找到</h1>
                    \\    <p>您请求的页面不存在。</p>
                    \\    <p><a href="/">返回首页</a></p>
                    \\</body>
                    \\</html>
                );
            },
            error.BadRequest => {
                ctx.status(.bad_request);
                try ctx.json("{\"error\":\"请求格式错误\"}");
            },
            error.Unauthorized => {
                ctx.status(.unauthorized);
                try ctx.json("{\"error\":\"未授权访问\"}");
            },
            error.Forbidden => {
                ctx.status(.forbidden);
                try ctx.json("{\"error\":\"禁止访问\"}");
            },
            error.InternalError => {
                ctx.status(.internal_server_error);
                try ctx.html(
                    \\<!DOCTYPE html>
                    \\<html>
                    \\<head>
                    \\    <title>500 - 服务器错误</title>
                    \\    <style>
                    \\        body { font-family: Arial, sans-serif; text-align: center; padding: 50px; }
                    \\        h1 { font-size: 36px; color: #333; }
                    \\        p { font-size: 18px; color: #666; }
                    \\    </style>
                    \\</head>
                    \\<body>
                    \\    <h1>500 - 服务器错误</h1>
                    \\    <p>服务器处理请求时发生错误。</p>
                    \\    <p><a href="/">返回首页</a></p>
                    \\</body>
                    \\</html>
                );
            },
            else => {
                std.debug.print("未处理的错误: {any}\n", .{err});
                ctx.status(.internal_server_error);
                try ctx.json("{\"error\":\"服务器内部错误\"}");
            },
        }
    };
}

/// 请求超时中间件
pub fn timeoutMiddleware(timeout_ms: u64) MiddlewareFn {
    const TimeoutMiddleware = struct {
        timeout: u64,

        fn middleware(self: @This(), ctx: *Context, next: NextFn) !void {
            const start_time = std.time.milliTimestamp();

            // 创建一个标志，表示是否已超时
            // var timed_out = false;

            // 在实际应用中，这里应该创建一个计时器线程
            // 简化实现，仅检查执行后是否超时

            try next(ctx);

            const end_time = std.time.milliTimestamp();
            const duration = end_time - start_time;

            if (duration > self.timeout) {
                std.debug.print("请求处理超时: {d}ms > {d}ms\n", .{ duration, self.timeout });
                // 在实际应用中，可能需要中断请求处理
            }
        }
    };

    const middleware_instance = TimeoutMiddleware{ .timeout = timeout_ms };
    return middleware_instance.middleware;
}

/// 限流中间件（简化实现）
pub fn rateLimitMiddleware(requests_per_minute: u32) MiddlewareFn {
    const middleware_instance = struct {
        limit: u32,
        // 在实际应用中，这里应该有一个计数器和时间窗口

        fn middleware(self: @This(), ctx: *Context, next: NextFn) !void {
            // 简化实现，实际应用中应该检查 IP 或用户标识
            // const client_ip = ctx.request.getHeader("X-Forwarded-For") orelse "unknown";

            // 模拟限流检查
            const rate_limit_exceeded = false; // 实际应该基于计数器判断

            if (rate_limit_exceeded) {
                ctx.status(.too_many_requests);
                try ctx.json("{\"error\":\"请求频率过高，请稍后再试\"}");
                return;
            }

            // 设置限流相关头部
            const limit_str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{self.limit});
            defer ctx.allocator.free(limit_str);
            try ctx.response.setHeader("X-RateLimit-Limit", limit_str);
            try ctx.response.setHeader("X-RateLimit-Remaining", "99"); // 实际应该是剩余请求数

            try next(ctx);
        }
    }{ .limit = requests_per_minute };
    return middleware_instance.middleware;
}

/// 认证中间件
pub fn authMiddleware(ctx: *Context, next: NextFn) !void {
    const auth_header = ctx.request.getHeader("Authorization");

    if (auth_header == null) {
        ctx.status(.unauthorized);
        try ctx.json("{\"error\":\"缺少认证信息\"}");
        return;
    }

    // 简单的 token 验证（实际应用中应该验证 JWT）
    if (!std.mem.startsWith(u8, auth_header.?, "Bearer ")) {
        ctx.status(.unauthorized);
        try ctx.json("{\"error\":\"认证格式无效\"}");
        return;
    }

    const token = auth_header.?[7..]; // 跳过 "Bearer "

    // 模拟 token 验证
    if (!std.mem.eql(u8, token, "valid-token")) {
        ctx.status(.unauthorized);
        try ctx.json("{\"error\":\"认证令牌无效\"}");
        return;
    }

    // 设置用户信息到上下文
    try ctx.setState("user", "authenticated_user");

    try next(ctx);
}

/// 压缩中间件（简化实现）
pub fn compressionMiddleware(ctx: *Context, next: NextFn) !void {
    // 检查客户端是否支持压缩
    const accept_encoding = ctx.request.getHeader("Accept-Encoding") orelse "";

    const supports_gzip = std.mem.indexOf(u8, accept_encoding, "gzip") != null;
    const supports_deflate = std.mem.indexOf(u8, accept_encoding, "deflate") != null;

    // 先执行下一个中间件，让响应体生成
    try next(ctx);

    // 如果响应体较小，不进行压缩
    if (ctx.response.body == null or ctx.response.body.?.len < 1024) {
        return;
    }

    // 实际应用中，这里应该进行压缩
    // 简化实现，仅设置头部
    if (supports_gzip) {
        try ctx.response.setHeader("Content-Encoding", "gzip");
    } else if (supports_deflate) {
        try ctx.response.setHeader("Content-Encoding", "deflate");
    }
}

/// 缓存控制中间件
pub fn cacheControlMiddleware(max_age_seconds: u32) MiddlewareFn {
    const CacheControlMiddleware = struct {
        max_age: u32,

        fn middleware(self: @This(), ctx: *Context, next: NextFn) !void {
            try next(ctx);

            // 只对成功的 GET 请求设置缓存
            if (std.mem.eql(u8, ctx.request.method, "GET") and
                @intFromEnum(ctx.response.status) >= 200 and
                @intFromEnum(ctx.response.status) < 300)
            {
                const cache_control = try std.fmt.allocPrint(ctx.allocator, "public, max-age={d}", .{self.max_age});
                defer ctx.allocator.free(cache_control);

                try ctx.response.setHeader("Cache-Control", cache_control);

                // 设置 ETag（简化实现）
                const etag = "\"simple-etag\""; // 实际应该基于内容生成
                try ctx.response.setHeader("ETag", etag);
            }
        }
    };

    const middleware_instance = CacheControlMiddleware{ .max_age = max_age_seconds };
    return middleware_instance.middleware;
}

/// 请求 ID 中间件
pub fn requestIdMiddleware(ctx: *Context, next: NextFn) !void {
    // 生成唯一请求 ID（简化实现）
    const timestamp = std.time.timestamp();
    const request_id = try std.fmt.allocPrint(ctx.allocator, "req-{d}-{d}", .{ timestamp, std.crypto.random.int(u32) });
    defer ctx.allocator.free(request_id);

    try ctx.response.setHeader("X-Request-ID", request_id);
    try ctx.setState("request_id", request_id);

    try next(ctx);
}
