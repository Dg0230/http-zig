const std = @import("std");
const testing = std.testing;
const HttpMethod = @import("request.zig").HttpMethod;
const HttpRequest = @import("request.zig").HttpRequest;

test "HttpMethod fromString 测试" {
    try testing.expect(HttpMethod.fromString("GET") == .GET);
    try testing.expect(HttpMethod.fromString("POST") == .POST);
    try testing.expect(HttpMethod.fromString("PUT") == .PUT);
    try testing.expect(HttpMethod.fromString("DELETE") == .DELETE);
    try testing.expect(HttpMethod.fromString("PATCH") == .PATCH);
    try testing.expect(HttpMethod.fromString("HEAD") == .HEAD);
    try testing.expect(HttpMethod.fromString("OPTIONS") == .OPTIONS);
    try testing.expect(HttpMethod.fromString("TRACE") == .TRACE);
    try testing.expect(HttpMethod.fromString("CONNECT") == .CONNECT);

    // 测试无效方法
    try testing.expect(HttpMethod.fromString("INVALID") == null);
    try testing.expect(HttpMethod.fromString("get") == null); // 小写
    try testing.expect(HttpMethod.fromString("") == null);
}

test "HttpMethod toString 测试" {
    try testing.expectEqualStrings("GET", HttpMethod.GET.toString());
    try testing.expectEqualStrings("POST", HttpMethod.POST.toString());
    try testing.expectEqualStrings("PUT", HttpMethod.PUT.toString());
    try testing.expectEqualStrings("DELETE", HttpMethod.DELETE.toString());
    try testing.expectEqualStrings("PATCH", HttpMethod.PATCH.toString());
    try testing.expectEqualStrings("HEAD", HttpMethod.HEAD.toString());
    try testing.expectEqualStrings("OPTIONS", HttpMethod.OPTIONS.toString());
    try testing.expectEqualStrings("TRACE", HttpMethod.TRACE.toString());
    try testing.expectEqualStrings("CONNECT", HttpMethod.CONNECT.toString());
}

test "HttpRequest 基本 GET 请求解析" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_request = "GET /hello HTTP/1.1\r\nHost: localhost\r\nUser-Agent: test\r\n\r\n";

    var request = try HttpRequest.parseFromBuffer(allocator, raw_request);
    defer request.deinit();

    try testing.expectEqualStrings("GET", request.method);
    try testing.expectEqualStrings("/hello", request.path);
    try testing.expectEqualStrings("HTTP/1.1", request.version);
    try testing.expect(request.query == null);
    try testing.expect(request.body == null);

    // 测试请求头
    const host = request.getHeader("Host");
    try testing.expect(host != null);
    try testing.expectEqualStrings("localhost", host.?);

    const user_agent = request.getHeader("User-Agent");
    try testing.expect(user_agent != null);
    try testing.expectEqualStrings("test", user_agent.?);
}

test "HttpRequest 带查询参数的请求解析" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_request = "GET /search?q=zig&limit=10 HTTP/1.1\r\nHost: example.com\r\n\r\n";

    var request = try HttpRequest.parseFromBuffer(allocator, raw_request);
    defer request.deinit();

    try testing.expectEqualStrings("GET", request.method);
    try testing.expectEqualStrings("/search", request.path);
    try testing.expect(request.query != null);
    try testing.expectEqualStrings("q=zig&limit=10", request.query.?);
}

test "HttpRequest POST 请求带请求体" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_request = "POST /api/users HTTP/1.1\r\nHost: api.example.com\r\nContent-Type: application/json\r\nContent-Length: 25\r\n\r\n{\"name\":\"John\",\"age\":30}";

    var request = try HttpRequest.parseFromBuffer(allocator, raw_request);
    defer request.deinit();

    try testing.expectEqualStrings("POST", request.method);
    try testing.expectEqualStrings("/api/users", request.path);
    try testing.expect(request.body != null);
    try testing.expectEqualStrings("{\"name\":\"John\",\"age\":30}", request.body.?);

    const content_type = request.getHeader("Content-Type");
    try testing.expect(content_type != null);
    try testing.expectEqualStrings("application/json", content_type.?);
}

test "HttpRequest 错误处理" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 测试无效请求（空请求行）
    const invalid_request1 = "\r\n\r\n";
    try testing.expectError(error.InvalidRequestLine, HttpRequest.parseFromBuffer(allocator, invalid_request1));

    // 测试无效请求行（只有空格）
    const invalid_request2 = "   \r\n\r\n";
    try testing.expectError(error.InvalidRequestLine, HttpRequest.parseFromBuffer(allocator, invalid_request2));

    // 测试无效请求行（缺少路径）
    const invalid_request3 = "GET HTTP/1.1\r\n\r\n";
    try testing.expectError(error.InvalidRequestLine, HttpRequest.parseFromBuffer(allocator, invalid_request3));

    // 测试无效请求头
    const invalid_request4 = "GET /test HTTP/1.1\r\nInvalidHeader\r\n\r\n";
    try testing.expectError(error.InvalidHeaderLine, HttpRequest.parseFromBuffer(allocator, invalid_request4));
}

test "HttpRequest 边界情况" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 测试最小有效请求
    const minimal_request = "GET / HTTP/1.1\r\n\r\n";
    var request1 = try HttpRequest.parseFromBuffer(allocator, minimal_request);
    defer request1.deinit();

    try testing.expectEqualStrings("GET", request1.method);
    try testing.expectEqualStrings("/", request1.path);
    try testing.expect(request1.query == null);
    try testing.expect(request1.body == null);

    // 测试空查询参数
    const empty_query_request = "GET /?test HTTP/1.1\r\n\r\n";
    var request2 = try HttpRequest.parseFromBuffer(allocator, empty_query_request);
    defer request2.deinit();

    try testing.expectEqualStrings("/", request2.path);
    try testing.expect(request2.query != null);
    try testing.expectEqualStrings("test", request2.query.?);
}
