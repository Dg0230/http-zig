# 洋葱模型中间件系统设计方案

## 🎯 目标
将当前的顺序执行中间件改进为真正的洋葱模型，实现请求从外层进入、响应从内层返回的执行流程。

## 🔍 当前问题分析

### 现有实现
```zig
// 当前简化实现：顺序执行所有中间件
for (self.middlewares.items) |middleware| {
    const next_fn = struct {
        fn next(ctx2: *Context) !void {
            _ = ctx2; // 简化实现，不做任何事
        }
    }.next;

    try middleware(ctx, next_fn);
}
```

### 问题
1. **next()函数无效** - 不能真正传递控制权
2. **无法回溯** - 响应阶段无法执行中间件
3. **错误处理困难** - 无法在中间件链中捕获和处理错误

## 🚀 洋葱模型设计

### 核心概念
```
请求 → 中间件1 → 中间件2 → 中间件3 → 处理函数
响应 ← 中间件1 ← 中间件2 ← 中间件3 ← 处理函数
```

### 实现方案

#### 1. 中间件上下文结构
```zig
pub const MiddlewareContext = struct {
    index: usize,
    middlewares: []const MiddlewareFn,
    handler: ?HandlerFn,
    ctx: *Context,

    pub fn next(self: *MiddlewareContext) !void {
        if (self.index < self.middlewares.len) {
            const middleware = self.middlewares[self.index];
            self.index += 1;
            try middleware(self.ctx, self);
        } else if (self.handler) |handler| {
            try handler(self.ctx);
        }
    }
};
```

#### 2. 新的中间件函数签名
```zig
pub const MiddlewareFn = *const fn(*Context, *MiddlewareContext) anyerror!void;
```

#### 3. 洋葱模型执行器
```zig
pub fn executeOnionModel(
    ctx: *Context,
    middlewares: []const MiddlewareFn,
    handler: HandlerFn
) !void {
    var middleware_ctx = MiddlewareContext{
        .index = 0,
        .middlewares = middlewares,
        .handler = handler,
        .ctx = ctx,
    };

    try middleware_ctx.next();
}
```

#### 4. 中间件示例
```zig
pub fn loggerMiddleware(ctx: *Context, next_ctx: *MiddlewareContext) !void {
    const start_time = std.time.milliTimestamp();
    std.debug.print("请求开始: {s} {s}\n", .{ctx.request.method, ctx.request.path});

    // 调用下一个中间件或处理函数
    try next_ctx.next();

    // 响应阶段处理
    const end_time = std.time.milliTimestamp();
    const duration = end_time - start_time;
    std.debug.print("请求完成: {d}ms\n", .{duration});
}
```

## 📊 优势分析

### 1. 真正的洋葱模型
- ✅ 请求阶段：外层到内层
- ✅ 响应阶段：内层到外层
- ✅ 完整的生命周期控制

### 2. 更好的错误处理
```zig
pub fn errorHandlerMiddleware(ctx: *Context, next_ctx: *MiddlewareContext) !void {
    next_ctx.next() catch |err| {
        switch (err) {
            error.NotFound => {
                ctx.status(.not_found);
                try ctx.json("{\"error\":\"Not Found\"}");
            },
            error.Unauthorized => {
                ctx.status(.unauthorized);
                try ctx.json("{\"error\":\"Unauthorized\"}");
            },
            else => {
                ctx.status(.internal_server_error);
                try ctx.json("{\"error\":\"Internal Server Error\"}");
            }
        }
    };
}
```

### 3. 灵活的控制流
- 中间件可以选择是否调用next()
- 可以在调用next()前后执行逻辑
- 支持条件性跳过后续中间件

## 🔧 实现计划

### 阶段1：核心结构重构 (1周)
1. 重新定义MiddlewareFn类型
2. 实现MiddlewareContext结构
3. 创建洋葱模型执行器

### 阶段2：中间件迁移 (1周)
1. 更新现有中间件实现
2. 添加错误处理中间件
3. 实现条件中间件

### 阶段3：测试和优化 (1周)
1. 编写全面的测试用例
2. 性能基准测试
3. 内存使用优化

## 📈 预期收益

### 性能提升
- 更精确的错误处理，减少不必要的处理
- 条件性中间件执行，提升效率
- 更好的资源管理

### 开发体验
- 符合主流框架的中间件模式
- 更直观的请求/响应生命周期
- 更容易调试和测试

### 扩展性
- 支持更复杂的中间件逻辑
- 便于添加新的中间件类型
- 更好的第三方中间件集成
