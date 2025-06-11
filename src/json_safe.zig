// 安全JSON处理模块 - 防止JSON注入攻击
// 提供安全的JSON编码和解码功能

const std = @import("std");
const testing = std.testing;

/// JSON安全处理错误
pub const JsonSafeError = error{
    InvalidInput,
    OutputTooLarge,
    OutOfMemory,
};

/// 安全的JSON字符串转义
/// 防止JSON注入攻击，正确处理特殊字符
pub fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (input.len == 0) {
        return try allocator.dupe(u8, "");
    }

    // 预估输出大小（最坏情况下每个字符都需要转义）
    var escaped = std.ArrayList(u8).init(allocator);
    defer escaped.deinit();

    for (input) |char| {
        switch (char) {
            '"' => try escaped.appendSlice("\\\""),
            '\\' => try escaped.appendSlice("\\\\"),
            '\n' => try escaped.appendSlice("\\n"),
            '\r' => try escaped.appendSlice("\\r"),
            '\t' => try escaped.appendSlice("\\t"),
            8 => try escaped.appendSlice("\\b"), // backspace
            12 => try escaped.appendSlice("\\f"), // form feed
            0...7, 11, 14...31 => {
                // 控制字符转义为Unicode
                try escaped.writer().print("\\u{:0>4}", .{char});
            },
            else => try escaped.append(char),
        }
    }

    return escaped.toOwnedSlice();
}

/// 验证JSON字符串是否安全
pub fn validateJsonString(input: []const u8) bool {
    for (input) |char| {
        switch (char) {
            // 检查危险字符
            0...8, 11, 14...31 => return false, // 控制字符
            '"', '\\' => return false, // 未转义的引号和反斜杠
            else => {},
        }
    }
    return true;
}

/// 安全的JSON对象构建器
pub const JsonBuilder = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) JsonBuilder {
        return JsonBuilder{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *JsonBuilder) void {
        self.buffer.deinit();
    }

    /// 开始JSON对象
    pub fn startObject(self: *JsonBuilder) !void {
        try self.buffer.append('{');
    }

    /// 结束JSON对象
    pub fn endObject(self: *JsonBuilder) !void {
        // 移除最后的逗号（如果存在）
        if (self.buffer.items.len > 0 and self.buffer.items[self.buffer.items.len - 1] == ',') {
            _ = self.buffer.pop();
        }
        try self.buffer.append('}');
    }

    /// 添加字符串字段
    pub fn addString(self: *JsonBuilder, key: []const u8, value: []const u8) !void {
        const escaped_key = try escapeJsonString(self.allocator, key);
        defer self.allocator.free(escaped_key);

        const escaped_value = try escapeJsonString(self.allocator, value);
        defer self.allocator.free(escaped_value);

        try self.buffer.writer().print("\"{s}\":\"{s}\",", .{ escaped_key, escaped_value });
    }

    /// 添加数字字段
    pub fn addNumber(self: *JsonBuilder, key: []const u8, value: anytype) !void {
        const escaped_key = try escapeJsonString(self.allocator, key);
        defer self.allocator.free(escaped_key);

        try self.buffer.writer().print("\"{s}\":{d},", .{ escaped_key, value });
    }

    /// 添加布尔字段
    pub fn addBool(self: *JsonBuilder, key: []const u8, value: bool) !void {
        const escaped_key = try escapeJsonString(self.allocator, key);
        defer self.allocator.free(escaped_key);

        const bool_str = if (value) "true" else "false";
        try self.buffer.writer().print("\"{s}\":{s},", .{ escaped_key, bool_str });
    }

    /// 添加null字段
    pub fn addNull(self: *JsonBuilder, key: []const u8) !void {
        const escaped_key = try escapeJsonString(self.allocator, key);
        defer self.allocator.free(escaped_key);

        try self.buffer.writer().print("\"{s}\":null,", .{escaped_key});
    }

    /// 获取构建的JSON字符串
    pub fn build(self: *JsonBuilder) ![]u8 {
        return try self.allocator.dupe(u8, self.buffer.items);
    }
};

/// 安全的Echo响应构建器
pub fn buildSafeEchoResponse(allocator: std.mem.Allocator, echo_data: []const u8) ![]u8 {
    var builder = JsonBuilder.init(allocator);
    defer builder.deinit();

    const timestamp_str = try getCurrentTimestamp(allocator);
    defer allocator.free(timestamp_str);

    try builder.startObject();
    try builder.addString("echo", echo_data);
    try builder.addNumber("length", echo_data.len);
    try builder.addBool("safe", true);
    try builder.addString("timestamp", timestamp_str);
    try builder.endObject();

    return builder.build();
}

/// 安全的错误响应构建器
pub fn buildSafeErrorResponse(allocator: std.mem.Allocator, error_message: []const u8, error_code: ?[]const u8) ![]u8 {
    var builder = JsonBuilder.init(allocator);
    defer builder.deinit();

    const timestamp_str = try getCurrentTimestamp(allocator);
    defer allocator.free(timestamp_str);

    try builder.startObject();
    try builder.addBool("success", false);
    try builder.addString("error", error_message);

    if (error_code) |code| {
        try builder.addString("code", code);
    }

    try builder.addString("timestamp", timestamp_str);
    try builder.endObject();

    return builder.build();
}

/// 安全的用户响应构建器
pub fn buildSafeUserResponse(allocator: std.mem.Allocator, user_id: []const u8, name: []const u8, email: []const u8) ![]u8 {
    var builder = JsonBuilder.init(allocator);
    defer builder.deinit();

    const timestamp_str = try getCurrentTimestamp(allocator);
    defer allocator.free(timestamp_str);

    try builder.startObject();
    try builder.addString("user_id", user_id);
    try builder.addString("name", name);
    try builder.addString("email", email);
    try builder.addBool("active", true);
    try builder.addString("created_at", timestamp_str);
    try builder.endObject();

    return builder.build();
}

/// 获取当前时间戳字符串
fn getCurrentTimestamp(allocator: std.mem.Allocator) ![]u8 {
    const timestamp = std.time.timestamp();
    return try std.fmt.allocPrint(allocator, "{d}", .{timestamp});
}

/// 验证和清理用户输入
pub fn sanitizeUserInput(allocator: std.mem.Allocator, input: []const u8, max_length: usize) ![]u8 {
    if (input.len > max_length) {
        return JsonSafeError.InvalidInput;
    }

    // 移除危险字符
    var sanitized = std.ArrayList(u8).init(allocator);
    defer sanitized.deinit();

    for (input) |char| {
        switch (char) {
            // 允许的字符
            'a'...'z', 'A'...'Z', '0'...'9', ' ', '.', '-', '_', '@' => {
                try sanitized.append(char);
            },
            // 其他字符替换为下划线
            else => try sanitized.append('_'),
        }
    }

    return sanitized.toOwnedSlice();
}

/// 检测潜在的注入攻击
pub fn detectInjectionAttempt(input: []const u8) bool {
    const dangerous_patterns = [_][]const u8{
        "\":", // JSON键值分隔符
        "\",", // JSON字段分隔符
        "\":\"", // JSON字符串值
        "admin", // 权限相关
        "role", // 角色相关
        "token", // 令牌相关
        "password", // 密码相关
        "<script", // XSS攻击
        "javascript:", // JavaScript协议
        "eval(", // 代码执行
        "function(", // 函数定义
    };

    const input_lower = std.ascii.allocLowerString(std.heap.page_allocator, input) catch return true;
    defer std.heap.page_allocator.free(input_lower);

    for (dangerous_patterns) |pattern| {
        if (std.mem.indexOf(u8, input_lower, pattern) != null) {
            return true;
        }
    }

    return false;
}

// ============================================================================
// 测试用例
// ============================================================================

test "JSON字符串转义" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 测试基本转义
    const escaped = try escapeJsonString(allocator, "Hello \"World\"");
    defer allocator.free(escaped);
    try testing.expectEqualStrings("Hello \\\"World\\\"", escaped);

    // 测试控制字符转义
    const control_escaped = try escapeJsonString(allocator, "Line1\nLine2\tTab");
    defer allocator.free(control_escaped);
    try testing.expectEqualStrings("Line1\\nLine2\\tTab", control_escaped);
}

test "JSON注入检测" {
    // 正常输入
    try testing.expect(!detectInjectionAttempt("Hello World"));

    // 注入尝试
    try testing.expect(detectInjectionAttempt("\",\"admin\":true,\""));
    try testing.expect(detectInjectionAttempt("test<script>alert('xss')</script>"));
    try testing.expect(detectInjectionAttempt("user\",\"role\":\"admin"));
}

test "安全JSON构建器" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var builder = JsonBuilder.init(allocator);
    defer builder.deinit();

    try builder.startObject();
    try builder.addString("name", "John \"Hacker\" Doe");
    try builder.addNumber("age", 30);
    try builder.addBool("active", true);
    try builder.endObject();

    const result = try builder.build();
    defer allocator.free(result);

    // 验证结果不包含注入
    try testing.expect(std.mem.indexOf(u8, result, "\"name\":\"John \\\"Hacker\\\" Doe\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"age\":30") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"active\":true") != null);
}

test "安全Echo响应构建" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const malicious_input = "\",\"admin\":true,\"hacked\":\"yes";
    const response = try buildSafeEchoResponse(allocator, malicious_input);
    defer allocator.free(response);

    // 验证恶意输入被正确转义
    try testing.expect(std.mem.indexOf(u8, response, "admin") == null or
        std.mem.indexOf(u8, response, "\\\"admin\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"safe\":true") != null);
}

test "用户输入清理" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const dirty_input = "user<script>alert('xss')</script>";
    const clean_input = try sanitizeUserInput(allocator, dirty_input, 100);
    defer allocator.free(clean_input);

    // 验证危险字符被移除
    try testing.expect(std.mem.indexOf(u8, clean_input, "<") == null);
    try testing.expect(std.mem.indexOf(u8, clean_input, ">") == null);
    try testing.expect(std.mem.indexOf(u8, clean_input, "(") == null);
    try testing.expect(std.mem.indexOf(u8, clean_input, ")") == null);
}
