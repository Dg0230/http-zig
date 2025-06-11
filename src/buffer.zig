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
/// 线程安全版本，使用互斥锁和原子操作
pub const BufferPool = struct {
    allocator: Allocator,
    buffers: std.ArrayList(Buffer),
    available: std.ArrayList(usize), // 可用缓冲区索引
    mutex: std.Thread.Mutex, // 添加互斥锁保护共享状态
    buffer_size: usize,
    max_buffers: usize,

    // 统计信息 - 使用原子操作
    total_acquired: std.atomic.Value(usize),
    total_released: std.atomic.Value(usize),
    peak_usage: std.atomic.Value(usize),

    pub fn init(allocator: Allocator, buffer_size: usize, max_buffers: usize) !BufferPool {
        return BufferPool{
            .allocator = allocator,
            .buffers = std.ArrayList(Buffer).init(allocator),
            .available = std.ArrayList(usize).init(allocator),
            .mutex = std.Thread.Mutex{},
            .buffer_size = buffer_size,
            .max_buffers = max_buffers,
            .total_acquired = std.atomic.Value(usize).init(0),
            .total_released = std.atomic.Value(usize).init(0),
            .peak_usage = std.atomic.Value(usize).init(0),
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
    /// 线程安全版本
    pub fn acquire(self: *BufferPool) !*Buffer {
        // 原子操作更新统计
        _ = self.total_acquired.fetchAdd(1, .monotonic);

        // 使用互斥锁保护共享状态
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.available.items.len > 0) {
            const index = self.available.pop().?;
            return &self.buffers.items[index];
        }

        if (self.buffers.items.len < self.max_buffers) {
            const buffer = try Buffer.init(self.allocator, self.buffer_size);
            try self.buffers.append(buffer);

            // 安全计算当前使用量
            const current_usage = if (self.buffers.items.len >= self.available.items.len)
                self.buffers.items.len - self.available.items.len
            else
                0;

            // 原子操作更新峰值使用量
            var current_peak = self.peak_usage.load(.monotonic);
            while (current_usage > current_peak) {
                const result = self.peak_usage.cmpxchgWeak(current_peak, current_usage, .monotonic, .monotonic);
                if (result == null) break; // 成功更新
                current_peak = result.?; // 重试
            }

            return &self.buffers.items[self.buffers.items.len - 1];
        }

        return error.BufferPoolExhausted;
    }

    /// 释放缓冲区回池中
    /// 线程安全版本
    pub fn release(self: *BufferPool, buffer: *Buffer) !void {
        // 原子操作更新统计
        _ = self.total_released.fetchAdd(1, .monotonic);

        // 使用互斥锁保护共享状态
        self.mutex.lock();
        defer self.mutex.unlock();

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
    /// 线程安全版本
    pub fn getStats(self: *BufferPool) BufferPoolStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        const used_buffers = if (self.buffers.items.len >= self.available.items.len)
            self.buffers.items.len - self.available.items.len
        else
            0;

        return BufferPoolStats{
            .total_buffers = self.buffers.items.len,
            .available_buffers = self.available.items.len,
            .used_buffers = used_buffers,
            .total_acquired = self.total_acquired.load(.monotonic),
            .total_released = self.total_released.load(.monotonic),
            .peak_usage = self.peak_usage.load(.monotonic),
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
