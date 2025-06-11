# libxev 集成方案

## 🎯 为什么选择 libxev

libxev 是一个完美的选择来替代我们之前设计的自定义异步I/O系统，原因如下：

### 核心优势
1. **跨平台高性能** - 在不同平台使用最优的事件循环机制
   - Linux: io_uring (最新) 或 epoll (兼容)
   - macOS: kqueue
   - Windows: 计划支持 (IOCP)
   - WASI: poll_oneoff

2. **零运行时分配** - 完全符合我们的性能目标
3. **Proactor模式** - 工作完成通知，而非就绪通知
4. **Zig原生** - 与我们的技术栈完美匹配
5. **生产就绪** - 已被 Ghostty、zml 等大型项目使用

## 🚀 集成设计方案

### 1. 架构重新设计

#### 原有设计 vs libxev集成
```zig
// 原有设计 - 自定义事件循环
pub const EventLoop = struct {
    epoll_fd: i32,
    events: []std.os.linux.epoll_event,
    connections: std.AutoHashMap(i32, *Connection),
    // ...
};

// 新设计 - 基于libxev
const xev = @import("xev");

pub const HttpServer = struct {
    loop: xev.Loop,
    tcp_server: xev.TCP,
    allocator: Allocator,
    router: *Router,
    config: HttpConfig,

    pub fn init(allocator: Allocator, config: HttpConfig) !*HttpServer {
        const server = try allocator.create(HttpServer);
        server.* = HttpServer{
            .loop = try xev.Loop.init(.{}),
            .tcp_server = try xev.TCP.init(),
            .allocator = allocator,
            .router = try Router.init(allocator),
            .config = config,
        };
        return server;
    }

    pub fn listen(self: *HttpServer) !void {
        const addr = try std.net.Address.parseIp(self.config.address, self.config.port);

        // 绑定和监听
        try self.tcp_server.bind(addr);
        try self.tcp_server.listen(self.config.backlog);

        // 开始接受连接
        var accept_completion: xev.Completion = undefined;
        self.tcp_server.accept(&self.loop, &accept_completion, HttpConnection, self, acceptCallback);

        // 运行事件循环
        try self.loop.run(.until_done);
    }

    fn acceptCallback(
        userdata: ?*HttpServer,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.TCP.AcceptError!xev.TCP
    ) xev.CallbackAction {
        const server = userdata.?;
        const client_socket = result catch |err| {
            std.debug.print("Accept error: {any}\n", .{err});
            return .rearm; // 继续接受连接
        };

        // 创建新的连接处理
        const connection = HttpConnection.init(server.allocator, client_socket, server.router) catch {
            client_socket.close();
            return .rearm;
        };

        // 开始读取请求
        connection.startReading(loop);

        return .rearm; // 继续接受新连接
    }
};
```

### 2. HTTP连接处理

#### 基于libxev的连接管理
```zig
pub const HttpConnection = struct {
    socket: xev.TCP,
    allocator: Allocator,
    router: *Router,
    state: ConnectionState,
    read_buffer: []u8,
    write_buffer: std.ArrayList(u8),
    request: ?HttpRequest,
    response: ?HttpResponse,

    const ConnectionState = enum {
        reading_headers,
        reading_body,
        processing,
        writing_response,
        closing,
    };

    pub fn init(allocator: Allocator, socket: xev.TCP, router: *Router) !*HttpConnection {
        const conn = try allocator.create(HttpConnection);
        conn.* = HttpConnection{
            .socket = socket,
            .allocator = allocator,
            .router = router,
            .state = .reading_headers,
            .read_buffer = try allocator.alloc(u8, 8192),
            .write_buffer = std.ArrayList(u8).init(allocator),
            .request = null,
            .response = null,
        };
        return conn;
    }

    pub fn startReading(self: *HttpConnection, loop: *xev.Loop) void {
        var read_completion: xev.Completion = undefined;
        self.socket.read(loop, &read_completion, .{ .slice = self.read_buffer }, HttpConnection, self, readCallback);
    }

    fn readCallback(
        userdata: ?*HttpConnection,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.TCP.ReadError!usize
    ) xev.CallbackAction {
        const conn = userdata.?;
        const bytes_read = result catch |err| {
            std.debug.print("Read error: {any}\n", .{err});
            conn.close();
            return .disarm;
        };

        if (bytes_read == 0) {
            // 连接关闭
            conn.close();
            return .disarm;
        }

        // 处理读取的数据
        conn.processData(loop, bytes_read) catch |err| {
            std.debug.print("Process data error: {any}\n", .{err});
            conn.close();
            return .disarm;
        };

        return switch (conn.state) {
            .reading_headers, .reading_body => .rearm, // 继续读取
            .processing => .disarm, // 等待处理完成
            .writing_response => .disarm, // 开始写响应
            .closing => .disarm,
        };
    }

    fn processData(self: *HttpConnection, loop: *xev.Loop, bytes_read: usize) !void {
        switch (self.state) {
            .reading_headers => {
                // 解析HTTP头
                if (try self.parseHeaders(bytes_read)) {
                    if (self.request.?.hasBody()) {
                        self.state = .reading_body;
                    } else {
                        self.state = .processing;
                        try self.processRequest(loop);
                    }
                }
            },
            .reading_body => {
                // 解析HTTP体
                if (try self.parseBody(bytes_read)) {
                    self.state = .processing;
                    try self.processRequest(loop);
                }
            },
            else => unreachable,
        }
    }

    fn processRequest(self: *HttpConnection, loop: *xev.Loop) !void {
        // 创建响应对象
        self.response = HttpResponse.init(self.allocator);

        // 创建上下文
        var ctx = Context.init(self.allocator, &self.request.?, &self.response.?);
        defer ctx.deinit();

        // 处理路由
        self.router.handleRequest(&ctx) catch |err| {
            // 错误处理
            try self.handleError(&ctx, err);
        };

        // 开始写响应
        try self.startWriting(loop);
    }

    fn startWriting(self: *HttpConnection, loop: *xev.Loop) !void {
        self.state = .writing_response;

        // 序列化响应
        try self.response.?.serialize(self.write_buffer.writer());

        // 开始写入
        var write_completion: xev.Completion = undefined;
        self.socket.write(loop, &write_completion, .{ .slice = self.write_buffer.items }, HttpConnection, self, writeCallback);
    }

    fn writeCallback(
        userdata: ?*HttpConnection,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.TCP.WriteError!usize
    ) xev.CallbackAction {
        const conn = userdata.?;
        const bytes_written = result catch |err| {
            std.debug.print("Write error: {any}\n", .{err});
            conn.close();
            return .disarm;
        };

        // 检查是否写完
        if (bytes_written < conn.write_buffer.items.len) {
            // 继续写入剩余数据
            const remaining = conn.write_buffer.items[bytes_written..];
            var write_completion: xev.Completion = undefined;
            conn.socket.write(loop, &write_completion, .{ .slice = remaining }, HttpConnection, conn, writeCallback);
            return .rearm;
        }

        // 写入完成，关闭连接或保持连接
        if (conn.shouldKeepAlive()) {
            conn.reset();
            conn.startReading(loop);
            return .rearm;
        } else {
            conn.close();
            return .disarm;
        }
    }
};
```

### 3. 定时器和异步任务

#### 利用libxev的定时器
```zig
pub const AsyncTimer = struct {
    timer: xev.Timer,

    pub fn init() !AsyncTimer {
        return AsyncTimer{
            .timer = try xev.Timer.init(),
        };
    }

    pub fn setTimeout(self: *AsyncTimer, loop: *xev.Loop, ms: u64, comptime T: type, userdata: ?*T, callback: fn(?*T, *xev.Loop, *xev.Completion, xev.Timer.RunError!void) xev.CallbackAction) !void {
        var completion: xev.Completion = undefined;
        self.timer.run(loop, &completion, ms, T, userdata, callback);
    }
};

// 使用示例：请求超时处理
fn handleRequestWithTimeout(connection: *HttpConnection, loop: *xev.Loop) !void {
    var timeout_timer = try AsyncTimer.init();
    defer timeout_timer.timer.deinit();

    // 设置30秒超时
    try timeout_timer.setTimeout(loop, 30000, HttpConnection, connection, timeoutCallback);

    // 处理请求...
}

fn timeoutCallback(
    userdata: ?*HttpConnection,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Timer.RunError!void
) xev.CallbackAction {
    const connection = userdata.?;

    if (connection.state != .closing) {
        // 请求超时，关闭连接
        connection.sendTimeoutResponse();
        connection.close();
    }

    return .disarm;
}
```

### 4. 文件操作异步化

#### 利用libxev的文件I/O
```zig
pub const AsyncFileHandler = struct {
    pub fn serveStaticFile(ctx: *Context, file_path: []const u8, loop: *xev.Loop) !void {
        var file = try xev.File.init();
        defer file.deinit();

        // 异步打开文件
        var open_completion: xev.Completion = undefined;
        file.open(loop, &open_completion, file_path, .{}, FileContext, &FileContext{
            .ctx = ctx,
            .file = &file,
        }, openCallback);
    }

    const FileContext = struct {
        ctx: *Context,
        file: *xev.File,
    };

    fn openCallback(
        userdata: ?*FileContext,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.File.OpenError!void
    ) xev.CallbackAction {
        const file_ctx = userdata.?;

        result catch |err| {
            file_ctx.ctx.status(.not_found);
            file_ctx.ctx.text("File not found") catch {};
            return .disarm;
        };

        // 异步读取文件
        var read_buffer = file_ctx.ctx.allocator.alloc(u8, 8192) catch {
            file_ctx.ctx.status(.internal_server_error);
            return .disarm;
        };

        var read_completion: xev.Completion = undefined;
        file_ctx.file.read(loop, &read_completion, .{ .slice = read_buffer }, FileContext, file_ctx, readCallback);

        return .disarm;
    }

    fn readCallback(
        userdata: ?*FileContext,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.File.ReadError!usize
    ) xev.CallbackAction {
        const file_ctx = userdata.?;
        const bytes_read = result catch |err| {
            file_ctx.ctx.status(.internal_server_error);
            file_ctx.ctx.text("Read error") catch {};
            return .disarm;
        };

        // 发送文件内容
        const content = file_ctx.ctx.allocator.dupe(u8, read_buffer[0..bytes_read]) catch {
            file_ctx.ctx.status(.internal_server_error);
            return .disarm;
        };

        file_ctx.ctx.setHeader("Content-Type", "application/octet-stream");
        file_ctx.ctx.text(content) catch {};

        return .disarm;
    }
};
```

## 📊 性能优势

### libxev vs 自定义实现对比

| 特性 | 自定义实现 | libxev集成 | 优势 |
|------|------------|------------|------|
| 开发时间 | 4-6周 | 1-2周 | 节省75%开发时间 |
| 跨平台支持 | 仅Linux | Linux/macOS/Windows/WASI | 全平台支持 |
| 性能优化 | 需要大量调优 | 已优化 | 开箱即用 |
| 维护成本 | 高 | 低 | 专业团队维护 |
| 稳定性 | 需要长期测试 | 生产验证 | 立即可用 |
| 特性完整性 | 基础功能 | 丰富功能 | 功能更全面 |

### 预期性能提升
- **并发连接数**: 100K+ (io_uring优化)
- **延迟**: P99 < 5ms (零分配设计)
- **吞吐量**: 相比当前提升20倍以上
- **内存使用**: 减少60% (高效的事件循环)

## 🔧 集成实施计划

### 第1周：基础集成
- [ ] 添加libxev依赖
- [ ] 重构HttpEngine使用libxev.Loop
- [ ] 实现基础的TCP服务器
- [ ] 基本的连接处理

### 第2周：功能完善
- [ ] HTTP请求解析集成
- [ ] 响应写入优化
- [ ] 错误处理完善
- [ ] Keep-Alive支持

### 第3周：高级特性
- [ ] 定时器集成
- [ ] 文件I/O异步化
- [ ] 信号处理
- [ ] 性能调优

### 第4周：测试和优化
- [ ] 全面的测试覆盖
- [ ] 性能基准测试
- [ ] 内存泄漏检测
- [ ] 文档更新

## 📈 预期收益

### 开发效率
- **减少75%的异步I/O开发时间**
- **零维护成本** - 由专业团队维护
- **更快的迭代速度** - 专注业务逻辑

### 性能提升
- **io_uring支持** - Linux上的最佳性能
- **零分配设计** - 可预测的性能
- **跨平台优化** - 每个平台的最佳实现

### 可靠性
- **生产验证** - 已在大型项目中使用
- **活跃维护** - 持续的bug修复和优化
- **社区支持** - 丰富的文档和示例

## 🎯 结论

集成libxev是一个明智的选择，它能让我们：

1. **专注核心价值** - 将精力投入到HTTP框架的独特特性上
2. **获得最佳性能** - 利用经过优化的事件循环实现
3. **降低风险** - 使用经过生产验证的稳定组件
4. **加速开发** - 大幅减少开发和测试时间

这个集成方案将使我们的Zig HTTP框架在保持高性能的同时，大大提升开发效率和系统稳定性。
