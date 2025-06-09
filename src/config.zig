const std = @import("std");

pub const HttpConfig = struct {
    // 服务器配置
    port: u16 = 8080,
    address: []const u8 = "127.0.0.1",

    // 连接配置
    max_connections: usize = 1000,
    read_timeout_ms: u32 = 30000,
    write_timeout_ms: u32 = 30000,

    // 缓冲区配置
    buffer_size: usize = 8192,
    max_buffers: usize = 200,

    // 路由配置
    max_routes: usize = 100,

    // 中间件配置
    max_middlewares: usize = 50,

    // 日志配置
    log_level: LogLevel = .info,

    pub const LogLevel = enum {
        debug,
        info,
        warning,
        @"error",
        critical,
    };
};

pub const AppConfig = struct {
    http: HttpConfig = .{},
    app_name: []const u8 = "Zig HTTP Server",
    version: []const u8 = "1.0.0",
    environment: Environment = .development,

    pub const Environment = enum {
        development,
        testing,
        production,
    };

    pub fn isDevelopment(self: AppConfig) bool {
        return self.environment == .development;
    }

    pub fn isProduction(self: AppConfig) bool {
        return self.environment == .production;
    }

    pub fn isTesting(self: AppConfig) bool {
        return self.environment == .testing;
    }
};

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !AppConfig {
    _ = allocator;
    _ = path;

    // 默认配置
    return AppConfig{};

    // TODO: 从文件加载配置
    // const file = try std.fs.cwd().openFile(path, .{});
    // defer file.close();
    // ...
}
