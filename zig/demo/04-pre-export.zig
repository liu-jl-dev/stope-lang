//! demo04：preExports —— 宿主注入的全局变量（参数表），编译 + 运行。
//! 运行：zig build --build-file zig/build.zig demo04 && ./zig/zig-out/bin/demo04
const std = @import("std");
const stope = @import("stope");

fn hostPrint(ctx: ?*anyopaque, args: []const stope.basic_vm.Value) stope.basic_vm.Value {
    _ = ctx;
    std.debug.print("print: {s}\n", .{args[0].string});
    return .null_;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src = "println(\"hello from pre-export\"); return 1;";
    var lx = stope.Lexer.init(alloc, src);
    var ps = try stope.Parser.init(alloc, &lx);
    var tree = stope.ast.Prog.init(alloc);
    try ps.parseProgram(&tree);
    const prog = try alloc.create(stope.program.Program);
    prog.* = stope.program.Program.init(alloc);
    var comp = try stope.Compiler.init(alloc, prog, null);
    const pre = [_][]const u8{"println"};
    if (!try comp.compile(&tree, &pre)) {
        for (comp.errors.items) |e| std.debug.print("{s}\n", .{e});
        return;
    }
    const state = try alloc.create(stope.basic_vm.State);
    state.* = try stope.basic_vm.State.init(alloc, prog);
    const slot = prog.exports.get("println").?;
    state.variables[@intCast(slot)] = .{ .host_fn = .{ .ctx = null, .func = hostPrint } };
    _ = try state.run();
    std.debug.print("returns: {s}\n", .{try fmtReturns(alloc, state)});
}

fn fmtReturns(alloc: std.mem.Allocator, s: *const stope.basic_vm.State) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.append(alloc, '[');
    for (s.returns.items, 0..) |v, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, try stope.basic_vm.fmtValue(alloc, v));
    }
    try out.append(alloc, ']');
    return out.toOwnedSlice(alloc);
}
