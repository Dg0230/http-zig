// libxev 基础功能测试
const std = @import("std");
const xev = @import("xev");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    _ = gpa.allocator();

    std.debug.print("🧪 测试 libxev 基本功能...\n", .{});

    // 事件循环
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    std.debug.print("✅ 事件循环创建成功\n", .{});

    // 定时器测试
    var timer = try xev.Timer.init();
    defer timer.deinit();
    std.debug.print("✅ 定时器创建成功\n", .{});

    // 启动定时器
    var completion: xev.Completion = undefined;
    timer.run(&loop, &completion, 1000, void, null, timerCallback);
    std.debug.print("⏰ 启动 1 秒定时器...\n", .{});

    // 运行事件循环
    try loop.run(.until_done);
    std.debug.print("🎉 测试完成！\n", .{});
}

fn timerCallback(userdata: ?*void, loop: *xev.Loop, completion: *xev.Completion, result: xev.Timer.RunError!void) xev.CallbackAction {
    _ = userdata;
    _ = loop;
    _ = completion;

    result catch |err| {
        std.debug.print("❌ 定时器错误: {any}\n", .{err});
        return .disarm;
    };

    std.debug.print("⏰ 定时器触发！libxev 工作正常\n", .{});
    return .disarm;
}
