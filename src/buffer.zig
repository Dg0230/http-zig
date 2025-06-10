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

/// 缓冲区池，用于减少内存分配开销
/// 通过重用缓冲区来提高性能，特别适用于高并发场景
pub const BufferPool = struct {
    allocator: Allocator,
    buffers: std.ArrayList(Buffer), // 所有缓冲区的存储
    available: std.ArrayList(usize), // 可用缓冲区的索引列表
    buffer_size: usize, // 每个缓冲区的大小
    max_buffers: usize, // 池中最大缓冲区数量

    pub fn init(allocator: Allocator, buffer_size: usize, max_buffers: usize) !BufferPool {
        return BufferPool{
            .allocator = allocator,
            .buffers = std.ArrayList(Buffer).init(allocator),
            .available = std.ArrayList(usize).init(allocator),
            .buffer_size = buffer_size,
            .max_buffers = max_buffers,
        };
    }

    pub fn deinit(self: *BufferPool) void {
        for (self.buffers.items) |*buffer| {
            buffer.deinit(self.allocator);
        }
        self.buffers.deinit();
        self.available.deinit();
    }

    /// 从池中获取一个可用的缓冲区
    /// 优先返回已存在的缓冲区，必要时创建新的缓冲区
    pub fn acquire(self: *BufferPool) !*Buffer {
        // 优先使用已有的可用缓冲区
        if (self.available.items.len > 0) {
            const index = self.available.pop().?;
            return &self.buffers.items[index];
        }

        // 在限制范围内创建新缓冲区
        if (self.buffers.items.len < self.max_buffers) {
            const buffer = try Buffer.init(self.allocator, self.buffer_size);
            try self.buffers.append(buffer);
            return &self.buffers.items[self.buffers.items.len - 1];
        }

        return error.BufferPoolExhausted;
    }

    /// 将缓冲区归还到池中以供重用
    /// 缓冲区会被重置并标记为可用状态
    pub fn release(self: *BufferPool, buffer: *Buffer) !void {
        // 验证缓冲区属于此池
        const index = blk: {
            for (self.buffers.items, 0..) |*b, i| {
                if (b == buffer) {
                    break :blk i;
                }
            }
            return error.BufferNotInPool;
        };

        // 清理缓冲区并标记为可用
        buffer.reset();
        try self.available.append(index);
    }
};
