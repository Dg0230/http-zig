# 安全增强系统设计方案

## 🎯 目标
构建企业级的安全防护体系，包括认证授权、输入验证、攻击防护、安全审计等功能。

## 🔒 安全威胁模型

### 1. 常见Web攻击
- **SQL注入** - 恶意SQL代码注入
- **XSS攻击** - 跨站脚本攻击
- **CSRF攻击** - 跨站请求伪造
- **XXE攻击** - XML外部实体注入
- **路径遍历** - 目录穿越攻击
- **DDoS攻击** - 分布式拒绝服务

### 2. 认证授权威胁
- **弱密码** - 容易被破解的密码
- **会话劫持** - Session/Token被盗用
- **权限提升** - 非法获取更高权限
- **暴力破解** - 密码/Token暴力破解

## 🚀 安全系统设计

### 1. 认证系统
```zig
pub const AuthenticationManager = struct {
    jwt_secret: []const u8,
    token_expiry: u64, // 秒
    refresh_expiry: u64, // 秒
    password_hasher: *PasswordHasher,
    rate_limiter: *RateLimiter,
    allocator: Allocator,

    pub fn init(allocator: Allocator, jwt_secret: []const u8) !*AuthenticationManager {
        return &AuthenticationManager{
            .jwt_secret = try allocator.dupe(u8, jwt_secret),
            .token_expiry = 3600, // 1小时
            .refresh_expiry = 86400 * 7, // 7天
            .password_hasher = try PasswordHasher.init(allocator),
            .rate_limiter = try RateLimiter.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn authenticate(self: *AuthenticationManager, username: []const u8, password: []const u8) !AuthResult {
        // 检查登录频率限制
        if (!try self.rate_limiter.checkLogin(username)) {
            return AuthResult{ .error = .rate_limited };
        }

        // 查找用户
        const user = try self.findUser(username) orelse {
            // 记录失败尝试
            try self.rate_limiter.recordFailedLogin(username);
            return AuthResult{ .error = .invalid_credentials };
        };

        // 验证密码
        if (!try self.password_hasher.verify(password, user.password_hash)) {
            try self.rate_limiter.recordFailedLogin(username);
            return AuthResult{ .error = .invalid_credentials };
        }

        // 检查账户状态
        if (!user.is_active) {
            return AuthResult{ .error = .account_disabled };
        }

        // 生成JWT令牌
        const access_token = try self.generateAccessToken(user);
        const refresh_token = try self.generateRefreshToken(user);

        // 记录成功登录
        try self.rate_limiter.recordSuccessfulLogin(username);

        return AuthResult{
            .success = .{
                .user = user,
                .access_token = access_token,
                .refresh_token = refresh_token,
                .expires_in = self.token_expiry,
            }
        };
    }

    pub fn validateToken(self: *AuthenticationManager, token: []const u8) !TokenValidationResult {
        const claims = try self.parseJWT(token);

        // 检查过期时间
        const now = std.time.timestamp();
        if (claims.exp < now) {
            return TokenValidationResult{ .error = .expired };
        }

        // 检查签名
        if (!try self.verifyJWTSignature(token)) {
            return TokenValidationResult{ .error = .invalid_signature };
        }

        // 检查用户状态
        const user = try self.findUserById(claims.sub) orelse {
            return TokenValidationResult{ .error = .user_not_found };
        };

        if (!user.is_active) {
            return TokenValidationResult{ .error = .user_disabled };
        }

        return TokenValidationResult{
            .success = .{
                .user = user,
                .claims = claims,
            }
        };
    }

    const AuthResult = union(enum) {
        success: struct {
            user: User,
            access_token: []const u8,
            refresh_token: []const u8,
            expires_in: u64,
        },
        error: AuthError,
    };

    const AuthError = enum {
        invalid_credentials,
        account_disabled,
        rate_limited,
        internal_error,
    };

    const TokenValidationResult = union(enum) {
        success: struct {
            user: User,
            claims: JWTClaims,
        },
        error: TokenError,
    };

    const TokenError = enum {
        expired,
        invalid_signature,
        user_not_found,
        user_disabled,
        malformed,
    };
};

pub const PasswordHasher = struct {
    allocator: Allocator,

    pub fn hash(self: *PasswordHasher, password: []const u8) ![]const u8 {
        // 使用Argon2id进行密码哈希
        var salt: [32]u8 = undefined;
        std.crypto.random.bytes(&salt);

        var hash: [32]u8 = undefined;
        try std.crypto.pwhash.argon2.kdf(
            &hash,
            password,
            &salt,
            .{ .t = 3, .m = 65536, .p = 1 }, // 时间成本=3, 内存成本=64MB, 并行度=1
            .argon2id
        );

        // 组合salt和hash
        var result = try self.allocator.alloc(u8, 64);
        std.mem.copy(u8, result[0..32], &salt);
        std.mem.copy(u8, result[32..64], &hash);

        return result;
    }

    pub fn verify(self: *PasswordHasher, password: []const u8, stored_hash: []const u8) !bool {
        if (stored_hash.len != 64) return false;

        const salt = stored_hash[0..32];
        const expected_hash = stored_hash[32..64];

        var computed_hash: [32]u8 = undefined;
        try std.crypto.pwhash.argon2.kdf(
            &computed_hash,
            password,
            salt,
            .{ .t = 3, .m = 65536, .p = 1 },
            .argon2id
        );

        return std.crypto.utils.timingSafeEql([32]u8, computed_hash, expected_hash.*);
    }
};
```

### 2. 授权系统 (RBAC)
```zig
pub const AuthorizationManager = struct {
    roles: std.StringHashMap(Role),
    permissions: std.StringHashMap(Permission),
    allocator: Allocator,

    const Role = struct {
        name: []const u8,
        permissions: std.ArrayList([]const u8),
        parent_roles: std.ArrayList([]const u8),
    };

    const Permission = struct {
        name: []const u8,
        resource: []const u8,
        action: []const u8,
        conditions: ?[]const Condition,
    };

    const Condition = struct {
        field: []const u8,
        operator: Operator,
        value: []const u8,

        const Operator = enum {
            equals,
            not_equals,
            contains,
            starts_with,
            ends_with,
            greater_than,
            less_than,
        };
    };

    pub fn checkPermission(
        self: *AuthorizationManager,
        user: User,
        resource: []const u8,
        action: []const u8,
        context: ?AuthContext
    ) !bool {
        // 获取用户所有角色（包括继承的角色）
        const user_roles = try self.getUserRoles(user);
        defer user_roles.deinit();

        // 检查每个角色的权限
        for (user_roles.items) |role_name| {
            const role = self.roles.get(role_name) orelse continue;

            for (role.permissions.items) |perm_name| {
                const permission = self.permissions.get(perm_name) orelse continue;

                // 检查资源和动作匹配
                if (self.matchesResource(permission.resource, resource) and
                    self.matchesAction(permission.action, action)) {

                    // 检查条件
                    if (permission.conditions) |conditions| {
                        if (try self.evaluateConditions(conditions, context)) {
                            return true;
                        }
                    } else {
                        return true;
                    }
                }
            }
        }

        return false;
    }

    fn evaluateConditions(self: *AuthorizationManager, conditions: []const Condition, context: ?AuthContext) !bool {
        if (context == null) return false;

        for (conditions) |condition| {
            if (!try self.evaluateCondition(condition, context.?)) {
                return false;
            }
        }

        return true;
    }

    const AuthContext = struct {
        user_id: []const u8,
        resource_owner: ?[]const u8,
        ip_address: []const u8,
        user_agent: []const u8,
        time: i64,
        custom_fields: std.StringHashMap([]const u8),
    };
};
```

### 3. 输入验证和清理
```zig
pub const InputSanitizer = struct {
    allocator: Allocator,

    pub fn sanitizeHTML(self: *InputSanitizer, input: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();

        var i: usize = 0;
        while (i < input.len) {
            switch (input[i]) {
                '<' => try result.appendSlice("&lt;"),
                '>' => try result.appendSlice("&gt;"),
                '&' => try result.appendSlice("&amp;"),
                '"' => try result.appendSlice("&quot;"),
                '\'' => try result.appendSlice("&#x27;"),
                '/' => try result.appendSlice("&#x2F;"),
                else => try result.append(input[i]),
            }
            i += 1;
        }

        return result.toOwnedSlice();
    }

    pub fn validateSQL(self: *InputSanitizer, input: []const u8) !bool {
        const dangerous_keywords = [_][]const u8{
            "DROP", "DELETE", "INSERT", "UPDATE", "CREATE", "ALTER",
            "EXEC", "EXECUTE", "UNION", "SELECT", "--", "/*", "*/",
            "xp_", "sp_", "SCRIPT", "JAVASCRIPT", "VBSCRIPT"
        };

        const upper_input = try std.ascii.allocUpperString(self.allocator, input);
        defer self.allocator.free(upper_input);

        for (dangerous_keywords) |keyword| {
            if (std.mem.indexOf(u8, upper_input, keyword) != null) {
                return false;
            }
        }

        return true;
    }

    pub fn validatePath(self: *InputSanitizer, path: []const u8) !bool {
        // 检查路径遍历攻击
        if (std.mem.indexOf(u8, path, "..") != null) return false;
        if (std.mem.indexOf(u8, path, "~") != null) return false;
        if (std.mem.indexOf(u8, path, "\\") != null) return false;

        // 检查绝对路径
        if (path.len > 0 and path[0] == '/') return false;

        // 检查危险字符
        const dangerous_chars = [_]u8{ '<', '>', '|', '&', ';', '`', '$' };
        for (dangerous_chars) |char| {
            if (std.mem.indexOfScalar(u8, path, char) != null) return false;
        }

        return true;
    }
};
```

### 4. 攻击防护中间件
```zig
pub fn securityMiddleware(ctx: *Context, next: NextFn) !void {
    // CSRF保护
    if (try requiresCSRFProtection(ctx)) {
        if (!try validateCSRFToken(ctx)) {
            ctx.status(.forbidden);
            try ctx.json("{\"error\":\"CSRF token validation failed\"}");
            return;
        }
    }

    // XSS保护头
    ctx.response.setHeader("X-Content-Type-Options", "nosniff");
    ctx.response.setHeader("X-Frame-Options", "DENY");
    ctx.response.setHeader("X-XSS-Protection", "1; mode=block");
    ctx.response.setHeader("Referrer-Policy", "strict-origin-when-cross-origin");

    // HSTS头（仅HTTPS）
    if (ctx.request.isHTTPS()) {
        ctx.response.setHeader("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
    }

    // 内容安全策略
    ctx.response.setHeader("Content-Security-Policy",
        "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'");

    // 输入验证
    if (ctx.request.body) |body| {
        if (!try validateRequestBody(body)) {
            ctx.status(.bad_request);
            try ctx.json("{\"error\":\"Invalid request body\"}");
            return;
        }
    }

    // 速率限制
    if (!try checkRateLimit(ctx)) {
        ctx.status(.too_many_requests);
        ctx.response.setHeader("Retry-After", "60");
        try ctx.json("{\"error\":\"Rate limit exceeded\"}");
        return;
    }

    try next(ctx);
}

pub const RateLimiter = struct {
    windows: std.AutoHashMap([]const u8, *TimeWindow),
    allocator: Allocator,
    mutex: std.Thread.Mutex,

    const TimeWindow = struct {
        requests: std.ArrayList(i64),
        window_size: u64, // 秒
        max_requests: u32,

        pub fn addRequest(self: *TimeWindow, timestamp: i64) bool {
            const window_start = timestamp - @as(i64, @intCast(self.window_size));

            // 清理过期请求
            var i: usize = 0;
            while (i < self.requests.items.len) {
                if (self.requests.items[i] < window_start) {
                    _ = self.requests.orderedRemove(i);
                } else {
                    i += 1;
                }
            }

            // 检查是否超过限制
            if (self.requests.items.len >= self.max_requests) {
                return false;
            }

            // 添加新请求
            self.requests.append(timestamp) catch return false;
            return true;
        }
    };

    pub fn checkLimit(self: *RateLimiter, key: []const u8, max_requests: u32, window_seconds: u64) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();

        const result = try self.windows.getOrPut(key);
        if (!result.found_existing) {
            result.value_ptr.* = try self.allocator.create(TimeWindow);
            result.value_ptr.*.* = TimeWindow{
                .requests = std.ArrayList(i64).init(self.allocator),
                .window_size = window_seconds,
                .max_requests = max_requests,
            };
        }

        return result.value_ptr.*.addRequest(now);
    }
};
```

### 5. 安全审计系统
```zig
pub const SecurityAuditor = struct {
    logger: *Logger,
    alert_manager: *AlertManager,
    allocator: Allocator,

    pub fn logSecurityEvent(self: *SecurityAuditor, event: SecurityEvent) !void {
        // 记录安全事件
        try self.logger.infoWithFields("Security event", .{
            .event_type = @tagName(event.event_type),
            .user_id = event.user_id orelse "anonymous",
            .ip_address = event.ip_address,
            .user_agent = event.user_agent orelse "unknown",
            .resource = event.resource orelse "unknown",
            .action = event.action orelse "unknown",
            .result = @tagName(event.result),
            .details = event.details orelse "",
        });

        // 检查是否需要告警
        if (try self.shouldAlert(event)) {
            try self.alert_manager.sendAlert(event);
        }
    }

    const SecurityEvent = struct {
        event_type: EventType,
        user_id: ?[]const u8,
        ip_address: []const u8,
        user_agent: ?[]const u8,
        resource: ?[]const u8,
        action: ?[]const u8,
        result: EventResult,
        details: ?[]const u8,
        timestamp: i64,

        const EventType = enum {
            authentication_attempt,
            authorization_check,
            suspicious_activity,
            data_access,
            configuration_change,
            security_violation,
        };

        const EventResult = enum {
            success,
            failure,
            blocked,
            warning,
        };
    };

    fn shouldAlert(self: *SecurityAuditor, event: SecurityEvent) !bool {
        return switch (event.event_type) {
            .security_violation => true,
            .authentication_attempt => event.result == .failure,
            .suspicious_activity => true,
            .configuration_change => true,
            else => false,
        };
    }
};
```

## 🔧 安全配置

### 1. TLS配置
```zig
pub const TLSConfig = struct {
    cert_file: []const u8,
    key_file: []const u8,
    min_version: TLSVersion,
    cipher_suites: []const CipherSuite,
    require_client_cert: bool,

    const TLSVersion = enum {
        tls_1_2,
        tls_1_3,
    };

    const CipherSuite = enum {
        tls_aes_256_gcm_sha384,
        tls_chacha20_poly1305_sha256,
        tls_aes_128_gcm_sha256,
    };
};
```

### 2. 安全头配置
```zig
pub const SecurityHeaders = struct {
    hsts_max_age: u64 = 31536000, // 1年
    csp_policy: []const u8 = "default-src 'self'",
    frame_options: FrameOptions = .deny,
    content_type_options: bool = true,
    xss_protection: bool = true,

    const FrameOptions = enum {
        deny,
        sameorigin,
        allow_from,
    };
};
```

## 📊 安全监控指标

### 认证指标
- `auth_attempts_total` - 认证尝试总数
- `auth_failures_total` - 认证失败总数
- `auth_rate_limited_total` - 被限流的认证尝试

### 授权指标
- `authz_checks_total` - 授权检查总数
- `authz_denials_total` - 授权拒绝总数
- `privilege_escalation_attempts` - 权限提升尝试

### 攻击防护指标
- `csrf_attacks_blocked` - 阻止的CSRF攻击
- `xss_attempts_blocked` - 阻止的XSS尝试
- `sql_injection_attempts` - SQL注入尝试
- `path_traversal_attempts` - 路径遍历尝试

## 🔧 实现计划

### 阶段1：认证授权 (1周)
1. JWT认证系统
2. RBAC授权系统
3. 密码安全处理

### 阶段2：攻击防护 (1周)
1. 输入验证和清理
2. 安全中间件
3. 速率限制

### 阶段3：审计监控 (1周)
1. 安全事件记录
2. 异常检测
3. 告警系统

## 📈 预期收益

### 安全性提升
- 全面的攻击防护
- 细粒度的权限控制
- 实时的安全监控

### 合规性
- 满足安全标准要求
- 完整的审计日志
- 数据保护措施

### 运维效率
- 自动化安全检测
- 实时安全告警
- 详细的安全报告
