// 安全限制配置模块 - NASA标准安全加固
// 定义系统安全边界，防止DoS攻击和资源耗尽

const std = @import("std");

/// 安全限制配置
/// 基于NASA软件安全标准制定的系统边界
pub const SecurityLimits = struct {
    // HTTP请求限制
    pub const MAX_REQUEST_SIZE: usize = 1024 * 1024; // 1MB - 防止内存耗尽
    pub const MAX_HEADER_COUNT: usize = 100; // 最大头部数量
    pub const MAX_HEADER_SIZE: usize = 8192; // 单个头部最大大小 8KB
    pub const MAX_HEADER_NAME_SIZE: usize = 256; // 头部名称最大长度
    pub const MAX_HEADER_VALUE_SIZE: usize = 4096; // 头部值最大长度
    pub const MAX_URI_LENGTH: usize = 2048; // URI最大长度
    pub const MAX_QUERY_STRING_LENGTH: usize = 1024; // 查询字符串最大长度
    pub const MAX_BODY_SIZE: usize = 10 * 1024 * 1024; // 10MB - 请求体最大大小
    pub const MAX_METHOD_LENGTH: usize = 16; // HTTP方法最大长度
    pub const MAX_VERSION_LENGTH: usize = 16; // HTTP版本最大长度

    // 连接和并发限制
    pub const MAX_CONNECTIONS: usize = 10000; // 最大并发连接数
    pub const MAX_CONNECTIONS_PER_IP: usize = 100; // 单IP最大连接数
    pub const CONNECTION_TIMEOUT_MS: u32 = 30000; // 连接超时 30秒
    pub const READ_TIMEOUT_MS: u32 = 30000; // 读取超时 30秒
    pub const WRITE_TIMEOUT_MS: u32 = 30000; // 写入超时 30秒
    pub const KEEPALIVE_TIMEOUT_MS: u32 = 60000; // Keep-Alive超时 60秒

    // 缓冲区和内存限制
    pub const MAX_BUFFER_SIZE: usize = 64 * 1024; // 64KB - 单个缓冲区最大大小
    pub const MAX_BUFFER_COUNT: usize = 1000; // 最大缓冲区数量
    pub const MAX_MEMORY_USAGE: usize = 512 * 1024 * 1024; // 512MB - 最大内存使用
    pub const BUFFER_POOL_SIZE: usize = 200; // 缓冲区池大小

    // 路由和中间件限制
    pub const MAX_ROUTES: usize = 1000; // 最大路由数量
    pub const MAX_MIDDLEWARES: usize = 50; // 最大中间件数量
    pub const MAX_ROUTE_PARAMS: usize = 20; // 单个路由最大参数数量
    pub const MAX_PARAM_NAME_LENGTH: usize = 64; // 参数名最大长度
    pub const MAX_PARAM_VALUE_LENGTH: usize = 1024; // 参数值最大长度

    // 速率限制
    pub const RATE_LIMIT_WINDOW_MS: u32 = 60000; // 速率限制窗口 1分钟
    pub const MAX_REQUESTS_PER_MINUTE: usize = 1000; // 每分钟最大请求数
    pub const MAX_REQUESTS_PER_IP_PER_MINUTE: usize = 100; // 单IP每分钟最大请求数
    pub const BURST_LIMIT: usize = 50; // 突发请求限制

    // 文件和静态资源限制
    pub const MAX_FILE_SIZE: usize = 100 * 1024 * 1024; // 100MB - 最大文件大小
    pub const MAX_FILENAME_LENGTH: usize = 255; // 文件名最大长度
    pub const MAX_PATH_DEPTH: usize = 20; // 路径最大深度
    pub const MAX_STATIC_FILES: usize = 10000; // 最大静态文件数量

    // 安全相关限制
    pub const MAX_AUTH_ATTEMPTS: usize = 5; // 最大认证尝试次数
    pub const AUTH_LOCKOUT_DURATION_MS: u32 = 300000; // 认证锁定时间 5分钟
    pub const MAX_SESSION_DURATION_MS: u32 = 3600000; // 最大会话时间 1小时
    pub const MAX_COOKIE_SIZE: usize = 4096; // Cookie最大大小
    pub const MAX_COOKIES_COUNT: usize = 50; // 最大Cookie数量

    // 日志和审计限制
    pub const MAX_LOG_ENTRY_SIZE: usize = 8192; // 单条日志最大大小
    pub const MAX_LOG_FILE_SIZE: usize = 100 * 1024 * 1024; // 100MB - 日志文件最大大小
    pub const LOG_ROTATION_COUNT: usize = 10; // 日志轮转保留数量
    pub const MAX_AUDIT_EVENTS_PER_SECOND: usize = 1000; // 每秒最大审计事件数
};

/// 安全限制错误类型
pub const SecurityLimitError = error{
    RequestTooLarge,
    TooManyHeaders,
    HeaderTooLarge,
    UriTooLong,
    BodyTooLarge,
    TooManyConnections,
    ConnectionTimeout,
    RateLimitExceeded,
    FileTooLarge,
    PathTooDeep,
    TooManyAuthAttempts,
    SessionExpired,
    InvalidInput,
    OutOfMemory,
};

/// 安全验证器
pub const SecurityValidator = struct {
    /// 验证HTTP请求大小
    pub fn validateRequestSize(size: usize) SecurityLimitError!void {
        if (size > SecurityLimits.MAX_REQUEST_SIZE) {
            return SecurityLimitError.RequestTooLarge;
        }
    }

    /// 验证头部数量
    pub fn validateHeaderCount(count: usize) SecurityLimitError!void {
        if (count > SecurityLimits.MAX_HEADER_COUNT) {
            return SecurityLimitError.TooManyHeaders;
        }
    }

    /// 验证头部大小
    pub fn validateHeaderSize(name: []const u8, value: []const u8) SecurityLimitError!void {
        if (name.len > SecurityLimits.MAX_HEADER_NAME_SIZE) {
            return SecurityLimitError.HeaderTooLarge;
        }
        if (value.len > SecurityLimits.MAX_HEADER_VALUE_SIZE) {
            return SecurityLimitError.HeaderTooLarge;
        }
        if (name.len + value.len > SecurityLimits.MAX_HEADER_SIZE) {
            return SecurityLimitError.HeaderTooLarge;
        }
    }

    /// 验证URI长度
    pub fn validateUriLength(uri: []const u8) SecurityLimitError!void {
        if (uri.len > SecurityLimits.MAX_URI_LENGTH) {
            return SecurityLimitError.UriTooLong;
        }
    }

    /// 验证请求体大小
    pub fn validateBodySize(size: usize) SecurityLimitError!void {
        if (size > SecurityLimits.MAX_BODY_SIZE) {
            return SecurityLimitError.BodyTooLarge;
        }
    }

    /// 验证HTTP方法
    pub fn validateMethod(method: []const u8) SecurityLimitError!void {
        if (method.len > SecurityLimits.MAX_METHOD_LENGTH) {
            return SecurityLimitError.InvalidInput;
        }

        // 验证方法是否为已知的HTTP方法
        const valid_methods = [_][]const u8{ "GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH", "TRACE" };

        for (valid_methods) |valid_method| {
            if (std.mem.eql(u8, method, valid_method)) {
                return;
            }
        }

        return SecurityLimitError.InvalidInput;
    }

    /// 验证HTTP版本
    pub fn validateVersion(version: []const u8) SecurityLimitError!void {
        if (version.len > SecurityLimits.MAX_VERSION_LENGTH) {
            return SecurityLimitError.InvalidInput;
        }

        // 验证版本格式
        if (!std.mem.startsWith(u8, version, "HTTP/")) {
            return SecurityLimitError.InvalidInput;
        }
    }

    /// 验证连接数量
    pub fn validateConnectionCount(current: usize) SecurityLimitError!void {
        if (current >= SecurityLimits.MAX_CONNECTIONS) {
            return SecurityLimitError.TooManyConnections;
        }
    }

    /// 验证文件大小
    pub fn validateFileSize(size: usize) SecurityLimitError!void {
        if (size > SecurityLimits.MAX_FILE_SIZE) {
            return SecurityLimitError.FileTooLarge;
        }
    }

    /// 验证路径深度
    pub fn validatePathDepth(path: []const u8) SecurityLimitError!void {
        var depth: usize = 0;
        var i: usize = 0;

        while (i < path.len) {
            if (path[i] == '/') {
                depth += 1;
                if (depth > SecurityLimits.MAX_PATH_DEPTH) {
                    return SecurityLimitError.PathTooDeep;
                }
            }
            i += 1;
        }
    }

    /// 验证输入字符串是否包含危险字符
    pub fn validateInputSafety(input: []const u8) SecurityLimitError!void {
        // 检查空字节注入
        for (input) |byte| {
            if (byte == 0) {
                return SecurityLimitError.InvalidInput;
            }
        }

        // 检查控制字符（除了常见的空白字符）
        for (input) |byte| {
            if (byte < 32 and byte != '\t' and byte != '\n' and byte != '\r') {
                return SecurityLimitError.InvalidInput;
            }
        }
    }
};

/// 速率限制器
pub const RateLimiter = struct {
    window_ms: u32,
    max_requests: usize,
    requests: std.HashMap([]const u8, RequestInfo, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    allocator: std.mem.Allocator,

    const RequestInfo = struct {
        count: usize,
        window_start: i64,
    };

    pub fn init(allocator: std.mem.Allocator) RateLimiter {
        return RateLimiter{
            .window_ms = SecurityLimits.RATE_LIMIT_WINDOW_MS,
            .max_requests = SecurityLimits.MAX_REQUESTS_PER_IP_PER_MINUTE,
            .requests = std.HashMap([]const u8, RequestInfo, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        var iterator = self.requests.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.requests.deinit();
    }

    /// 检查是否超过速率限制
    pub fn checkRateLimit(self: *RateLimiter, client_ip: []const u8) SecurityLimitError!void {
        const now = std.time.milliTimestamp();

        if (self.requests.get(client_ip)) |info| {
            // 检查是否在同一时间窗口内
            if (now - info.window_start < self.window_ms) {
                if (info.count >= self.max_requests) {
                    return SecurityLimitError.RateLimitExceeded;
                }
                // 更新计数
                var new_info = info;
                new_info.count += 1;
                try self.requests.put(client_ip, new_info);
            } else {
                // 新的时间窗口
                try self.requests.put(client_ip, RequestInfo{
                    .count = 1,
                    .window_start = now,
                });
            }
        } else {
            // 新的客户端
            const owned_ip = try self.allocator.dupe(u8, client_ip);
            try self.requests.put(owned_ip, RequestInfo{
                .count = 1,
                .window_start = now,
            });
        }
    }

    /// 清理过期的速率限制记录
    pub fn cleanup(self: *RateLimiter) void {
        const now = std.time.milliTimestamp();
        var to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer to_remove.deinit();

        var iterator = self.requests.iterator();
        while (iterator.next()) |entry| {
            if (now - entry.value_ptr.window_start >= self.window_ms * 2) {
                to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.requests.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
            }
        }
    }
};

// ============================================================================
// 测试用例
// ============================================================================

const testing = std.testing;

test "安全限制验证测试" {
    // 请求大小验证
    try SecurityValidator.validateRequestSize(1024);
    try testing.expectError(SecurityLimitError.RequestTooLarge, SecurityValidator.validateRequestSize(SecurityLimits.MAX_REQUEST_SIZE + 1));

    // 头部验证
    try SecurityValidator.validateHeaderSize("Content-Type", "application/json");
    try testing.expectError(SecurityLimitError.HeaderTooLarge, SecurityValidator.validateHeaderSize("A" ** 300, "value"));

    // URI验证
    try SecurityValidator.validateUriLength("/api/test");
    try testing.expectError(SecurityLimitError.UriTooLong, SecurityValidator.validateUriLength("/" ++ "A" ** 3000));

    // HTTP方法验证
    try SecurityValidator.validateMethod("GET");
    try SecurityValidator.validateMethod("POST");
    try testing.expectError(SecurityLimitError.InvalidInput, SecurityValidator.validateMethod("INVALID_METHOD"));

    // 输入安全验证
    try SecurityValidator.validateInputSafety("normal text");
    try testing.expectError(SecurityLimitError.InvalidInput, SecurityValidator.validateInputSafety("text\x00with\x00null"));
}

test "速率限制器测试" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var limiter = RateLimiter.init(allocator);
    defer limiter.deinit();

    // 设置较小的限制用于测试
    limiter.max_requests = 3;
    limiter.window_ms = 1000;

    const test_ip = "192.168.1.1";

    // 前3个请求应该成功
    try limiter.checkRateLimit(test_ip);
    try limiter.checkRateLimit(test_ip);
    try limiter.checkRateLimit(test_ip);

    // 第4个请求应该被限制
    try testing.expectError(SecurityLimitError.RateLimitExceeded, limiter.checkRateLimit(test_ip));
}
