const std = @import("std");
const testing = std.testing;
const Context = @import("context.zig").Context;
const StatusCode = @import("context.zig").StatusCode;
const HttpRequest = @import("request.zig").HttpRequest;
const HttpResponse = @import("response.zig").HttpResponse;

test "StatusCode 枚举值" {
    try testing.expect(@intFromEnum(StatusCode.ok) == 200);
    try testing.expect(@intFromEnum(StatusCode.created) == 201);
    try testing.expect(@intFromEnum(StatusCode.no_content) == 204);
    try testing.expect(@intFromEnum(StatusCode.bad_request) == 400);
    try testing.expect(@intFromEnum(StatusCode.unauthorized) == 401);
    try testing.expect(@intFromEnum(StatusCode.forbidden) == 403);
    try testing.expect(@intFromEnum(StatusCode.not_found) == 404);
    try testing.expect(@intFromEnum(StatusCode.method_not_allowed) == 405);
    try testing.expect(@intFromEnum(StatusCode.internal_server_error) == 500);
    try testing.expect(@intFromEnum(StatusCode.not_implemented) == 501);
    try testing.expect(@intFromEnum(StatusCode.bad_gateway) == 502);
    try testing.expect(@intFromEnum(StatusCode.service_unavailable) == 503);
}

test "StatusCode toString 方法" {
    try testing.expectEqualStrings("OK", StatusCode.ok.toString());
    try testing.expectEqualStrings("Created", StatusCode.created.toString());
    try testing.expectEqualStrings("No Content", StatusCode.no_content.toString());
    try testing.expectEqualStrings("Bad Request", StatusCode.bad_request.toString());
    try testing.expectEqualStrings("Unauthorized", StatusCode.unauthorized.toString());
    try testing.expectEqualStrings("Forbidden", StatusCode.forbidden.toString());
    try testing.expectEqualStrings("Not Found", StatusCode.not_found.toString());
    try testing.expectEqualStrings("Method Not Allowed", StatusCode.method_not_allowed.toString());
    try testing.expectEqualStrings("Internal Server Error", StatusCode.internal_server_error.toString());
    try testing.expectEqualStrings("Not Implemented", StatusCode.not_implemented.toString());
    try testing.expectEqualStrings("Bad Gateway", StatusCode.bad_gateway.toString());
    try testing.expectEqualStrings("Service Unavailable", StatusCode.service_unavailable.toString());
}

test "Context 初始化和清理" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 创建模拟请求和响应
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

    // 创建上下文
    var ctx = Context.init(allocator, &request, &response);
    defer ctx.deinit();

    // 验证初始状态
    try testing.expect(ctx.request == &request);
    try testing.expect(ctx.response == &response);
    try testing.expect(ctx.allocator.ptr == allocator.ptr);
    try testing.expect(ctx.params.count() == 0);
    try testing.expect(ctx.state.count() == 0);
}

test "Context 参数操作" {
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

    var ctx = Context.init(allocator, &request, &response);
    defer ctx.deinit();

    // 设置参数
    try ctx.setParam("id", "123");
    try ctx.setParam("name", "test");

    // 获取参数
    const id = ctx.getParam("id");
    try testing.expect(id != null);
    try testing.expectEqualStrings("123", id.?);

    const name = ctx.getParam("name");
    try testing.expect(name != null);
    try testing.expectEqualStrings("test", name.?);

    // 获取不存在的参数
    const nonexistent = ctx.getParam("nonexistent");
    try testing.expect(nonexistent == null);

    // 覆盖参数
    try ctx.setParam("id", "456");
    const updated_id = ctx.getParam("id");
    try testing.expectEqualStrings("456", updated_id.?);
}

test "Context 状态操作" {
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

    var ctx = Context.init(allocator, &request, &response);
    defer ctx.deinit();

    // 设置状态
    try ctx.setState("user_id", "user123");
    try ctx.setState("session", "session456");

    // 获取状态
    const user_id = ctx.getState("user_id");
    try testing.expect(user_id != null);
    try testing.expectEqualStrings("user123", user_id.?);

    const session = ctx.getState("session");
    try testing.expect(session != null);
    try testing.expectEqualStrings("session456", session.?);

    // 获取不存在的状态
    const nonexistent = ctx.getState("nonexistent");
    try testing.expect(nonexistent == null);
}

test "Context 响应状态码设置" {
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

    var ctx = Context.init(allocator, &request, &response);
    defer ctx.deinit();

    // 测试设置不同状态码
    ctx.status(StatusCode.created);
    try testing.expect(ctx.response.status == StatusCode.created);

    ctx.status(StatusCode.not_found);
    try testing.expect(ctx.response.status == StatusCode.not_found);

    ctx.status(StatusCode.internal_server_error);
    try testing.expect(ctx.response.status == StatusCode.internal_server_error);
}

test "Context JSON 响应" {
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

    var ctx = Context.init(allocator, &request, &response);
    defer ctx.deinit();

    // 测试 JSON 响应
    try ctx.json("{\"message\":\"hello\"}");

    // 验证响应头和响应体
    const content_type = ctx.response.headers.get("Content-Type");
    try testing.expect(content_type != null);
    try testing.expectEqualStrings("application/json", content_type.?);

    try testing.expect(ctx.response.body != null);
    try testing.expectEqualStrings("{\"message\":\"hello\"}", ctx.response.body.?);
}

test "Context 文本响应" {
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

    var ctx = Context.init(allocator, &request, &response);
    defer ctx.deinit();

    // 测试文本响应
    try ctx.text("Hello, World!");

    // 验证响应头和响应体
    const content_type = ctx.response.headers.get("Content-Type");
    try testing.expect(content_type != null);
    try testing.expectEqualStrings("text/plain", content_type.?);

    try testing.expect(ctx.response.body != null);
    try testing.expectEqualStrings("Hello, World!", ctx.response.body.?);
}

test "Context HTML 响应" {
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

    var ctx = Context.init(allocator, &request, &response);
    defer ctx.deinit();

    // 测试 HTML 响应
    try ctx.html("<h1>Hello</h1>");

    // 验证响应头和响应体
    const content_type = ctx.response.headers.get("Content-Type");
    try testing.expect(content_type != null);
    try testing.expectEqualStrings("text/html", content_type.?);

    try testing.expect(ctx.response.body != null);
    try testing.expectEqualStrings("<h1>Hello</h1>", ctx.response.body.?);
}
