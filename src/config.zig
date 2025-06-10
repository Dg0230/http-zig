const std = @import("std");

/// HTTP 服务器配置
/// 包含服务器运行所需的所有配置参数
pub const HttpConfig = struct {
    // 网络配置
    port: u16 = 8080, // 监听端口
    address: []const u8 = "127.0.0.1", // 绑定地址

    // 连接管理配置
    max_connections: usize = 1000, // 最大并发连接数
    read_timeout_ms: u32 = 30000, // 读取超时时间（毫秒）
    write_timeout_ms: u32 = 30000, // 写入超时时间（毫秒）

    // 内存管理配置
    buffer_size: usize = 8192, // 单个缓冲区大小
    max_buffers: usize = 200, // 缓冲区池最大数量

    // 路由系统配置
    max_routes: usize = 100, // 最大路由数量

    // 中间件系统配置
    max_middlewares: usize = 50, // 最大中间件数量

    // 日志系统配置
    log_level: LogLevel = .info, // 日志级别

    /// 日志级别枚举
    /// 定义了不同的日志输出级别
    pub const LogLevel = enum {
        debug,
        info,
        warning,
        @"error",
        critical,
    };
};

/// 应用程序配置
/// 包含应用级别的配置和 HTTP 服务器配置
pub const AppConfig = struct {
    http: HttpConfig = .{}, // HTTP 服务器配置
    app_name: []const u8 = "Zig HTTP Server", // 应用程序名称
    version: []const u8 = "1.0.0", // 应用程序版本
    environment: Environment = .development, // 运行环境

    /// 应用程序运行环境枚举
    pub const Environment = enum {
        development,
        testing,
        production,
    };

    /// 检查是否为开发环境
    pub fn isDevelopment(self: AppConfig) bool {
        return self.environment == .development;
    }

    /// 检查是否为生产环境
    pub fn isProduction(self: AppConfig) bool {
        return self.environment == .production;
    }

    /// 检查是否为测试环境
    pub fn isTesting(self: AppConfig) bool {
        return self.environment == .testing;
    }
};

/// 从配置文件加载应用配置
/// 目前返回默认配置，未来可扩展为从文件读取
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
