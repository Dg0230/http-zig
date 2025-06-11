# Radix树路由系统设计方案

## 🎯 目标
将当前基于哈希表的路由系统升级为高性能的Radix树实现，提升路由匹配效率和支持更复杂的路由模式。

## 🔍 当前问题分析

### 现有实现
```zig
// 当前基于哈希表的路由映射
route_map: RouteMap, // HashMap([]const u8, ArrayList(*Route))

// 路由查找：O(n)线性搜索
pub fn findRoute(self: *Router, method: HttpMethod, path: []const u8) ?*Route {
    const method_str = method.toString();
    if (self.route_map.get(method_str)) |routes| {
        for (routes.items) |route| {
            if (self.matchRoute(route.pattern, path)) {
                return route;
            }
        }
    }
    return null;
}
```

### 问题
1. **性能瓶颈** - O(n)线性搜索，路由数量增加时性能下降
2. **内存效率低** - 每个HTTP方法都需要独立的路由列表
3. **模式匹配复杂** - 参数提取和通配符处理效率低
4. **扩展性差** - 难以支持复杂的路由模式

## 🚀 Radix树设计

### 核心概念
Radix树（压缩前缀树）是一种优化的前缀树，相同前缀的路径会被压缩到同一个节点中。

```
路由示例：
/api/users
/api/users/:id
/api/users/:id/posts
/api/posts
/static/*filepath

Radix树结构：
root
├── /api/
│   ├── users
│   │   ├── [handler] (GET /api/users)
│   │   └── /:id
│   │       ├── [handler] (GET /api/users/:id)
│   │       └── /posts [handler] (GET /api/users/:id/posts)
│   └── posts [handler] (GET /api/posts)
└── /static/*filepath [handler] (GET /static/*)
```

### 实现方案

#### 1. Radix节点结构
```zig
pub const RadixNode = struct {
    // 节点路径片段
    path: []const u8,

    // 子节点列表
    children: ArrayList(*RadixNode),

    // 参数子节点（:param）
    param_child: ?*RadixNode,

    // 通配符子节点（*wildcard）
    wildcard_child: ?*RadixNode,

    // 路由处理器（按HTTP方法分组）
    handlers: EnumMap(HttpMethod, ?HandlerFn),

    // 路由中间件
    middlewares: ArrayList(MiddlewareFn),

    // 节点类型
    node_type: NodeType,

    // 参数名（仅对参数节点有效）
    param_name: ?[]const u8,

    allocator: Allocator,

    const NodeType = enum {
        static,    // 静态路径
        param,     // 参数路径 (:id)
        wildcard,  // 通配符路径 (*path)
    };
};
```

#### 2. Radix树路由器
```zig
pub const RadixRouter = struct {
    root: *RadixNode,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !*RadixRouter {
        const router = try allocator.create(RadixRouter);
        router.* = RadixRouter{
            .root = try RadixNode.init(allocator, "", .static),
            .allocator = allocator,
        };
        return router;
    }

    pub fn addRoute(
        self: *RadixRouter,
        method: HttpMethod,
        path: []const u8,
        handler: HandlerFn
    ) !void {
        try self.root.addRoute(method, path, handler);
    }

    pub fn findRoute(
        self: *RadixRouter,
        method: HttpMethod,
        path: []const u8,
        params: *StringHashMap([]const u8)
    ) ?HandlerFn {
        return self.root.findRoute(method, path, params);
    }
};
```

#### 3. 路由添加算法
```zig
pub fn addRoute(
    self: *RadixNode,
    method: HttpMethod,
    path: []const u8,
    handler: HandlerFn
) !void {
    if (path.len == 0) {
        self.handlers.put(method, handler);
        return;
    }

    // 解析路径段
    const segment = self.parseSegment(path);

    // 查找匹配的子节点
    if (self.findChild(segment)) |child| {
        // 找到匹配的子节点，递归添加
        const remaining = path[segment.len..];
        try child.addRoute(method, remaining, handler);
    } else {
        // 创建新的子节点
        const child = try self.createChild(segment);
        const remaining = path[segment.len..];
        try child.addRoute(method, remaining, handler);
    }
}
```

#### 4. 路由查找算法
```zig
pub fn findRoute(
    self: *RadixNode,
    method: HttpMethod,
    path: []const u8,
    params: *StringHashMap([]const u8)
) ?HandlerFn {
    if (path.len == 0) {
        return self.handlers.get(method);
    }

    // 1. 尝试静态匹配
    for (self.children.items) |child| {
        if (child.node_type == .static) {
            if (std.mem.startsWith(u8, path, child.path)) {
                const remaining = path[child.path.len..];
                if (child.findRoute(method, remaining, params)) |handler| {
                    return handler;
                }
            }
        }
    }

    // 2. 尝试参数匹配
    if (self.param_child) |param_child| {
        const segment_end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
        const param_value = path[0..segment_end];

        // 保存参数值
        try params.put(param_child.param_name.?, param_value);

        const remaining = path[segment_end..];
        if (param_child.findRoute(method, remaining, params)) |handler| {
            return handler;
        }

        // 回滚参数
        _ = params.remove(param_child.param_name.?);
    }

    // 3. 尝试通配符匹配
    if (self.wildcard_child) |wildcard_child| {
        try params.put(wildcard_child.param_name.?, path);
        return wildcard_child.handlers.get(method);
    }

    return null;
}
```

## 📊 性能优势

### 时间复杂度对比
| 操作 | 当前实现 | Radix树 | 改进 |
|------|----------|---------|------|
| 路由查找 | O(n) | O(log n) | 显著提升 |
| 路由添加 | O(1) | O(log n) | 可接受 |
| 内存使用 | O(n×m) | O(n) | 大幅减少 |

### 实际性能测试预期
```
路由数量: 1000个
当前实现: 平均50μs查找时间
Radix树: 平均5μs查找时间
性能提升: 10倍
```

## 🔧 高级特性

### 1. 路由优先级
```zig
// 静态路由 > 参数路由 > 通配符路由
/api/users/profile    (优先级最高)
/api/users/:id        (中等优先级)
/api/*path           (优先级最低)
```

### 2. 路由约束
```zig
// 参数类型约束
/api/users/:id{int}     // 只匹配整数
/api/posts/:slug{slug}  // 只匹配slug格式
```

### 3. 路由组支持
```zig
// 路由组前缀压缩
const api_group = router.group("/api/v1");
api_group.get("/users", handler);     // /api/v1/users
api_group.post("/users", handler);    // /api/v1/users
```

## 🔧 实现计划

### 阶段1：核心结构实现 (2周)
1. 实现RadixNode基础结构
2. 实现路由添加算法
3. 实现路由查找算法

### 阶段2：高级特性 (1周)
1. 参数提取和验证
2. 通配符路由支持
3. 路由约束系统

### 阶段3：集成和优化 (1周)
1. 与现有系统集成
2. 性能基准测试
3. 内存使用优化

## 📈 预期收益

### 性能提升
- 路由查找速度提升10倍以上
- 内存使用减少50%以上
- 支持更大规模的路由表

### 功能增强
- 支持复杂的路由模式
- 更好的参数提取性能
- 路由约束和验证

### 开发体验
- 更直观的路由定义
- 更好的错误提示
- 更容易调试路由问题
