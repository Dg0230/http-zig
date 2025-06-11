# 依赖注入系统设计方案

## 🎯 目标
为Zig HTTP框架设计一个类型安全、高性能的依赖注入系统，提升代码的可测试性和模块化程度。

## 🔍 需求分析

### 当前问题
```zig
// 当前处理函数需要手动管理依赖
fn handleUsers(ctx: *Context) !void {
    // 硬编码的依赖创建
    var db = Database.init(ctx.allocator);
    defer db.deinit();

    var user_service = UserService.init(&db);

    const users = try user_service.getAllUsers();
    try ctx.json(users);
}
```

### 问题
1. **依赖硬编码** - 难以测试和替换
2. **重复代码** - 每个处理函数都要创建依赖
3. **生命周期管理复杂** - 手动管理资源释放
4. **缺乏类型安全** - 运行时才能发现依赖错误

## 🚀 依赖注入设计

### 核心概念
利用Zig的编译时特性实现零运行时开销的依赖注入系统。

#### 1. 服务容器
```zig
pub const ServiceContainer = struct {
    allocator: Allocator,
    services: std.StringHashMap(*anyopaque),
    service_types: std.StringHashMap(type),
    singletons: std.StringHashMap(*anyopaque),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .services = std.StringHashMap(*anyopaque).init(allocator),
            .service_types = std.StringHashMap(type).init(allocator),
            .singletons = std.StringHashMap(*anyopaque).init(allocator),
        };
    }

    // 注册服务类型
    pub fn register(self: *Self, comptime T: type) !void {
        const type_name = @typeName(T);
        try self.service_types.put(type_name, T);
    }

    // 注册单例服务
    pub fn registerSingleton(self: *Self, comptime T: type, instance: *T) !void {
        const type_name = @typeName(T);
        try self.singletons.put(type_name, @ptrCast(instance));
        try self.register(T);
    }

    // 解析服务实例
    pub fn resolve(self: *Self, comptime T: type) !*T {
        const type_name = @typeName(T);

        // 检查是否为单例
        if (self.singletons.get(type_name)) |singleton| {
            return @ptrCast(@alignCast(singleton));
        }

        // 创建新实例
        return try self.createInstance(T);
    }

    // 编译时依赖解析
    fn createInstance(self: *Self, comptime T: type) !*T {
        const instance = try self.allocator.create(T);

        // 使用编译时反射自动注入依赖
        inline for (@typeInfo(T).Struct.fields) |field| {
            if (comptime std.mem.startsWith(u8, field.name, "inject_")) {
                const dep_type = field.type;
                const dependency = try self.resolve(dep_type);
                @field(instance, field.name) = dependency;
            }
        }

        // 调用初始化方法
        if (@hasDecl(T, "init")) {
            try instance.init();
        }

        return instance;
    }
};
```

#### 2. 依赖注入装饰器
```zig
// 使用编译时装饰器标记依赖
pub fn Injectable(comptime T: type) type {
    return struct {
        const InjectableType = T;

        pub fn create(container: *ServiceContainer) !*T {
            return try container.resolve(T);
        }
    };
}

// 服务定义示例
pub const UserService = Injectable(struct {
    inject_database: *Database,
    inject_logger: *Logger,

    const Self = @This();

    pub fn init(self: *Self) !void {
        // 初始化逻辑
    }

    pub fn getAllUsers(self: *Self) ![]User {
        try self.inject_logger.info("获取所有用户");
        return try self.inject_database.query("SELECT * FROM users");
    }

    pub fn getUserById(self: *Self, id: u32) !?User {
        try self.inject_logger.info("获取用户: {d}", .{id});
        return try self.inject_database.queryOne("SELECT * FROM users WHERE id = ?", .{id});
    }
});
```

#### 3. 处理函数依赖注入
```zig
// 自动依赖注入的处理函数
pub fn InjectableHandler(
    comptime handler_fn: anytype,
    comptime deps: anytype
) HandlerFn {
    return struct {
        fn handle(ctx: *Context) !void {
            // 编译时解析依赖类型
            const DepsType = @TypeOf(deps);
            const deps_info = @typeInfo(DepsType);

            // 创建依赖实例
            var resolved_deps: DepsType = undefined;
            inline for (deps_info.Struct.fields) |field| {
                const dep_type = field.type;
                @field(resolved_deps, field.name) = try ctx.container.resolve(dep_type);
            }

            // 调用处理函数
            try handler_fn(ctx, resolved_deps);
        }
    }.handle;
}

// 使用示例
const handleUsers = InjectableHandler(
    struct {
        fn handle(ctx: *Context, deps: struct {
            user_service: *UserService,
            auth_service: *AuthService,
        }) !void {
            // 验证用户权限
            const user = try deps.auth_service.getCurrentUser(ctx);
            if (user == null) {
                return ctx.unauthorized();
            }

            // 获取用户列表
            const users = try deps.user_service.getAllUsers();
            try ctx.json(users);
        }
    }.handle,
    .{
        .user_service = UserService,
        .auth_service = AuthService,
    }
);
```

#### 4. 生命周期管理
```zig
pub const ServiceLifetime = enum {
    transient,  // 每次请求创建新实例
    scoped,     // 请求范围内单例
    singleton,  // 应用程序级单例
};

pub const ServiceDescriptor = struct {
    service_type: type,
    implementation_type: type,
    lifetime: ServiceLifetime,
    factory: ?*const fn(*ServiceContainer) anyerror!*anyopaque,
};

// 服务注册
pub fn registerService(
    container: *ServiceContainer,
    comptime ServiceType: type,
    comptime ImplType: type,
    lifetime: ServiceLifetime
) !void {
    const descriptor = ServiceDescriptor{
        .service_type = ServiceType,
        .implementation_type = ImplType,
        .lifetime = lifetime,
        .factory = null,
    };

    const type_name = @typeName(ServiceType);
    try container.service_descriptors.put(type_name, descriptor);
}
```

## 🔧 高级特性

### 1. 接口注入
```zig
// 定义接口
pub const IUserRepository = struct {
    const Self = @This();

    getAllUsersFn: *const fn(*Self) anyerror![]User,
    getUserByIdFn: *const fn(*Self, u32) anyerror!?User,

    pub fn getAllUsers(self: *Self) ![]User {
        return try self.getAllUsersFn(self);
    }

    pub fn getUserById(self: *Self, id: u32) !?User {
        return try self.getUserByIdFn(self, id);
    }
};

// 实现接口
pub const DatabaseUserRepository = struct {
    inject_database: *Database,

    pub fn asInterface(self: *@This()) IUserRepository {
        return IUserRepository{
            .getAllUsersFn = getAllUsers,
            .getUserByIdFn = getUserById,
        };
    }

    fn getAllUsers(interface: *IUserRepository) ![]User {
        const self = @fieldParentPtr(@This(), "interface", interface);
        return try self.inject_database.query("SELECT * FROM users");
    }
};
```

### 2. 条件注入
```zig
// 基于配置的条件注入
pub fn registerConditional(
    container: *ServiceContainer,
    comptime condition: bool,
    comptime ServiceType: type,
    comptime ImplType: type
) !void {
    if (condition) {
        try container.register(ServiceType, ImplType);
    }
}

// 使用示例
try registerConditional(container, config.use_redis, ICacheService, RedisCacheService);
try registerConditional(container, !config.use_redis, ICacheService, MemoryCacheService);
```

### 3. 装饰器模式
```zig
// 服务装饰器
pub fn CachedService(comptime T: type) type {
    return struct {
        inner: *T,
        cache: *ICacheService,

        const Self = @This();

        pub fn init(inner: *T, cache: *ICacheService) Self {
            return Self{
                .inner = inner,
                .cache = cache,
            };
        }

        // 自动代理所有方法并添加缓存
        pub usingnamespace blk: {
            var decls: []const std.builtin.Type.Declaration = &.{};
            for (@typeInfo(T).Struct.decls) |decl| {
                if (decl.is_pub and @typeInfo(@field(T, decl.name)) == .Fn) {
                    decls = decls ++ [_]std.builtin.Type.Declaration{
                        .{
                            .name = decl.name,
                            .is_pub = true,
                            .data = .{
                                .Fn = .{
                                    .fn_type = @TypeOf(createCachedMethod(T, decl.name)),
                                },
                            },
                        },
                    };
                }
            }
            break :blk @Type(.{
                .Struct = .{
                    .layout = .Auto,
                    .fields = &.{},
                    .decls = decls,
                    .is_tuple = false,
                },
            });
        };
    };
}
```

## 📊 性能优势

### 编译时优化
- **零运行时开销** - 所有依赖解析在编译时完成
- **类型安全** - 编译时检查依赖关系
- **内联优化** - 编译器可以内联依赖调用

### 内存效率
- **精确的生命周期管理** - 避免内存泄漏
- **按需创建** - 只创建实际使用的服务
- **共享单例** - 减少重复实例

## 🔧 实现计划

### 阶段1：核心容器 (1周)
1. 实现ServiceContainer基础结构
2. 基本的服务注册和解析
3. 编译时依赖注入

### 阶段2：高级特性 (1周)
1. 生命周期管理
2. 接口注入支持
3. 条件注入和装饰器

### 阶段3：集成优化 (1周)
1. 与路由系统集成
2. 性能基准测试
3. 文档和示例

## 📈 预期收益

### 代码质量
- 更好的可测试性
- 更清晰的依赖关系
- 更容易的模块替换

### 开发效率
- 减少样板代码
- 自动依赖管理
- 更好的错误提示

### 性能
- 零运行时开销
- 编译时优化
- 精确的内存管理
