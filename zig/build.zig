const std = @import("std");

/// Stope 的 Zig 实现。零第三方依赖，模块划分对齐 python/stope/。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const stope = b.addModule("stope", .{
        .root_source_file = b.path("stope/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 测试跑器（读 gdscript/test/data/ 的 golden；只在本仓库内跑）。
    const tests = b.addExecutable(.{
        .name = "run_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("stope", stope);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "运行 golden 测试");
    test_step.dependOn(&run_tests.step);

    // 四个 demo（输出以可读为准，不追求逐字节一致）
    const demo_names = [_][]const u8{ "01-quick-start", "02-stml", "03-custom-opcode", "04-pre-export" };
    var demo_steps = std.ArrayList(*std.Build.Step).empty;
    for (demo_names) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("demo/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("stope", stope);
        const run = b.addRunArtifact(exe);
        const step = b.step(name, b.fmt("运行 demo {s}", .{name}));
        step.dependOn(&run.step);
        demo_steps.append(b.allocator, step) catch unreachable;
    }
    const demos = b.step("demos", "运行全部 demo");
    for (demo_steps.items) |step| demos.dependOn(step);
}
