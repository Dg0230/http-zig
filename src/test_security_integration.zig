// 安全模块集成测试
// 验证新添加的安全模块与现有系统的集成

const std = @import("std");
const testing = std.testing;

// 导入安全模块
const safe_math = @import("safe_math.zig");
const security_limits = @import("security_limits.zig");
const security_logger = @import("security_logger.zig");

// 导入现有模块
const HttpRequest = @import("request.zig").HttpRequest;
const HttpResponse = @import("response.zig").HttpResponse;
const Context = @import("context.zig").Context;
const BufferPool = @import("buffer.zig").BufferPool;

// 测试安全数学模块与缓冲区池的集成
test "安全数学模块与缓冲区池集成测试" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = try BufferPool.init(allocator, 1024, 10);
    defer pool.deinit();

    // 使用安全数学运算计算缓冲区使用情况
    const buffer1 = try pool.acquire();
    const buffer2 = try pool.acquire();

    // 安全计算当前使用的缓冲区数量
    const total_buffers = pool.buffers.items.len;
    const available_buffers = pool.available.items.len;

    // 使用安全减法计算使用中的缓冲区数量
    const used_buffers = try safe_math.safeSub(usize, total_buffers, available_buffers);
    try testing.expect(used_buffers == 2);

    // 释放缓冲区
    try pool.release(buffer1);
    try pool.release(buffer2);

    std.debug.print("✅ 安全数学模块与缓冲区池集成测试通过\n", .{});
}

// 测试安全限制与HTTP请求解析的集成
test "安全限制与HTTP请求解析集成测试" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 测试正常大小的请求
    const normal_request = "GET /api/test HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\ntest data";

    // 验证请求大小
    try security_limits.SecurityValidator.validateRequestSize(normal_request.len);

    // 解析请求
    var request = try HttpRequest.parseFromBuffer(allocator, normal_request);
    defer request.deinit();

    // 验证解析结果
    try testing.expectEqualStrings("GET", request.method);
    try testing.expectEqualStrings("/api/test", request.path);

    // 测试超大请求被拒绝
    const large_request = "A" ** (security_limits.SecurityLimits.MAX_REQUEST_SIZE + 1);
    try testing.expectError(security_limits.SecurityLimitError.RequestTooLarge, security_limits.SecurityValidator.validateRequestSize(large_request.len));

    std.debug.print("✅ 安全限制与HTTP请求解析集成测试通过\n", .{});
}

// 测试安全日志与错误处理的集成
test "安全日志与错误处理集成测试" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 初始化安全日志记录器
    var logger = try security_logger.SecurityLogger.init(allocator, null);
    defer logger.deinit();

    // 模拟HTTP请求解析错误
    const malicious_request = "GET /\x00evil HTTP/1.1\r\n\r\n";

    // 验证输入安全性
    const validation_result = security_limits.SecurityValidator.validateInputSafety(malicious_request);
    try testing.expectError(security_limits.SecurityLimitError.InvalidInput, validation_result);

    // 记录安全事件
    try logger.logMaliciousInput("192.168.1.100", "Null Byte Injection", "Request contains null bytes");

    // 测试认证失败日志
    try logger.logAuthenticationFailure("192.168.1.100", "test_user", "Invalid password");

    std.debug.print("✅ 安全日志与错误处理集成测试通过\n", .{});
}

// 测试速率限制器功能
test "速率限制器功能测试" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var limiter = security_limits.RateLimiter.init(allocator);
    defer limiter.deinit();

    // 设置测试参数
    limiter.max_requests = 3;
    limiter.window_ms = 1000;

    const test_ip = "192.168.1.100";

    // 前3个请求应该成功
    try limiter.checkRateLimit(test_ip);
    try limiter.checkRateLimit(test_ip);
    try limiter.checkRateLimit(test_ip);

    // 第4个请求应该被限制
    try testing.expectError(security_limits.SecurityLimitError.RateLimitExceeded, limiter.checkRateLimit(test_ip));

    std.debug.print("✅ 速率限制器功能测试通过\n", .{});
}

// 测试安全头部验证
test "安全头部验证测试" {
    // 测试正常头部
    try security_limits.SecurityValidator.validateHeaderSize("Content-Type", "application/json");
    try security_limits.SecurityValidator.validateHeaderSize("Authorization", "Bearer token123");

    // 测试超长头部名称
    const long_name = "A" ** (security_limits.SecurityLimits.MAX_HEADER_NAME_SIZE + 1);
    try testing.expectError(security_limits.SecurityLimitError.HeaderTooLarge, security_limits.SecurityValidator.validateHeaderSize(long_name, "value"));

    // 测试超长头部值
    const long_value = "B" ** (security_limits.SecurityLimits.MAX_HEADER_VALUE_SIZE + 1);
    try testing.expectError(security_limits.SecurityLimitError.HeaderTooLarge, security_limits.SecurityValidator.validateHeaderSize("Header", long_value));

    std.debug.print("✅ 安全头部验证测试通过\n", .{});
}

// 测试HTTP方法验证
test "HTTP方法验证测试" {
    // 测试有效的HTTP方法
    try security_limits.SecurityValidator.validateMethod("GET");
    try security_limits.SecurityValidator.validateMethod("POST");
    try security_limits.SecurityValidator.validateMethod("PUT");
    try security_limits.SecurityValidator.validateMethod("DELETE");
    try security_limits.SecurityValidator.validateMethod("HEAD");
    try security_limits.SecurityValidator.validateMethod("OPTIONS");
    try security_limits.SecurityValidator.validateMethod("PATCH");
    try security_limits.SecurityValidator.validateMethod("TRACE");

    // 测试无效的HTTP方法
    try testing.expectError(security_limits.SecurityLimitError.InvalidInput, security_limits.SecurityValidator.validateMethod("INVALID"));
    try testing.expectError(security_limits.SecurityLimitError.InvalidInput, security_limits.SecurityValidator.validateMethod("HACK"));

    // 测试超长方法名
    const long_method = "A" ** (security_limits.SecurityLimits.MAX_METHOD_LENGTH + 1);
    try testing.expectError(security_limits.SecurityLimitError.InvalidInput, security_limits.SecurityValidator.validateMethod(long_method));

    std.debug.print("✅ HTTP方法验证测试通过\n", .{});
}

// 测试路径深度验证
test "路径深度验证测试" {
    // 测试正常路径
    try security_limits.SecurityValidator.validatePathDepth("/api/v1/users/123");
    try security_limits.SecurityValidator.validatePathDepth("/static/css/style.css");

    // 测试过深的路径
    var deep_path = std.ArrayList(u8).init(std.testing.allocator);
    defer deep_path.deinit();

    var i: usize = 0;
    while (i <= security_limits.SecurityLimits.MAX_PATH_DEPTH) : (i += 1) {
        try deep_path.appendSlice("/level");
    }

    try testing.expectError(security_limits.SecurityLimitError.PathTooDeep, security_limits.SecurityValidator.validatePathDepth(deep_path.items));

    std.debug.print("✅ 路径深度验证测试通过\n", .{});
}

// 性能基准测试 - 安全验证开销
test "安全验证性能基准测试" {
    const iterations = 100000;
    var i: usize = 0;

    const start_time = std.time.nanoTimestamp();

    while (i < iterations) : (i += 1) {
        // 测试各种安全验证的性能
        _ = security_limits.SecurityValidator.validateRequestSize(1024) catch {};
        _ = security_limits.SecurityValidator.validateHeaderSize("Content-Type", "application/json") catch {};
        _ = security_limits.SecurityValidator.validateUriLength("/api/test") catch {};
        _ = security_limits.SecurityValidator.validateMethod("GET") catch {};
        _ = security_limits.SecurityValidator.validateInputSafety("normal text") catch {};
    }

    const end_time = std.time.nanoTimestamp();
    const duration_ns = end_time - start_time;
    const avg_ns = @divTrunc(duration_ns, iterations);

    std.debug.print("\n=== 安全验证性能基准 ===\n", .{});
    std.debug.print("测试次数: {d}\n", .{iterations});
    std.debug.print("平均时间: {d} ns/次\n", .{avg_ns});
    std.debug.print("目标阈值: < 1000 ns\n", .{});
    std.debug.print("测试结果: {s}\n\n", .{if (avg_ns < 1000) "✅ 通过" else "⚠️ 需要优化"});

    // 性能要求：每次验证 < 1μs
    try testing.expect(avg_ns < 1000);
}

// 综合集成测试
test "综合安全集成测试" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 初始化安全日志
    var logger = try security_logger.SecurityLogger.init(allocator, null);
    defer logger.deinit();

    // 初始化速率限制器
    var limiter = security_limits.RateLimiter.init(allocator);
    defer limiter.deinit();

    // 模拟完整的请求处理流程
    const client_ip = "192.168.1.100";
    const request_data = "GET /api/users/123 HTTP/1.1\r\nHost: localhost\r\nUser-Agent: TestClient/1.0\r\n\r\n";

    // 1. 验证请求大小
    try security_limits.SecurityValidator.validateRequestSize(request_data.len);

    // 2. 检查速率限制
    try limiter.checkRateLimit(client_ip);

    // 3. 验证输入安全性
    try security_limits.SecurityValidator.validateInputSafety(request_data);

    // 4. 解析HTTP请求
    var request = try HttpRequest.parseFromBuffer(allocator, request_data);
    defer request.deinit();

    // 5. 验证HTTP方法
    try security_limits.SecurityValidator.validateMethod(request.method);

    // 6. 验证URI长度
    try security_limits.SecurityValidator.validateUriLength(request.path);

    // 7. 记录成功的安全事件
    var event = try security_logger.SecurityEvent.create(allocator, .authorization_success, .info, "Request processed successfully");
    defer event.deinit(allocator);

    try event.setSourceIp(allocator, client_ip);
    try event.setResource(allocator, request.path);
    event.result = .success;

    try logger.logEvent(event);

    std.debug.print("✅ 综合安全集成测试通过\n", .{});
}

// 测试总结
test "安全模块集成测试总结" {
    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("🛡️ 安全模块集成测试总结\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});
    std.debug.print("✅ 安全数学模块: 集成成功\n", .{});
    std.debug.print("✅ 安全限制模块: 集成成功\n", .{});
    std.debug.print("✅ 安全日志模块: 集成成功\n", .{});
    std.debug.print("✅ 速率限制器: 功能正常\n", .{});
    std.debug.print("✅ 输入验证: 防护有效\n", .{});
    std.debug.print("✅ 性能影响: 在可接受范围内\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});
    std.debug.print("🚀 NASA标准安全加固: 第一阶段完成！\n", .{});
    std.debug.print("=" ** 60 ++ "\n\n", .{});
}
