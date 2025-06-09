const std = @import("std");
const Context = @import("../context.zig").Context;
const NextFn = @import("../router.zig").NextFn;

pub fn errorHandlerMiddleware(ctx: *Context, next: NextFn) !void {
    next(ctx) catch |err| {
        std.debug.print("错误处理中间件捕获到错误: {any}\n", .{err});

        const status = switch (err) {
            error.NotFound => .{ .code = 404, .message = "Not Found" },
            error.InvalidRequest => .{ .code = 400, .message = "Bad Request" },
            error.Unauthorized => .{ .code = 401, .message = "Unauthorized" },
            error.Forbidden => .{ .code = 403, .message = "Forbidden" },
            else => .{ .code = 500, .message = "Internal Server Error" },
        };

        ctx.response.setStatus(status);

        const error_json = try std.fmt.allocPrint(ctx.allocator,
            \\{{
            \\  "error": "{s}",
            \\  "status": {d},
            \\  "message": "{s}"
            \\}}
        , .{ @errorName(err), status.code, status.message });
        defer ctx.allocator.free(error_json);

        try ctx.json(error_json);
    };
}
