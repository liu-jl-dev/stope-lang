//! demo03：注册自定义指令，编译 + 反汇编（不接执行器）。
//! 运行：zig build --build-file zig/build.zig demo03 && ./zig/zig-out/bin/demo03
const std = @import("std");
const stope = @import("stope");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cfg = stope.opcode.CustomOpcodeConfig.init(alloc);
    try cfg.add("myop", 100, 2); // 定长 2 参数
    try cfg.add("vop", 101, -1); // 变长

    const src = "myop(1, 2); vop(3, 4, 5);";
    var lx = stope.Lexer.init(alloc, src);
    lx.custom = &cfg;
    var ps = try stope.Parser.init(alloc, &lx);
    var tree = stope.ast.Prog.init(alloc);
    try ps.parseProgram(&tree);
    const prog = try alloc.create(stope.program.Program);
    prog.* = stope.program.Program.init(alloc);
    var comp = try stope.Compiler.init(alloc, prog, &cfg);
    _ = try comp.compile(&tree, &.{});
    std.debug.print("{s}", .{try stope.debug.disasm(alloc, prog, &cfg)});
}
