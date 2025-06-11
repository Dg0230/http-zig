# 内存池优化方案

## 🎯 目标
优化当前的缓冲区池系统，实现更高效的内存管理，减少分配开销和内存碎片。

## 🔍 当前问题分析

### 现有实现
```zig
// 当前简单的缓冲区池
pub const BufferPool = struct {
    buffers: ArrayList(Buffer),
    available: ArrayList(usize),
    buffer_size: usize,
    max_buffers: usize,
    allocator: Allocator,
};
```

### 问题
1. **单一大小限制** - 只支持固定大小的缓冲区
2. **分配效率低** - 频繁的malloc/free调用
3. **内存碎片** - 长期运行后内存碎片化严重
4. **缺乏统计** - 无法监控内存使用情况
5. **线程安全开销** - 简单的锁机制影响性能

## 🚀 多级内存池设计

### 核心概念
实现分层的内存池系统，支持多种大小的内存块，减少分配开销和内存碎片。

#### 1. 内存池架构
```zig
pub const MemoryPool = struct {
    allocator: Allocator,

    // 小对象池 (8B - 4KB)
    small_pools: [SMALL_POOL_COUNT]*FixedSizePool,

    // 大对象池 (4KB - 1MB)
    large_pools: [LARGE_POOL_COUNT]*FixedSizePool,

    // 巨大对象直接分配 (>1MB)
    huge_allocations: std.AutoHashMap(*anyopaque, usize),

    // 统计信息
    stats: PoolStats,

    // 线程本地缓存
    thread_caches: std.AutoHashMap(std.Thread.Id, *ThreadCache),

    const SMALL_POOL_COUNT = 16;  // 8, 16, 24, ..., 128 bytes
    const LARGE_POOL_COUNT = 8;   // 4KB, 8KB, 16KB, ..., 1MB

    pub fn init(allocator: Allocator) !*MemoryPool {
        const pool = try allocator.create(MemoryPool);

        // 初始化小对象池
        for (0..SMALL_POOL_COUNT) |i| {
            const size = (i + 1) * 8;
            pool.small_pools[i] = try FixedSizePool.init(allocator, size, 1000);
        }

        // 初始化大对象池
        for (0..LARGE_POOL_COUNT) |i| {
            const size = @as(usize, 4096) << @intCast(i);
            pool.large_pools[i] = try FixedSizePool.init(allocator, size, 100);
        }

        pool.* = MemoryPool{
            .allocator = allocator,
            .small_pools = pool.small_pools,
            .large_pools = pool.large_pools,
            .huge_allocations = std.AutoHashMap(*anyopaque, usize).init(allocator),
            .stats = PoolStats.init(),
            .thread_caches = std.AutoHashMap(std.Thread.Id, *ThreadCache).init(allocator),
        };

        return pool;
    }

    pub fn alloc(self: *MemoryPool, size: usize) !*anyopaque {
        // 更新统计
        self.stats.total_allocations.fetchAdd(1, .monotonic);
        self.stats.total_allocated.fetchAdd(size, .monotonic);

        // 选择合适的池
        if (size <= 128) {
            return try self.allocSmall(size);
        } else if (size <= 1024 * 1024) {
            return try self.allocLarge(size);
        } else {
            return try self.allocHuge(size);
        }
    }

    fn allocSmall(self: *MemoryPool, size: usize) !*anyopaque {
        // 计算池索引 (向上取整到8的倍数)
        const pool_index = (size + 7) / 8 - 1;

        // 尝试从线程本地缓存分配
        if (self.getThreadCache()) |cache| {
            if (cache.tryAlloc(pool_index)) |ptr| {
                return ptr;
            }
        }

        // 从全局池分配
        return try self.small_pools[pool_index].alloc();
    }

    fn allocLarge(self: *MemoryPool, size: usize) !*anyopaque {
        // 找到最小的合适池
        var pool_index: usize = 0;
        var pool_size: usize = 4096;

        while (pool_size < size and pool_index < LARGE_POOL_COUNT) {
            pool_index += 1;
            pool_size <<= 1;
        }

        if (pool_index >= LARGE_POOL_COUNT) {
            return try self.allocHuge(size);
        }

        return try self.large_pools[pool_index].alloc();
    }

    fn allocHuge(self: *MemoryPool, size: usize) !*anyopaque {
        const ptr = try self.allocator.alloc(u8, size);
        try self.huge_allocations.put(ptr.ptr, size);
        return ptr.ptr;
    }
};
```

#### 2. 固定大小内存池
```zig
pub const FixedSizePool = struct {
    allocator: Allocator,
    block_size: usize,
    blocks_per_chunk: usize,
    chunks: ArrayList(*Chunk),
    free_blocks: std.fifo.LinearFifo(*Block, .Dynamic),
    mutex: std.Thread.Mutex,

    const Chunk = struct {
        data: []u8,
        blocks: []Block,

        const Block = struct {
            data: *anyopaque,
            next: ?*Block,
        };
    };

    pub fn init(allocator: Allocator, block_size: usize, initial_blocks: usize) !*FixedSizePool {
        const pool = try allocator.create(FixedSizePool);

        pool.* = FixedSizePool{
            .allocator = allocator,
            .block_size = block_size,
            .blocks_per_chunk = initial_blocks,
            .chunks = ArrayList(*Chunk).init(allocator),
            .free_blocks = std.fifo.LinearFifo(*Block, .Dynamic).init(allocator),
            .mutex = std.Thread.Mutex{},
        };

        // 预分配第一个chunk
        try pool.allocateChunk();

        return pool;
    }

    pub fn alloc(self: *FixedSizePool) !*anyopaque {
        self.mutex.lock();
        defer self.mutex.unlock();

        // 尝试从空闲列表获取
        if (self.free_blocks.readItem()) |block| {
            return block.data;
        }

        // 分配新的chunk
        try self.allocateChunk();

        // 再次尝试
        if (self.free_blocks.readItem()) |block| {
            return block.data;
        }

        return error.OutOfMemory;
    }

    pub fn free(self: *FixedSizePool, ptr: *anyopaque) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // 创建新的空闲块
        const block = self.allocator.create(Chunk.Block) catch return;
        block.* = Chunk.Block{
            .data = ptr,
            .next = null,
        };

        // 添加到空闲列表
        self.free_blocks.writeItem(block) catch return;
    }

    fn allocateChunk(self: *FixedSizePool) !void {
        const chunk_size = self.block_size * self.blocks_per_chunk;
        const data = try self.allocator.alloc(u8, chunk_size);

        const chunk = try self.allocator.create(Chunk);
        chunk.* = Chunk{
            .data = data,
            .blocks = try self.allocator.alloc(Chunk.Block, self.blocks_per_chunk),
        };

        // 初始化所有块并添加到空闲列表
        for (0..self.blocks_per_chunk) |i| {
            const block_ptr = data.ptr + i * self.block_size;
            chunk.blocks[i] = Chunk.Block{
                .data = block_ptr,
                .next = null,
            };

            try self.free_blocks.writeItem(&chunk.blocks[i]);
        }

        try self.chunks.append(chunk);
    }
};
```

#### 3. 线程本地缓存
```zig
pub const ThreadCache = struct {
    small_caches: [MemoryPool.SMALL_POOL_COUNT]LocalCache,
    parent_pool: *MemoryPool,

    const LocalCache = struct {
        free_list: ?*Block,
        count: usize,
        max_count: usize,

        const Block = struct {
            next: ?*Block,
        };

        const MAX_LOCAL_BLOCKS = 64;
    };

    pub fn init(parent_pool: *MemoryPool) !*ThreadCache {
        const cache = try parent_pool.allocator.create(ThreadCache);

        cache.* = ThreadCache{
            .small_caches = [_]LocalCache{LocalCache{
                .free_list = null,
                .count = 0,
                .max_count = LocalCache.MAX_LOCAL_BLOCKS,
            }} ** MemoryPool.SMALL_POOL_COUNT,
            .parent_pool = parent_pool,
        };

        return cache;
    }

    pub fn tryAlloc(self: *ThreadCache, pool_index: usize) ?*anyopaque {
        var cache = &self.small_caches[pool_index];

        if (cache.free_list) |block| {
            cache.free_list = block.next;
            cache.count -= 1;
            return @ptrCast(block);
        }

        return null;
    }

    pub fn tryFree(self: *ThreadCache, pool_index: usize, ptr: *anyopaque) bool {
        var cache = &self.small_caches[pool_index];

        if (cache.count >= cache.max_count) {
            return false; // 缓存已满，需要返回给全局池
        }

        const block: *LocalCache.Block = @ptrCast(@alignCast(ptr));
        block.next = cache.free_list;
        cache.free_list = block;
        cache.count += 1;

        return true;
    }

    pub fn flushToGlobal(self: *ThreadCache, pool_index: usize) void {
        var cache = &self.small_caches[pool_index];
        const pool = self.parent_pool.small_pools[pool_index];

        // 将一半的缓存块返回给全局池
        const flush_count = cache.count / 2;

        for (0..flush_count) |_| {
            if (cache.free_list) |block| {
                cache.free_list = block.next;
                cache.count -= 1;
                pool.free(@ptrCast(block));
            }
        }
    }
};
```

#### 4. 内存统计和监控
```zig
pub const PoolStats = struct {
    total_allocations: atomic.Value(u64),
    total_deallocations: atomic.Value(u64),
    total_allocated: atomic.Value(u64),
    total_freed: atomic.Value(u64),
    peak_usage: atomic.Value(u64),

    // 按池分类的统计
    small_pool_stats: [MemoryPool.SMALL_POOL_COUNT]PoolStat,
    large_pool_stats: [MemoryPool.LARGE_POOL_COUNT]PoolStat,

    const PoolStat = struct {
        allocations: atomic.Value(u64),
        deallocations: atomic.Value(u64),
        current_usage: atomic.Value(u64),
        peak_usage: atomic.Value(u64),
    };

    pub fn init() PoolStats {
        return PoolStats{
            .total_allocations = atomic.Value(u64).init(0),
            .total_deallocations = atomic.Value(u64).init(0),
            .total_allocated = atomic.Value(u64).init(0),
            .total_freed = atomic.Value(u64).init(0),
            .peak_usage = atomic.Value(u64).init(0),
            .small_pool_stats = [_]PoolStat{PoolStat{
                .allocations = atomic.Value(u64).init(0),
                .deallocations = atomic.Value(u64).init(0),
                .current_usage = atomic.Value(u64).init(0),
                .peak_usage = atomic.Value(u64).init(0),
            }} ** MemoryPool.SMALL_POOL_COUNT,
            .large_pool_stats = [_]PoolStat{PoolStat{
                .allocations = atomic.Value(u64).init(0),
                .deallocations = atomic.Value(u64).init(0),
                .current_usage = atomic.Value(u64).init(0),
                .peak_usage = atomic.Value(u64).init(0),
            }} ** MemoryPool.LARGE_POOL_COUNT,
        };
    }

    pub fn getReport(self: *PoolStats) MemoryReport {
        return MemoryReport{
            .total_allocations = self.total_allocations.load(.monotonic),
            .total_deallocations = self.total_deallocations.load(.monotonic),
            .current_usage = self.total_allocated.load(.monotonic) - self.total_freed.load(.monotonic),
            .peak_usage = self.peak_usage.load(.monotonic),
            .fragmentation_ratio = self.calculateFragmentation(),
        };
    }

    fn calculateFragmentation(self: *PoolStats) f64 {
        // 计算内存碎片率
        const total_allocated = self.total_allocated.load(.monotonic);
        const total_used = total_allocated - self.total_freed.load(.monotonic);

        if (total_allocated == 0) return 0.0;

        return @as(f64, @floatFromInt(total_allocated - total_used)) / @as(f64, @floatFromInt(total_allocated));
    }
};

pub const MemoryReport = struct {
    total_allocations: u64,
    total_deallocations: u64,
    current_usage: u64,
    peak_usage: u64,
    fragmentation_ratio: f64,
};
```

## 📊 性能优势

### 分配性能对比
| 操作 | 标准分配器 | 内存池 | 改进 |
|------|------------|--------|------|
| 小对象分配 | ~100ns | ~10ns | 10倍 |
| 大对象分配 | ~500ns | ~50ns | 10倍 |
| 内存碎片 | 高 | 低 | 显著改善 |

### 内存使用优化
- **减少系统调用** - 批量分配减少malloc/free调用
- **降低碎片率** - 固定大小池避免外部碎片
- **提升缓存局部性** - 相邻分配的对象在内存中连续

## 🔧 实现计划

### 阶段1：核心池结构 (1周)
1. 实现FixedSizePool
2. 多级池管理器
3. 基本的分配和释放

### 阶段2：线程优化 (1周)
1. 线程本地缓存
2. 无锁优化
3. 缓存刷新策略

### 阶段3：监控和调优 (1周)
1. 统计系统
2. 性能监控
3. 自动调优机制

## 📈 预期收益

### 性能提升
- 内存分配速度提升10倍
- 减少内存碎片90%
- 降低GC压力（如果使用）

### 资源优化
- 减少系统调用开销
- 提升内存利用率
- 更好的缓存局部性

### 可观测性
- 详细的内存使用统计
- 实时的性能监控
- 自动的性能调优
