//! golden 测试跑器：目前覆盖词法（golden_lex.txt），后续模块陆续接入。
const std = @import("std");
const stope = @import("stope");
const golden = @import("golden.zig");
const dump = @import("dump.zig");

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

fn testCompiler(alloc: std.mem.Allocator, io: std.Io, rep: *Report) !void {
    const cases = try golden.readGolden(alloc, io, "golden.txt", true);
    if (cases.len == 0) return;
    for (cases) |c| {
        const cid = c.get("ID");
        const src = try golden.unescape(alloc, c.get("SRC"));
        var lx = stope.Lexer.init(alloc, src);
        var cfg = stope.opcode.CustomOpcodeConfig.init(alloc);
        try cfg.add("myop", 100, 2);
        try cfg.add("vop", 101, -1);
        var ps = try stope.Parser.init(alloc, &lx);
        ps.const_folding = std.mem.eql(u8, c.get("FOLD"), "1");
        var tree = stope.ast.Prog.init(alloc);
        try ps.parseProgram(&tree);

        var pre = std.ArrayList([]const u8).empty;
        const pre_field = c.get("PRE");
        if (pre_field.len > 0) {
            var pit = std.mem.splitScalar(u8, pre_field, ',');
            while (pit.next()) |name| try pre.append(alloc, name);
        }
        var prog = stope.program.Program.init(alloc);
        var comp = try stope.Compiler.init(alloc, &prog, &cfg);
        _ = try comp.compile(&tree, pre.items);

        const out = try dump.dumpProgram(alloc, &prog, &cfg);
        rep.check(cid, "OUT", c.get("OUT"), out);
        rep.check(cid, "CERRS", c.get("CERRS"), try golden.joinEsc(alloc, comp.errors.items));
    }
}

fn testParser(alloc: std.mem.Allocator, io: std.Io, rep: *Report) !void {
    const cases = try golden.readGolden(alloc, io, "golden.txt", true);
    if (cases.len == 0) {
        std.debug.print("FAIL golden.txt 一条都没读到\n", .{});
        rep.failed += 1;
        return;
    }
    for (cases) |c| {
        const cid = c.get("ID");
        // golden.txt 的 SRC 在读文件时已解一层 E_()，这里再解一层 escUtf8。
        const src = try golden.unescape(alloc, c.get("SRC"));
        var lx = stope.Lexer.init(alloc, src);
        var ps = try stope.Parser.init(alloc, &lx);
        ps.const_folding = std.mem.eql(u8, c.get("FOLD"), "1");
        var tree = stope.ast.Prog.init(alloc);
        try ps.parseProgram(&tree);
        const shape = try stope.ast.shapeProg(alloc, &tree);
        rep.check(cid, "SHAPE", c.get("SHAPE"), shape);

        var lines = std.ArrayList(u8).empty;
        for (tree.stmts.items, 0..) |s, i| {
            if (i > 0) try lines.append(alloc, ',');
            var buf: [32]u8 = undefined;
            try lines.appendSlice(alloc, try std.fmt.bufPrint(&buf, "{d}", .{s.line}));
        }
        rep.check(cid, "LINES", c.get("LINES"), try lines.toOwnedSlice(alloc));

        const perr = try std.fmt.allocPrint(alloc, "{d}", .{ps.errors.items.len});
        rep.check(cid, "PERR", c.get("PERR"), perr);
        rep.check(cid, "PERRS", c.get("PERRS"), try golden.joinEsc(alloc, ps.errors.items));
        const lerr = try std.fmt.allocPrint(alloc, "{d}", .{lx.errors.items.len});
        rep.check(cid, "LEXERR", c.get("LEXERR"), lerr);
        rep.check(cid, "LEXERRS", c.get("LEXERRS"), try golden.joinEsc(alloc, lx.errors.items));
    }
}

fn depthSource(alloc: std.mem.Allocator, kind: []const u8, n: usize) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    if (std.mem.eql(u8, kind, "paren")) {
        var i: usize = 0;
        while (i < n) : (i += 1) try out.append(alloc, '(');
        try out.appendSlice(alloc, "a");
        i = 0;
        while (i < n) : (i += 1) try out.append(alloc, ')');
        try out.appendSlice(alloc, ";");
    } else if (std.mem.eql(u8, kind, "block")) {
        var i: usize = 0;
        while (i < n) : (i += 1) try out.append(alloc, '{');
        try out.appendSlice(alloc, "a;");
        i = 0;
        while (i < n) : (i += 1) try out.append(alloc, '}');
    } else if (std.mem.eql(u8, kind, "unary")) {
        var i: usize = 0;
        while (i < n) : (i += 1) try out.append(alloc, '-');
        try out.appendSlice(alloc, "a;");
    } else if (std.mem.eql(u8, kind, "at")) {
        var i: usize = 0;
        while (i < n) : (i += 1) try out.appendSlice(alloc, "a[");
        try out.appendSlice(alloc, "0");
        i = 0;
        while (i < n) : (i += 1) try out.append(alloc, ']');
        try out.appendSlice(alloc, ";");
    }
    return out.toOwnedSlice(alloc);
}

fn testDepth(alloc: std.mem.Allocator, rep: *Report) !void {
    const cases = [_]struct { kind: []const u8, n: usize, deep: bool }{
        .{ .kind = "paren", .n = 200, .deep = false },
        .{ .kind = "paren", .n = 300, .deep = true },
        .{ .kind = "block", .n = 300, .deep = true },
        .{ .kind = "unary", .n = 300, .deep = true },
        .{ .kind = "at", .n = 300, .deep = true },
        .{ .kind = "block", .n = 200, .deep = false },
        .{ .kind = "unary", .n = 200, .deep = false },
        .{ .kind = "at", .n = 200, .deep = false },
    };
    for (cases) |c| {
        const src = try depthSource(alloc, c.kind, c.n);
        var lx = stope.Lexer.init(alloc, src);
        var ps = try stope.Parser.init(alloc, &lx);
        var tree = stope.ast.Prog.init(alloc);
        try ps.parseProgram(&tree);
        const id = try std.fmt.allocPrint(alloc, "PD-{s}-{d}", .{ c.kind, c.n });
        const nerr = try std.fmt.allocPrint(alloc, "{d}", .{ps.errors.items.len});
        if (c.deep) {
            rep.check(id, "错误条数", "1", nerr);
            const want = "line 1: nesting too deep (max 256). ";
            const got = if (ps.errors.items.len > 0) ps.errors.items[0] else "<无错误>";
            rep.check(id, "错误文案", want, got);
        } else {
            rep.check(id, "错误条数", "0", nerr);
        }
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
    const lex_failed = rep.failed;
    try testParser(alloc, io, &rep);
    const parser_failed = rep.failed - lex_failed;
    try testCompiler(alloc, io, &rep);
    const compiler_failed = rep.failed - lex_failed - parser_failed;
    try testDepth(alloc, &rep);

    std.debug.print("词法失败 {d}，语法失败 {d}，编译失败 {d}，深度失败 {d}；总计 {d} 断言、失败 {d}\n", .{ lex_failed, parser_failed, compiler_failed, rep.failed - lex_failed - parser_failed - compiler_failed, rep.passed + rep.failed, rep.failed });
    if (rep.failed > 0) std.process.exit(1);
}
