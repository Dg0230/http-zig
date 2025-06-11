// JWT认证模块 - 替换硬编码认证
// 实现安全的基于JWT的认证系统

const std = @import("std");
const crypto = std.crypto;
const base64 = std.base64;
const json = std.json;

/// JWT认证配置
pub const AuthConfig = struct {
    secret_key: []const u8,
    token_expiry: i64 = 3600, // 1小时
    issuer: []const u8 = "zig-http-server",
    algorithm: []const u8 = "HS256",
};

/// 认证错误类型
pub const AuthError = error{
    InvalidToken,
    ExpiredToken,
    MissingToken,
    InvalidSignature,
    InvalidFormat,
    InvalidClaims,
    OutOfMemory,
};

/// JWT Claims结构
pub const JWTClaims = struct {
    sub: []const u8, // subject (用户ID)
    iss: []const u8, // issuer
    exp: i64, // expiration time
    iat: i64, // issued at
    role: []const u8, // 用户角色

    pub fn init(allocator: std.mem.Allocator, user_id: []const u8, role: []const u8, config: AuthConfig) !JWTClaims {
        const now = std.time.timestamp();
        return JWTClaims{
            .sub = try allocator.dupe(u8, user_id),
            .iss = try allocator.dupe(u8, config.issuer),
            .exp = now + config.token_expiry,
            .iat = now,
            .role = try allocator.dupe(u8, role),
        };
    }

    pub fn deinit(self: *JWTClaims, allocator: std.mem.Allocator) void {
        allocator.free(self.sub);
        allocator.free(self.iss);
        allocator.free(self.role);
    }
};

/// JWT Header结构
const JWTHeader = struct {
    alg: []const u8,
    typ: []const u8 = "JWT",
};

/// JWT认证器
pub const JWTAuth = struct {
    allocator: std.mem.Allocator,
    config: AuthConfig,

    pub fn init(allocator: std.mem.Allocator, config: AuthConfig) JWTAuth {
        return JWTAuth{
            .allocator = allocator,
            .config = config,
        };
    }

    /// 生成JWT token
    pub fn generateToken(self: *JWTAuth, user_id: []const u8, role: []const u8) ![]u8 {
        // 创建header
        const header = JWTHeader{
            .alg = self.config.algorithm,
            .typ = "JWT",
        };

        // 创建claims
        var claims = try JWTClaims.init(self.allocator, user_id, role, self.config);
        defer claims.deinit(self.allocator);

        // 序列化header和claims
        const header_json = try json.stringifyAlloc(self.allocator, header, .{});
        defer self.allocator.free(header_json);

        const claims_json = try json.stringifyAlloc(self.allocator, claims, .{});
        defer self.allocator.free(claims_json);

        // Base64URL编码
        const header_b64 = try self.base64UrlEncode(header_json);
        defer self.allocator.free(header_b64);

        const claims_b64 = try self.base64UrlEncode(claims_json);
        defer self.allocator.free(claims_b64);

        // 创建签名数据
        const sign_data = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ header_b64, claims_b64 });
        defer self.allocator.free(sign_data);

        // 生成签名
        const signature = try self.generateSignature(sign_data);
        defer self.allocator.free(signature);

        const signature_b64 = try self.base64UrlEncode(signature);
        defer self.allocator.free(signature_b64);

        // 组合最终token
        return try std.fmt.allocPrint(self.allocator, "{s}.{s}.{s}", .{ header_b64, claims_b64, signature_b64 });
    }

    /// 验证JWT token
    pub fn validateToken(self: *JWTAuth, token: []const u8) !JWTClaims {
        // 分割token
        var parts = std.mem.splitScalar(u8, token, '.');
        const header_b64 = parts.next() orelse return AuthError.InvalidFormat;
        const claims_b64 = parts.next() orelse return AuthError.InvalidFormat;
        const signature_b64 = parts.next() orelse return AuthError.InvalidFormat;

        if (parts.next() != null) return AuthError.InvalidFormat; // 确保只有3部分

        // 验证签名
        const sign_data = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ header_b64, claims_b64 });
        defer self.allocator.free(sign_data);

        const expected_signature = try self.generateSignature(sign_data);
        defer self.allocator.free(expected_signature);

        const expected_signature_b64 = try self.base64UrlEncode(expected_signature);
        defer self.allocator.free(expected_signature_b64);

        // 时间常数比较防止时间攻击
        if (!constantTimeCompare(signature_b64, expected_signature_b64)) {
            return AuthError.InvalidSignature;
        }

        // 解码claims
        const claims_json = try self.base64UrlDecode(claims_b64);
        defer self.allocator.free(claims_json);

        // 解析claims
        var parsed = json.parseFromSlice(json.Value, self.allocator, claims_json, .{}) catch {
            return AuthError.InvalidClaims;
        };
        defer parsed.deinit();

        const claims_obj = parsed.value.object;

        // 提取claims字段
        const sub = claims_obj.get("sub").?.string;
        const iss = claims_obj.get("iss").?.string;

        // 安全地提取数字字段
        const exp = switch (claims_obj.get("exp").?) {
            .integer => |i| i,
            .float => |f| @as(i64, @intFromFloat(f)),
            else => return AuthError.InvalidClaims,
        };

        const iat = switch (claims_obj.get("iat").?) {
            .integer => |i| i,
            .float => |f| @as(i64, @intFromFloat(f)),
            else => return AuthError.InvalidClaims,
        };

        const role = claims_obj.get("role").?.string;

        // 验证过期时间
        const now = std.time.timestamp();
        if (exp < now) {
            return AuthError.ExpiredToken;
        }

        // 验证签发者
        if (!std.mem.eql(u8, iss, self.config.issuer)) {
            return AuthError.InvalidClaims;
        }

        // 返回验证后的claims
        return JWTClaims{
            .sub = try self.allocator.dupe(u8, sub),
            .iss = try self.allocator.dupe(u8, iss),
            .exp = exp,
            .iat = iat,
            .role = try self.allocator.dupe(u8, role),
        };
    }

    /// 生成HMAC-SHA256签名
    fn generateSignature(self: *JWTAuth, data: []const u8) ![]u8 {
        var hmac = crypto.auth.hmac.sha2.HmacSha256.init(self.config.secret_key);
        hmac.update(data);

        var signature: [32]u8 = undefined;
        hmac.final(&signature);

        return try self.allocator.dupe(u8, &signature);
    }

    /// Base64URL编码
    fn base64UrlEncode(self: *JWTAuth, data: []const u8) ![]u8 {
        const encoder = base64.url_safe_no_pad;
        const encoded_len = encoder.Encoder.calcSize(data.len);
        const encoded = try self.allocator.alloc(u8, encoded_len);
        _ = encoder.Encoder.encode(encoded, data);
        return encoded;
    }

    /// Base64URL解码
    fn base64UrlDecode(self: *JWTAuth, data: []const u8) ![]u8 {
        const decoder = base64.url_safe_no_pad;
        const decoded_len = try decoder.Decoder.calcSizeForSlice(data);
        const decoded = try self.allocator.alloc(u8, decoded_len);
        try decoder.Decoder.decode(decoded, data);
        return decoded;
    }
};

/// 时间常数比较函数，防止时间攻击
fn constantTimeCompare(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;

    var result: u8 = 0;
    for (a, b) |x, y| {
        result |= x ^ y;
    }
    return result == 0;
}

/// 用户认证数据库（简化版本，生产环境应使用真实数据库）
pub const UserDB = struct {
    users: std.StringHashMap(User),
    allocator: std.mem.Allocator,

    const User = struct {
        id: []const u8,
        username: []const u8,
        password_hash: []const u8,
        role: []const u8,
        active: bool,
    };

    pub fn init(allocator: std.mem.Allocator) UserDB {
        return UserDB{
            .users = std.StringHashMap(User).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UserDB) void {
        var iterator = self.users.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.id);
            self.allocator.free(entry.value_ptr.username);
            self.allocator.free(entry.value_ptr.password_hash);
            self.allocator.free(entry.value_ptr.role);
        }
        self.users.deinit();
    }

    /// 添加用户
    pub fn addUser(self: *UserDB, username: []const u8, password: []const u8, role: []const u8) !void {
        const user_id = try std.fmt.allocPrint(self.allocator, "user_{d}", .{std.crypto.random.int(u32)});
        const password_hash = try self.hashPassword(password);

        const user = User{
            .id = user_id,
            .username = try self.allocator.dupe(u8, username),
            .password_hash = password_hash,
            .role = try self.allocator.dupe(u8, role),
            .active = true,
        };

        const key = try self.allocator.dupe(u8, username);
        try self.users.put(key, user);
    }

    /// 验证用户凭据
    pub fn authenticateUser(self: *UserDB, username: []const u8, password: []const u8) ?User {
        const user = self.users.get(username) orelse return null;

        if (!user.active) return null;

        const password_hash = self.hashPassword(password) catch return null;
        defer self.allocator.free(password_hash);

        if (constantTimeCompare(user.password_hash, password_hash)) {
            return user;
        }

        return null;
    }

    /// 简单的密码哈希（生产环境应使用bcrypt或argon2）
    fn hashPassword(self: *UserDB, password: []const u8) ![]u8 {
        var hasher = crypto.hash.sha2.Sha256.init(.{});
        hasher.update("salt_"); // 简化的盐值
        hasher.update(password);

        var hash: [32]u8 = undefined;
        hasher.final(&hash);

        return try std.fmt.allocPrint(self.allocator, "{}", .{std.fmt.fmtSliceHexLower(&hash)});
    }

    /// 初始化默认用户
    pub fn initDefaultUsers(self: *UserDB) !void {
        try self.addUser("admin", "admin123", "admin");
        try self.addUser("user", "user123", "user");
        try self.addUser("guest", "guest123", "guest");
    }
};

// ============================================================================
// 测试用例
// ============================================================================

const testing = std.testing;

test "JWT token生成和验证" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = AuthConfig{
        .secret_key = "test-secret-key-very-secure",
        .token_expiry = 3600,
        .issuer = "test-server",
    };

    var auth = JWTAuth.init(allocator, config);

    // 生成token
    const token = try auth.generateToken("user123", "admin");
    defer allocator.free(token);

    // 验证token
    var claims = try auth.validateToken(token);
    defer claims.deinit(allocator);

    try testing.expectEqualStrings("user123", claims.sub);
    try testing.expectEqualStrings("admin", claims.role);
    try testing.expectEqualStrings("test-server", claims.iss);
}

test "JWT token过期验证" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = AuthConfig{
        .secret_key = "test-secret-key",
        .token_expiry = -1, // 已过期
        .issuer = "test-server",
    };

    var auth = JWTAuth.init(allocator, config);

    const token = try auth.generateToken("user123", "admin");
    defer allocator.free(token);

    // 验证过期token应该失败
    try testing.expectError(AuthError.ExpiredToken, auth.validateToken(token));
}

test "用户数据库认证" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var user_db = UserDB.init(allocator);
    defer user_db.deinit();

    try user_db.addUser("testuser", "password123", "user");

    // 正确凭据
    const user = user_db.authenticateUser("testuser", "password123");
    try testing.expect(user != null);
    try testing.expectEqualStrings("user", user.?.role);

    // 错误凭据
    const invalid_user = user_db.authenticateUser("testuser", "wrongpassword");
    try testing.expect(invalid_user == null);
}

test "时间常数比较" {
    try testing.expect(constantTimeCompare("hello", "hello"));
    try testing.expect(!constantTimeCompare("hello", "world"));
    try testing.expect(!constantTimeCompare("hello", "hello123"));
}
