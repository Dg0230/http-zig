// 安全事件日志模块 - NASA标准安全加固
// 记录和监控安全相关事件，支持实时分析和审计

const std = @import("std");
const testing = std.testing;

/// 安全事件类型
pub const SecurityEventType = enum {
    // 认证相关
    authentication_success,
    authentication_failure,
    authentication_lockout,
    session_created,
    session_expired,

    // 授权相关
    authorization_success,
    authorization_failure,
    privilege_escalation_attempt,

    // 输入验证相关
    request_too_large,
    invalid_request_format,
    malicious_input_detected,
    sql_injection_attempt,
    xss_attempt,

    // 网络安全相关
    rate_limit_exceeded,
    connection_limit_exceeded,
    suspicious_ip_activity,
    ddos_attempt,

    // 系统安全相关
    buffer_overflow_attempt,
    integer_overflow_detected,
    memory_exhaustion_attempt,
    file_access_violation,

    // 配置和管理相关
    configuration_change,
    security_policy_violation,
    admin_action,

    // 其他安全事件
    unknown_security_event,
};

/// 安全事件严重程度
pub const SecuritySeverity = enum {
    info, // 信息性事件
    low, // 低风险
    medium, // 中等风险
    high, // 高风险
    critical, // 关键风险

    pub fn toString(self: SecuritySeverity) []const u8 {
        return switch (self) {
            .info => "INFO",
            .low => "LOW",
            .medium => "MEDIUM",
            .high => "HIGH",
            .critical => "CRITICAL",
        };
    }
};

/// 安全事件结构
pub const SecurityEvent = struct {
    id: u64, // 事件唯一ID
    timestamp: i64, // 事件时间戳
    event_type: SecurityEventType, // 事件类型
    severity: SecuritySeverity, // 严重程度
    source_ip: ?[]const u8, // 源IP地址
    user_id: ?[]const u8, // 用户ID
    session_id: ?[]const u8, // 会话ID
    resource: ?[]const u8, // 访问的资源
    action: ?[]const u8, // 执行的操作
    result: EventResult, // 事件结果
    details: ?[]const u8, // 详细信息
    user_agent: ?[]const u8, // 用户代理
    referer: ?[]const u8, // 引用页面

    pub const EventResult = enum {
        success,
        failure,
        blocked,
        warning,
    };

    /// 创建新的安全事件
    pub fn create(
        allocator: std.mem.Allocator,
        event_type: SecurityEventType,
        severity: SecuritySeverity,
        details: ?[]const u8,
    ) !SecurityEvent {
        return SecurityEvent{
            .id = generateEventId(),
            .timestamp = std.time.milliTimestamp(),
            .event_type = event_type,
            .severity = severity,
            .source_ip = null,
            .user_id = null,
            .session_id = null,
            .resource = null,
            .action = null,
            .result = .warning,
            .details = if (details) |d| try allocator.dupe(u8, d) else null,
            .user_agent = null,
            .referer = null,
        };
    }

    /// 设置源IP
    pub fn setSourceIp(self: *SecurityEvent, allocator: std.mem.Allocator, ip: []const u8) !void {
        if (self.source_ip) |old_ip| {
            allocator.free(old_ip);
        }
        self.source_ip = try allocator.dupe(u8, ip);
    }

    /// 设置用户ID
    pub fn setUserId(self: *SecurityEvent, allocator: std.mem.Allocator, user_id: []const u8) !void {
        if (self.user_id) |old_id| {
            allocator.free(old_id);
        }
        self.user_id = try allocator.dupe(u8, user_id);
    }

    /// 设置资源路径
    pub fn setResource(self: *SecurityEvent, allocator: std.mem.Allocator, resource: []const u8) !void {
        if (self.resource) |old_resource| {
            allocator.free(old_resource);
        }
        self.resource = try allocator.dupe(u8, resource);
    }

    /// 清理资源
    pub fn deinit(self: *SecurityEvent, allocator: std.mem.Allocator) void {
        if (self.source_ip) |ip| allocator.free(ip);
        if (self.user_id) |id| allocator.free(id);
        if (self.session_id) |id| allocator.free(id);
        if (self.resource) |res| allocator.free(res);
        if (self.action) |act| allocator.free(act);
        if (self.details) |det| allocator.free(det);
        if (self.user_agent) |ua| allocator.free(ua);
        if (self.referer) |ref| allocator.free(ref);
    }
};

/// 安全日志记录器
pub const SecurityLogger = struct {
    allocator: std.mem.Allocator,
    log_file: ?std.fs.File,
    event_counter: std.atomic.Value(u64),
    buffer: std.ArrayList(u8),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, log_file_path: ?[]const u8) !SecurityLogger {
        var log_file: ?std.fs.File = null;

        if (log_file_path) |path| {
            log_file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch |err| switch (err) {
                error.FileNotFound => try std.fs.cwd().createFile(path, .{}),
                else => return err,
            };
        }

        return SecurityLogger{
            .allocator = allocator,
            .log_file = log_file,
            .event_counter = std.atomic.Value(u64).init(0),
            .buffer = std.ArrayList(u8).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *SecurityLogger) void {
        if (self.log_file) |file| {
            file.close();
        }
        self.buffer.deinit();
    }

    /// 记录安全事件
    pub fn logEvent(self: *SecurityLogger, event: SecurityEvent) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // 清空缓冲区
        self.buffer.clearRetainingCapacity();

        // 构建JSON格式的日志条目
        const writer = self.buffer.writer();
        try writer.print("{{", .{});
        try writer.print("\"id\":{d},", .{event.id});
        try writer.print("\"timestamp\":{d},", .{event.timestamp});
        try writer.print("\"event_type\":\"{s}\",", .{@tagName(event.event_type)});
        try writer.print("\"severity\":\"{s}\",", .{event.severity.toString()});
        try writer.print("\"result\":\"{s}\"", .{@tagName(event.result)});

        if (event.source_ip) |ip| {
            try writer.print(",\"source_ip\":\"{s}\"", .{ip});
        }
        if (event.user_id) |user| {
            try writer.print(",\"user_id\":\"{s}\"", .{user});
        }
        if (event.session_id) |session| {
            try writer.print(",\"session_id\":\"{s}\"", .{session});
        }
        if (event.resource) |resource| {
            try writer.print(",\"resource\":\"{s}\"", .{resource});
        }
        if (event.action) |action| {
            try writer.print(",\"action\":\"{s}\"", .{action});
        }
        if (event.details) |details| {
            try writer.print(",\"details\":\"{s}\"", .{details});
        }
        if (event.user_agent) |ua| {
            try writer.print(",\"user_agent\":\"{s}\"", .{ua});
        }

        try writer.print("}}\n", .{});

        // 写入文件
        if (self.log_file) |file| {
            try file.writeAll(self.buffer.items);
            try file.sync();
        }

        // 同时输出到标准日志
        std.log.warn("[SECURITY] {s} - {s} - {s}", .{
            event.severity.toString(),
            @tagName(event.event_type),
            event.details orelse "No details",
        });
    }

    /// 记录认证失败事件
    pub fn logAuthenticationFailure(self: *SecurityLogger, ip: ?[]const u8, user_id: ?[]const u8, reason: []const u8) !void {
        var event = try SecurityEvent.create(self.allocator, .authentication_failure, .medium, reason);
        defer event.deinit(self.allocator);

        if (ip) |source_ip| {
            try event.setSourceIp(self.allocator, source_ip);
        }
        if (user_id) |uid| {
            try event.setUserId(self.allocator, uid);
        }

        event.result = .failure;
        try self.logEvent(event);
    }

    /// 记录速率限制超出事件
    pub fn logRateLimitExceeded(self: *SecurityLogger, ip: []const u8, endpoint: []const u8) !void {
        var event = try SecurityEvent.create(self.allocator, .rate_limit_exceeded, .medium, "Rate limit exceeded");
        defer event.deinit(self.allocator);

        try event.setSourceIp(self.allocator, ip);
        try event.setResource(self.allocator, endpoint);
        event.result = .blocked;

        try self.logEvent(event);
    }

    /// 记录恶意输入检测事件
    pub fn logMaliciousInput(self: *SecurityLogger, ip: ?[]const u8, input_type: []const u8, details: []const u8) !void {
        var event = try SecurityEvent.create(self.allocator, .malicious_input_detected, .high, details);
        defer event.deinit(self.allocator);

        if (ip) |source_ip| {
            try event.setSourceIp(self.allocator, source_ip);
        }

        // 设置action为输入类型
        if (event.action) |old_action| {
            self.allocator.free(old_action);
        }
        event.action = try self.allocator.dupe(u8, input_type);
        event.result = .blocked;

        try self.logEvent(event);
    }

    /// 记录缓冲区溢出尝试事件
    pub fn logBufferOverflowAttempt(self: *SecurityLogger, ip: ?[]const u8, buffer_type: []const u8, attempted_size: usize) !void {
        const details = try std.fmt.allocPrint(self.allocator, "Buffer overflow attempt: {s}, size: {d}", .{ buffer_type, attempted_size });
        defer self.allocator.free(details);

        var event = try SecurityEvent.create(self.allocator, .buffer_overflow_attempt, .critical, details);
        defer event.deinit(self.allocator);

        if (ip) |source_ip| {
            try event.setSourceIp(self.allocator, source_ip);
        }

        event.result = .blocked;
        try self.logEvent(event);
    }

    /// 记录整数溢出检测事件
    pub fn logIntegerOverflow(self: *SecurityLogger, operation: []const u8, values: []const u8) !void {
        const details = try std.fmt.allocPrint(self.allocator, "Integer overflow in {s}: {s}", .{ operation, values });
        defer self.allocator.free(details);

        var event = try SecurityEvent.create(self.allocator, .integer_overflow_detected, .high, details);
        defer event.deinit(self.allocator);

        event.result = .blocked;
        try self.logEvent(event);
    }
};

/// 生成唯一事件ID
fn generateEventId() u64 {
    const static = struct {
        var counter = std.atomic.Value(u64).init(1);
    };
    return static.counter.fetchAdd(1, .monotonic);
}

// ============================================================================
// 便捷函数
// ============================================================================

/// 全局安全日志记录器实例
var global_logger: ?*SecurityLogger = null;
var global_logger_mutex = std.Thread.Mutex{};

/// 初始化全局安全日志记录器
pub fn initGlobalLogger(allocator: std.mem.Allocator, log_file_path: ?[]const u8) !void {
    global_logger_mutex.lock();
    defer global_logger_mutex.unlock();

    if (global_logger) |logger| {
        logger.deinit();
        allocator.destroy(logger);
    }

    const logger = try allocator.create(SecurityLogger);
    logger.* = try SecurityLogger.init(allocator, log_file_path);
    global_logger = logger;
}

/// 清理全局安全日志记录器
pub fn deinitGlobalLogger(allocator: std.mem.Allocator) void {
    global_logger_mutex.lock();
    defer global_logger_mutex.unlock();

    if (global_logger) |logger| {
        logger.deinit();
        allocator.destroy(logger);
        global_logger = null;
    }
}

/// 记录安全事件到全局日志记录器
pub fn logSecurityEvent(event: SecurityEvent) !void {
    global_logger_mutex.lock();
    defer global_logger_mutex.unlock();

    if (global_logger) |logger| {
        try logger.logEvent(event);
    }
}

/// 快速记录认证失败
pub fn logAuthFailure(ip: ?[]const u8, user_id: ?[]const u8, reason: []const u8) void {
    global_logger_mutex.lock();
    defer global_logger_mutex.unlock();

    if (global_logger) |logger| {
        logger.logAuthenticationFailure(ip, user_id, reason) catch |err| {
            std.log.err("Failed to log authentication failure: {any}", .{err});
        };
    }
}

/// 快速记录速率限制
pub fn logRateLimit(ip: []const u8, endpoint: []const u8) void {
    global_logger_mutex.lock();
    defer global_logger_mutex.unlock();

    if (global_logger) |logger| {
        logger.logRateLimitExceeded(ip, endpoint) catch |err| {
            std.log.err("Failed to log rate limit: {any}", .{err});
        };
    }
}

// ============================================================================
// 测试用例
// ============================================================================

test "安全事件创建和记录" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var logger = try SecurityLogger.init(allocator, null);
    defer logger.deinit();

    // 创建测试事件
    var event = try SecurityEvent.create(allocator, .authentication_failure, .medium, "Invalid password");
    defer event.deinit(allocator);

    try event.setSourceIp(allocator, "192.168.1.100");
    try event.setUserId(allocator, "test_user");
    event.result = .failure;

    // 记录事件
    try logger.logEvent(event);

    // 验证事件ID生成
    try testing.expect(event.id > 0);
    try testing.expect(event.timestamp > 0);
}

test "安全日志记录器便捷方法" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var logger = try SecurityLogger.init(allocator, null);
    defer logger.deinit();

    // 测试认证失败记录
    try logger.logAuthenticationFailure("192.168.1.100", "test_user", "Invalid credentials");

    // 测试速率限制记录
    try logger.logRateLimitExceeded("192.168.1.100", "/api/login");

    // 测试恶意输入记录
    try logger.logMaliciousInput("192.168.1.100", "SQL Injection", "SELECT * FROM users");

    // 测试缓冲区溢出记录
    try logger.logBufferOverflowAttempt("192.168.1.100", "HTTP Header", 10000);
}
