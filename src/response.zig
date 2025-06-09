const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const StatusCode = @import("context.zig").StatusCode;

/// HTTP 响应结构体
pub const HttpResponse = struct {
    allocator: Allocator,
    status: StatusCode,
    headers: StringHashMap([]const u8),
    body: ?[]const u8,
    cookies: ArrayList(Cookie),

    const Self = @This();

    /// Cookie 结构体
    pub const Cookie = struct {
        name: []const u8,
        value: []const u8,
        path: ?[]const u8 = null,
        domain: ?[]const u8 = null,
        expires: ?[]const u8 = null,
        max_age: ?i64 = null,
        secure: bool = false,
        http_only: bool = false,
        same_site: ?SameSite = null,

        /// SameSite 枚举
        pub const SameSite = enum {
            Strict,
            Lax,
            None,

            pub fn toString(self: SameSite) []const u8 {
                return switch (self) {
                    .Strict => "Strict",
                    .Lax => "Lax",
                    .None => "None",
                };
            }
        };

        /// Cookie 选项结构体
        pub const Options = struct {
            path: ?[]const u8 = null,
            domain: ?[]const u8 = null,
            expires: ?[]const u8 = null,
            max_age: ?i64 = null,
            secure: bool = false,
            http_only: bool = false,
            same_site: ?SameSite = null,
        };
    };

    /// 设置状态码
    pub fn setStatus(self: *Self, status: StatusCode) void {
        self.status = status;
    }

    /// 设置响应头
    pub fn setHeader(self: *Self, name: []const u8, value: []const u8) !void {
        const name_dup = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_dup);

        const value_dup = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_dup);

        // 如果已存在同名头部，先释放旧值
        if (self.headers.get(name)) |old_value| {
            const old_name = self.headers.getKey(name).?;
            self.allocator.free(old_name);
            self.allocator.free(old_value);
            _ = self.headers.remove(name);
        }

        try self.headers.put(name_dup, value_dup);
    }

    /// 设置响应体
    pub fn setBody(self: *Self, body: []const u8) !void {
        if (self.body) |old_body| {
            self.allocator.free(old_body);
        }

        self.body = try self.allocator.dupe(u8, body);
    }

    /// 设置 JSON 响应体
    pub fn setJsonBody(self: *Self, json: []const u8) !void {
        try self.setHeader("Content-Type", "application/json; charset=utf-8");
        try self.setBody(json);
    }

    /// 设置 HTML 响应体
    pub fn setHtmlBody(self: *Self, html: []const u8) !void {
        try self.setHeader("Content-Type", "text/html; charset=utf-8");
        try self.setBody(html);
    }

    /// 设置文本响应体
    pub fn setTextBody(self: *Self, text: []const u8) !void {
        try self.setHeader("Content-Type", "text/plain; charset=utf-8");
        try self.setBody(text);
    }

    /// 设置 Cookie
    pub fn setCookie(self: *Self, cookie: Cookie) !void {
        try self.cookies.append(cookie);
    }

    /// 构建完整的 HTTP 响应
    pub fn build(self: *Self) ![]u8 {
        var response = ArrayList(u8).init(self.allocator);
        errdefer response.deinit();

        // 状态行
        try response.writer().print("HTTP/1.1 {d} {s}\r\n", .{ @intFromEnum(self.status), self.status.toString() });

        // 默认头部
        if (!self.headers.contains("Server")) {
            try response.writer().print("Server: Zig-HTTP/1.0\r\n", .{});
        }

        if (!self.headers.contains("Date")) {
            const timestamp = std.time.timestamp();
            try response.writer().print("Date: {d}\r\n", .{timestamp});
        }

        if (!self.headers.contains("Connection")) {
            try response.writer().print("Connection: close\r\n", .{});
        }

        // 自定义头部
        var iterator = self.headers.iterator();
        while (iterator.next()) |entry| {
            try response.writer().print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        // Cookie 头部
        for (self.cookies.items) |cookie| {
            var cookie_str = ArrayList(u8).init(self.allocator);
            defer cookie_str.deinit();

            try cookie_str.writer().print("{s}={s}", .{ cookie.name, cookie.value });

            if (cookie.path) |path| {
                try cookie_str.writer().print("; Path={s}", .{path});
            }

            if (cookie.domain) |domain| {
                try cookie_str.writer().print("; Domain={s}", .{domain});
            }

            if (cookie.expires) |expires| {
                try cookie_str.writer().print("; Expires={s}", .{expires});
            }

            if (cookie.max_age) |max_age| {
                try cookie_str.writer().print("; Max-Age={d}", .{max_age});
            }

            if (cookie.secure) {
                try cookie_str.writer().print("; Secure", .{});
            }

            if (cookie.http_only) {
                try cookie_str.writer().print("; HttpOnly", .{});
            }

            if (cookie.same_site) |same_site| {
                try cookie_str.writer().print("; SameSite={s}", .{same_site.toString()});
            }

            try response.writer().print("Set-Cookie: {s}\r\n", .{cookie_str.items});
        }

        // 响应体
        if (self.body) |body| {
            if (!self.headers.contains("Content-Length")) {
                try response.writer().print("Content-Length: {d}\r\n", .{body.len});
            }

            try response.writer().print("\r\n", .{});
            try response.writer().print("{s}", .{body});
        } else {
            try response.writer().print("Content-Length: 0\r\n\r\n", .{});
        }

        return response.toOwnedSlice();
    }

    /// 清理资源
    pub fn deinit(self: *Self) void {
        var it = self.headers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();

        if (self.body) |body| {
            self.allocator.free(body);
        }

        self.cookies.deinit();
    }
};
