const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const Context = @import("context.zig").Context;
const HttpMethod = @import("request.zig").HttpMethod;

/// 路由处理函数类型定义
pub const HandlerFn = *const fn (*Context) anyerror!void;
/// 中间件链中下一个处理函数的类型定义
pub const NextFn = *const fn (*Context) anyerror!void;
/// 中间件函数类型定义
pub const MiddlewareFn = *const fn (*Context, NextFn) anyerror!void;

/// 单个路由定义
/// 包含 HTTP 方法、路径模式、处理函数和中间件
pub const Route = struct {
    method: HttpMethod, // HTTP 方法
    pattern: []const u8, // 路径模式（支持参数和通配符）
    handler: HandlerFn, // 路由处理函数
    middlewares: ArrayList(MiddlewareFn), // 路由级中间件
    allocator: Allocator, // 内存分配器

    pub fn init(allocator: Allocator, method: HttpMethod, pattern: []const u8, handler: HandlerFn) !*Route {
        const route = try allocator.create(Route);
        route.* = Route{
            .method = method,
            .pattern = try allocator.dupe(u8, pattern),
            .handler = handler,
            .middlewares = ArrayList(MiddlewareFn).init(allocator),
            .allocator = allocator,
        };
        return route;
    }

    pub fn deinit(self: *Route) void {
        self.allocator.free(self.pattern);
        self.middlewares.deinit();
    }

    /// 为路由添加中间件
    pub fn use(self: *Route, middleware: MiddlewareFn) !void {
        try self.middlewares.append(middleware);
    }
};

/// 路由组
/// 允许为一组路由设置共同的前缀和中间件
pub const RouterGroup = struct {
    router: *Router, // 所属路由器
    prefix: []const u8, // 路径前缀
    middlewares: ArrayList(MiddlewareFn), // 组级中间件
    allocator: Allocator, // 内存分配器

    pub fn init(router: *Router, prefix: []const u8) !*RouterGroup {
        const new_group = try router.allocator.create(RouterGroup);
        new_group.* = RouterGroup{
            .router = router,
            .prefix = try router.allocator.dupe(u8, prefix),
            .middlewares = ArrayList(MiddlewareFn).init(router.allocator),
            .allocator = router.allocator,
        };
        return new_group;
    }

    pub fn deinit(self: *RouterGroup) void {
        self.allocator.free(self.prefix);
        self.middlewares.deinit();
        self.allocator.destroy(self);
    }

    pub fn use(self: *RouterGroup, middleware: MiddlewareFn) !void {
        try self.middlewares.append(middleware);
    }

    pub fn group(self: *RouterGroup, prefix: []const u8) !*RouterGroup {
        const full_prefix = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, prefix });
        defer self.allocator.free(full_prefix);

        const new_group = try RouterGroup.init(self.router, full_prefix);

        // 继承父组的中间件
        for (self.middlewares.items) |middleware| {
            try new_group.use(middleware);
        }

        return new_group;
    }

    pub fn get(self: *RouterGroup, path: []const u8, handler: HandlerFn) !*Route {
        return try self.addRoute(.GET, path, handler);
    }

    pub fn post(self: *RouterGroup, path: []const u8, handler: HandlerFn) !*Route {
        return try self.addRoute(.POST, path, handler);
    }

    pub fn put(self: *RouterGroup, path: []const u8, handler: HandlerFn) !*Route {
        return try self.addRoute(.PUT, path, handler);
    }

    pub fn delete(self: *RouterGroup, path: []const u8, handler: HandlerFn) !*Route {
        return try self.addRoute(.DELETE, path, handler);
    }

    pub fn options(self: *RouterGroup, path: []const u8, handler: HandlerFn) !*Route {
        return try self.addRoute(.OPTIONS, path, handler);
    }

    pub fn head(self: *RouterGroup, path: []const u8, handler: HandlerFn) !*Route {
        return try self.addRoute(.HEAD, path, handler);
    }

    pub fn patch(self: *RouterGroup, path: []const u8, handler: HandlerFn) !*Route {
        return try self.addRoute(.PATCH, path, handler);
    }

    fn addRoute(self: *RouterGroup, method: HttpMethod, path: []const u8, handler: HandlerFn) !*Route {
        const full_path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, path });
        defer self.allocator.free(full_path);

        const route = try self.router.addRoute(method, full_path, handler);

        // 添加组级中间件到路由
        for (self.middlewares.items) |middleware| {
            try route.use(middleware);
        }

        return route;
    }
};

/// HTTP 路由器
/// 管理所有路由和全局中间件，负责请求分发和处理
pub const Router = struct {
    routes: ArrayList(*Route), // 所有注册的路由
    global_middlewares: ArrayList(MiddlewareFn), // 全局中间件
    allocator: Allocator, // 内存分配器

    pub fn init(allocator: Allocator) !*Router {
        const router = try allocator.create(Router);
        router.* = Router{
            .routes = ArrayList(*Route).init(allocator),
            .global_middlewares = ArrayList(MiddlewareFn).init(allocator),
            .allocator = allocator,
        };
        return router;
    }

    pub fn deinit(self: *Router) void {
        for (self.routes.items) |route| {
            route.deinit();
            self.allocator.destroy(route);
        }
        self.routes.deinit();
        self.global_middlewares.deinit();
    }

    pub fn use(self: *Router, middleware: MiddlewareFn) !void {
        try self.global_middlewares.append(middleware);
    }

    pub fn group(self: *Router, prefix: []const u8) !*RouterGroup {
        return try RouterGroup.init(self, prefix);
    }

    pub fn get(self: *Router, path: []const u8, handler: HandlerFn) !*Route {
        return try self.addRoute(.GET, path, handler);
    }

    pub fn post(self: *Router, path: []const u8, handler: HandlerFn) !*Route {
        return try self.addRoute(.POST, path, handler);
    }

    pub fn put(self: *Router, path: []const u8, handler: HandlerFn) !*Route {
        return try self.addRoute(.PUT, path, handler);
    }

    pub fn delete(self: *Router, path: []const u8, handler: HandlerFn) !*Route {
        return try self.addRoute(.DELETE, path, handler);
    }

    pub fn options(self: *Router, path: []const u8, handler: HandlerFn) !*Route {
        return try self.addRoute(.OPTIONS, path, handler);
    }

    pub fn head(self: *Router, path: []const u8, handler: HandlerFn) !*Route {
        return try self.addRoute(.HEAD, path, handler);
    }

    pub fn patch(self: *Router, path: []const u8, handler: HandlerFn) !*Route {
        return try self.addRoute(.PATCH, path, handler);
    }

    pub fn addRoute(self: *Router, method: HttpMethod, path: []const u8, handler: HandlerFn) !*Route {
        const route = try Route.init(self.allocator, method, path, handler);
        try self.routes.append(route);
        return route;
    }

    pub fn handleRequest(self: *Router, ctx: *Context) !void {
        // 执行全局中间件
        try self.executeMiddlewares(ctx, self.global_middlewares.items);

        // 查找匹配的路由
        const method_enum = HttpMethod.fromString(ctx.request.method) orelse {
            return error.InvalidMethod;
        };
        const route = self.findRoute(method_enum, ctx.request.path) orelse {
            return error.NotFound;
        };

        // 提取路由参数
        try self.extractParams(route.pattern, ctx.request.path, ctx);

        // 执行路由中间件和处理函数
        try self.executeRouteHandler(ctx, route);
    }

    pub fn findRoute(self: *Router, method: HttpMethod, path: []const u8) ?*Route {
        for (self.routes.items) |route| {
            if (route.method == method and self.matchRoute(route.pattern, path)) {
                return route;
            }
        }
        return null;
    }

    fn matchRoute(_: *Router, pattern: []const u8, path: []const u8) bool {
        // 精确匹配
        if (std.mem.eql(u8, pattern, path)) {
            return true;
        }

        // 参数匹配
        var pattern_parts = std.mem.splitScalar(u8, pattern, '/');
        var path_parts = std.mem.splitScalar(u8, path, '/');

        while (true) {
            const pattern_part = pattern_parts.next() orelse {
                // 如果路径还有剩余部分，则不匹配
                return path_parts.next() == null;
            };

            const path_part = path_parts.next() orelse {
                // 如果模式还有剩余部分，则不匹配
                return false;
            };

            // 参数部分（以:开头）
            if (pattern_part.len > 0 and pattern_part[0] == ':') {
                // 参数匹配任何非空路径部分
                if (path_part.len == 0) {
                    return false;
                }
                continue;
            }

            // 通配符部分（*）
            if (std.mem.eql(u8, pattern_part, "*")) {
                // 匹配任何内容，包括剩余的所有路径
                return true;
            }

            // 普通部分，必须精确匹配
            if (!std.mem.eql(u8, pattern_part, path_part)) {
                return false;
            }
        }

        return true;
    }

    pub fn extractParams(self: *Router, pattern: []const u8, path: []const u8, ctx: *Context) !void {
        _ = self;

        var pattern_parts = std.mem.splitScalar(u8, pattern, '/');
        var path_parts = std.mem.splitScalar(u8, path, '/');

        while (true) {
            const pattern_part = pattern_parts.next() orelse break;
            const path_part = path_parts.next() orelse break;

            // 参数部分（以:开头）
            if (pattern_part.len > 0 and pattern_part[0] == ':') {
                const param_name = pattern_part[1..];
                try ctx.setParam(param_name, path_part);
            }
        }
    }

    fn executeMiddlewares(self: *Router, ctx: *Context, middlewares: []const MiddlewareFn) !void {
        _ = self;

        if (middlewares.len == 0) {
            return;
        }

        // 简化的中间件执行逻辑
        var i: usize = 0;
        while (i < middlewares.len) {
            const current = middlewares[i];
            i += 1;

            // 创建一个简单的next函数，如果还有中间件就继续执行
            const nextFn = struct {
                fn next(ctx2: *Context) !void {
                    // 这里什么都不做，因为我们在while循环中处理
                    _ = ctx2;
                }
            }.next;

            try current(ctx, nextFn);
        }
    }

    fn executeRouteHandler(self: *Router, ctx: *Context, route: *Route) !void {
        // 创建包含路由中间件和处理函数的中间件链
        var all_middlewares = ArrayList(MiddlewareFn).init(self.allocator);
        defer all_middlewares.deinit();

        // 添加路由中间件
        for (route.middlewares.items) |middleware| {
            try all_middlewares.append(middleware);
        }

        // 执行中间件链
        try self.executeMiddlewares(ctx, all_middlewares.items);

        // 最后执行路由处理函数
        try route.handler(ctx);
    }
};
