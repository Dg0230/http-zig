const std = @import("std");
const Context = @import("../context.zig").Context;
const NextFn = @import("../router.zig").NextFn;

pub fn loggerMiddleware(ctx: *Context, next: NextFn) !void {
    const start_time = std.time.milliTimestamp();

    std.debug.print("[{d}] {s} {s} - 开始处理\n", .{
        std.time.timestamp(),
        ctx.request.method.toString(),
        ctx.request.path,
    });

    try next(ctx);

    const end_time = std.time.milliTimestamp();
    const duration = end_time - start_time;

    std.debug.print("[{d}] {s} {s} - {d} - {d}ms\n", .{
        std.time.timestamp(),
        ctx.request.method.toString(),
        ctx.request.path,
        ctx.response.status.code,
        duration,
    });
}
