# 可观测性系统设计方案

## 🎯 目标
构建完整的可观测性系统，包括指标收集、分布式追踪、结构化日志和健康检查，为生产环境提供全面的监控能力。

## 🔍 可观测性三大支柱

### 1. 指标 (Metrics)
数值型数据，用于监控系统性能和健康状态。

### 2. 日志 (Logs)
结构化的事件记录，用于问题诊断和审计。

### 3. 追踪 (Traces)
请求在分布式系统中的完整路径，用于性能分析和问题定位。

## 🚀 系统设计

### 1. 指标收集系统
```zig
pub const MetricsRegistry = struct {
    counters: std.StringHashMap(*Counter),
    gauges: std.StringHashMap(*Gauge),
    histograms: std.StringHashMap(*Histogram),
    allocator: Allocator,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: Allocator) !*MetricsRegistry {
        const registry = try allocator.create(MetricsRegistry);
        registry.* = MetricsRegistry{
            .counters = std.StringHashMap(*Counter).init(allocator),
            .gauges = std.StringHashMap(*Gauge).init(allocator),
            .histograms = std.StringHashMap(*Histogram).init(allocator),
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };
        return registry;
    }

    pub fn counter(self: *MetricsRegistry, name: []const u8, labels: ?Labels) !*Counter {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = try self.buildKey(name, labels);

        if (self.counters.get(key)) |existing| {
            return existing;
        }

        const new_counter = try Counter.init(self.allocator, name, labels);
        try self.counters.put(key, new_counter);
        return new_counter;
    }

    pub fn gauge(self: *MetricsRegistry, name: []const u8, labels: ?Labels) !*Gauge {
        // 类似counter的实现
    }

    pub fn histogram(self: *MetricsRegistry, name: []const u8, buckets: []const f64, labels: ?Labels) !*Histogram {
        // 类似counter的实现，但包含bucket配置
    }
};

pub const Counter = struct {
    value: atomic.Value(u64),
    name: []const u8,
    labels: ?Labels,

    pub fn inc(self: *Counter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    pub fn add(self: *Counter, delta: u64) void {
        _ = self.value.fetchAdd(delta, .monotonic);
    }

    pub fn get(self: *Counter) u64 {
        return self.value.load(.monotonic);
    }
};

pub const Gauge = struct {
    value: atomic.Value(f64),
    name: []const u8,
    labels: ?Labels,

    pub fn set(self: *Gauge, value: f64) void {
        self.value.store(value, .monotonic);
    }

    pub fn inc(self: *Gauge) void {
        self.add(1.0);
    }

    pub fn dec(self: *Gauge) void {
        self.add(-1.0);
    }

    pub fn add(self: *Gauge, delta: f64) void {
        while (true) {
            const current = self.value.load(.monotonic);
            const new_value = current + delta;
            if (self.value.cmpxchgWeak(current, new_value, .monotonic, .monotonic) == null) {
                break;
            }
        }
    }
};

pub const Histogram = struct {
    buckets: []Bucket,
    sum: atomic.Value(f64),
    count: atomic.Value(u64),
    name: []const u8,
    labels: ?Labels,

    const Bucket = struct {
        upper_bound: f64,
        count: atomic.Value(u64),
    };

    pub fn observe(self: *Histogram, value: f64) void {
        _ = self.sum.fetchAdd(value, .monotonic);
        _ = self.count.fetchAdd(1, .monotonic);

        for (self.buckets) |*bucket| {
            if (value <= bucket.upper_bound) {
                _ = bucket.count.fetchAdd(1, .monotonic);
            }
        }
    }
};

pub const Labels = std.StringHashMap([]const u8);
```

### 2. 分布式追踪系统
```zig
pub const TraceContext = struct {
    trace_id: [16]u8,
    span_id: [8]u8,
    parent_span_id: ?[8]u8,
    flags: u8,

    pub fn new() TraceContext {
        var trace_id: [16]u8 = undefined;
        var span_id: [8]u8 = undefined;

        std.crypto.random.bytes(&trace_id);
        std.crypto.random.bytes(&span_id);

        return TraceContext{
            .trace_id = trace_id,
            .span_id = span_id,
            .parent_span_id = null,
            .flags = 0,
        };
    }

    pub fn child(self: *const TraceContext) TraceContext {
        var span_id: [8]u8 = undefined;
        std.crypto.random.bytes(&span_id);

        return TraceContext{
            .trace_id = self.trace_id,
            .span_id = span_id,
            .parent_span_id = self.span_id,
            .flags = self.flags,
        };
    }

    pub fn toHex(self: *const TraceContext) struct { trace_id: [32]u8, span_id: [16]u8 } {
        var trace_hex: [32]u8 = undefined;
        var span_hex: [16]u8 = undefined;

        _ = std.fmt.bufPrint(&trace_hex, "{}", .{std.fmt.fmtSliceHexLower(&self.trace_id)}) catch unreachable;
        _ = std.fmt.bufPrint(&span_hex, "{}", .{std.fmt.fmtSliceHexLower(&self.span_id)}) catch unreachable;

        return .{ .trace_id = trace_hex, .span_id = span_hex };
    }
};

pub const Span = struct {
    context: TraceContext,
    operation_name: []const u8,
    start_time: i64,
    end_time: ?i64,
    tags: std.StringHashMap([]const u8),
    logs: std.ArrayList(LogEntry),
    allocator: Allocator,

    const LogEntry = struct {
        timestamp: i64,
        fields: std.StringHashMap([]const u8),
    };

    pub fn init(allocator: Allocator, operation_name: []const u8, context: TraceContext) !*Span {
        const span = try allocator.create(Span);
        span.* = Span{
            .context = context,
            .operation_name = try allocator.dupe(u8, operation_name),
            .start_time = std.time.nanoTimestamp(),
            .end_time = null,
            .tags = std.StringHashMap([]const u8).init(allocator),
            .logs = std.ArrayList(LogEntry).init(allocator),
            .allocator = allocator,
        };
        return span;
    }

    pub fn setTag(self: *Span, key: []const u8, value: []const u8) !void {
        try self.tags.put(try self.allocator.dupe(u8, key), try self.allocator.dupe(u8, value));
    }

    pub fn log(self: *Span, fields: std.StringHashMap([]const u8)) !void {
        var owned_fields = std.StringHashMap([]const u8).init(self.allocator);

        var iterator = fields.iterator();
        while (iterator.next()) |entry| {
            try owned_fields.put(
                try self.allocator.dupe(u8, entry.key_ptr.*),
                try self.allocator.dupe(u8, entry.value_ptr.*)
            );
        }

        try self.logs.append(LogEntry{
            .timestamp = std.time.nanoTimestamp(),
            .fields = owned_fields,
        });
    }

    pub fn finish(self: *Span) void {
        self.end_time = std.time.nanoTimestamp();

        // 发送到追踪收集器
        tracer.reportSpan(self) catch |err| {
            std.debug.print("Failed to report span: {any}\n", .{err});
        };
    }

    pub fn duration(self: *const Span) ?i64 {
        if (self.end_time) |end| {
            return end - self.start_time;
        }
        return null;
    }
};

pub const Tracer = struct {
    service_name: []const u8,
    collector_url: []const u8,
    allocator: Allocator,

    pub fn startSpan(self: *Tracer, operation_name: []const u8, parent: ?*const Span) !*Span {
        const context = if (parent) |p| p.context.child() else TraceContext.new();
        return try Span.init(self.allocator, operation_name, context);
    }

    pub fn reportSpan(self: *Tracer, span: *Span) !void {
        // 将span发送到Jaeger或其他追踪系统
        const json_data = try self.spanToJSON(span);
        defer self.allocator.free(json_data);

        // HTTP POST到收集器
        // 实现略...
    }
};
```

### 3. 结构化日志系统
```zig
pub const Logger = struct {
    level: LogLevel,
    output: LogOutput,
    formatter: LogFormatter,
    fields: std.StringHashMap([]const u8),
    allocator: Allocator,

    const LogLevel = enum(u8) {
        trace = 0,
        debug = 1,
        info = 2,
        warn = 3,
        error = 4,
        fatal = 5,

        pub fn toString(self: LogLevel) []const u8 {
            return switch (self) {
                .trace => "TRACE",
                .debug => "DEBUG",
                .info => "INFO",
                .warn => "WARN",
                .error => "ERROR",
                .fatal => "FATAL",
            };
        }
    };

    const LogOutput = union(enum) {
        stdout,
        stderr,
        file: std.fs.File,
        syslog,
        network: struct {
            host: []const u8,
            port: u16,
        },
    };

    const LogFormatter = enum {
        json,
        text,
        logfmt,
    };

    pub fn init(allocator: Allocator, level: LogLevel, output: LogOutput) !*Logger {
        const logger = try allocator.create(Logger);
        logger.* = Logger{
            .level = level,
            .output = output,
            .formatter = .json,
            .fields = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
        return logger;
    }

    pub fn withField(self: *Logger, key: []const u8, value: []const u8) !*Logger {
        const new_logger = try self.allocator.create(Logger);
        new_logger.* = self.*;
        new_logger.fields = try self.fields.clone();
        try new_logger.fields.put(try self.allocator.dupe(u8, key), try self.allocator.dupe(u8, value));
        return new_logger;
    }

    pub fn info(self: *Logger, message: []const u8) void {
        self.log(.info, message, null);
    }

    pub fn infoWithFields(self: *Logger, message: []const u8, fields: std.StringHashMap([]const u8)) void {
        self.log(.info, message, fields);
    }

    pub fn error(self: *Logger, message: []const u8) void {
        self.log(.error, message, null);
    }

    fn log(self: *Logger, level: LogLevel, message: []const u8, extra_fields: ?std.StringHashMap([]const u8)) void {
        if (@intFromEnum(level) < @intFromEnum(self.level)) return;

        const entry = LogEntry{
            .timestamp = std.time.timestamp(),
            .level = level,
            .message = message,
            .fields = self.mergeFields(extra_fields),
        };

        const formatted = self.format(entry) catch return;
        defer self.allocator.free(formatted);

        self.write(formatted) catch return;
    }

    const LogEntry = struct {
        timestamp: i64,
        level: LogLevel,
        message: []const u8,
        fields: std.StringHashMap([]const u8),
    };

    fn format(self: *Logger, entry: LogEntry) ![]u8 {
        return switch (self.formatter) {
            .json => try self.formatJSON(entry),
            .text => try self.formatText(entry),
            .logfmt => try self.formatLogfmt(entry),
        };
    }

    fn formatJSON(self: *Logger, entry: LogEntry) ![]u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        const writer = buffer.writer();

        try writer.writeAll("{");
        try writer.print("\"timestamp\":{d},", .{entry.timestamp});
        try writer.print("\"level\":\"{s}\",", .{entry.level.toString()});
        try writer.print("\"message\":\"{s}\"", .{entry.message});

        var iterator = entry.fields.iterator();
        while (iterator.next()) |field| {
            try writer.print(",\"{s}\":\"{s}\"", .{ field.key_ptr.*, field.value_ptr.* });
        }

        try writer.writeAll("}\n");

        return buffer.toOwnedSlice();
    }
};
```

### 4. 健康检查系统
```zig
pub const HealthChecker = struct {
    checks: std.ArrayList(HealthCheck),
    allocator: Allocator,

    const HealthCheck = struct {
        name: []const u8,
        check_fn: *const fn() HealthStatus,
        timeout: u64, // 毫秒
        interval: u64, // 毫秒
        last_check: i64,
        last_status: HealthStatus,
    };

    const HealthStatus = union(enum) {
        healthy: struct {
            message: []const u8,
        },
        unhealthy: struct {
            message: []const u8,
            error: []const u8,
        },
        unknown,
    };

    pub fn addCheck(self: *HealthChecker, name: []const u8, check_fn: *const fn() HealthStatus) !void {
        try self.checks.append(HealthCheck{
            .name = try self.allocator.dupe(u8, name),
            .check_fn = check_fn,
            .timeout = 5000, // 5秒默认超时
            .interval = 30000, // 30秒默认间隔
            .last_check = 0,
            .last_status = .unknown,
        });
    }

    pub fn checkAll(self: *HealthChecker) HealthReport {
        var report = HealthReport{
            .overall_status = .healthy,
            .checks = std.ArrayList(CheckResult).init(self.allocator),
            .timestamp = std.time.timestamp(),
        };

        for (self.checks.items) |*check| {
            const result = self.runCheck(check);
            report.checks.append(result) catch continue;

            if (result.status == .unhealthy) {
                report.overall_status = .unhealthy;
            }
        }

        return report;
    }

    const HealthReport = struct {
        overall_status: enum { healthy, unhealthy },
        checks: std.ArrayList(CheckResult),
        timestamp: i64,
    };

    const CheckResult = struct {
        name: []const u8,
        status: HealthStatus,
        duration_ms: u64,
    };
};

// 内置健康检查
pub fn databaseHealthCheck() HealthChecker.HealthStatus {
    // 检查数据库连接
    database.ping() catch {
        return .{ .unhealthy = .{
            .message = "Database connection failed",
            .error = "Connection timeout",
        }};
    };

    return .{ .healthy = .{ .message = "Database connection OK" }};
}

pub fn memoryHealthCheck() HealthChecker.HealthStatus {
    const usage = getMemoryUsage();
    if (usage > 0.9) { // 90%以上内存使用
        return .{ .unhealthy = .{
            .message = "High memory usage",
            .error = "Memory usage above 90%",
        }};
    }

    return .{ .healthy = .{ .message = "Memory usage normal" }};
}
```

### 5. 中间件集成
```zig
pub fn observabilityMiddleware(ctx: *Context, next: NextFn) !void {
    // 创建追踪span
    const span = try tracer.startSpan("http_request", null);
    defer span.finish();

    // 设置span标签
    try span.setTag("http.method", ctx.request.method);
    try span.setTag("http.url", ctx.request.path);

    // 记录请求指标
    const request_counter = try metrics.counter("http_requests_total", .{
        .method = ctx.request.method,
        .endpoint = ctx.request.path,
    });
    request_counter.inc();

    // 记录请求开始时间
    const start_time = std.time.nanoTimestamp();

    // 执行下一个中间件
    next(ctx) catch |err| {
        // 记录错误
        try span.setTag("error", "true");
        try span.log(.{
            .event = "error",
            .message = @errorName(err),
        });

        // 错误指标
        const error_counter = try metrics.counter("http_errors_total", .{
            .method = ctx.request.method,
            .endpoint = ctx.request.path,
            .error = @errorName(err),
        });
        error_counter.inc();

        return err;
    };

    // 记录响应时间
    const duration = std.time.nanoTimestamp() - start_time;
    const duration_ms = @as(f64, @floatFromInt(duration)) / 1_000_000.0;

    const duration_histogram = try metrics.histogram("http_request_duration_ms",
        &.{ 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000 }, .{
        .method = ctx.request.method,
        .endpoint = ctx.request.path,
    });
    duration_histogram.observe(duration_ms);

    // 设置响应标签
    try span.setTag("http.status_code", @tagName(ctx.response.status));

    // 记录响应状态指标
    const status_counter = try metrics.counter("http_responses_total", .{
        .method = ctx.request.method,
        .endpoint = ctx.request.path,
        .status = @tagName(ctx.response.status),
    });
    status_counter.inc();
}
```

## 📊 监控指标

### HTTP指标
- `http_requests_total` - 总请求数
- `http_request_duration_ms` - 请求延迟分布
- `http_responses_total` - 按状态码分组的响应数
- `http_errors_total` - 错误计数

### 系统指标
- `memory_usage_bytes` - 内存使用量
- `cpu_usage_percent` - CPU使用率
- `goroutines_count` - 活跃连接数
- `gc_duration_ms` - GC耗时

### 业务指标
- `active_users` - 活跃用户数
- `database_connections` - 数据库连接数
- `cache_hit_ratio` - 缓存命中率

## 🔧 实现计划

### 阶段1：基础设施 (1周)
1. 指标收集系统
2. 结构化日志
3. 基本的健康检查

### 阶段2：分布式追踪 (1周)
1. 追踪上下文传播
2. Span生成和收集
3. 与Jaeger集成

### 阶段3：集成和优化 (1周)
1. 中间件集成
2. 性能优化
3. 监控面板

## 📈 预期收益

### 运维效率
- 快速问题定位
- 主动故障发现
- 性能瓶颈识别

### 系统可靠性
- 全面的监控覆盖
- 实时的健康状态
- 详细的错误追踪

### 开发体验
- 丰富的调试信息
- 性能分析工具
- 自动化监控
