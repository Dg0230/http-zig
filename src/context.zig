const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const HttpRequest = @import("request.zig").HttpRequest;
const HttpResponse = @import("response.zig").HttpResponse;

/// HTTP状态码枚举
pub const StatusCode = enum(u16) {
    // 1xx - 信息性状态码
    @"continue" = 100,
    switching_protocols = 101,
    processing = 102,
    early_hints = 103,

    // 2xx - 成功状态码
    ok = 200,
    created = 201,
    accepted = 202,
    non_authoritative_information = 203,
    no_content = 204,
    reset_content = 205,
    partial_content = 206,
    multi_status = 207,
    already_reported = 208,
    im_used = 226,

    // 3xx - 重定向状态码
    multiple_choices = 300,
    moved_permanently = 301,
    found = 302,
    see_other = 303,
    not_modified = 304,
    use_proxy = 305,
    temporary_redirect = 307,
    permanent_redirect = 308,

    // 4xx - 客户端错误状态码
    bad_request = 400,
    unauthorized = 401,
    payment_required = 402,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    not_acceptable = 406,
    proxy_authentication_required = 407,
    request_timeout = 408,
    conflict = 409,
    gone = 410,
    length_required = 411,
    precondition_failed = 412,
    payload_too_large = 413,
    uri_too_long = 414,
    unsupported_media_type = 415,
    range_not_satisfiable = 416,
    expectation_failed = 417,
    im_a_teapot = 418,
    misdirected_request = 421,
    unprocessable_entity = 422,
    locked = 423,
    failed_dependency = 424,
    too_early = 425,
    upgrade_required = 426,
    precondition_required = 428,
    too_many_requests = 429,
    request_header_fields_too_large = 431,
    unavailable_for_legal_reasons = 451,

    // 5xx - 服务器错误状态码
    internal_server_error = 500,
    not_implemented = 501,
    bad_gateway = 502,
    service_unavailable = 503,
    gateway_timeout = 504,
    http_version_not_supported = 505,
    variant_also_negotiates = 506,
    insufficient_storage = 507,
    loop_detected = 508,
    not_extended = 510,
    network_authentication_required = 511,

    /// 获取状态码的文本描述
    pub fn toString(self: StatusCode) []const u8 {
        return switch (self) {
            .@"continue" => "Continue",
            .switching_protocols => "Switching Protocols",
            .processing => "Processing",
            .early_hints => "Early Hints",
            .ok => "OK",
            .created => "Created",
            .accepted => "Accepted",
            .non_authoritative_information => "Non-Authoritative Information",
            .no_content => "No Content",
            .reset_content => "Reset Content",
            .partial_content => "Partial Content",
            .multi_status => "Multi-Status",
            .already_reported => "Already Reported",
            .im_used => "IM Used",
            .multiple_choices => "Multiple Choices",
            .moved_permanently => "Moved Permanently",
            .found => "Found",
            .see_other => "See Other",
            .not_modified => "Not Modified",
            .use_proxy => "Use Proxy",
            .temporary_redirect => "Temporary Redirect",
            .permanent_redirect => "Permanent Redirect",
            .bad_request => "Bad Request",
            .unauthorized => "Unauthorized",
            .payment_required => "Payment Required",
            .forbidden => "Forbidden",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .not_acceptable => "Not Acceptable",
            .proxy_authentication_required => "Proxy Authentication Required",
            .request_timeout => "Request Timeout",
            .conflict => "Conflict",
            .gone => "Gone",
            .length_required => "Length Required",
            .precondition_failed => "Precondition Failed",
            .payload_too_large => "Payload Too Large",
            .uri_too_long => "URI Too Long",
            .unsupported_media_type => "Unsupported Media Type",
            .range_not_satisfiable => "Range Not Satisfiable",
            .expectation_failed => "Expectation Failed",
            .im_a_teapot => "I'm a teapot",
            .misdirected_request => "Misdirected Request",
            .unprocessable_entity => "Unprocessable Entity",
            .locked => "Locked",
            .failed_dependency => "Failed Dependency",
            .too_early => "Too Early",
            .upgrade_required => "Upgrade Required",
            .precondition_required => "Precondition Required",
            .too_many_requests => "Too Many Requests",
            .request_header_fields_too_large => "Request Header Fields Too Large",
            .unavailable_for_legal_reasons => "Unavailable For Legal Reasons",
            .internal_server_error => "Internal Server Error",
            .not_implemented => "Not Implemented",
            .bad_gateway => "Bad Gateway",
            .service_unavailable => "Service Unavailable",
            .gateway_timeout => "Gateway Timeout",
            .http_version_not_supported => "HTTP Version Not Supported",
            .variant_also_negotiates => "Variant Also Negotiates",
            .insufficient_storage => "Insufficient Storage",
            .loop_detected => "Loop Detected",
            .not_extended => "Not Extended",
            .network_authentication_required => "Network Authentication Required",
        };
    }
};

/// 请求上下文结构体
pub const Context = struct {
    request: *HttpRequest,
    response: *HttpResponse,
    allocator: Allocator,
    params: StringHashMap([]const u8),
    state: StringHashMap([]const u8),

    const Self = @This();

    /// 初始化上下文
    pub fn init(allocator: Allocator, request: *HttpRequest, response: *HttpResponse) Self {
        return Self{
            .request = request,
            .response = response,
            .allocator = allocator,
            .params = StringHashMap([]const u8).init(allocator),
            .state = StringHashMap([]const u8).init(allocator),
        };
    }

    /// 清理资源
    pub fn deinit(self: *Self) void {
        var it = self.params.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.params.deinit();

        var state_it = self.state.iterator();
        while (state_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.state.deinit();
    }

    /// 设置路径参数
    pub fn setParam(self: *Self, key: []const u8, value: []const u8) !void {
        // 检查是否已存在该键，如果存在则释放旧的内存
        if (self.params.fetchRemove(key)) |old_entry| {
            self.allocator.free(old_entry.key);
            self.allocator.free(old_entry.value);
        }

        const owned_key = try self.allocator.dupe(u8, key);
        const owned_value = try self.allocator.dupe(u8, value);
        try self.params.put(owned_key, owned_value);
    }

    /// 获取路径参数
    pub fn getParam(self: *Self, key: []const u8) ?[]const u8 {
        return self.params.get(key);
    }

    /// 设置状态
    pub fn setState(self: *Self, key: []const u8, value: []const u8) !void {
        // 检查是否已存在该键，如果存在则释放旧的内存
        if (self.state.fetchRemove(key)) |old_entry| {
            self.allocator.free(old_entry.key);
            self.allocator.free(old_entry.value);
        }

        const owned_key = try self.allocator.dupe(u8, key);
        const owned_value = try self.allocator.dupe(u8, value);
        try self.state.put(owned_key, owned_value);
    }

    /// 获取状态
    pub fn getState(self: *Self, key: []const u8) ?[]const u8 {
        return self.state.get(key);
    }

    /// 设置响应状态码
    pub fn status(self: *Self, code: StatusCode) void {
        self.response.status = code;
    }

    /// 发送JSON响应
    pub fn json(self: *Self, data: []const u8) !void {
        try self.response.setHeader("Content-Type", "application/json");
        try self.response.setBody(data);
    }

    /// 发送文本响应
    pub fn text(self: *Self, content: []const u8) !void {
        try self.response.setHeader("Content-Type", "text/plain");
        try self.response.setBody(content);
    }

    /// 发送HTML响应
    pub fn html(self: *Self, content: []const u8) !void {
        try self.response.setHeader("Content-Type", "text/html");
        try self.response.setBody(content);
    }

    /// 重定向
    pub fn redirect(self: *Self, url: []const u8, status_code: StatusCode) !void {
        self.response.status = status_code;
        try self.response.setHeader("Location", url);
    }
};
