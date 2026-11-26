//! demo01：编译 + 运行一段 Stope 代码。
//! 运行：zig build --build-file zig/build.zig demo01 && ./zig/zig-out/bin/demo01
//! 输出以可读为准，不追求与其它实现逐字节相同。
const std = @import("std");
const stope = @import("stope");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src = "let a = 7; let b = 2; return a + b, a * b;";
    var lx = stope.Lexer.init(alloc, src);
    var ps = try stope.Parser.init(alloc, &lx);
    var tree = stope.ast.Prog.init(alloc);
    try ps.parseProgram(&tree);
    if (ps.errors.items.len > 0) {
        for (ps.errors.items) |e| std.debug.print("{s}\n", .{e});
        return;
    }

    const prog = try alloc.create(stope.program.Program);
    prog.* = stope.program.Program.init(alloc);
    var comp = try stope.Compiler.init(alloc, prog, null);
    if (!try comp.compile(&tree, &.{})) {
        for (comp.errors.items) |e| std.debug.print("{s}\n", .{e});
        return;
    }

    const state = try alloc.create(stope.basic_vm.State);
    state.* = try stope.basic_vm.State.init(alloc, prog);
    _ = try state.run();
    std.debug.print("code size: {d}\n", .{prog.opcodes.items.len});
    std.debug.print("returns: ", .{});
    for (state.returns.items, 0..) |v, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("{s}", .{try stope.basic_vm.fmtValue(alloc, v)});
    }
    std.debug.print("\n", .{});
}
