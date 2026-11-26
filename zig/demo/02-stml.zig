//! demo02：解析一份 STML 文档，打印元素树。
//! 运行：zig build --build-file zig/build.zig demo02 && ./zig/zig-out/bin/demo02
const std = @import("std");
const stope = @import("stope");

fn stateFunc(tag: []const u8) stope.stml.LexerState {
    return stope.stml_parser.defaultStateFunc(tag);
}

fn printElement(alloc: std.mem.Allocator, e: *const stope.stml.Element, depth: usize) !void {
    const indent = try alloc.alloc(u8, depth * 2);
    @memset(indent, ' ');
    std.debug.print("{s}<{s} L{d}", .{ indent, e.tag, e.line });
    var it = e.attrs.iterator();
    while (it.next()) |ent| std.debug.print(" @{s}=\"{s}\"", .{ ent.key_ptr.*, ent.value_ptr.* });
    if (e.self_closing) {
        std.debug.print(" />\n", .{});
        return;
    }
    std.debug.print(">\n", .{});
    if (e.text.len > 0) std.debug.print("{s}  text(L{d}): {s}\n", .{ indent, e.text_line, e.text });
    for (e.children.items) |c| try printElement(alloc, c, depth + 1);
    std.debug.print("{s}</{s}>\n", .{ indent, e.tag });
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const src = "<doc>\n  <p>hello</p>\n  <sto>return 1;</sto>\n  <item flag />\n</doc>";
    var lx = stope.stml_lexer.Lexer.init(alloc, src, .Xml);
    var ps = stope.stml_parser.Parser.init(alloc, &lx);
    var root = stope.stml.Element.init(alloc);
    const ok = try ps.parse(&root, stateFunc);
    std.debug.print("parse: {s}\n", .{if (ok) "Success" else "Error"});
    try printElement(alloc, &root, 0);
}
