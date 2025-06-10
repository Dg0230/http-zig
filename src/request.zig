const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;

/// HTTP方法枚举
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

    /// 从字符串解析HTTP方法
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

    /// 转换为字符串
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

/// HTTP 请求结构体
pub const HttpRequest = struct {
    allocator: Allocator,
    method: []const u8,
    path: []const u8,
    query: ?[]const u8,
    version: []const u8,
    headers: StringHashMap([]const u8),
    body: ?[]const u8,
    raw_data: []const u8,

    const Self = @This();

    /// 从缓冲区解析 HTTP 请求
    pub fn parseFromBuffer(allocator: Allocator, buffer: []const u8) !Self {
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
                const body_end = @min(body_start + content_length.?, buffer.len);
                request.body = buffer[body_start..body_end];
            }
        }

        return request;
    }

    /// 解析请求行
    fn parseRequestLine(self: *Self, line: []const u8) !void {
        var parts = std.mem.splitSequence(u8, line, " ");

        // 先验证所有部分都存在且有效
        const method = parts.next() orelse {
            return error.InvalidRequestLine;
        };
        if (method.len == 0) {
            return error.InvalidRequestLine;
        }

        const url = parts.next() orelse {
            return error.InvalidRequestLine;
        };
        if (url.len == 0) {
            return error.InvalidRequestLine;
        }

        const version = parts.next() orelse {
            return error.InvalidRequestLine;
        };
        if (version.len == 0) {
            return error.InvalidRequestLine;
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
        const colon_pos = std.mem.indexOf(u8, line, ":") orelse {
            return error.InvalidHeaderLine;
        };

        const name = std.mem.trim(u8, line[0..colon_pos], " ");
        const value = std.mem.trim(u8, line[colon_pos + 1 ..], " ");

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
