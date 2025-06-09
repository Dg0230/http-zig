const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Buffer = struct {
    data: []u8,
    len: usize,

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

    pub fn slice(self: *const Buffer) []const u8 {
        return self.data[0..self.len];
    }

    pub fn reset(self: *Buffer) void {
        self.len = 0;
    }
};

pub const BufferPool = struct {
    allocator: Allocator,
    buffers: std.ArrayList(Buffer),
    available: std.ArrayList(usize),
    buffer_size: usize,
    max_buffers: usize,

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

    pub fn acquire(self: *BufferPool) !*Buffer {
        // 如果有可用的缓冲区，返回它
        if (self.available.items.len > 0) {
            const index = self.available.pop();
            return &self.buffers.items[index];
        }

        // 如果没有达到最大缓冲区数量，创建新的缓冲区
        if (self.buffers.items.len < self.max_buffers) {
            const buffer = try Buffer.init(self.allocator, self.buffer_size);
            try self.buffers.append(buffer);
            return &self.buffers.items[self.buffers.items.len - 1];
        }

        return error.BufferPoolExhausted;
    }

    pub fn release(self: *BufferPool, buffer: *Buffer) !void {
        // 查找缓冲区在池中的索引
        const index = blk: {
            for (self.buffers.items, 0..) |*b, i| {
                if (b == buffer) {
                    break :blk i;
                }
            }
            return error.BufferNotInPool;
        };

        // 重置缓冲区并标记为可用
        buffer.reset();
        try self.available.append(index);
    }
};
