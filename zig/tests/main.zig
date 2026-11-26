//! golden 测试跑器：目前覆盖词法（golden_lex.txt），后续模块陆续接入。
const std = @import("std");
const stope = @import("stope");
const golden = @import("golden.zig");

const TokenType = stope.TokenType;

const Report = struct {
    alloc: std.mem.Allocator,
    passed: usize = 0,
    failed: usize = 0,

    fn check(self: *Report, cid: []const u8, field: []const u8, want: []const u8, got: []const u8) void {
        if (std.mem.eql(u8, want, got)) {
            self.passed += 1;
        } else {
            self.failed += 1;
            std.debug.print("FAIL {s} {s}\n  want=[{s}]\n  got =[{s}]\n", .{ cid, field, want, got });
        }
    }
};

fn isLexemeType(t: TokenType) bool {
    return t == .Integer or t == .Float or t == .String or t == .BinArr;
}

fn one(alloc: std.mem.Allocator, src: []const u8) !struct { toks: []const u8, lexemes: []const u8, errn: usize, errs: []const u8 } {
    var lx = stope.Lexer.init(alloc, src);
    var toks = std.ArrayList(u8).empty;
    var lexemes = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        const t = try lx.nextToken();
        if (i > 0) try toks.append(alloc, ' ');
        try toks.appendSlice(alloc, stope.typeName(t.typ));
        try toks.append(alloc, '(');
        var lbuf: [32]u8 = undefined;
        try toks.appendSlice(alloc, try std.fmt.bufPrint(&lbuf, "{d}", .{t.line}));
        try toks.append(alloc, ')');
        if (t.parsed.len > 0) {
            try toks.append(alloc, '[');
            try toks.appendSlice(alloc, try golden.escLex(alloc, t.parsed));
            try toks.append(alloc, ']');
        }
        switch (t.value) {
            .integer => |v| {
                try toks.append(alloc, '=');
                var vbuf: [32]u8 = undefined;
                try toks.appendSlice(alloc, try std.fmt.bufPrint(&vbuf, "{d}", .{v}));
            },
            .float => |v| {
                try toks.append(alloc, '=');
                try toks.appendSlice(alloc, try golden.fmtG(alloc, v));
            },
            .none => {},
        }
        if (isLexemeType(t.typ)) {
            if (lexemes.items.len > 0) try lexemes.append(alloc, ',');
            var ibuf: [32]u8 = undefined;
            try lexemes.appendSlice(alloc, try std.fmt.bufPrint(&ibuf, "{d}:", .{i}));
            try lexemes.appendSlice(alloc, try golden.escLex(alloc, t.lexeme));
        }
        if (t.typ == .Eof) break;
    }
    return .{
        .toks = try toks.toOwnedSlice(alloc),
        .lexemes = try lexemes.toOwnedSlice(alloc),
        .errn = lx.errors.items.len,
        .errs = try golden.joinEsc(alloc, lx.errors.items),
    };
}

fn testLexer(alloc: std.mem.Allocator, io: std.Io, rep: *Report) !void {
    const cases = try golden.readGolden(alloc, io, "golden_lex.txt", false);
    if (cases.len == 0) {
        std.debug.print("FAIL golden_lex.txt 一条都没读到\n", .{});
        rep.failed += 1;
        return;
    }
    for (cases) |c| {
        const cid = c.get("ID");
        const src = try golden.unescapeLex(alloc, c.get("SRC"));
        const r = try one(alloc, src);
        rep.check(cid, "TOKS", c.get("TOKS"), r.toks);
        rep.check(cid, "LEXEMES", c.get("LEXEMES"), r.lexemes);
        const errn_buf = try std.fmt.allocPrint(alloc, "{d}", .{r.errn});
        rep.check(cid, "ERRN", c.get("ERRN"), errn_buf);
        rep.check(cid, "ERRS", c.get("ERRS"), r.errs);
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded_io: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    var rep = Report{ .alloc = alloc };
    try testLexer(alloc, io, &rep);

    std.debug.print("词法断言 {d} 条，失败 {d} 条\n", .{ rep.passed + rep.failed, rep.failed });
    if (rep.failed > 0) std.process.exit(1);
}
