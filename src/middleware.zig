const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Context = @import("context.zig").Context;

/// 中间件链中下一个处理函数的类型定义
pub const NextFn = *const fn (*Context) anyerror!void;

/// 中间件函数的类型定义
/// 接收上下文和下一个处理函数，实现请求处理逻辑
pub const MiddlewareFn = *const fn (*Context, NextFn) anyerror!void;

/// 中间件执行栈
/// 管理中间件的注册和按顺序执行
pub const MiddlewareStack = struct {
    allocator: Allocator, // 内存分配器
    middlewares: ArrayList(MiddlewareFn), // 中间件函数列表

    const Self = @This();

    /// 初始化中间件栈
    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .middlewares = ArrayList(MiddlewareFn).init(allocator),
        };
    }

    /// 注册中间件到执行栈
    pub fn use(self: *Self, middleware: MiddlewareFn) !void {
        try self.middlewares.append(middleware);
    }

    /// 按注册顺序执行所有中间件
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

/// 请求日志中间件
pub fn loggerMiddleware(ctx: *Context, next: NextFn) !void {
    const start_time = std.time.milliTimestamp();

    std.debug.print("[{s}] {s} - 开始处理\n", .{ ctx.request.method, ctx.request.path });

    try next(ctx);

    const end_time = std.time.milliTimestamp();
    const duration = end_time - start_time;

    std.debug.print("[{s}] {s} - {d} - {d}ms\n", .{ ctx.request.method, ctx.request.path, @intFromEnum(ctx.response.status), duration });
}

/// CORS中间件
pub fn corsMiddleware(ctx: *Context, next: NextFn) !void {
    try ctx.response.setHeader("Access-Control-Allow-Origin", "*");
    try ctx.response.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    try ctx.response.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");

    // 预检请求处理
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

/// 超时中间件
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
            }
        }
    };

    const middleware_instance = TimeoutMiddleware{ .timeout = timeout_ms };
    return middleware_instance.middleware;
}

/// 限流中间件
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

/// JWT认证中间件
/// 使用安全的JWT验证替换硬编码token
const auth_module = @import("auth.zig");

// 全局认证配置和实例
var global_jwt_auth: ?*auth_module.JWTAuth = null;
var global_auth_mutex = std.Thread.Mutex{};

/// 初始化全局JWT认证
pub fn initGlobalAuth(allocator: std.mem.Allocator, secret_key: []const u8) !void {
    global_auth_mutex.lock();
    defer global_auth_mutex.unlock();

    if (global_jwt_auth) |auth| {
        allocator.destroy(auth);
    }

    const config = auth_module.AuthConfig{
        .secret_key = secret_key,
        .token_expiry = 3600, // 1小时
        .issuer = "zig-http-server",
    };

    const auth = try allocator.create(auth_module.JWTAuth);
    auth.* = auth_module.JWTAuth.init(allocator, config);
    global_jwt_auth = auth;
}

/// 清理全局JWT认证
pub fn deinitGlobalAuth(allocator: std.mem.Allocator) void {
    global_auth_mutex.lock();
    defer global_auth_mutex.unlock();

    if (global_jwt_auth) |auth| {
        allocator.destroy(auth);
        global_jwt_auth = null;
    }
}

/// 安全的JWT认证中间件
pub fn authMiddleware(ctx: *Context, next: NextFn) !void {
    const auth_header = ctx.request.getHeader("Authorization");

    if (auth_header == null) {
        ctx.status(.unauthorized);
        try ctx.json("{\"error\":\"Missing authentication token\"}");
        return;
    }

    // 验证Bearer格式
    if (!std.mem.startsWith(u8, auth_header.?, "Bearer ")) {
        ctx.status(.unauthorized);
        try ctx.json("{\"error\":\"Invalid authentication format\"}");
        return;
    }

    const token = auth_header.?[7..];

    // 使用JWT验证
    global_auth_mutex.lock();
    defer global_auth_mutex.unlock();

    if (global_jwt_auth) |jwt_auth| {
        var claims = jwt_auth.validateToken(token) catch |err| {
            const error_msg = switch (err) {
                auth_module.AuthError.ExpiredToken => "Token has expired",
                auth_module.AuthError.InvalidSignature => "Invalid token signature",
                auth_module.AuthError.InvalidFormat => "Invalid token format",
                auth_module.AuthError.InvalidClaims => "Invalid token claims",
                else => "Invalid token",
            };

            ctx.status(.unauthorized);
            const response = try std.fmt.allocPrint(ctx.allocator, "{{\"error\":\"{s}\"}}", .{error_msg});
            defer ctx.allocator.free(response);
            try ctx.json(response);
            return;
        };
        defer claims.deinit(ctx.allocator);

        // 设置用户信息到上下文
        try ctx.setState("user_id", claims.sub);
        try ctx.setState("user_role", claims.role);
        try ctx.setState("authenticated", "true");

        try next(ctx);
    } else {
        ctx.status(.internal_server_error);
        try ctx.json("{\"error\":\"Authentication service unavailable\"}");
        return;
    }
}

/// 压缩中间件
pub fn compressionMiddleware(ctx: *Context, next: NextFn) !void {
    // 检查压缩支持
    const accept_encoding = ctx.request.getHeader("Accept-Encoding") orelse "";

    const supports_gzip = std.mem.indexOf(u8, accept_encoding, "gzip") != null;
    const supports_deflate = std.mem.indexOf(u8, accept_encoding, "deflate") != null;

    // 生成响应体
    try next(ctx);

    // 小响应体不压缩
    if (ctx.response.body == null or ctx.response.body.?.len < 1024) {
        return;
    }

    // 设置压缩头部
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

            // 仅对成功的GET请求设置缓存
            if (std.mem.eql(u8, ctx.request.method, "GET") and
                @intFromEnum(ctx.response.status) >= 200 and
                @intFromEnum(ctx.response.status) < 300)
            {
                const cache_control = try std.fmt.allocPrint(ctx.allocator, "public, max-age={d}", .{self.max_age});
                defer ctx.allocator.free(cache_control);

                try ctx.response.setHeader("Cache-Control", cache_control);

                // 设置ETag
                const etag = "\"simple-etag\"";
                try ctx.response.setHeader("ETag", etag);
            }
        }
    };

    const middleware_instance = CacheControlMiddleware{ .max_age = max_age_seconds };
    return middleware_instance.middleware;
}

/// 请求ID中间件
pub fn requestIdMiddleware(ctx: *Context, next: NextFn) !void {
    // 生成请求ID
    const timestamp = std.time.timestamp();
    const request_id = try std.fmt.allocPrint(ctx.allocator, "req-{d}-{d}", .{ timestamp, std.crypto.random.int(u32) });
    defer ctx.allocator.free(request_id);

    try ctx.response.setHeader("X-Request-ID", request_id);
    try ctx.setState("request_id", request_id);

    try next(ctx);
}
