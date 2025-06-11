const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;

/// HTTP 请求方法枚举
/// 定义了所有标准的 HTTP 方法
pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
    TRACE,
    CONNECT,

    /// 将字符串转换为 HTTP 方法枚举值
    pub fn fromString(method_str: []const u8) ?HttpMethod {
        if (std.mem.eql(u8, method_str, "GET")) return .GET;
        if (std.mem.eql(u8, method_str, "POST")) return .POST;
        if (std.mem.eql(u8, method_str, "PUT")) return .PUT;
        if (std.mem.eql(u8, method_str, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, method_str, "PATCH")) return .PATCH;
        if (std.mem.eql(u8, method_str, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, method_str, "OPTIONS")) return .OPTIONS;
        if (std.mem.eql(u8, method_str, "TRACE")) return .TRACE;
        if (std.mem.eql(u8, method_str, "CONNECT")) return .CONNECT;
        return null;
    }

    /// 将 HTTP 方法枚举值转换为字符串表示
    pub fn toString(self: HttpMethod) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
            .TRACE => "TRACE",
            .CONNECT => "CONNECT",
        };
    }
};

/// HTTP 请求的完整表示
/// 包含请求行、请求头、请求体等所有信息
/// 负责解析原始 HTTP 请求数据并提供结构化访问
pub const HttpRequest = struct {
    allocator: Allocator, // 内存分配器
    method: []const u8, // HTTP 方法 (GET, POST, etc.)
    path: []const u8, // 请求路径
    query: ?[]const u8, // 查询字符串 (可选)
    version: []const u8, // HTTP 版本
    headers: StringHashMap([]const u8), // 请求头映射
    body: ?[]const u8, // 请求体 (可选)
    raw_data: []const u8, // 原始请求数据的引用

    const Self = @This();

    /// 解析原始 HTTP 请求数据
    /// 将字节流转换为结构化的请求对象
    pub fn parseFromBuffer(allocator: Allocator, buffer: []const u8) !Self {
        const SecurityLimits = @import("security_limits.zig").SecurityLimits;

        // 添加请求大小检查
        if (buffer.len > SecurityLimits.MAX_REQUEST_SIZE) {
            return error.RequestTooLarge;
        }
        var request = Self{
            .allocator = allocator,
            .method = "",
            .path = "",
            .query = null,
            .version = "",
            .headers = StringHashMap([]const u8).init(allocator),
            .body = null,
            .raw_data = buffer,
        };

        // 查找请求头和请求体的分隔
        const header_end = std.mem.indexOf(u8, buffer, "\r\n\r\n") orelse {
            return error.InvalidRequest;
        };

        const headers_part = buffer[0..header_end];

        // 解析请求行和请求头
        var lines = std.mem.splitSequence(u8, headers_part, "\r\n");

        // 解析请求行
        const request_line = lines.next() orelse {
            return error.InvalidRequest;
        };

        try request.parseRequestLine(request_line);
        errdefer request.deinit();

        // 解析请求头
        while (lines.next()) |line| {
            if (line.len == 0) break;
            try request.parseHeaderLine(line);
        }

        // 解析请求体
        if (header_end + 4 < buffer.len) {
            const body_start = header_end + 4;
            const content_length = request.getContentLength();

            if (content_length != null and content_length.? > 0) {
                // 增强边界检查
                if (body_start >= buffer.len) {
                    return error.InvalidRequestFormat;
                }

                const available_body_size = buffer.len - body_start;
                const actual_body_size = @min(content_length.?, available_body_size);

                if (actual_body_size > 0) {
                    const body_end = body_start + actual_body_size;
                    request.body = buffer[body_start..body_end];
                }
            }
        }

        return request;
    }

    /// 解析请求行
    fn parseRequestLine(self: *Self, line: []const u8) !void {
        const SecurityLimits = @import("security_limits.zig").SecurityLimits;

        var parts = std.mem.splitSequence(u8, line, " ");

        // 先验证所有部分都存在且有效
        const method = parts.next() orelse {
            return error.InvalidRequestLine;
        };
        if (method.len == 0 or method.len > SecurityLimits.MAX_METHOD_LENGTH) {
            return error.InvalidRequestLine;
        }

        const url = parts.next() orelse {
            return error.InvalidRequestLine;
        };
        if (url.len == 0 or url.len > SecurityLimits.MAX_URI_LENGTH) {
            return error.InvalidRequestLine;
        }

        const version = parts.next() orelse {
            return error.InvalidRequestLine;
        };
        if (version.len == 0 or version.len > SecurityLimits.MAX_VERSION_LENGTH) {
            return error.InvalidRequestLine;
        }

        // 验证HTTP方法
        const valid_methods = [_][]const u8{ "GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH", "TRACE" };
        var method_valid = false;
        for (valid_methods) |valid_method| {
            if (std.mem.eql(u8, method, valid_method)) {
                method_valid = true;
                break;
            }
        }
        if (!method_valid) {
            return error.InvalidRequestLine;
        }

        // 验证HTTP版本格式
        if (!std.mem.startsWith(u8, version, "HTTP/")) {
            return error.InvalidRequestLine;
        }

        // 检查URL中的危险字符
        for (url) |char| {
            if (char == 0) { // 空字节注入检测
                return error.InvalidRequestLine;
            }
        }

        // 所有验证通过后，开始分配内存
        self.method = try self.allocator.dupe(u8, method);
        errdefer {
            self.allocator.free(self.method);
            self.method = "";
        }

        // 检查是否有查询参数
        if (std.mem.indexOf(u8, url, "?")) |query_start| {
            self.path = try self.allocator.dupe(u8, url[0..query_start]);
            errdefer {
                self.allocator.free(self.path);
                self.path = "";
            }
            self.query = try self.allocator.dupe(u8, url[query_start + 1 ..]);
            errdefer {
                if (self.query) |q| {
                    self.allocator.free(q);
                    self.query = null;
                }
            }
        } else {
            self.path = try self.allocator.dupe(u8, url);
            errdefer {
                self.allocator.free(self.path);
                self.path = "";
            }
        }

        self.version = try self.allocator.dupe(u8, version);
        errdefer {
            self.allocator.free(self.version);
            self.version = "";
        }
    }

    /// 解析请求头行
    fn parseHeaderLine(self: *Self, line: []const u8) !void {
        const SecurityLimits = @import("security_limits.zig").SecurityLimits;

        const colon_pos = std.mem.indexOf(u8, line, ":") orelse {
            return error.InvalidHeaderLine;
        };

        const name = std.mem.trim(u8, line[0..colon_pos], " ");
        const value = std.mem.trim(u8, line[colon_pos + 1 ..], " ");

        // 验证头部名称和值的长度
        if (name.len == 0 or name.len > SecurityLimits.MAX_HEADER_NAME_SIZE) {
            return error.InvalidHeaderLine;
        }
        if (value.len > SecurityLimits.MAX_HEADER_VALUE_SIZE) {
            return error.InvalidHeaderLine;
        }

        // 检查CRLF注入攻击
        for (value) |char| {
            if (char == '\r' or char == '\n' or char == 0) {
                return error.InvalidHeaderLine;
            }
        }

        // 检查头部数量限制
        if (self.headers.count() >= SecurityLimits.MAX_HEADER_COUNT) {
            return error.TooManyHeaders;
        }

        const name_dup = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_dup);

        const value_dup = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_dup);

        try self.headers.put(name_dup, value_dup);
    }

    /// 获取内容长度
    fn getContentLength(self: *Self) ?usize {
        const content_length = self.headers.get("Content-Length") orelse {
            return null;
        };

        return std.fmt.parseInt(usize, content_length, 10) catch null;
    }

    /// 获取请求头
    pub fn getHeader(self: *const Self, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    /// 清理资源
    pub fn deinit(self: *Self) void {
        // 释放字符串内存（只要不是空字符串就释放）
        if (self.method.len > 0) {
            self.allocator.free(self.method);
            self.method = "";
        }
        if (self.path.len > 0) {
            self.allocator.free(self.path);
            self.path = "";
        }
        if (self.query) |query| {
            self.allocator.free(query);
            self.query = null;
        }
        if (self.version.len > 0) {
            self.allocator.free(self.version);
            self.version = "";
        }

        // 释放请求头内存
        var it = self.headers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }

        self.headers.deinit();
    }
};
