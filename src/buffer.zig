const std = @import("std");
const Allocator = std.mem.Allocator;

/// 可重用的字节缓冲区，用于高效的内存管理
/// 维护一个固定大小的缓冲区和当前使用长度
pub const Buffer = struct {
    data: []u8, // 底层数据存储
    len: usize, // 当前有效数据长度

    pub fn init(allocator: Allocator, size: usize) !Buffer {
        const data = try allocator.alloc(u8, size);
        return Buffer{
            .data = data,
            .len = 0,
        };
    }

    pub fn deinit(self: *Buffer, allocator: Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }

    /// 获取当前有效数据的只读切片
    pub fn slice(self: *const Buffer) []const u8 {
        return self.data[0..self.len];
    }

    /// 重置缓冲区，清空所有数据但保留底层存储
    pub fn reset(self: *Buffer) void {
        self.len = 0;
    }
};

/// 缓冲区池，重用缓冲区减少内存分配
pub const BufferPool = struct {
    allocator: Allocator,
    buffers: std.ArrayList(Buffer),
    available: std.ArrayList(usize), // 可用缓冲区索引
    buffer_size: usize,
    max_buffers: usize,

    // 统计信息
    total_acquired: usize,
    total_released: usize,
    peak_usage: usize,

    pub fn init(allocator: Allocator, buffer_size: usize, max_buffers: usize) !BufferPool {
        return BufferPool{
            .allocator = allocator,
            .buffers = std.ArrayList(Buffer).init(allocator),
            .available = std.ArrayList(usize).init(allocator),
            .buffer_size = buffer_size,
            .max_buffers = max_buffers,
            .total_acquired = 0,
            .total_released = 0,
            .peak_usage = 0,
        };
    }

    pub fn deinit(self: *BufferPool) void {
        for (self.buffers.items) |*buffer| {
            buffer.deinit(self.allocator);
        }
        self.buffers.deinit();
        self.available.deinit();
    }

    /// 获取缓冲区，优先复用已有缓冲区
    pub fn acquire(self: *BufferPool) !*Buffer {
        self.total_acquired += 1;

        if (self.available.items.len > 0) {
            const index = self.available.pop().?;
            return &self.buffers.items[index];
        }

        if (self.buffers.items.len < self.max_buffers) {
            const buffer = try Buffer.init(self.allocator, self.buffer_size);
            try self.buffers.append(buffer);

            const current_usage = self.buffers.items.len - self.available.items.len;
            if (current_usage > self.peak_usage) {
                self.peak_usage = current_usage;
            }

            return &self.buffers.items[self.buffers.items.len - 1];
        }

        return error.BufferPoolExhausted;
    }

    /// 释放缓冲区回池中
    pub fn release(self: *BufferPool, buffer: *Buffer) !void {
        self.total_released += 1;

        const index = blk: {
            for (self.buffers.items, 0..) |*b, i| {
                if (b == buffer) {
                    break :blk i;
                }
            }
            return error.BufferNotInPool;
        };

        // 检查缓冲区是否已经在可用列表中（防止重复释放）
        for (self.available.items) |available_index| {
            if (available_index == index) {
                return error.BufferAlreadyReleased;
            }
        }

        buffer.reset();
        try self.available.append(index);
    }

    /// 获取统计信息
    pub fn getStats(self: *BufferPool) BufferPoolStats {
        return BufferPoolStats{
            .total_buffers = self.buffers.items.len,
            .available_buffers = self.available.items.len,
            .used_buffers = self.buffers.items.len - self.available.items.len,
            .total_acquired = self.total_acquired,
            .total_released = self.total_released,
            .peak_usage = self.peak_usage,
        };
    }
};

/// 缓冲区池统计
pub const BufferPoolStats = struct {
    total_buffers: usize,
    available_buffers: usize,
    used_buffers: usize,
    total_acquired: usize,
    total_released: usize,
    peak_usage: usize,
};
