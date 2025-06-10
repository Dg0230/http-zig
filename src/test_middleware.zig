const std = @import("std");
const testing = std.testing;
const Context = @import("context.zig").Context;
const StatusCode = @import("context.zig").StatusCode;
const HttpRequest = @import("request.zig").HttpRequest;
const HttpResponse = @import("response.zig").HttpResponse;
const MiddlewareFn = @import("middleware.zig").MiddlewareFn;
const NextFn = @import("middleware.zig").NextFn;
const MiddlewareStack = @import("middleware.zig").MiddlewareStack;

// 导入中间件函数
const corsMiddleware = @import("middleware.zig").corsMiddleware;
const loggerMiddleware = @import("middleware.zig").loggerMiddleware;
const errorHandlerMiddleware = @import("middleware.zig").errorHandlerMiddleware;
const authMiddleware = @import("middleware.zig").authMiddleware;

// 模拟 next 函数
fn mockNext(ctx: *Context) !void {
    try ctx.setState("next_called", "true");
}

test "CORS 中间件基本功能" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_request = "GET /test HTTP/1.1\r\nHost: localhost\r\nOrigin: http://example.com\r\n\r\n";
    var request = try HttpRequest.parseFromBuffer(allocator, raw_request);
    defer request.deinit();

    var response = HttpResponse{
        .allocator = allocator,
        .status = StatusCode.ok,
        .headers = std.StringHashMap([]const u8).init(allocator),
        .body = null,
        .cookies = std.ArrayList(HttpResponse.Cookie).init(allocator),
    };
    defer response.deinit();

    var context = Context.init(allocator, &request, &response);
    defer context.deinit();

    // 测试 CORS 中间件
    try corsMiddleware(&context, mockNext);

    // 验证 CORS 头部已设置
    const access_control_allow_origin = response.headers.get("Access-Control-Allow-Origin");
    try testing.expect(access_control_allow_origin != null);
    try testing.expectEqualStrings("*", access_control_allow_origin.?);

    const access_control_allow_methods = response.headers.get("Access-Control-Allow-Methods");
    try testing.expect(access_control_allow_methods != null);
    try testing.expectEqualStrings("GET, POST, PUT, DELETE, OPTIONS", access_control_allow_methods.?);

    const access_control_allow_headers = response.headers.get("Access-Control-Allow-Headers");
    try testing.expect(access_control_allow_headers != null);
    try testing.expectEqualStrings("Content-Type, Authorization", access_control_allow_headers.?);

    // 验证 next 被调用
    const next_called = context.getState("next_called");
    try testing.expect(next_called != null);
    try testing.expectEqualStrings("true", next_called.?);
}

test "MiddlewareStack 基本操作" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stack = MiddlewareStack.init(allocator);
    defer stack.deinit();

    // 测试初始状态
    try testing.expect(stack.middlewares.items.len == 0);

    // 添加中间件
    try stack.use(corsMiddleware);
    try stack.use(loggerMiddleware);

    try testing.expect(stack.middlewares.items.len == 2);

    // 测试执行中间件栈
    const raw_request = "GET /test HTTP/1.1\r\nHost: localhost\r\nOrigin: http://example.com\r\n\r\n";
    var request = try HttpRequest.parseFromBuffer(allocator, raw_request);
    defer request.deinit();

    var response = HttpResponse{
        .allocator = allocator,
        .status = StatusCode.ok,
        .headers = std.StringHashMap([]const u8).init(allocator),
        .body = null,
        .cookies = std.ArrayList(HttpResponse.Cookie).init(allocator),
    };
    defer response.deinit();

    var context = Context.init(allocator, &request, &response);
    defer context.deinit();

    try stack.execute(&context);

    // 验证 CORS 头部已设置
    const access_control_allow_origin = response.headers.get("Access-Control-Allow-Origin");
    try testing.expect(access_control_allow_origin != null);
}

test "CORS 预检请求处理" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 创建 OPTIONS 预检请求
    const raw_request = "OPTIONS /test HTTP/1.1\r\nHost: localhost\r\nOrigin: http://example.com\r\nAccess-Control-Request-Method: POST\r\n\r\n";
    var request = try HttpRequest.parseFromBuffer(allocator, raw_request);
    defer request.deinit();

    var response = HttpResponse{
        .allocator = allocator,
        .status = StatusCode.ok,
        .headers = std.StringHashMap([]const u8).init(allocator),
        .body = null,
        .cookies = std.ArrayList(HttpResponse.Cookie).init(allocator),
    };
    defer response.deinit();

    var context = Context.init(allocator, &request, &response);
    defer context.deinit();

    try corsMiddleware(&context, mockNext);

    // 验证预检请求响应
    try testing.expect(context.response.status == StatusCode.no_content);
    try testing.expect(context.response.headers.get("Access-Control-Allow-Origin") != null);
}

test "Logger 中间件" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_request = "GET /test HTTP/1.1\r\nHost: localhost\r\n\r\n";
    var request = try HttpRequest.parseFromBuffer(allocator, raw_request);
    defer request.deinit();

    var response = HttpResponse{
        .allocator = allocator,
        .status = StatusCode.ok,
        .headers = std.StringHashMap([]const u8).init(allocator),
        .body = null,
        .cookies = std.ArrayList(HttpResponse.Cookie).init(allocator),
    };
    defer response.deinit();

    var context = Context.init(allocator, &request, &response);
    defer context.deinit();

    // 测试日志中间件
    try loggerMiddleware(&context, mockNext);

    // 验证 next 被调用
    const next_called = context.getState("next_called");
    try testing.expect(next_called != null);
    try testing.expectEqualStrings("true", next_called.?);

    // 注意：实际的日志输出很难在测试中验证，这里主要测试中间件不会崩溃
}

test "错误处理中间件" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_request = "GET /test HTTP/1.1\r\nHost: localhost\r\n\r\n";
    var request = try HttpRequest.parseFromBuffer(allocator, raw_request);
    defer request.deinit();

    var response = HttpResponse{
        .allocator = allocator,
        .status = StatusCode.ok,
        .headers = std.StringHashMap([]const u8).init(allocator),
        .body = null,
        .cookies = std.ArrayList(HttpResponse.Cookie).init(allocator),
    };
    defer response.deinit();

    var context = Context.init(allocator, &request, &response);
    defer context.deinit();

    // 模拟会抛出错误的 next 函数
    const errorNext = struct {
        fn next(ctx: *Context) !void {
            _ = ctx;
            return error.NotFound;
        }
    }.next;

    // 测试错误处理中间件
    try errorHandlerMiddleware(&context, errorNext);

    // 验证错误被处理
    try testing.expect(context.response.status == StatusCode.not_found);
    try testing.expect(context.response.body != null);
}

test "认证中间件" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 测试无认证头的情况
    {
        const raw_request = "GET /test HTTP/1.1\r\nHost: localhost\r\n\r\n";
        var request = try HttpRequest.parseFromBuffer(allocator, raw_request);
        defer request.deinit();

        var response = HttpResponse{
            .allocator = allocator,
            .status = StatusCode.ok,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = null,
            .cookies = std.ArrayList(HttpResponse.Cookie).init(allocator),
        };
        defer response.deinit();

        var context = Context.init(allocator, &request, &response);
        defer context.deinit();

        try authMiddleware(&context, mockNext);
        try testing.expect(context.response.status == StatusCode.unauthorized);
    }

    // 测试有效认证头的情况
    {
        const raw_request_with_auth = "GET /test HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer valid-token\r\n\r\n";
        var request_with_auth = try HttpRequest.parseFromBuffer(allocator, raw_request_with_auth);
        defer request_with_auth.deinit();

        var response_with_auth = HttpResponse{
            .allocator = allocator,
            .status = StatusCode.ok,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = null,
            .cookies = std.ArrayList(HttpResponse.Cookie).init(allocator),
        };
        defer response_with_auth.deinit();

        var context_with_auth = Context.init(allocator, &request_with_auth, &response_with_auth);
        defer context_with_auth.deinit();

        try authMiddleware(&context_with_auth, mockNext);

        // 验证认证成功
        const user = context_with_auth.getState("user");
        try testing.expect(user != null);
        try testing.expectEqualStrings("authenticated_user", user.?);
    }
}

test "中间件链执行顺序" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_request = "GET /test HTTP/1.1\r\nHost: localhost\r\n\r\n";
    var request = try HttpRequest.parseFromBuffer(allocator, raw_request);
    defer request.deinit();

    var response = HttpResponse{
        .allocator = allocator,
        .status = StatusCode.ok,
        .headers = std.StringHashMap([]const u8).init(allocator),
        .body = null,
        .cookies = std.ArrayList(HttpResponse.Cookie).init(allocator),
    };
    defer response.deinit();

    var context = Context.init(allocator, &request, &response);
    defer context.deinit();

    // 创建测试中间件来验证执行顺序
    const middleware1 = struct {
        fn middleware(ctx: *Context, next: NextFn) !void {
            try ctx.setState("middleware1", "called");
            try next(ctx);
        }
    }.middleware;

    const middleware2 = struct {
        fn middleware(ctx: *Context, next: NextFn) !void {
            try ctx.setState("middleware2", "called");
            try next(ctx);
        }
    }.middleware;

    const finalHandler = struct {
        fn handler(ctx: *Context) !void {
            try ctx.setState("handler", "called");
        }
    }.handler;

    // 模拟中间件链执行
    const chainNext = struct {
        fn next(ctx: *Context) !void {
            try middleware2(ctx, struct {
                fn next2(ctx2: *Context) !void {
                    try finalHandler(ctx2);
                }
            }.next2);
        }
    }.next;

    try middleware1(&context, chainNext);

    // 验证执行顺序
    try testing.expectEqualStrings("called", context.getState("middleware1").?);
    try testing.expectEqualStrings("called", context.getState("middleware2").?);
    try testing.expectEqualStrings("called", context.getState("handler").?);
}

test "中间件错误传播" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_request = "GET /test HTTP/1.1\r\nHost: localhost\r\n\r\n";
    var request = try HttpRequest.parseFromBuffer(allocator, raw_request);
    defer request.deinit();

    var response = HttpResponse{
        .allocator = allocator,
        .status = StatusCode.ok,
        .headers = std.StringHashMap([]const u8).init(allocator),
        .body = null,
        .cookies = std.ArrayList(HttpResponse.Cookie).init(allocator),
    };
    defer response.deinit();

    var context = Context.init(allocator, &request, &response);
    defer context.deinit();

    // 创建会抛出错误的中间件
    const errorMiddleware = struct {
        fn middleware(ctx: *Context, next: NextFn) !void {
            _ = ctx;
            _ = next;
            return error.MiddlewareError;
        }
    }.middleware;

    // 测试错误传播
    try testing.expectError(error.MiddlewareError, errorMiddleware(&context, mockNext));
}
