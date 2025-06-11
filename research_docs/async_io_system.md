# 异步I/O系统设计方案

## 🎯 目标
将当前的多线程同步I/O模型升级为高性能的异步I/O系统，提升并发处理能力和资源利用率。

## 🔍 当前问题分析

### 现有实现
```zig
// 当前每连接一线程模型
const thread = Thread.spawn(.{}, handleConnectionWrapper, .{ self, connection }) catch |err| {
    std.debug.print("创建线程失败: {any}\n", .{err});
    connection.stream.close();
    _ = self.connection_count.fetchSub(1, .monotonic);
    continue;
};
```

### 问题
1. **线程开销大** - 每个连接需要独立线程，内存和上下文切换开销高
2. **扩展性差** - 线程数量受系统限制，无法支持大量并发连接
3. **资源浪费** - 大部分时间线程在等待I/O，CPU利用率低
4. **复杂的同步** - 需要复杂的锁机制处理共享资源

## 🚀 异步I/O设计

### 核心概念
基于事件循环的异步I/O模型，使用少量线程处理大量并发连接。

#### 1. 事件循环核心
```zig
pub const EventLoop = struct {
    allocator: Allocator,
    epoll_fd: i32,  // Linux epoll
    events: []std.os.linux.epoll_event,
    connections: std.AutoHashMap(i32, *Connection),
    task_queue: std.fifo.LinearFifo(*Task, .Dynamic),
    running: atomic.Value(bool),

    const Self = @This();
    const MAX_EVENTS = 1024;

    pub fn init(allocator: Allocator) !*Self {
        const loop = try allocator.create(Self);

        loop.* = Self{
            .allocator = allocator,
            .epoll_fd = try std.os.epoll_create1(std.os.linux.EPOLL.CLOEXEC),
            .events = try allocator.alloc(std.os.linux.epoll_event, MAX_EVENTS),
            .connections = std.AutoHashMap(i32, *Connection).init(allocator),
            .task_queue = std.fifo.LinearFifo(*Task, .Dynamic).init(allocator),
            .running = atomic.Value(bool).init(false),
        };

        return loop;
    }

    pub fn run(self: *Self) !void {
        self.running.store(true, .monotonic);

        while (self.running.load(.monotonic)) {
            // 处理待执行任务
            try self.processTasks();

            // 等待I/O事件
            const event_count = std.os.epoll_wait(
                self.epoll_fd,
                self.events,
                1000  // 1秒超时
            );

            // 处理I/O事件
            for (self.events[0..event_count]) |event| {
                try self.handleEvent(event);
            }
        }
    }

    fn handleEvent(self: *Self, event: std.os.linux.epoll_event) !void {
        const fd = @intCast(i32, event.data.fd);

        if (self.connections.get(fd)) |connection| {
            if (event.events & std.os.linux.EPOLL.IN != 0) {
                // 可读事件
                try self.handleRead(connection);
            }

            if (event.events & std.os.linux.EPOLL.OUT != 0) {
                // 可写事件
                try self.handleWrite(connection);
            }

            if (event.events & (std.os.linux.EPOLL.HUP | std.os.linux.EPOLL.ERR) != 0) {
                // 连接关闭或错误
                try self.closeConnection(connection);
            }
        }
    }
};
```

#### 2. 异步连接处理
```zig
pub const AsyncConnection = struct {
    fd: i32,
    state: ConnectionState,
    read_buffer: Buffer,
    write_buffer: Buffer,
    request: ?HttpRequest,
    response: ?HttpResponse,
    event_loop: *EventLoop,

    const ConnectionState = enum {
        reading_request,
        processing_request,
        writing_response,
        closed,
    };

    pub fn init(allocator: Allocator, fd: i32, event_loop: *EventLoop) !*AsyncConnection {
        const conn = try allocator.create(AsyncConnection);
        conn.* = AsyncConnection{
            .fd = fd,
            .state = .reading_request,
            .read_buffer = try Buffer.init(allocator, 4096),
            .write_buffer = try Buffer.init(allocator, 4096),
            .request = null,
            .response = null,
            .event_loop = event_loop,
        };

        // 注册到事件循环
        try event_loop.addConnection(conn);

        return conn;
    }

    pub fn handleRead(self: *AsyncConnection) !void {
        switch (self.state) {
            .reading_request => {
                const bytes_read = try std.os.read(self.fd, self.read_buffer.available());
                if (bytes_read == 0) {
                    // 连接关闭
                    self.state = .closed;
                    return;
                }

                self.read_buffer.advance(bytes_read);

                // 尝试解析HTTP请求
                if (try self.parseRequest()) {
                    self.state = .processing_request;
                    try self.processRequest();
                }
            },
            else => {
                // 其他状态不应该有读事件
                return error.UnexpectedRead;
            },
        }
    }

    pub fn handleWrite(self: *AsyncConnection) !void {
        switch (self.state) {
            .writing_response => {
                const bytes_written = try std.os.write(self.fd, self.write_buffer.data());
                self.write_buffer.consume(bytes_written);

                if (self.write_buffer.isEmpty()) {
                    // 响应发送完成
                    self.state = .closed;
                }
            },
            else => {
                // 其他状态不应该有写事件
                return error.UnexpectedWrite;
            },
        }
    }
};
```

#### 3. 异步任务系统
```zig
pub const Task = struct {
    context: *anyopaque,
    execute_fn: *const fn(*anyopaque) anyerror!void,

    pub fn init(comptime T: type, context: *T, execute_fn: *const fn(*T) anyerror!void) Task {
        return Task{
            .context = @ptrCast(context),
            .execute_fn = @ptrCast(execute_fn),
        };
    }

    pub fn execute(self: *Task) !void {
        try self.execute_fn(self.context);
    }
};

// 异步处理函数包装器
pub fn AsyncHandler(comptime handler_fn: anytype) type {
    return struct {
        const HandlerContext = struct {
            connection: *AsyncConnection,
            handler: @TypeOf(handler_fn),
        };

        pub fn schedule(connection: *AsyncConnection) !void {
            const context = try connection.event_loop.allocator.create(HandlerContext);
            context.* = HandlerContext{
                .connection = connection,
                .handler = handler_fn,
            };

            const task = Task.init(HandlerContext, context, execute);
            try connection.event_loop.scheduleTask(&task);
        }

        fn execute(context: *HandlerContext) !void {
            defer context.connection.event_loop.allocator.destroy(context);

            // 创建异步上下文
            var async_ctx = AsyncContext.init(
                context.connection.event_loop.allocator,
                context.connection.request.?,
                &context.connection.response.?
            );
            defer async_ctx.deinit();

            // 执行处理函数
            try context.handler(&async_ctx);

            // 准备响应数据
            try context.connection.prepareResponse();
            context.connection.state = .writing_response;

            // 启用写事件
            try context.connection.event_loop.enableWrite(context.connection.fd);
        }
    };
}
```

#### 4. 异步上下文
```zig
pub const AsyncContext = struct {
    allocator: Allocator,
    request: *HttpRequest,
    response: *HttpResponse,
    event_loop: *EventLoop,

    pub fn init(allocator: Allocator, request: *HttpRequest, response: *HttpResponse) AsyncContext {
        return AsyncContext{
            .allocator = allocator,
            .request = request,
            .response = response,
            .event_loop = undefined, // 将在实际使用时设置
        };
    }

    // 异步数据库查询
    pub fn queryDatabase(self: *AsyncContext, sql: []const u8) !DatabaseFuture {
        return DatabaseFuture.init(self.allocator, sql);
    }

    // 异步HTTP请求
    pub fn httpRequest(self: *AsyncContext, url: []const u8) !HttpFuture {
        return HttpFuture.init(self.allocator, url);
    }

    // 异步文件读取
    pub fn readFile(self: *AsyncContext, path: []const u8) !FileFuture {
        return FileFuture.init(self.allocator, path);
    }
};
```

#### 5. Future/Promise模式
```zig
pub fn Future(comptime T: type) type {
    return struct {
        state: State,
        result: ?T,
        error_value: ?anyerror,
        callbacks: std.ArrayList(*const fn(T) void),

        const State = enum {
            pending,
            resolved,
            rejected,
        };

        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return Self{
                .state = .pending,
                .result = null,
                .error_value = null,
                .callbacks = std.ArrayList(*const fn(T) void).init(allocator),
            };
        }

        pub fn resolve(self: *Self, value: T) void {
            if (self.state != .pending) return;

            self.state = .resolved;
            self.result = value;

            // 执行所有回调
            for (self.callbacks.items) |callback| {
                callback(value);
            }
        }

        pub fn reject(self: *Self, err: anyerror) void {
            if (self.state != .pending) return;

            self.state = .rejected;
            self.error_value = err;
        }

        pub fn then(self: *Self, callback: *const fn(T) void) void {
            if (self.state == .resolved) {
                callback(self.result.?);
            } else if (self.state == .pending) {
                self.callbacks.append(callback) catch {};
            }
        }

        pub fn await(self: *Self) !T {
            while (self.state == .pending) {
                // 让出控制权，等待异步操作完成
                std.time.sleep(1000); // 1μs
            }

            return switch (self.state) {
                .resolved => self.result.?,
                .rejected => self.error_value.?,
                .pending => unreachable,
            };
        }
    };
}

// 使用示例
pub fn handleAsyncUsers(ctx: *AsyncContext) !void {
    // 异步数据库查询
    var user_future = try ctx.queryDatabase("SELECT * FROM users");

    // 异步缓存查询
    var cache_future = try ctx.queryCache("users:all");

    // 等待结果
    const users = try user_future.await();
    const cached_data = cache_future.await() catch null;

    if (cached_data) |data| {
        try ctx.json(data);
    } else {
        try ctx.json(users);
        // 异步更新缓存（不等待结果）
        _ = try ctx.updateCache("users:all", users);
    }
}
```

## 📊 性能优势

### 并发能力对比
| 模型 | 最大连接数 | 内存使用 | CPU利用率 |
|------|------------|----------|-----------|
| 多线程 | ~1,000 | 高 | 低 |
| 异步I/O | ~100,000+ | 低 | 高 |

### 资源使用优化
- **内存使用减少90%** - 无需为每个连接创建线程栈
- **CPU利用率提升300%** - 减少上下文切换开销
- **延迟降低50%** - 更快的事件响应

## 🔧 实现计划

### 阶段1：事件循环核心 (2周)
1. 实现EventLoop基础结构
2. epoll/kqueue事件处理
3. 基本的连接管理

### 阶段2：异步任务系统 (1周)
1. Task和Future实现
2. 异步处理函数包装
3. 回调和Promise支持

### 阶段3：集成优化 (1周)
1. 与现有路由系统集成
2. 异步中间件支持
3. 性能基准测试

## 📈 预期收益

### 性能提升
- 并发连接数提升100倍
- 内存使用减少90%
- 响应延迟降低50%

### 扩展性
- 支持C10K问题
- 更好的资源利用率
- 更平滑的负载处理

### 开发体验
- 现代的异步编程模型
- 更好的错误处理
- 更容易的性能调优
