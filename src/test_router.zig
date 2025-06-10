const std = @import("std");
const testing = std.testing;
const Router = @import("router.zig").Router;
const Route = @import("router.zig").Route;
const RouterGroup = @import("router.zig").RouterGroup;
const HandlerFn = @import("router.zig").HandlerFn;
const MiddlewareFn = @import("router.zig").MiddlewareFn;
const Context = @import("context.zig").Context;
const HttpMethod = @import("request.zig").HttpMethod;
const HttpRequest = @import("request.zig").HttpRequest;
const HttpResponse = @import("response.zig").HttpResponse;
const StatusCode = @import("context.zig").StatusCode;

// 测试处理函数
fn testHandler(ctx: *Context) !void {
    try ctx.text("test response");
}

fn jsonHandler(ctx: *Context) !void {
    try ctx.json("{\"message\":\"json response\"}");
}

fn paramHandler(ctx: *Context) !void {
    const id = ctx.getParam("id") orelse "unknown";
    const response = try std.fmt.allocPrint(ctx.allocator, "ID: {s}", .{id});
    defer ctx.allocator.free(response);
    try ctx.text(response);
}

// 测试中间件
fn testMiddleware(ctx: *Context, next: @import("router.zig").NextFn) !void {
    try ctx.setState("middleware_called", "true");
    try next(ctx);
}

test "Router 初始化和清理" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var router = try Router.init(allocator);
    defer {
        router.deinit();
        allocator.destroy(router);
    }

    try testing.expect(router.routes.items.len == 0);
    try testing.expect(router.global_middlewares.items.len == 0);
}

test "Router 添加路由" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var router = try Router.init(allocator);
    defer {
        router.deinit();
        allocator.destroy(router);
    }

    // 添加不同方法的路由
    _ = try router.get("/", testHandler);
    _ = try router.post("/users", jsonHandler);
    _ = try router.put("/users/:id", paramHandler);
    _ = try router.delete("/users/:id", paramHandler);

    try testing.expect(router.routes.items.len == 4);

    // 验证路由信息
    try testing.expect(router.routes.items[0].method == .GET);
    try testing.expectEqualStrings("/", router.routes.items[0].pattern);

    try testing.expect(router.routes.items[1].method == .POST);
    try testing.expectEqualStrings("/users", router.routes.items[1].pattern);

    try testing.expect(router.routes.items[2].method == .PUT);
    try testing.expectEqualStrings("/users/:id", router.routes.items[2].pattern);

    try testing.expect(router.routes.items[3].method == .DELETE);
    try testing.expectEqualStrings("/users/:id", router.routes.items[3].pattern);
}

test "Router 路由匹配" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var router = try Router.init(allocator);
    defer {
        router.deinit();
        allocator.destroy(router);
    }

    _ = try router.get("/hello", testHandler);
    _ = try router.get("/users/:id", paramHandler);
    _ = try router.get("/static/*", testHandler);

    // 测试精确匹配
    const route1 = router.findRoute(.GET, "/hello");
    try testing.expect(route1 != null);
    try testing.expectEqualStrings("/hello", route1.?.pattern);

    // 测试参数匹配
    const route2 = router.findRoute(.GET, "/users/123");
    try testing.expect(route2 != null);
    try testing.expectEqualStrings("/users/:id", route2.?.pattern);

    // 测试通配符匹配
    const route3 = router.findRoute(.GET, "/static/css/style.css");
    try testing.expect(route3 != null);
    try testing.expectEqualStrings("/static/*", route3.?.pattern);

    // 测试不匹配
    const route4 = router.findRoute(.GET, "/nonexistent");
    try testing.expect(route4 == null);

    // 测试方法不匹配
    const route5 = router.findRoute(.POST, "/hello");
    try testing.expect(route5 == null);
}

test "Router 参数提取" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 创建模拟请求
    const raw_request = "GET /users/123 HTTP/1.1\r\nHost: localhost\r\n\r\n";
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

    var router = try Router.init(allocator);
    defer {
        router.deinit();
        allocator.destroy(router);
    }

    // 测试参数提取
    try router.extractParams("/users/:id", "/users/123", &ctx);
    const id = ctx.getParam("id");
    try testing.expect(id != null);
    try testing.expectEqualStrings("123", id.?);

    // 测试多个参数
    try router.extractParams("/users/:userId/posts/:postId", "/users/456/posts/789", &ctx);
    const user_id = ctx.getParam("userId");
    const post_id = ctx.getParam("postId");
    try testing.expect(user_id != null);
    try testing.expect(post_id != null);
    try testing.expectEqualStrings("456", user_id.?);
    try testing.expectEqualStrings("789", post_id.?);
}

test "RouterGroup 基本操作" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var router = try Router.init(allocator);
    defer {
        router.deinit();
        allocator.destroy(router);
    }

    // 创建路由组
    var api_group = try router.group("/api");
    defer api_group.deinit();

    // 在组中添加路由
    _ = try api_group.get("/users", testHandler);
    _ = try api_group.post("/users", jsonHandler);

    // 验证路由已添加到主路由器
    try testing.expect(router.routes.items.len == 2);
    try testing.expectEqualStrings("/api/users", router.routes.items[0].pattern);
    try testing.expectEqualStrings("/api/users", router.routes.items[1].pattern);
    try testing.expect(router.routes.items[0].method == .GET);
    try testing.expect(router.routes.items[1].method == .POST);
}

test "RouterGroup 嵌套组" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var router = try Router.init(allocator);
    defer {
        router.deinit();
        allocator.destroy(router);
    }

    // 创建嵌套路由组
    var api_group = try router.group("/api");
    defer api_group.deinit();

    var v1_group = try api_group.group("/v1");
    defer v1_group.deinit();

    // 在嵌套组中添加路由
    _ = try v1_group.get("/users", testHandler);

    // 验证完整路径
    try testing.expect(router.routes.items.len == 1);
    try testing.expectEqualStrings("/api/v1/users", router.routes.items[0].pattern);
}

test "Router 全局中间件" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var router = try Router.init(allocator);
    defer {
        router.deinit();
        allocator.destroy(router);
    }

    // 添加全局中间件
    try router.use(testMiddleware);

    try testing.expect(router.global_middlewares.items.len == 1);
}

test "Route 中间件" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var router = try Router.init(allocator);
    defer {
        router.deinit();
        allocator.destroy(router);
    }

    // 添加路由并设置中间件
    var route = try router.get("/test", testHandler);
    try route.use(testMiddleware);

    try testing.expect(route.middlewares.items.len == 1);
}
