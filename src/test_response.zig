const std = @import("std");
const testing = std.testing;
const HttpResponse = @import("response.zig").HttpResponse;
const StatusCode = @import("context.zig").StatusCode;

test "HttpResponse 初始化和基本操作" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var response = HttpResponse{
        .allocator = allocator,
        .status = StatusCode.ok,
        .headers = std.StringHashMap([]const u8).init(allocator),
        .body = null,
        .cookies = std.ArrayList(HttpResponse.Cookie).init(allocator),
    };
    defer response.deinit();

    // 测试初始状态
    try testing.expect(response.status == StatusCode.ok);
    try testing.expect(response.body == null);
    try testing.expect(response.headers.count() == 0);
    try testing.expect(response.cookies.items.len == 0);
}

test "HttpResponse 设置状态码" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var response = HttpResponse{
        .allocator = allocator,
        .status = StatusCode.ok,
        .headers = std.StringHashMap([]const u8).init(allocator),
        .body = null,
        .cookies = std.ArrayList(HttpResponse.Cookie).init(allocator),
    };
    defer response.deinit();

    // 测试设置不同状态码
    response.setStatus(StatusCode.not_found);
    try testing.expect(response.status == StatusCode.not_found);

    response.setStatus(StatusCode.internal_server_error);
    try testing.expect(response.status == StatusCode.internal_server_error);

    response.setStatus(StatusCode.created);
    try testing.expect(response.status == StatusCode.created);
}

test "HttpResponse 设置请求头" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var response = HttpResponse{
        .allocator = allocator,
        .status = StatusCode.ok,
        .headers = std.StringHashMap([]const u8).init(allocator),
        .body = null,
        .cookies = std.ArrayList(HttpResponse.Cookie).init(allocator),
    };
    defer response.deinit();

    // 设置请求头
    try response.setHeader("Content-Type", "application/json");
    try response.setHeader("Cache-Control", "no-cache");

    // 验证请求头
    try testing.expect(response.headers.count() == 2);
    try testing.expectEqualStrings("application/json", response.headers.get("Content-Type").?);
    try testing.expectEqualStrings("no-cache", response.headers.get("Cache-Control").?);

    // 覆盖现有请求头
    try response.setHeader("Content-Type", "text/html");
    try testing.expectEqualStrings("text/html", response.headers.get("Content-Type").?);
    try testing.expect(response.headers.count() == 2); // 数量不变
}

test "HttpResponse 设置响应体" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var response = HttpResponse{
        .allocator = allocator,
        .status = StatusCode.ok,
        .headers = std.StringHashMap([]const u8).init(allocator),
        .body = null,
        .cookies = std.ArrayList(HttpResponse.Cookie).init(allocator),
    };
    defer response.deinit();

    // 设置响应体
    try response.setBody("Hello, World!");
    try testing.expect(response.body != null);
    try testing.expectEqualStrings("Hello, World!", response.body.?);

    // 覆盖响应体
    try response.setBody("New content");
    try testing.expectEqualStrings("New content", response.body.?);
}

test "HttpResponse JSON 响应" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var response = HttpResponse{
        .allocator = allocator,
        .status = StatusCode.ok,
        .headers = std.StringHashMap([]const u8).init(allocator),
        .body = null,
        .cookies = std.ArrayList(HttpResponse.Cookie).init(allocator),
    };
    defer response.deinit();

    // 设置 JSON 响应
    try response.setJsonBody("{\"message\":\"success\"}");

    // 验证内容类型和响应体
    try testing.expectEqualStrings("application/json; charset=utf-8", response.headers.get("Content-Type").?);
    try testing.expectEqualStrings("{\"message\":\"success\"}", response.body.?);
}

test "HttpResponse HTML 响应" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var response = HttpResponse{
        .allocator = allocator,
        .status = StatusCode.ok,
        .headers = std.StringHashMap([]const u8).init(allocator),
        .body = null,
        .cookies = std.ArrayList(HttpResponse.Cookie).init(allocator),
    };
    defer response.deinit();

    // 设置 HTML 响应
    try response.setHtmlBody("<html><body>Hello</body></html>");

    // 验证内容类型和响应体
    try testing.expectEqualStrings("text/html; charset=utf-8", response.headers.get("Content-Type").?);
    try testing.expectEqualStrings("<html><body>Hello</body></html>", response.body.?);
}

test "HttpResponse 文本响应" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var response = HttpResponse{
        .allocator = allocator,
        .status = StatusCode.ok,
        .headers = std.StringHashMap([]const u8).init(allocator),
        .body = null,
        .cookies = std.ArrayList(HttpResponse.Cookie).init(allocator),
    };
    defer response.deinit();

    // 设置文本响应
    try response.setTextBody("Plain text content");

    // 验证内容类型和响应体
    try testing.expectEqualStrings("text/plain; charset=utf-8", response.headers.get("Content-Type").?);
    try testing.expectEqualStrings("Plain text content", response.body.?);
}

test "HttpResponse Cookie 操作" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var response = HttpResponse{
        .allocator = allocator,
        .status = StatusCode.ok,
        .headers = std.StringHashMap([]const u8).init(allocator),
        .body = null,
        .cookies = std.ArrayList(HttpResponse.Cookie).init(allocator),
    };
    defer response.deinit();

    // 创建简单 Cookie
    const simple_cookie = HttpResponse.Cookie{
        .name = "session_id",
        .value = "abc123",
    };
    try response.setCookie(simple_cookie);

    // 创建复杂 Cookie
    const complex_cookie = HttpResponse.Cookie{
        .name = "user_pref",
        .value = "dark_mode",
        .path = "/",
        .domain = "example.com",
        .max_age = 3600,
        .secure = true,
        .http_only = true,
        .same_site = .Strict,
    };
    try response.setCookie(complex_cookie);

    // 验证 Cookie 数量
    try testing.expect(response.cookies.items.len == 2);

    // 验证 Cookie 内容
    try testing.expectEqualStrings("session_id", response.cookies.items[0].name);
    try testing.expectEqualStrings("abc123", response.cookies.items[0].value);

    try testing.expectEqualStrings("user_pref", response.cookies.items[1].name);
    try testing.expectEqualStrings("dark_mode", response.cookies.items[1].value);
    try testing.expectEqualStrings("/", response.cookies.items[1].path.?);
    try testing.expect(response.cookies.items[1].max_age.? == 3600);
    try testing.expect(response.cookies.items[1].secure == true);
    try testing.expect(response.cookies.items[1].http_only == true);
    try testing.expect(response.cookies.items[1].same_site.? == .Strict);
}

test "HttpResponse SameSite 枚举" {
    const SameSite = HttpResponse.Cookie.SameSite;

    try testing.expectEqualStrings("Strict", SameSite.Strict.toString());
    try testing.expectEqualStrings("Lax", SameSite.Lax.toString());
    try testing.expectEqualStrings("None", SameSite.None.toString());
}
