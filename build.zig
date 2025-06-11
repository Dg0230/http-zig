const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // libxev 依赖
    const libxev_dep = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });

    // 原版 HTTP 服务器
    const exe = b.addExecutable(.{
        .name = "zig-http",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // libxev HTTP 引擎
    const libxev_http = b.addExecutable(.{
        .name = "libxev-http",
        .root_source_file = b.path("src/libxev_http_engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    libxev_http.root_module.addImport("xev", libxev_dep.module("xev"));

    // libxev 基础测试
    const libxev_test = b.addExecutable(.{
        .name = "libxev-test",
        .root_source_file = b.path("src/libxev_basic_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    libxev_test.root_module.addImport("xev", libxev_dep.module("xev"));

    // 安装可执行文件
    b.installArtifact(exe);
    b.installArtifact(libxev_http);
    b.installArtifact(libxev_test);

    // 运行步骤
    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_exe.addArgs(args);
    }
    const run_step = b.step("run", "Run the original HTTP server");
    run_step.dependOn(&run_exe.step);

    const run_libxev = b.addRunArtifact(libxev_http);
    run_libxev.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_libxev.addArgs(args);
    }
    const run_libxev_step = b.step("run-libxev", "Run the libxev HTTP engine");
    run_libxev_step.dependOn(&run_libxev.step);

    const run_test = b.addRunArtifact(libxev_test);
    run_test.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_test.addArgs(args);
    }
    const test_step = b.step("test-libxev", "Run the libxev test");
    test_step.dependOn(&run_test.step);

    // 单元测试
    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_unit_step = b.step("test", "Run unit tests");
    test_unit_step.dependOn(&run_exe_unit_tests.step);
}
