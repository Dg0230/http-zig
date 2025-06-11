# 🛡️ 安全修复建议

> **基于**: 黑客视角安全评审结果
> **目标**: 修复发现的关键安全漏洞
> **优先级**: 按风险等级排序

## 🔴 关键漏洞修复 (立即执行)

### 1. 认证绕过漏洞修复

**当前问题**:
```zig
// src/middleware.zig:233 - 硬编码token
if (!std.mem.eql(u8, token, "valid-token")) {
```

**修复方案**:
```zig
// 新建 src/auth.zig
const std = @import("std");
const jwt = @import("jwt");  // 需要添加JWT库

pub const AuthConfig = struct {
    secret_key: []const u8,
    token_expiry: u32 = 3600, // 1小时
    issuer: []const u8 = "zig-http-server",
};

pub const AuthError = error{
    InvalidToken,
    ExpiredToken,
    MissingToken,
    InvalidSignature,
};

pub fn validateJWT(token: []const u8, config: AuthConfig) AuthError!void {
    // 解析JWT token
    const decoded = jwt.decode(token, config.secret_key) catch {
        return AuthError.InvalidToken;
    };

    // 验证过期时间
    const now = std.time.timestamp();
    if (decoded.exp < now) {
        return AuthError.ExpiredToken;
    }

    // 验证签发者
    if (!std.mem.eql(u8, decoded.iss, config.issuer)) {
        return AuthError.InvalidToken;
    }
}

// 修复后的中间件
pub fn authMiddleware(ctx: *Context, next: NextFn) !void {
    const auth_header = ctx.request.getHeader("Authorization");

    if (auth_header == null) {
        ctx.status(.unauthorized);
        try ctx.json("{\"error\":\"Missing authentication\"}");
        return;
    }

    if (!std.mem.startsWith(u8, auth_header.?, "Bearer ")) {
        ctx.status(.unauthorized);
        try ctx.json("{\"error\":\"Invalid authentication format\"}");
        return;
    }

    const token = auth_header.?[7..];

    // 使用安全的JWT验证
    validateJWT(token, auth_config) catch {
        ctx.status(.unauthorized);
        try ctx.json("{\"error\":\"Invalid or expired token\"}");
        return;
    };

    try next(ctx);
}
```

### 2. JSON注入漏洞修复

**当前问题**:
```zig
// src/libxev_http_engine.zig:472 - 不安全的字符串格式化
const response = try std.fmt.allocPrint(ctx.allocator,
    "{{\"echo\":\"{s}\",\"length\":{d}}}", .{ body, body.len });
```

**修复方案**:
```zig
// 新建 src/json_safe.zig
const std = @import("std");

pub fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var escaped = std.ArrayList(u8).init(allocator);
    defer escaped.deinit();

    for (input) |char| {
        switch (char) {
            '"' => try escaped.appendSlice("\\\""),
            '\\' => try escaped.appendSlice("\\\\"),
            '\n' => try escaped.appendSlice("\\n"),
            '\r' => try escaped.appendSlice("\\r"),
            '\t' => try escaped.appendSlice("\\t"),
            0...31 => {
                try escaped.writer().print("\\u{:0>4x}", .{char});
            },
            else => try escaped.append(char),
        }
    }

    return escaped.toOwnedSlice();
}

pub fn buildSafeJsonResponse(allocator: std.mem.Allocator, echo_data: []const u8) ![]u8 {
    const escaped_data = try escapeJsonString(allocator, echo_data);
    defer allocator.free(escaped_data);

    return try std.fmt.allocPrint(allocator,
        "{{\"echo\":\"{s}\",\"length\":{d},\"safe\":true}}",
        .{ escaped_data, echo_data.len });
}

// 修复后的echo处理函数
fn echoHandler(ctx: *Context) !void {
    const body = ctx.request.body orelse "";

    // 输入验证
    if (body.len > 10000) {  // 限制输入大小
        ctx.status(.bad_request);
        try ctx.json("{\"error\":\"Input too large\"}");
        return;
    }

    // 安全的JSON构建
    const response = try buildSafeJsonResponse(ctx.allocator, body);
    defer ctx.allocator.free(response);

    try ctx.json(response);
}
```

### 3. 缓冲区溢出修复

**当前问题**:
```zig
// src/libxev_http_engine.zig:340 - 没有边界检查
@memcpy(conn_ctx.write_buffer[0..response_data.len], response_data);
```

**修复方案**:
```zig
// 修复后的响应处理
fn processHttpRequest(conn_ctx: *ConnectionContext, loop: *xev.Loop, request_data: []const u8) !void {
    // ... 前面的代码保持不变 ...

    // 构建响应数据
    const response_data = try response.build();
    conn_ctx.response_data = response_data;

    // 安全的缓冲区处理
    if (response_data.len > conn_ctx.write_buffer.len) {
        // 响应太大，使用动态分配
        conn_ctx.bytes_to_write = response_data.len;
        // response_data将在写入完成后释放
    } else {
        // 安全的内存复制，添加边界检查
        const copy_len = @min(response_data.len, conn_ctx.write_buffer.len);
        @memcpy(conn_ctx.write_buffer[0..copy_len], response_data[0..copy_len]);
        conn_ctx.bytes_to_write = copy_len;

        // 释放原始数据
        conn_ctx.allocator.free(response_data);
        conn_ctx.response_data = null;
    }

    startWrite(conn_ctx, loop);
}

// 添加缓冲区大小验证
const MAX_RESPONSE_SIZE = 1024 * 1024; // 1MB

fn validateResponseSize(size: usize) !void {
    if (size > MAX_RESPONSE_SIZE) {
        return error.ResponseTooLarge;
    }
}
```

---

## 🟡 重要漏洞修复 (短期内执行)

### 4. 请求大小限制

```zig
// 修改 src/request.zig
const SecurityLimits = @import("security_limits.zig").SecurityLimits;

pub fn parseFromBuffer(allocator: Allocator, buffer: []const u8) !Self {
    // 添加请求大小检查
    if (buffer.len > SecurityLimits.MAX_REQUEST_SIZE) {
        return error.RequestTooLarge;
    }

    // 原有解析逻辑...
}
```

### 5. 竞态条件修复

```zig
// 修改 src/buffer.zig - 添加线程安全
const std = @import("std");

pub const BufferPool = struct {
    allocator: Allocator,
    buffers: std.ArrayList(Buffer),
    available: std.ArrayList(usize),
    mutex: std.Thread.Mutex,  // 添加互斥锁
    buffer_size: usize,
    max_buffers: usize,
    total_acquired: std.atomic.Value(usize),  // 使用原子变量
    total_released: std.atomic.Value(usize),

    pub fn init(allocator: Allocator, buffer_size: usize, max_buffers: usize) !BufferPool {
        return BufferPool{
            .allocator = allocator,
            .buffers = std.ArrayList(Buffer).init(allocator),
            .available = std.ArrayList(usize).init(allocator),
            .mutex = std.Thread.Mutex{},
            .buffer_size = buffer_size,
            .max_buffers = max_buffers,
            .total_acquired = std.atomic.Value(usize).init(0),
            .total_released = std.atomic.Value(usize).init(0),
        };
    }

    pub fn acquire(self: *BufferPool) !*Buffer {
        self.mutex.lock();
        defer self.mutex.unlock();

        // 原子操作更新统计
        _ = self.total_acquired.fetchAdd(1, .monotonic);

        // 原有逻辑...
    }

    pub fn release(self: *BufferPool, buffer: *Buffer) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // 原子操作更新统计
        _ = self.total_released.fetchAdd(1, .monotonic);

        // 原有逻辑...
    }
};
```

### 6. CORS安全配置

```zig
// 修改 src/libxev_http_engine.zig
fn processHttpRequest(conn_ctx: *ConnectionContext, loop: *xev.Loop, request_data: []const u8) !void {
    // ... 前面代码 ...

    // 安全的CORS配置
    if (conn_ctx.server_ctx.config.enable_cors) {
        // 不要使用通配符 "*"
        const allowed_origins = [_][]const u8{
            "https://yourdomain.com",
            "https://app.yourdomain.com",
            "http://localhost:3000",  // 仅开发环境
        };

        const origin = request.getHeader("Origin");
        if (origin) |origin_value| {
            for (allowed_origins) |allowed| {
                if (std.mem.eql(u8, origin_value, allowed)) {
                    try response.setHeader("Access-Control-Allow-Origin", origin_value);
                    break;
                }
            }
        }

        try response.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE");
        try response.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
        try response.setHeader("Access-Control-Allow-Credentials", "true");
        try response.setHeader("Access-Control-Max-Age", "86400");
    }
}
```

### 7. 输入验证增强

```zig
// 新建 src/input_validator.zig
const std = @import("std");
const SecurityLimits = @import("security_limits.zig").SecurityLimits;

pub const ValidationError = error{
    InvalidInput,
    InputTooLarge,
    MaliciousContent,
    InvalidCharacters,
};

pub fn validateHttpMethod(method: []const u8) ValidationError!void {
    if (method.len > SecurityLimits.MAX_METHOD_LENGTH) {
        return ValidationError.InputTooLarge;
    }

    const valid_methods = [_][]const u8{
        "GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH"
    };

    for (valid_methods) |valid| {
        if (std.mem.eql(u8, method, valid)) return;
    }

    return ValidationError.InvalidInput;
}

pub fn validateUri(uri: []const u8) ValidationError!void {
    if (uri.len > SecurityLimits.MAX_URI_LENGTH) {
        return ValidationError.InputTooLarge;
    }

    // 检查路径遍历攻击
    if (std.mem.indexOf(u8, uri, "..") != null) {
        return ValidationError.MaliciousContent;
    }

    // 检查空字节注入
    for (uri) |char| {
        if (char == 0) {
            return ValidationError.MaliciousContent;
        }
    }
}

pub fn validateHeaderValue(value: []const u8) ValidationError!void {
    if (value.len > SecurityLimits.MAX_HEADER_VALUE_SIZE) {
        return ValidationError.InputTooLarge;
    }

    // 检查CRLF注入
    if (std.mem.indexOf(u8, value, "\r") != null or
        std.mem.indexOf(u8, value, "\n") != null) {
        return ValidationError.MaliciousContent;
    }
}
```

---

## 🟢 安全增强建议 (中期执行)

### 8. 安全头部添加

```zig
// 新建 src/security_headers.zig
pub fn addSecurityHeaders(response: *HttpResponse) !void {
    // 防止XSS
    try response.setHeader("X-Content-Type-Options", "nosniff");
    try response.setHeader("X-Frame-Options", "DENY");
    try response.setHeader("X-XSS-Protection", "1; mode=block");

    // CSP策略
    try response.setHeader("Content-Security-Policy",
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'");

    // HSTS (仅HTTPS)
    try response.setHeader("Strict-Transport-Security",
        "max-age=31536000; includeSubDomains");

    // 隐私保护
    try response.setHeader("Referrer-Policy", "strict-origin-when-cross-origin");

    // 权限策略
    try response.setHeader("Permissions-Policy",
        "geolocation=(), microphone=(), camera=()");
}
```

### 9. 速率限制实现

```zig
// 集成到主处理流程
fn processHttpRequest(conn_ctx: *ConnectionContext, loop: *xev.Loop, request_data: []const u8) !void {
    // 获取客户端IP
    const client_ip = getClientIP(conn_ctx);

    // 检查速率限制
    conn_ctx.server_ctx.rate_limiter.checkRateLimit(client_ip) catch {
        sendErrorResponse(conn_ctx, loop, .too_many_requests, "Rate limit exceeded");
        return;
    };

    // 原有处理逻辑...
}
```

### 10. 日志安全增强

```zig
// 修改日志记录，避免敏感信息泄露
fn logSecureRequest(request: *HttpRequest, client_ip: []const u8) void {
    // 不记录敏感头部
    const safe_headers = std.StringHashMap([]const u8).init(allocator);
    defer safe_headers.deinit();

    var header_iter = request.headers.iterator();
    while (header_iter.next()) |entry| {
        const header_name = entry.key_ptr.*;

        // 过滤敏感头部
        if (std.mem.eql(u8, header_name, "Authorization") or
            std.mem.eql(u8, header_name, "Cookie") or
            std.mem.eql(u8, header_name, "X-API-Key")) {
            try safe_headers.put(header_name, "[REDACTED]");
        } else {
            try safe_headers.put(header_name, entry.value_ptr.*);
        }
    }

    std.log.info("Request: {s} {s} from {s}", .{
        request.method, request.path, client_ip
    });
}
```

---

## 📋 修复优先级和时间表

### 🔴 P0 - 立即修复 (1-3天)
1. **认证绕过** - 实施JWT认证
2. **JSON注入** - 安全的JSON编码
3. **缓冲区溢出** - 边界检查

### 🟡 P1 - 短期修复 (1-2周)
4. **请求大小限制** - 输入验证
5. **竞态条件** - 线程安全
6. **CORS配置** - 安全策略

### 🟢 P2 - 中期改进 (2-4周)
7. **安全头部** - 防护策略
8. **速率限制** - DoS防护
9. **日志安全** - 信息保护

---

## 🧪 修复验证测试

### 认证修复验证
```bash
# 测试硬编码token是否仍然有效
curl -H "Authorization: Bearer valid-token" http://localhost:8080/admin
# 应该返回401 Unauthorized

# 测试有效JWT token
curl -H "Authorization: Bearer <valid-jwt>" http://localhost:8080/admin
# 应该返回200 OK
```

### JSON注入修复验证
```bash
# 测试JSON注入
curl -X POST -d '","admin":true,"' http://localhost:8080/api/echo
# 响应应该正确转义，不包含注入内容
```

### 缓冲区溢出修复验证
```bash
# 测试大载荷
python -c "print('A' * 1000000)" | curl -X POST --data-binary @- http://localhost:8080/api/echo
# 应该正常处理或返回适当错误，不应崩溃
```

---

## 🎯 修复完成标准

### ✅ 修复验收标准
- [ ] 所有P0漏洞修复并通过测试
- [ ] 安全扫描工具无高危漏洞报告
- [ ] 渗透测试无法利用已修复漏洞
- [ ] 性能影响 < 15%
- [ ] 所有修复都有对应的测试用例

### 📊 安全评分目标
- 认证安全: 60/100 → **95/100**
- 输入验证: 85/100 → **95/100**
- 输出编码: 70/100 → **95/100**
- 错误处理: 92/100 → **98/100**
- 总体安全: 91.7/100 → **96/100**

---

*这些修复建议基于黑客视角安全评审结果，旨在消除关键安全风险*
