const std = @import("std");
const testing = std.testing;
const HttpConfig = @import("config.zig").HttpConfig;
const AppConfig = @import("config.zig").AppConfig;
const loadConfig = @import("config.zig").loadConfig;

test "HttpConfig 默认值" {
    const config = HttpConfig{};

    try testing.expect(config.port == 8080);
    try testing.expectEqualStrings("127.0.0.1", config.address);
    try testing.expect(config.max_connections == 1000);
    try testing.expect(config.read_timeout_ms == 30000);
    try testing.expect(config.write_timeout_ms == 30000);
    try testing.expect(config.buffer_size == 8192);
    try testing.expect(config.max_buffers == 200);
    try testing.expect(config.max_routes == 100);
    try testing.expect(config.max_middlewares == 50);
    try testing.expect(config.log_level == .info);
}

test "HttpConfig 自定义值" {
    const config = HttpConfig{
        .port = 3000,
        .address = "0.0.0.0",
        .max_connections = 500,
        .read_timeout_ms = 10000,
        .write_timeout_ms = 10000,
        .buffer_size = 16384,
        .max_buffers = 100,
        .log_level = .debug,
    };

    try testing.expect(config.port == 3000);
    try testing.expectEqualStrings("0.0.0.0", config.address);
    try testing.expect(config.max_connections == 500);
    try testing.expect(config.read_timeout_ms == 10000);
    try testing.expect(config.write_timeout_ms == 10000);
    try testing.expect(config.buffer_size == 16384);
    try testing.expect(config.max_buffers == 100);
    try testing.expect(config.log_level == .debug);
}

test "AppConfig 默认值" {
    const config = AppConfig{};

    try testing.expectEqualStrings("Zig HTTP Server", config.app_name);
    try testing.expectEqualStrings("1.0.0", config.version);
    try testing.expect(config.environment == .development);

    // 测试默认的 HttpConfig
    try testing.expect(config.http.port == 8080);
    try testing.expectEqualStrings("127.0.0.1", config.http.address);
}

test "AppConfig 环境检测方法" {
    // 测试开发环境
    const dev_config = AppConfig{
        .environment = .development,
    };

    try testing.expect(dev_config.isDevelopment() == true);
    try testing.expect(dev_config.isProduction() == false);
    try testing.expect(dev_config.isTesting() == false);

    // 测试生产环境
    const prod_config = AppConfig{
        .environment = .production,
    };

    try testing.expect(prod_config.isDevelopment() == false);
    try testing.expect(prod_config.isProduction() == true);
    try testing.expect(prod_config.isTesting() == false);

    // 测试测试环境
    const test_config = AppConfig{
        .environment = .testing,
    };

    try testing.expect(test_config.isDevelopment() == false);
    try testing.expect(test_config.isProduction() == false);
    try testing.expect(test_config.isTesting() == true);
}

test "AppConfig 自定义配置" {
    const custom_http = HttpConfig{
        .port = 9000,
        .address = "192.168.1.100",
        .max_connections = 200,
    };

    const config = AppConfig{
        .http = custom_http,
        .app_name = "My Custom Server",
        .version = "2.0.0",
        .environment = .production,
    };

    try testing.expectEqualStrings("My Custom Server", config.app_name);
    try testing.expectEqualStrings("2.0.0", config.version);
    try testing.expect(config.environment == .production);
    try testing.expect(config.http.port == 9000);
    try testing.expectEqualStrings("192.168.1.100", config.http.address);
    try testing.expect(config.http.max_connections == 200);
}

test "loadConfig 函数" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 测试加载默认配置（当前实现返回默认值）
    const config = try loadConfig(allocator, "nonexistent.json");

    try testing.expectEqualStrings("Zig HTTP Server", config.app_name);
    try testing.expectEqualStrings("1.0.0", config.version);
    try testing.expect(config.environment == .development);
    try testing.expect(config.http.port == 8080);
}

test "Environment 枚举值" {
    const Environment = AppConfig.Environment;

    try testing.expect(Environment.development != Environment.testing);
    try testing.expect(Environment.development != Environment.production);
    try testing.expect(Environment.testing != Environment.production);
}

test "配置组合测试" {
    // 测试不同配置组合的有效性
    const configs = [_]AppConfig{
        AppConfig{}, // 默认配置
        AppConfig{
            .environment = .production,
            .http = HttpConfig{
                .port = 80,
                .address = "0.0.0.0",
            },
        },
        AppConfig{
            .environment = .testing,
            .http = HttpConfig{
                .port = 0, // 随机端口
                .max_connections = 10,
                .read_timeout_ms = 1000,
            },
        },
    };

    for (configs) |config| {
        // 验证每个配置都是有效的
        try testing.expect(config.app_name.len > 0);
        try testing.expect(config.version.len > 0);
        try testing.expect(config.http.address.len > 0);
        try testing.expect(config.http.buffer_size > 0);
        try testing.expect(config.http.max_buffers > 0);
        try testing.expect(config.http.max_routes > 0);
    }
}

test "配置边界值测试" {
    // 测试极端配置值
    const extreme_config = AppConfig{
        .http = HttpConfig{
            .port = 65535, // 最大端口号
            .max_connections = 1, // 最小连接数
            .read_timeout_ms = 1, // 最小超时
            .write_timeout_ms = 1,
            .buffer_size = 1, // 最小缓冲区
            .max_buffers = 1,
            .max_routes = 1,
        },
    };

    try testing.expect(extreme_config.http.port == 65535);
    try testing.expect(extreme_config.http.max_connections == 1);
    try testing.expect(extreme_config.http.read_timeout_ms == 1);
    try testing.expect(extreme_config.http.write_timeout_ms == 1);
    try testing.expect(extreme_config.http.buffer_size == 1);
    try testing.expect(extreme_config.http.max_buffers == 1);
    try testing.expect(extreme_config.http.max_routes == 1);
}
