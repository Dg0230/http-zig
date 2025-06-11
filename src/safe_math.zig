// 安全算术运算模块 - NASA标准安全加固
// 防止整数溢出、除零错误等算术安全问题

const std = @import("std");
const testing = std.testing;

/// 安全算术运算错误类型
pub const SafeMathError = error{
    IntegerOverflow,
    IntegerUnderflow,
    DivisionByZero,
    InvalidInput,
};

/// 安全加法运算
/// 检测整数溢出，确保运算安全
pub fn safeAdd(comptime T: type, a: T, b: T) SafeMathError!T {
    return std.math.add(T, a, b) catch SafeMathError.IntegerOverflow;
}

/// 安全减法运算
/// 检测整数下溢，确保运算安全
pub fn safeSub(comptime T: type, a: T, b: T) SafeMathError!T {
    return std.math.sub(T, a, b) catch SafeMathError.IntegerUnderflow;
}

/// 安全乘法运算
/// 检测整数溢出，确保运算安全
pub fn safeMul(comptime T: type, a: T, b: T) SafeMathError!T {
    return std.math.mul(T, a, b) catch SafeMathError.IntegerOverflow;
}

/// 安全除法运算
/// 检测除零错误，确保运算安全
pub fn safeDiv(comptime T: type, a: T, b: T) SafeMathError!T {
    if (b == 0) return SafeMathError.DivisionByZero;
    return @divTrunc(a, b);
}

/// 安全模运算
/// 检测除零错误，确保运算安全
pub fn safeMod(comptime T: type, a: T, b: T) SafeMathError!T {
    if (b == 0) return SafeMathError.DivisionByZero;
    return @mod(a, b);
}

/// 安全左移运算
/// 检测移位溢出，确保运算安全
pub fn safeShl(comptime T: type, a: T, shift: u8) SafeMathError!T {
    const bit_count = @bitSizeOf(T);
    if (shift >= bit_count) return SafeMathError.IntegerOverflow;

    // 检查是否会溢出
    const max_shift = bit_count - 1;
    if (shift > max_shift) return SafeMathError.IntegerOverflow;

    // 检查左移后是否会溢出
    const shifted_bits = @as(T, 1) << @intCast(shift);
    if (a > @divTrunc(std.math.maxInt(T), shifted_bits)) {
        return SafeMathError.IntegerOverflow;
    }

    return a << @intCast(shift);
}

/// 安全右移运算
/// 确保移位操作的安全性
pub fn safeShr(comptime T: type, a: T, shift: u8) SafeMathError!T {
    const bit_count = @bitSizeOf(T);
    if (shift >= bit_count) return SafeMathError.InvalidInput;
    return a >> @intCast(shift);
}

/// 检查值是否在指定范围内
pub fn checkRange(comptime T: type, value: T, min_val: T, max_val: T) SafeMathError!T {
    if (value < min_val or value > max_val) {
        return SafeMathError.InvalidInput;
    }
    return value;
}

/// 安全的平均值计算
/// 避免中间结果溢出
pub fn safeAverage(comptime T: type, a: T, b: T) SafeMathError!T {
    // 使用 (a + b) / 2 的安全版本: a/2 + b/2 + (a%2 + b%2)/2
    const half_a = @divTrunc(a, 2);
    const half_b = @divTrunc(b, 2);
    const remainder = @divTrunc(@mod(a, 2) + @mod(b, 2), 2);

    return try safeAdd(T, try safeAdd(T, half_a, half_b), remainder);
}

/// 安全的数组索引计算
pub fn safeIndex(index: usize, array_len: usize) SafeMathError!usize {
    if (index >= array_len) return SafeMathError.InvalidInput;
    return index;
}

/// 安全的缓冲区大小计算
pub fn safeBufferSize(item_count: usize, item_size: usize) SafeMathError!usize {
    return try safeMul(usize, item_count, item_size);
}

// ============================================================================
// 测试用例
// ============================================================================

test "安全加法测试" {
    // 正常情况
    try testing.expect(try safeAdd(u32, 100, 200) == 300);

    // 溢出检测
    try testing.expectError(SafeMathError.IntegerOverflow, safeAdd(u8, 255, 1));
    try testing.expectError(SafeMathError.IntegerOverflow, safeAdd(u32, std.math.maxInt(u32), 1));
}

test "安全减法测试" {
    // 正常情况
    try testing.expect(try safeSub(u32, 300, 100) == 200);

    // 下溢检测
    try testing.expectError(SafeMathError.IntegerUnderflow, safeSub(u8, 0, 1));
    try testing.expectError(SafeMathError.IntegerUnderflow, safeSub(u32, 100, 200));
}

test "安全乘法测试" {
    // 正常情况
    try testing.expect(try safeMul(u32, 100, 200) == 20000);

    // 溢出检测
    try testing.expectError(SafeMathError.IntegerOverflow, safeMul(u8, 16, 16));
    try testing.expectError(SafeMathError.IntegerOverflow, safeMul(u32, std.math.maxInt(u32), 2));
}

test "安全除法测试" {
    // 正常情况
    try testing.expect(try safeDiv(u32, 300, 100) == 3);

    // 除零检测
    try testing.expectError(SafeMathError.DivisionByZero, safeDiv(u32, 100, 0));
}

test "安全模运算测试" {
    // 正常情况
    try testing.expect(try safeMod(u32, 300, 100) == 0);
    try testing.expect(try safeMod(u32, 301, 100) == 1);

    // 除零检测
    try testing.expectError(SafeMathError.DivisionByZero, safeMod(u32, 100, 0));
}

test "安全移位测试" {
    // 正常情况
    try testing.expect(try safeShl(u32, 1, 8) == 256);
    try testing.expect(try safeShr(u32, 256, 8) == 1);

    // 溢出检测
    try testing.expectError(SafeMathError.IntegerOverflow, safeShl(u32, 1, 32));
    try testing.expectError(SafeMathError.InvalidInput, safeShr(u32, 256, 32));
}

test "范围检查测试" {
    // 正常情况
    try testing.expect(try checkRange(u32, 50, 0, 100) == 50);

    // 范围错误
    try testing.expectError(SafeMathError.InvalidInput, checkRange(u32, 150, 0, 100));
    try testing.expectError(SafeMathError.InvalidInput, checkRange(i32, -50, 0, 100));
}

test "安全平均值测试" {
    // 正常情况
    try testing.expect(try safeAverage(u32, 100, 200) == 150);
    try testing.expect(try safeAverage(u32, 101, 200) == 150);

    // 避免溢出的大数平均
    const large1 = std.math.maxInt(u32) - 1;
    const large2 = std.math.maxInt(u32) - 3;
    const avg = try safeAverage(u32, large1, large2);
    try testing.expect(avg == large1 - 1);
}

test "安全索引测试" {
    // 正常情况
    try testing.expect(try safeIndex(5, 10) == 5);

    // 越界检测
    try testing.expectError(SafeMathError.InvalidInput, safeIndex(10, 10));
    try testing.expectError(SafeMathError.InvalidInput, safeIndex(15, 10));
}

test "安全缓冲区大小测试" {
    // 正常情况
    try testing.expect(try safeBufferSize(100, 8) == 800);

    // 溢出检测
    const large_count = std.math.maxInt(usize) / 2 + 1;
    try testing.expectError(SafeMathError.IntegerOverflow, safeBufferSize(large_count, 2));
}

// ============================================================================
// 性能基准测试
// ============================================================================

test "安全算术性能基准" {
    const iterations = 1000000;
    var i: usize = 0;

    const start_time = std.time.nanoTimestamp();

    while (i < iterations) : (i += 1) {
        _ = try safeAdd(u32, @as(u32, @intCast(i % 1000)), @as(u32, @intCast(i % 500)));
        _ = try safeMul(u32, @as(u32, @intCast(i % 100)), @as(u32, @intCast(i % 50)));
        _ = try safeDiv(u32, @as(u32, @intCast(i % 1000 + 1)), @as(u32, @intCast(i % 10 + 1)));
    }

    const end_time = std.time.nanoTimestamp();
    const duration_ns = end_time - start_time;
    const avg_ns = @divTrunc(duration_ns, iterations);

    std.debug.print("\n=== 安全算术性能基准 ===\n", .{});
    std.debug.print("测试次数: {d}\n", .{iterations});
    std.debug.print("平均时间: {d} ns/次\n", .{avg_ns});
    std.debug.print("目标阈值: < 100 ns\n", .{});
    std.debug.print("测试结果: {s}\n\n", .{if (avg_ns < 100) "✅ 通过" else "⚠️ 需要优化"});
}
