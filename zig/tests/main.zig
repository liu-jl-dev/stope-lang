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

fn makeCfg(alloc: std.mem.Allocator, which: []const u8) !stope.opcode.CustomOpcodeConfig {
    var cfg = stope.opcode.CustomOpcodeConfig.init(alloc);
    if (std.mem.eql(u8, which, "collide")) {
        try cfg.add("my:steal", 20, 2);
    } else {
        try cfg.add("myop", 100, 2);
        try cfg.add("vop", 101, -1);
    }
    return cfg;
}

fn isLexemeType(t: TokenType) bool {
    return t == .Integer or t == .Float or t == .String or t == .BinArr;
}

fn one(alloc: std.mem.Allocator, src: []const u8, cfg: *stope.opcode.CustomOpcodeConfig) !struct { toks: []const u8, lexemes: []const u8, errn: usize, errs: []const u8 } {
    var lx = stope.Lexer.init(alloc, src);
    lx.custom = cfg;
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
        var cfg = try makeCfg(alloc, "main");
        const r = try one(alloc, src, &cfg);
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
        var cfg = try makeCfg(alloc, "main");
        var lx = stope.Lexer.init(alloc, src);
        lx.custom = &cfg;
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

fn testDisasm(alloc: std.mem.Allocator, io: std.Io, rep: *Report) !void {
    const cases = try golden.readGolden(alloc, io, "golden_disasm.txt", true);
    if (cases.len == 0) return;
    for (cases) |c| {
        const cid = c.get("ID");
        var cfg = stope.opcode.CustomOpcodeConfig.init(alloc);
        const cfg_name = c.get("CFG");
        if (std.mem.eql(u8, cfg_name, "main")) {
            try cfg.add("myop", 100, 2);
            try cfg.add("vop", 101, -1);
        } else if (std.mem.eql(u8, cfg_name, "collide")) {
            try cfg.add("my:steal", 20, 2); // 撞内置 Add
        }
        const cfgp: ?*stope.opcode.CustomOpcodeConfig = if (cfg.opcodes.count() > 0) &cfg else null;
        var prog = stope.program.Program.init(alloc);
        if (std.mem.eql(u8, c.get("MODE"), "src")) {
            const src = try golden.unescape(alloc, c.get("SRC"));
            var lx = stope.Lexer.init(alloc, src);
            lx.custom = cfgp;
            var ps = try stope.Parser.init(alloc, &lx);
            var tree = stope.ast.Prog.init(alloc);
            try ps.parseProgram(&tree);
            var comp = try stope.Compiler.init(alloc, &prog, cfgp);
            _ = try comp.compile(&tree, &.{});
        } else {
            var it = std.mem.splitScalar(u8, c.get("OPS"), ',');
            while (it.next()) |s| {
                if (s.len == 0) continue;
                const v = try std.fmt.parseInt(i32, s, 10);
                try prog.opcodes.append(alloc, @bitCast(@as(i16, @intCast(v))));
            }
            const vars = c.get("VARS");
            if (vars.len > 0) prog.variable_num = try std.fmt.parseInt(i32, vars, 10);
        }
        const dis = try stope.debug.disasm(alloc, &prog, cfgp);
        rep.check(cid, "DIS", c.get("DIS"), dis);
    }
}

/// escUtf8 按 UTF-16 码元遍历（转义引号），对齐 python/tests/test_stml.py 的 _esc16。
fn esc16(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 128) {
            switch (c) {
                '\\' => try out.appendSlice(alloc, "\\\\"),
                '"' => try out.appendSlice(alloc, "\\\""),
                '\n' => try out.appendSlice(alloc, "\\n"),
                '\r' => try out.appendSlice(alloc, "\\r"),
                '\t' => try out.appendSlice(alloc, "\\t"),
                else => try out.append(alloc, c),
            }
            i += 1;
        } else {
            const n = std.unicode.utf8ByteSequenceLength(c) catch 1;
            const cp = std.unicode.utf8Decode(s[i .. @min(i + n, s.len)]) catch 0;
            const units: usize = if (cp > 0xffff) 2 else 1;
            var k: usize = 0;
            while (k < units) : (k += 1) try out.append(alloc, '?');
            i += n;
        }
    }
    return out.toOwnedSlice(alloc);
}

fn joinEsc16(alloc: std.mem.Allocator, errs: []const []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (errs, 0..) |e, i| {
        if (i > 0) try out.append(alloc, '|');
        try out.appendSlice(alloc, try esc16(alloc, e));
    }
    return out.toOwnedSlice(alloc);
}

fn stateOf(name: []const u8) stope.stml.LexerState {
    if (std.mem.eql(u8, name, "Text")) return .Text;
    if (std.mem.eql(u8, name, "Nevext")) return .Nevext;
    if (std.mem.eql(u8, name, "Stope")) return .Stope;
    return .Xml;
}

const textStateFunc: stope.stml_parser.StateFunc = struct {
    fn f(_: []const u8) stope.stml.LexerState { return .Text; }
}.f;

fn testStml(alloc: std.mem.Allocator, io: std.Io, rep: *Report) !void {
    const cases = try golden.readStmlCases(alloc, io);
    const wants = try golden.readGolden(alloc, io, "golden_stml.txt", false);
    var by_id = std.StringHashMap(golden.Record).init(alloc);
    for (wants) |w| try by_id.put(w.get("ID"), w);
    for (cases) |c| {
        const cid = c.get("ID");
        const want = by_id.get(cid) orelse {
            rep.failed += 1;
            std.debug.print("FAIL {s} 缺 golden 记录\n", .{cid});
            continue;
        };
        const src = try repeatStr(alloc, c.src, c.times);
        if (std.mem.eql(u8, c.get("KIND"), "parse")) {
            var lx = stope.stml_lexer.Lexer.init(alloc, src, .Xml);
            var ps = stope.stml_parser.Parser.init(alloc, &lx);
            const md = c.get("MD");
            if (md.len > 0) ps.max_depth = std.fmt.parseInt(i32, md, 10) catch 256;
            var root = stope.stml.Element.init(alloc);
            const sf_name = c.get("SF");
            var sf: ?stope.stml_parser.StateFunc = stope.stml_parser.defaultStateFunc;
            if (std.mem.eql(u8, sf_name, "null")) {
                sf = null;
            } else if (std.mem.eql(u8, sf_name, "text")) {
                sf = textStateFunc;
            }
            const ok = try ps.parse(&root, sf);
            rep.check(cid, "SHAPE", want.get("SHAPE"), try stope.stml_parser.shape(alloc, &root, esc16));
            rep.check(cid, "RESULT", want.get("RESULT"), if (ok) "Success" else "Error");
            const errn = try std.fmt.allocPrint(alloc, "{d}", .{ps.errors.items.len});
            rep.check(cid, "ERRN", want.get("ERRN"), errn);
            rep.check(cid, "ERRS", want.get("ERRS"), try joinEsc16(alloc, ps.errors.items));
            const lerrn = try std.fmt.allocPrint(alloc, "{d}", .{lx.errors.items.len});
            rep.check(cid, "LEXERRN", want.get("LEXERRN"), lerrn);
            rep.check(cid, "LEXERRS", want.get("LEXERRS"), try joinEsc16(alloc, lx.errors.items));
        } else {
            var lx = stope.stml_lexer.Lexer.init(alloc, src, stateOf(c.get("ST")));
            var toks = std.ArrayList(u8).empty;
            var lexs = std.ArrayList(u8).empty;
            var i: usize = 0;
            while (i < 10000) : (i += 1) {
                const t = try lx.nextToken();
                if (i > 0) try toks.append(alloc, ' ');
                const name = stope.stml.typeName(t.typ);
                try toks.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s}({d})", .{ name, t.line }));
                if (stope.stml_lexer.hasLexeme(t.typ)) {
                    if (lexs.items.len > 0) try lexs.append(alloc, ',');
                    try lexs.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{d}:", .{i}));
                    try lexs.appendSlice(alloc, try esc16(alloc, t.lexeme));
                }
                if (t.typ == .Eof) break;
            }
            rep.check(cid, "TOKS", want.get("TOKS"), try toks.toOwnedSlice(alloc));
            rep.check(cid, "LEXS", want.get("LEXS"), try lexs.toOwnedSlice(alloc));
            const errn = try std.fmt.allocPrint(alloc, "{d}", .{lx.errors.items.len});
            rep.check(cid, "ERRN", want.get("ERRN"), errn);
            rep.check(cid, "ERRS", want.get("ERRS"), try joinEsc16(alloc, lx.errors.items));
        }
    }
}

fn repeatStr(alloc: std.mem.Allocator, s: []const u8, n: usize) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < n) : (i += 1) try out.appendSlice(alloc, s);
    return out.toOwnedSlice(alloc);
}

fn buildVm(alloc: std.mem.Allocator, src: []const u8) !?*stope.basic_vm.State {
    var cfg = try makeCfg(alloc, "main");
    var lx = stope.Lexer.init(alloc, src);
    lx.custom = &cfg;
    var ps = try stope.Parser.init(alloc, &lx);
    var tree = stope.ast.Prog.init(alloc);
    try ps.parseProgram(&tree);
    const prog = try alloc.create(stope.program.Program);
    prog.* = stope.program.Program.init(alloc);
    var comp = try stope.Compiler.init(alloc, prog, &cfg);
    if (!try comp.compile(&tree, &.{})) return null;
    const st = try alloc.create(stope.basic_vm.State);
    st.* = try stope.basic_vm.State.init(alloc, prog);
    _ = try st.run();
    return st;
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

fn vmReturns(alloc: std.mem.Allocator, rep: *Report, cid: []const u8, src: []const u8, want: []const u8) !void {
    const s = try buildVm(alloc, src) orelse {
        rep.failed += 1;
        std.debug.print("FAIL {s} 编译失败\n", .{cid});
        return;
    };
    rep.check(cid, "returns", want, try fmtReturns(alloc, s));
    var errs = std.ArrayList(u8).empty;
    for (s.errors.items, 0..) |e, i| {
        if (i > 0) try errs.append(alloc, '|');
        try errs.appendSlice(alloc, e);
    }
    rep.check(cid, "errors", "", try errs.toOwnedSlice(alloc));
}

fn vmErrs(alloc: std.mem.Allocator, rep: *Report, cid: []const u8, src: []const u8, want_msg: []const u8) !void {
    const s = try buildVm(alloc, src) orelse {
        rep.failed += 1;
        std.debug.print("FAIL {s} 编译失败\n", .{cid});
        return;
    };
    const n = try std.fmt.allocPrint(alloc, "{d}", .{s.errors.items.len});
    rep.check(cid, "错误条数", "1", n);
    var got: []const u8 = "<无错误>";
    if (s.errors.items.len > 0) {
        const e = s.errors.items[0];
        const pos = std.mem.indexOf(u8, e, ": ");
        got = if (pos) |p| e[p + 2 ..] else e;
    }
    rep.check(cid, "错误消息", want_msg, got);
}

fn hostAdd(ctx: ?*anyopaque, args: []const stope.basic_vm.Value) stope.basic_vm.Value {
    _ = ctx;
    return .{ .integer = args[0].integer +% args[1].integer };
}
fn hostTrue(ctx: ?*anyopaque, args: []const stope.basic_vm.Value) stope.basic_vm.Value {
    _ = ctx; _ = args;
    return .{ .integer = 1 }; // Stope 侧 bool 归一成整数 1
}
const ArgsCtx = struct { data: []const stope.basic_vm.Value };
fn argsAt(ctx: ?*anyopaque, s: *stope.basic_vm.State, key: stope.basic_vm.Value) stope.basic_vm.Value {
    const data: []const stope.basic_vm.Value = @as(*const ArgsCtx, @ptrCast(@alignCast(ctx.?))).data;
    if (key != .integer or key.integer < 0 or key.integer >= data.len) {
        s.addError("argument out of range. ") catch {};
        return .null_;
    }
    return data[@intCast(key.integer)];
}
fn argsNum(ctx: ?*anyopaque) i32 {
    const data: []const stope.basic_vm.Value = @as(*const ArgsCtx, @ptrCast(@alignCast(ctx.?))).data;
    return @intCast(data.len);
}
fn noArgsAt(ctx: ?*anyopaque, s: *stope.basic_vm.State, key: stope.basic_vm.Value) stope.basic_vm.Value {
    _ = ctx; _ = key;
    s.addError("args not provided in this test. ") catch {};
    return .null_;
}

fn compileToState(alloc: std.mem.Allocator, src: []const u8) !?*stope.basic_vm.State {
    var cfg = try makeCfg(alloc, "main");
    var lx = stope.Lexer.init(alloc, src);
    lx.custom = &cfg;
    var ps = try stope.Parser.init(alloc, &lx);
    var tree = stope.ast.Prog.init(alloc);
    try ps.parseProgram(&tree);
    const prog = try alloc.create(stope.program.Program);
    prog.* = stope.program.Program.init(alloc);
    var comp = try stope.Compiler.init(alloc, prog, &cfg);
    if (!try comp.compile(&tree, &.{})) return null;
    const s = try alloc.create(stope.basic_vm.State);
    s.* = try stope.basic_vm.State.init(alloc, prog);
    return s;
}

fn testVmHost(alloc: std.mem.Allocator, rep: *Report) !void {
    // V-14 宿主函数
    if (try compileToState(alloc, "return f(1, 2);")) |s| {
        const slot = s.prog.exports.get("f").?;
        s.variables[@intCast(slot)] = .{ .host_fn = .{ .ctx = null, .func = hostAdd } };
        _ = try s.run();
        rep.check("V-14", "returns", "[3]", try fmtReturns(alloc, s));
    } else rep.failed += 1;
    // V-14b bool 归一
    if (try compileToState(alloc, "return g();")) |s| {
        const slot = s.prog.exports.get("g").?;
        s.variables[@intCast(slot)] = .{ .host_fn = .{ .ctx = null, .func = hostTrue } };
        _ = try s.run();
        rep.check("V-14b", "returns", "[1]", try fmtReturns(alloc, s));
    } else rep.failed += 1;
    // V-17 Call 非函数
    try vmErrs(alloc, rep, "V-17", "let x = 1; return x(2);", "\"Call\" can only call a function. ");
    // V-18 argc + args[0]
    if (try compileToState(alloc, "return argc + args[0];")) |s| {
        const data = try alloc.alloc(stope.basic_vm.Value, 1);
        data[0] = .{ .integer = 2 };
        const ac = try alloc.create(ArgsCtx);
        ac.* = .{ .data = data };
        const a = try alloc.create(stope.basic_vm.Arguments);
        a.* = .{ .ctx = ac, .at = argsAt, .num = argsNum };
        s.args = a;
        _ = try s.run();
        rep.check("V-18", "returns", "[3]", try fmtReturns(alloc, s));
    } else rep.failed += 1;
    // V-20 实参越界宿主报错
    if (try compileToState(alloc, "return args[5];")) |s| {
        const data = try alloc.alloc(stope.basic_vm.Value, 1);
        data[0] = .{ .integer = 1 };
        const ac = try alloc.create(ArgsCtx);
        ac.* = .{ .data = data };
        const a = try alloc.create(stope.basic_vm.Arguments);
        a.* = .{ .ctx = ac, .at = argsAt, .num = argsNum };
        s.args = a;
        _ = try s.run();
        const p = if (s.errors.items.len > 0) std.mem.indexOf(u8, s.errors.items[0], ": ") else null;
        rep.check("V-20", "错误消息", "argument out of range. ", if (p) |x| s.errors.items[0][x + 2 ..] else "<无错误>");
    } else rep.failed += 1;
    // V-04 noargs 报错后停机在 GetArg
    if (try compileToState(alloc, "return args[0];")) |s| {
        const a = try alloc.create(stope.basic_vm.Arguments);
        a.* = .{ .ctx = null, .at = noArgsAt, .num = argsNum };
        s.args = a;
        _ = try s.run();
        const p = if (s.errors.items.len > 0) std.mem.indexOf(u8, s.errors.items[0], ": ") else null;
        rep.check("V-04", "错误消息", "args not provided in this test. ", if (p) |x| s.errors.items[0][x + 2 ..] else "<无错误>");
    } else rep.failed += 1;
    // V-19 无实参表
    if (try compileToState(alloc, "return argc;")) |s| {
        _ = try s.run();
        const p = if (s.errors.items.len > 0) std.mem.indexOf(u8, s.errors.items[0], ": ") else null;
        rep.check("V-19", "错误消息", "no args. ", if (p) |x| s.errors.items[0][x + 2 ..] else "<无错误>");
    } else rep.failed += 1;
    // V-16 错误下标前缀
    if (try buildVm(alloc, "return 1 / 0;")) |s| {
        if (s.errors.items.len > 0) {
            rep.check("V-16", "错误前缀", "4: \"Div\" division by zero. ", s.errors.items[0]);
        } else rep.failed += 1;
    } else rep.failed += 1;
}

fn testVm(alloc: std.mem.Allocator, rep: *Report) !void {
    // 布尔就是整数
    try vmReturns(alloc, rep, "V-06", "return true;", "[1]");
    try vmReturns(alloc, rep, "V-06b", "return false;", "[0]");
    try vmReturns(alloc, rep, "V-06c", "let t = true; let f = false; return t + f + (1 == 1);", "[2]");
    try vmReturns(alloc, rep, "V-06d", "let a = 1; let b = 2; return a < b;", "[1]");
    // 整数幂
    try vmReturns(alloc, rep, "V-07", "let a = 2; let b = 64; return a ^ b;", "[0]");
    try vmReturns(alloc, rep, "V-07b", "let a = 2; return a ^ -1;", "[0.5]");
    try vmReturns(alloc, rep, "V-07c", "let a = -8.0; let b = 0.5; return a ^ b;", "[nan]");
    // 序列
    try vmReturns(alloc, rep, "V-08", "let s = \"ab\"; return s * 2;", "[abab]");
    try vmReturns(alloc, rep, "V-08b", "let s = \"ab\"; return 2 * s;", "[abab]");
    try vmReturns(alloc, rep, "V-08c", "let b = 'd 1 2'; return b * 2;", "[[1,2,1,2]]");
    try vmErrs(alloc, rep, "V-08d", "let s = \"ab\"; let n = -1; return s * n;", "\"Mul\" cannot repeat a sequence by a negative number. ");
    try vmReturns(alloc, rep, "V-08e", "let a = \"x\"; let b = \"y\"; return a + b;", "[xy]");
    try vmReturns(alloc, rep, "V-08f", "let a = 'd 1'; let b = 'd 2'; return a + b;", "[[1,2]]");
    try vmErrs(alloc, rep, "V-08g", "let b = 'd 1'; let n = -2; return b * n;", "\"Mul\" cannot repeat a sequence by a negative number. ");
    // 真值
    try vmReturns(alloc, rep, "V-09", "let s = \"\"; if s { return 1; } return 2;", "[2]");
    try vmReturns(alloc, rep, "V-09b", "let s = \"x\"; if s { return 1; } return 2;", "[1]");
    try vmReturns(alloc, rep, "V-09c", "let b = 'd'; if b { return 1; } return 2;", "[2]");
    // 除零
    try vmErrs(alloc, rep, "V-10", "let a = 1; let b = 0; return a / b;", "\"Div\" division by zero. ");
    try vmErrs(alloc, rep, "V-10b", "let a = 1; let b = 0; return a idiv b;", "\"IDiv\" division by zero. ");
    try vmErrs(alloc, rep, "V-10c", "let a = 1; let b = 0; return a % b;", "\"Mod\" division by zero. ");
    try vmReturns(alloc, rep, "V-10d", "let a = 1.0; let b = 0; return a / b;", "[inf]");
    try vmReturns(alloc, rep, "V-10e", "let a = 0.0; let b = 0; return a / b;", "[nan]");
    try vmReturns(alloc, rep, "V-10f", "let a = 1.5; let b = 0; return a % b;", "[nan]");
    try vmReturns(alloc, rep, "V-10g", "let a = -7.0; let b = 2.0; return a % b;", "[-1.0]");
    // Not
    try vmErrs(alloc, rep, "V-11", "let s = \"abc\"; return !s;", "\"Not\" can only operate on integer or float. ");
    // MIN
    try vmReturns(alloc, rep, "V-12", "let m = 0 - 9223372036854775807 - 1; return -m;", "[-9223372036854775808]");
    try vmReturns(alloc, rep, "V-12b", "let m = 0 - 9223372036854775807 - 1; return m idiv -1;", "[-9223372036854775808]");
    try vmReturns(alloc, rep, "V-12c", "let m = 0 - 9223372036854775807 - 1; return m % -1;", "[0]");
    // idiv
    try vmReturns(alloc, rep, "V-13", "let a = 7; let b = 2; return a idiv b;", "[3]");
    try vmReturns(alloc, rep, "V-13b", "let a = 7.5; let b = 2; return a idiv b;", "[3.0]");
    try vmReturns(alloc, rep, "V-13c", "let a = 1.0; let b = 0; return a idiv b;", "[inf]");
    // 相等
    try vmReturns(alloc, rep, "V-15", "let a = \"1\"; let b = 1; return a == b;", "[0]");
    try vmReturns(alloc, rep, "V-15b", "let a = null; let b = 0; return a == b;", "[0]");
    try vmReturns(alloc, rep, "V-15c", "let a = 'd 1 2'; let b = 'd 1 2'; return a == b;", "[1]");
    try vmReturns(alloc, rep, "V-15d", "let a = 'd 1'; let b = 'd 2'; return a == b;", "[0]");
    try vmReturns(alloc, rep, "V-15e", "let a = \"ab\"; let n = 0; return a * n;", "[]");
    // 下标
    try vmReturns(alloc, rep, "V-15f", "let b = 'd 1 2'; return b[1];", "[2]");
    try vmReturns(alloc, rep, "V-15g", "let s = \"\xF0\x9F\x98\x80\"; return s[0];", "[55357]");
    try vmErrs(alloc, rep, "V-15h", "let b = 'd 1'; return b[5];", "index out of range. ");
}

fn buildVmStep(alloc: std.mem.Allocator, src: []const u8) !?struct { s: *stope.basic_vm.State, inst_count: usize } {
    var cfg = try makeCfg(alloc, "main");
    var lx = stope.Lexer.init(alloc, src);
    lx.custom = &cfg;
    var ps = try stope.Parser.init(alloc, &lx);
    var tree = stope.ast.Prog.init(alloc);
    try ps.parseProgram(&tree);
    const prog = try alloc.create(stope.program.Program);
    prog.* = stope.program.Program.init(alloc);
    var comp = try stope.Compiler.init(alloc, prog, &cfg);
    if (!try comp.compile(&tree, &.{})) return null;
    const s = try alloc.create(stope.basic_vm.State);
    s.* = try stope.basic_vm.State.init(alloc, prog);
    // 统计指令条数（跳过操作数）
    var count: usize = 0;
    var i: usize = 0;
    while (i < prog.opcodes.items.len) {
        count += 1;
        const raw = prog.opcodes.items[i];
        const o: u16 = @bitCast(raw);
        i += if (o <= 32 and stope.opcode.hasArg(o)) 2 else 1;
    }
    return .{ .s = s, .inst_count = count };
}

fn testVmStepEquiv(alloc: std.mem.Allocator, rep: *Report) !void {
    const cases = [_][]const u8{
        "return 1;",
        "let a = 1; let b = 2; return a + b;",
        "let s = \"ab\"; return s * 2;",
        "let a = 1; let b = 0; return a / b;",
        "if false { return 1; } return 2;",
        "let a = 0; while a < 3 { a = a + 1; } return a;",
        "true && false; return 1;",
        "true || false; return 1;",
    };
    for (cases, 0..) |src, idx| {
        const cid = try std.fmt.allocPrint(alloc, "V-21-{d}", .{idx});
        // run 路径
        const r1 = try buildVm(alloc, src) orelse continue;
        // step 路径
        const pair = try buildVmStep(alloc, src) orelse continue;
        const s2 = pair.s;
        _ = pair.inst_count;
        var steps: usize = 0;
        while (s2.i < s2.prog.opcodes.items.len) {
            if (!try s2.step()) break;
            steps += 1;
            if (steps > 10000) break;
        }
        rep.check(cid, "returns", try fmtReturns(alloc, r1), try fmtReturns(alloc, s2));
        rep.check(cid, "i", try std.fmt.allocPrint(alloc, "{d}", .{r1.i}), try std.fmt.allocPrint(alloc, "{d}", .{s2.i}));
        // 两条路径的错误消息（只比 : 后正文）
        var e1 = std.ArrayList(u8).empty;
        for (r1.errors.items, 0..) |e, k| {
            if (k > 0) try e1.append(alloc, '|');
            const p = std.mem.indexOf(u8, e, ": ");
            try e1.appendSlice(alloc, if (p) |x| e[x + 2 ..] else e);
        }
        var e2 = std.ArrayList(u8).empty;
        for (s2.errors.items, 0..) |e, k| {
            if (k > 0) try e2.append(alloc, '|');
            const p = std.mem.indexOf(u8, e, ": ");
            try e2.appendSlice(alloc, if (p) |x| e[x + 2 ..] else e);
        }
        rep.check(cid, "errors", try e1.toOwnedSlice(alloc), try e2.toOwnedSlice(alloc));
        // 停机后 step 不再做事
        const before = s2.i;
        _ = try s2.step();
        rep.check(cid, "停机后 i 不变", try std.fmt.allocPrint(alloc, "{d}", .{before}), try std.fmt.allocPrint(alloc, "{d}", .{s2.i}));
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
        var cfg = try makeCfg(alloc, "main");
        var lx = stope.Lexer.init(alloc, src);
        lx.custom = &cfg;
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
    try testParser(alloc, io, &rep);
    try testCompiler(alloc, io, &rep);
    try testDisasm(alloc, io, &rep);
    try testStml(alloc, io, &rep);
    try testDepth(alloc, &rep);
    try testVm(alloc, &rep);
    try testVmHost(alloc, &rep);
    try testVmStepEquiv(alloc, &rep);

    std.debug.print("全部断言 {d}，失败 {d}\n", .{ rep.passed + rep.failed, rep.failed });
    if (rep.failed > 0) std.process.exit(1);
}
