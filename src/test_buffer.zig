const std = @import("std");
const testing = std.testing;
const Buffer = @import("buffer.zig").Buffer;
const BufferPool = @import("buffer.zig").BufferPool;

test "Buffer 初始化和基本操作" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 测试 Buffer 初始化
    var buffer = try Buffer.init(allocator, 1024);
    defer buffer.deinit(allocator);

    // 验证初始状态
    try testing.expect(buffer.data.len == 1024);
    try testing.expect(buffer.len == 0);

    // 测试 slice 方法
    const slice = buffer.slice();
    try testing.expect(slice.len == 0);

    // 模拟写入数据
    const test_data = "Hello, World!";
    @memcpy(buffer.data[0..test_data.len], test_data);
    buffer.len = test_data.len;

    // 验证数据
    const data_slice = buffer.slice();
    try testing.expectEqualStrings(test_data, data_slice);

    // 测试重置
    buffer.reset();
    try testing.expect(buffer.len == 0);
    try testing.expect(buffer.slice().len == 0);
}

test "BufferPool 初始化和基本操作" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 测试 BufferPool 初始化
    var pool = try BufferPool.init(allocator, 512, 3);
    defer pool.deinit();

    // 验证初始状态
    try testing.expect(pool.buffer_size == 512);
    try testing.expect(pool.max_buffers == 3);
    try testing.expect(pool.buffers.items.len == 0);
    try testing.expect(pool.available.items.len == 0);
}

test "BufferPool 获取和释放缓冲区" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = try BufferPool.init(allocator, 256, 2);
    defer pool.deinit();

    // 获取第一个缓冲区
    const buffer1 = try pool.acquire();
    try testing.expect(buffer1.data.len == 256);
    try testing.expect(buffer1.len == 0);
    try testing.expect(pool.buffers.items.len == 1);

    // 获取第二个缓冲区
    const buffer2 = try pool.acquire();
    try testing.expect(buffer2.data.len == 256);
    try testing.expect(pool.buffers.items.len == 2);

    // 尝试获取第三个缓冲区（应该失败）
    try testing.expectError(error.BufferPoolExhausted, pool.acquire());

    // 释放第一个缓冲区
    try pool.release(buffer1);
    try testing.expect(pool.available.items.len == 1);

    // 再次获取缓冲区（应该重用已释放的）
    const buffer3 = try pool.acquire();
    try testing.expect(buffer3 == buffer1); // 应该是同一个缓冲区
    try testing.expect(pool.available.items.len == 0);
}

test "BufferPool 缓冲区重置" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = try BufferPool.init(allocator, 128, 1);
    defer pool.deinit();

    // 获取缓冲区并写入数据
    const buffer = try pool.acquire();
    const test_data = "Test data";
    @memcpy(buffer.data[0..test_data.len], test_data);
    buffer.len = test_data.len;

    // 验证数据已写入
    try testing.expectEqualStrings(test_data, buffer.slice());

    // 释放缓冲区
    try pool.release(buffer);

    // 重新获取缓冲区，应该已被重置
    const reused_buffer = try pool.acquire();
    try testing.expect(reused_buffer == buffer);
    try testing.expect(reused_buffer.len == 0);
}

test "BufferPool 错误处理" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = try BufferPool.init(allocator, 64, 1);
    defer pool.deinit();

    // 创建一个不属于池的缓冲区
    var external_buffer = try Buffer.init(allocator, 64);
    defer external_buffer.deinit(allocator);

    // 尝试释放不属于池的缓冲区
    try testing.expectError(error.BufferNotInPool, pool.release(&external_buffer));
}

test "Buffer 边界情况" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 测试零大小缓冲区
    var zero_buffer = try Buffer.init(allocator, 0);
    defer zero_buffer.deinit(allocator);

    try testing.expect(zero_buffer.data.len == 0);
    try testing.expect(zero_buffer.len == 0);
    try testing.expect(zero_buffer.slice().len == 0);

    // 测试大缓冲区
    var large_buffer = try Buffer.init(allocator, 1024 * 1024);
    defer large_buffer.deinit(allocator);

    try testing.expect(large_buffer.data.len == 1024 * 1024);
    try testing.expect(large_buffer.len == 0);
}

test "BufferPool 边界情况" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 测试最大缓冲区数为0的池
    var zero_pool = try BufferPool.init(allocator, 128, 0);
    defer zero_pool.deinit();

    // 应该立即失败
    try testing.expectError(error.BufferPoolExhausted, zero_pool.acquire());

    // 测试最大缓冲区数为1的池
    var single_pool = try BufferPool.init(allocator, 64, 1);
    defer single_pool.deinit();

    const buffer = try single_pool.acquire();
    try testing.expectError(error.BufferPoolExhausted, single_pool.acquire());

    try single_pool.release(buffer);
    const reused = try single_pool.acquire();
    try testing.expect(reused == buffer);
}
