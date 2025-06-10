const std = @import("std");

// 导入所有测试模块
const test_buffer = @import("test_buffer.zig");
const test_config = @import("test_config.zig");
const test_context = @import("test_context.zig");
const test_request = @import("test_request.zig");
const test_response = @import("test_response.zig");
const test_router = @import("test_router.zig");
const test_middleware = @import("test_middleware.zig");
const test_performance = @import("test_performance.zig");
const test_bug_fixes = @import("test_bug_fixes.zig");

// 导入源模块
const HttpRequest = @import("request.zig").HttpRequest;
const HttpResponse = @import("response.zig").HttpResponse;
const Context = @import("context.zig").Context;
const StatusCode = @import("context.zig").StatusCode;

// 导入测试框架
test {
    // 引用所有测试模块以确保它们被编译和运行
    _ = test_buffer;
    _ = test_config;
    _ = test_context;
    _ = test_request;
    _ = test_response;
    _ = test_router;
    _ = test_middleware;
    _ = test_performance;
    _ = test_bug_fixes;
}

// 集成测试示例
test "HTTP 服务器集成测试" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 测试基本的 HTTP 请求解析和响应构建流程
    const raw_request = "GET /test?param=value HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n";

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

    // 测试参数设置和获取
    try ctx.setParam("id", "123");
    const param_value = ctx.getParam("id");
    try std.testing.expect(param_value != null);
    try std.testing.expectEqualStrings("123", param_value.?);

    // 测试响应设置
    try ctx.json("{\"message\":\"test\"}");

    // 验证响应
    try std.testing.expect(response.body != null);
    try std.testing.expectEqualStrings("{\"message\":\"test\"}", response.body.?);

    const content_type = response.headers.get("Content-Type");
    try std.testing.expect(content_type != null);
    try std.testing.expectEqualStrings("application/json", content_type.?);
}
