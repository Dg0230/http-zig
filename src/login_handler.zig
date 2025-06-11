// 登录处理模块 - 安全的用户认证和JWT生成
// 替换硬编码认证，提供真实的登录功能

const std = @import("std");
const Context = @import("context.zig").Context;
const auth_module = @import("auth.zig");
const security_logger = @import("security_logger.zig");

/// 登录请求结构
const LoginRequest = struct {
    username: []const u8,
    password: []const u8,
};

/// 登录响应结构
const LoginResponse = struct {
    success: bool,
    token: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    role: ?[]const u8 = null,
    expires_in: ?i64 = null,
    @"error": ?[]const u8 = null,
};

/// 全局用户数据库和JWT认证
var global_user_db: ?*auth_module.UserDB = null;
var global_jwt_auth: ?*auth_module.JWTAuth = null;
var global_login_mutex = std.Thread.Mutex{};

/// 初始化登录系统
pub fn initLoginSystem(allocator: std.mem.Allocator, secret_key: []const u8) !void {
    global_login_mutex.lock();
    defer global_login_mutex.unlock();

    // 清理旧实例
    if (global_user_db) |db| {
        db.deinit();
        allocator.destroy(db);
    }
    if (global_jwt_auth) |auth| {
        allocator.destroy(auth);
    }

    // 创建用户数据库
    const user_db = try allocator.create(auth_module.UserDB);
    user_db.* = auth_module.UserDB.init(allocator);
    try user_db.initDefaultUsers(); // 添加默认用户
    global_user_db = user_db;

    // 创建JWT认证
    const config = auth_module.AuthConfig{
        .secret_key = secret_key,
        .token_expiry = 3600, // 1小时
        .issuer = "zig-http-server",
    };

    const jwt_auth = try allocator.create(auth_module.JWTAuth);
    jwt_auth.* = auth_module.JWTAuth.init(allocator, config);
    global_jwt_auth = jwt_auth;
}

/// 清理登录系统
pub fn deinitLoginSystem(allocator: std.mem.Allocator) void {
    global_login_mutex.lock();
    defer global_login_mutex.unlock();

    if (global_user_db) |db| {
        db.deinit();
        allocator.destroy(db);
        global_user_db = null;
    }

    if (global_jwt_auth) |auth| {
        allocator.destroy(auth);
        global_jwt_auth = null;
    }
}

/// 登录处理函数
pub fn loginHandler(ctx: *Context) !void {
    // 只允许POST请求
    if (!std.mem.eql(u8, ctx.request.method, "POST")) {
        ctx.status(.method_not_allowed);
        try ctx.json("{\"error\":\"Only POST method allowed\"}");
        return;
    }

    // 获取请求体
    const body = ctx.request.body orelse "";
    if (body.len == 0) {
        ctx.status(.bad_request);
        try ctx.json("{\"error\":\"Request body is required\"}");
        return;
    }

    // 解析JSON请求
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch {
        ctx.status(.bad_request);
        try ctx.json("{\"error\":\"Invalid JSON format\"}");
        return;
    };
    defer parsed.deinit();

    const json_obj = parsed.value.object;
    const username = json_obj.get("username").?.string;
    const password = json_obj.get("password").?.string;

    // 输入验证
    if (username.len == 0 or password.len == 0) {
        ctx.status(.bad_request);
        try ctx.json("{\"error\":\"Username and password are required\"}");
        return;
    }

    if (username.len > 50 or password.len > 100) {
        ctx.status(.bad_request);
        try ctx.json("{\"error\":\"Username or password too long\"}");
        return;
    }

    // 获取客户端IP用于日志记录
    const client_ip = getClientIP(ctx);

    global_login_mutex.lock();
    defer global_login_mutex.unlock();

    if (global_user_db == null or global_jwt_auth == null) {
        ctx.status(.internal_server_error);
        try ctx.json("{\"error\":\"Authentication service unavailable\"}");
        return;
    }

    // 验证用户凭据
    const user = global_user_db.?.authenticateUser(username, password);

    if (user == null) {
        // 记录认证失败
        security_logger.logAuthFailure(client_ip, username, "Invalid credentials");

        ctx.status(.unauthorized);
        try ctx.json("{\"error\":\"Invalid username or password\"}");
        return;
    }

    // 生成JWT token
    const token = global_jwt_auth.?.generateToken(user.?.id, user.?.role) catch {
        ctx.status(.internal_server_error);
        try ctx.json("{\"error\":\"Failed to generate token\"}");
        return;
    };
    defer ctx.allocator.free(token);

    // 构建成功响应
    const response = LoginResponse{
        .success = true,
        .token = token,
        .user_id = user.?.id,
        .role = user.?.role,
        .expires_in = 3600,
    };

    const response_json = try std.json.stringifyAlloc(ctx.allocator, response, .{});
    defer ctx.allocator.free(response_json);

    // 记录成功登录
    var event = try security_logger.SecurityEvent.create(ctx.allocator, .authentication_success, .info, "User login successful");
    defer event.deinit(ctx.allocator);

    try event.setSourceIp(ctx.allocator, client_ip);
    try event.setUserId(ctx.allocator, user.?.id);
    event.result = .success;

    security_logger.logSecurityEvent(event) catch {}; // 不让日志错误影响登录

    ctx.status(.ok);
    try ctx.json(response_json);
}

/// 注销处理函数
pub fn logoutHandler(ctx: *Context) !void {
    // 获取用户信息（如果已认证）
    const user_id = ctx.getState("user_id");
    const client_ip = getClientIP(ctx);

    // 记录注销事件
    if (user_id) |uid| {
        var event = try security_logger.SecurityEvent.create(ctx.allocator, .session_expired, .info, "User logout");
        defer event.deinit(ctx.allocator);

        try event.setSourceIp(ctx.allocator, client_ip);
        try event.setUserId(ctx.allocator, uid);
        event.result = .success;

        security_logger.logSecurityEvent(event) catch {};
    }

    ctx.status(.ok);
    try ctx.json("{\"success\":true,\"message\":\"Logged out successfully\"}");
}

/// 用户信息处理函数
pub fn userInfoHandler(ctx: *Context) !void {
    // 需要认证
    const user_id = ctx.getState("user_id") orelse {
        ctx.status(.unauthorized);
        try ctx.json("{\"error\":\"Authentication required\"}");
        return;
    };

    const user_role = ctx.getState("user_role") orelse "unknown";

    const response = try std.fmt.allocPrint(ctx.allocator, "{{\"user_id\":\"{s}\",\"role\":\"{s}\",\"authenticated\":true}}", .{ user_id, user_role });
    defer ctx.allocator.free(response);

    try ctx.json(response);
}

/// 获取客户端IP地址
fn getClientIP(ctx: *Context) []const u8 {
    // 尝试从X-Forwarded-For头获取真实IP
    if (ctx.request.getHeader("X-Forwarded-For")) |forwarded| {
        var parts = std.mem.split(u8, forwarded, ",");
        if (parts.next()) |first_ip| {
            return std.mem.trim(u8, first_ip, " ");
        }
    }

    // 尝试从X-Real-IP头获取
    if (ctx.request.getHeader("X-Real-IP")) |real_ip| {
        return real_ip;
    }

    // 默认返回未知
    return "unknown";
}

/// 添加用户处理函数（仅管理员）
pub fn addUserHandler(ctx: *Context) !void {
    // 检查管理员权限
    const user_role = ctx.getState("user_role") orelse {
        ctx.status(.unauthorized);
        try ctx.json("{\"error\":\"Authentication required\"}");
        return;
    };

    if (!std.mem.eql(u8, user_role, "admin")) {
        ctx.status(.forbidden);
        try ctx.json("{\"error\":\"Admin privileges required\"}");
        return;
    }

    // 解析请求
    const body = ctx.request.body orelse "";
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch {
        ctx.status(.bad_request);
        try ctx.json("{\"error\":\"Invalid JSON format\"}");
        return;
    };
    defer parsed.deinit();

    const json_obj = parsed.value.object;
    const username = json_obj.get("username").?.string;
    const password = json_obj.get("password").?.string;
    const role = json_obj.get("role").?.string;

    // 输入验证
    if (username.len == 0 or password.len == 0 or role.len == 0) {
        ctx.status(.bad_request);
        try ctx.json("{\"error\":\"Username, password and role are required\"}");
        return;
    }

    // 验证角色
    const valid_roles = [_][]const u8{ "admin", "user", "guest" };
    var role_valid = false;
    for (valid_roles) |valid_role| {
        if (std.mem.eql(u8, role, valid_role)) {
            role_valid = true;
            break;
        }
    }

    if (!role_valid) {
        ctx.status(.bad_request);
        try ctx.json("{\"error\":\"Invalid role. Must be admin, user, or guest\"}");
        return;
    }

    global_login_mutex.lock();
    defer global_login_mutex.unlock();

    if (global_user_db) |user_db| {
        user_db.addUser(username, password, role) catch {
            ctx.status(.conflict);
            try ctx.json("{\"error\":\"User already exists or creation failed\"}");
            return;
        };

        ctx.status(.created);
        try ctx.json("{\"success\":true,\"message\":\"User created successfully\"}");
    } else {
        ctx.status(.internal_server_error);
        try ctx.json("{\"error\":\"User database unavailable\"}");
    }
}

// ============================================================================
// 测试用例
// ============================================================================

const testing = std.testing;

test "登录系统初始化" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try initLoginSystem(allocator, "test-secret-key");
    defer deinitLoginSystem(allocator);

    // 验证系统已初始化
    try testing.expect(global_user_db != null);
    try testing.expect(global_jwt_auth != null);
}
