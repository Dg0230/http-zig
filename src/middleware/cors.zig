const std = @import("std");
const Context = @import("../context.zig").Context;
const NextFn = @import("../router.zig").NextFn;
const HttpMethod = @import("../request.zig").HttpMethod;

pub fn corsMiddleware(ctx: *Context, next: NextFn) !void {
    try ctx.response.setHeader("Access-Control-Allow-Origin", "*");
    try ctx.response.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    try ctx.response.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");

    if (ctx.request.method == .OPTIONS) {
        ctx.response.setStatus(.{ .code = 204, .message = "No Content" });
        return;
    }

    try next(ctx);
}
