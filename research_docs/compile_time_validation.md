# 编译时数据验证系统设计方案

## 🎯 目标
利用Zig的编译时特性实现零运行时开销的数据验证系统，提供类似FastAPI的开发体验。

## 🔍 需求分析

### 当前问题
```zig
// 当前手动解析和验证
fn handleCreateUser(ctx: *Context) !void {
    const body = ctx.request.body orelse return error.MissingBody;

    // 手动JSON解析
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body) catch {
        return error.InvalidJSON;
    };
    defer parsed.deinit();

    // 手动字段验证
    const name = parsed.value.object.get("name") orelse return error.MissingName;
    const age = parsed.value.object.get("age") orelse return error.MissingAge;

    // 类型检查
    if (name != .string) return error.InvalidNameType;
    if (age != .integer) return error.InvalidAgeType;

    // 业务逻辑验证
    if (name.string.len == 0) return error.EmptyName;
    if (age.integer < 0 or age.integer > 150) return error.InvalidAge;
}
```

### 问题
1. **大量样板代码** - 每个端点都需要重复的验证逻辑
2. **运行时错误** - 验证错误只能在运行时发现
3. **类型不安全** - JSON解析后失去类型信息
4. **维护困难** - 验证逻辑分散，难以统一管理

## 🚀 编译时验证设计

### 核心概念
使用Zig的编译时反射和类型系统实现自动的数据验证。

#### 1. 验证装饰器系统
```zig
// 验证规则定义
pub const ValidationRule = union(enum) {
    required,
    min_length: usize,
    max_length: usize,
    min_value: i64,
    max_value: i64,
    pattern: []const u8,
    email,
    url,
    custom: *const fn(anytype) bool,
};

// 字段验证装饰器
pub fn Field(comptime rules: []const ValidationRule) type {
    return struct {
        pub const validation_rules = rules;
    };
}

// 验证模型定义
pub const CreateUserRequest = struct {
    name: Field(&.{ .required, .min_length(1), .max_length(50) }),
    email: Field(&.{ .required, .email }),
    age: Field(&.{ .required, .min_value(0), .max_value(150) }),
    bio: Field(&.{ .max_length(500) }), // 可选字段

    // 编译时生成的验证函数
    pub fn validate(data: std.json.Value) !@This() {
        return comptime generateValidator(@This())(data);
    }
};
```

#### 2. 编译时验证器生成
```zig
pub fn generateValidator(comptime T: type) fn(std.json.Value) anyerror!T {
    return struct {
        fn validate(data: std.json.Value) !T {
            if (data != .object) return error.ExpectedObject;

            var result: T = undefined;

            // 编译时遍历所有字段
            inline for (@typeInfo(T).Struct.fields) |field| {
                const field_type = field.type;
                const field_name = field.name;

                // 检查字段是否有验证规则
                if (@hasDecl(field_type, "validation_rules")) {
                    const rules = field_type.validation_rules;
                    const json_value = data.object.get(field_name);

                    // 应用验证规则
                    const validated_value = try applyValidationRules(
                        json_value,
                        rules,
                        field_name
                    );

                    @field(result, field_name) = validated_value;
                } else {
                    // 普通字段，直接解析
                    @field(result, field_name) = try parseField(
                        data.object.get(field_name),
                        field_type,
                        field_name
                    );
                }
            }

            return result;
        }
    }.validate;
}

fn applyValidationRules(
    value: ?std.json.Value,
    comptime rules: []const ValidationRule,
    comptime field_name: []const u8
) !std.json.Value {
    // 检查required规则
    inline for (rules) |rule| {
        switch (rule) {
            .required => {
                if (value == null) {
                    @compileError("Field '" ++ field_name ++ "' is required");
                }
            },
            else => {},
        }
    }

    const val = value orelse return error.MissingField;

    // 应用其他验证规则
    inline for (rules) |rule| {
        switch (rule) {
            .min_length => |min_len| {
                if (val != .string) return error.ExpectedString;
                if (val.string.len < min_len) return error.TooShort;
            },
            .max_length => |max_len| {
                if (val != .string) return error.ExpectedString;
                if (val.string.len > max_len) return error.TooLong;
            },
            .min_value => |min_val| {
                if (val != .integer) return error.ExpectedInteger;
                if (val.integer < min_val) return error.TooSmall;
            },
            .max_value => |max_val| {
                if (val != .integer) return error.ExpectedInteger;
                if (val.integer > max_val) return error.TooLarge;
            },
            .email => {
                if (val != .string) return error.ExpectedString;
                if (!isValidEmail(val.string)) return error.InvalidEmail;
            },
            .pattern => |pattern| {
                if (val != .string) return error.ExpectedString;
                if (!matchesPattern(val.string, pattern)) return error.PatternMismatch;
            },
            .custom => |validator_fn| {
                if (!validator_fn(val)) return error.CustomValidationFailed;
            },
            .required => {}, // 已处理
        }
    }

    return val;
}
```

#### 3. 自动路由处理器
```zig
pub fn ValidatedHandler(
    comptime RequestType: type,
    comptime ResponseType: type,
    comptime handler_fn: anytype
) HandlerFn {
    return struct {
        fn handle(ctx: *Context) !void {
            // 编译时验证请求类型
            comptime validateRequestType(RequestType);
            comptime validateResponseType(ResponseType);

            // 解析和验证请求
            const request_data = try parseAndValidateRequest(RequestType, ctx);

            // 调用业务逻辑
            const response_data = try handler_fn(ctx, request_data);

            // 序列化响应
            try serializeResponse(ResponseType, ctx, response_data);
        }

        fn parseAndValidateRequest(comptime T: type, ctx: *Context) !T {
            const body = ctx.request.body orelse return error.MissingBody;

            var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body) catch {
                return error.InvalidJSON;
            };
            defer parsed.deinit();

            return try T.validate(parsed.value);
        }

        fn serializeResponse(comptime T: type, ctx: *Context, data: T) !void {
            var json_buffer = std.ArrayList(u8).init(ctx.allocator);
            defer json_buffer.deinit();

            try std.json.stringify(data, .{}, json_buffer.writer());
            try ctx.json(json_buffer.items);
        }
    }.handle;
}

// 编译时类型验证
fn validateRequestType(comptime T: type) void {
    const type_info = @typeInfo(T);
    if (type_info != .Struct) {
        @compileError("Request type must be a struct");
    }

    // 检查是否有validate方法
    if (!@hasDecl(T, "validate")) {
        @compileError("Request type must have a validate method");
    }
}

fn validateResponseType(comptime T: type) void {
    // 检查响应类型是否可序列化
    const type_info = @typeInfo(T);
    switch (type_info) {
        .Struct, .Union, .Enum => {},
        else => @compileError("Response type must be serializable"),
    }
}
```

#### 4. 使用示例
```zig
// 定义请求和响应模型
pub const CreateUserRequest = struct {
    name: Field(&.{ .required, .min_length(1), .max_length(50) }),
    email: Field(&.{ .required, .email }),
    age: Field(&.{ .required, .min_value(0), .max_value(150) }),
    bio: Field(&.{ .max_length(500) }),

    pub fn validate(data: std.json.Value) !@This() {
        return comptime generateValidator(@This())(data);
    }
};

pub const UserResponse = struct {
    id: u32,
    name: []const u8,
    email: []const u8,
    age: u8,
    created_at: i64,
};

// 业务逻辑处理函数
fn createUserLogic(ctx: *Context, request: CreateUserRequest) !UserResponse {
    // 纯业务逻辑，无需关心验证
    const user_id = try ctx.user_service.createUser(.{
        .name = request.name,
        .email = request.email,
        .age = @intCast(request.age),
        .bio = request.bio,
    });

    return UserResponse{
        .id = user_id,
        .name = request.name,
        .email = request.email,
        .age = @intCast(request.age),
        .created_at = std.time.timestamp(),
    };
}

// 注册路由（编译时生成验证代码）
const createUserHandler = ValidatedHandler(
    CreateUserRequest,
    UserResponse,
    createUserLogic
);

// 在路由器中使用
try router.post("/api/users", createUserHandler);
```

#### 5. 高级验证特性
```zig
// 条件验证
pub const ConditionalField = struct {
    condition: *const fn(anytype) bool,
    rules: []const ValidationRule,
};

// 嵌套对象验证
pub const Address = struct {
    street: Field(&.{ .required, .min_length(1) }),
    city: Field(&.{ .required, .min_length(1) }),
    country: Field(&.{ .required, .min_length(2), .max_length(2) }),

    pub fn validate(data: std.json.Value) !@This() {
        return comptime generateValidator(@This())(data);
    }
};

pub const UserWithAddress = struct {
    name: Field(&.{ .required, .min_length(1) }),
    email: Field(&.{ .required, .email }),
    address: Address, // 嵌套验证

    pub fn validate(data: std.json.Value) !@This() {
        return comptime generateValidator(@This())(data);
    }
};

// 数组验证
pub const CreateUsersRequest = struct {
    users: []CreateUserRequest,

    pub fn validate(data: std.json.Value) !@This() {
        if (data != .object) return error.ExpectedObject;

        const users_json = data.object.get("users") orelse return error.MissingUsers;
        if (users_json != .array) return error.ExpectedArray;

        var users = try std.ArrayList(CreateUserRequest).initCapacity(
            std.heap.page_allocator,
            users_json.array.items.len
        );

        for (users_json.array.items) |user_json| {
            const user = try CreateUserRequest.validate(user_json);
            try users.append(user);
        }

        return @This(){
            .users = users.toOwnedSlice(),
        };
    }
};

// 自定义验证器
fn isValidUsername(value: std.json.Value) bool {
    if (value != .string) return false;
    const str = value.string;

    // 用户名只能包含字母、数字和下划线
    for (str) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_') {
            return false;
        }
    }

    return true;
}

pub const RegisterRequest = struct {
    username: Field(&.{ .required, .min_length(3), .max_length(20), .custom(isValidUsername) }),
    password: Field(&.{ .required, .min_length(8) }),
    email: Field(&.{ .required, .email }),

    pub fn validate(data: std.json.Value) !@This() {
        return comptime generateValidator(@This())(data);
    }
};
```

## 📊 优势分析

### 编译时优势
- **零运行时开销** - 所有验证逻辑在编译时生成
- **类型安全** - 编译时检查所有类型错误
- **早期错误发现** - 配置错误在编译时发现

### 开发体验
- **声明式验证** - 简洁的验证规则定义
- **自动代码生成** - 减少样板代码
- **IDE支持** - 完整的类型提示和自动补全

### 性能优势
- **无反射开销** - 编译时生成特化代码
- **内联优化** - 编译器可以完全内联验证逻辑
- **最小内存分配** - 避免运行时验证器创建

## 🔧 实现计划

### 阶段1：核心验证系统 (2周)
1. 实现Field装饰器
2. 编译时验证器生成
3. 基本验证规则

### 阶段2：高级特性 (1周)
1. 嵌套对象验证
2. 数组和集合验证
3. 条件验证

### 阶段3：集成优化 (1周)
1. 与路由系统集成
2. 错误处理优化
3. 性能基准测试

## 📈 预期收益

### 开发效率
- 减少验证代码90%
- 提升开发速度3倍
- 减少运行时错误

### 代码质量
- 更好的类型安全
- 统一的验证逻辑
- 更容易的测试

### 性能
- 零运行时验证开销
- 更快的请求处理
- 更少的内存分配
