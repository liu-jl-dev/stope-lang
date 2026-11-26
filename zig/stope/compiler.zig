//! 编译器：AST → Program（照搬 python/stope/compiler.py，对齐 cpp/src/compiler.cpp）。
//! 指令流中指令与操作数混排；If/GoTo 的操作数是 opcodes 下标。
const std = @import("std");
const ast = @import("ast.zig");
const tok = @import("token.zig");
const op = @import("opcode.zig");
const progmod = @import("program.zig");
const TokenType = tok.TokenType;
const Opcode = op.Opcode;
const Program = progmod.Program;
const Stmt = ast.Stmt;
const Expr = ast.Expr;

const Deferred = struct { stmt: ?*Stmt, line: i32, order_baseline: i32 };
const BlockScope = struct {
    id_map: std.StringHashMap(i32),
    id_order: std.StringHashMap(i32),
    defers: std.ArrayList(Deferred),
    is_defer_payload: bool = false,
    fn init(alloc: std.mem.Allocator) BlockScope {
        return .{
            .id_map = std.StringHashMap(i32).init(alloc),
            .id_order = std.StringHashMap(i32).init(alloc),
            .defers = std.ArrayList(Deferred).empty,
        };
    }
};
const WhileScope = struct { start_index: usize = 0, break_indices: std.ArrayList(usize) };

const ScopeTag = enum { block, while_ };
const Scope = struct {
    tag: ScopeTag,
    block: ?*BlockScope = null,
    while_: ?*WhileScope = null,
};

const StackMgr = struct {
    size: i32 = 0,
    max_size: i32 = 0,
    fn inc(self: *StackMgr, n: i32) void {
        self.size += n;
        if (self.size > self.max_size) self.max_size = self.size;
    }
    fn dec(self: *StackMgr, n: i32) void {
        self.size -= n;
    }
    fn converge(self: *StackMgr, depth: i32) void {
        self.size = depth;
    }
};

pub const Compiler = struct {
    alloc: std.mem.Allocator,
    prog: *Program,
    custom: ?*op.CustomOpcodeConfig,
    errors: std.ArrayList([]const u8),
    var_names: std.ArrayList([]const u8),
    recycled: std.ArrayList(i32),
    stack: StackMgr,
    scopes: std.ArrayList(Scope),
    decl_counter: i32 = 0,
    defer_order_floor: i32 = -1,
    defer_err_line: i32 = -1,
    stmt_terminates: bool = false,
    saw_break: bool = false,
    cur_line: i32 = -1,

    pub fn init(alloc: std.mem.Allocator, out: *Program, custom: ?*op.CustomOpcodeConfig) !Compiler {
        var c = Compiler{
            .alloc = alloc,
            .prog = out,
            .custom = custom,
            .errors = std.ArrayList([]const u8).empty,
            .var_names = std.ArrayList([]const u8).empty,
            .recycled = std.ArrayList(i32).empty,
            .stack = .{},
            .scopes = std.ArrayList(Scope).empty,
        };
        try c.resetCompile();
        return c;
    }

    fn resetCompile(self: *Compiler) anyerror!void {
        self.errors.clearRetainingCapacity();
        self.var_names.clearRetainingCapacity();
        self.recycled.clearRetainingCapacity();
        self.scopes.clearRetainingCapacity();
        self.decl_counter = 0;
        self.defer_order_floor = -1;
        self.defer_err_line = -1;
        self.stmt_terminates = false;
        self.saw_break = false;
        self.cur_line = -1;
        self.prog.clear();
        const fs = try self.alloc.create(BlockScope);
        fs.* = BlockScope.init(self.alloc);
        try self.scopes.append(self.alloc, .{ .tag = .block, .block = fs });
    }

    pub fn compile(self: *Compiler, tree: *const ast.Prog, pre_exports: []const []const u8) anyerror!bool {
        try self.resetCompile();
        // 预导出
        for (pre_exports) |n| {
            if (n.len == 0) {
                try self.addError(0, "empty name in pre-exports. ");
                continue;
            }
            const fs = self.fileScope();
            if (fs.id_map.contains(n)) {
                try self.addError(0, try std.fmt.allocPrint(self.alloc, "duplicate export of \"{s}\". ", .{n}));
                continue;
            }
            const idx = try self.newUniqueVar(n);
            try self.declareExported(n, idx, false);
        }
        try self.visitProg(tree);
        if (!self.stmt_terminates) try self.spliceDefers(self.fileScope());
        self.fileScope().defers.clearRetainingCapacity();
        if (self.errors.items.len > 0) {
            self.prog.clear();
            return false;
        }
        self.prog.variable_num = @intCast(self.var_names.items.len);
        self.prog.required_stack_size = self.stack.max_size;
        return true;
    }

    // ------------------------------------------------------------ 指令发射
    fn codeSize(self: *Compiler) usize {
        return self.prog.opcodes.items.len;
    }
    fn emitOp(self: *Compiler, o: Opcode) anyerror!void {
        try self.prog.opcodes.append(self.alloc, @intFromEnum(o));
    }
    fn emitRaw(self: *Compiler, v: i32) anyerror!void {
        if (v < -32768 or v > 32767) {
            try self.addError(self.cur_line, "compile output too large: index exceeds int16. ");
            try self.prog.opcodes.append(self.alloc, 0);
            return;
        }
        try self.prog.opcodes.append(self.alloc, @bitCast(@as(i16, @intCast(v))));
    }
    fn emitIndex(self: *Compiler, idx: i32) anyerror!void {
        try self.emitRaw(idx);
    }
    fn emitPlaceholder(self: *Compiler) anyerror!usize {
        try self.prog.opcodes.append(self.alloc, @bitCast(@as(i16, -1)));
        return self.codeSize() - 1;
    }
    fn patchIndex(self: *Compiler, pos: usize, target: usize) anyerror!void {
        const t: i64 = @intCast(target);
        if (t > 32767) {
            try self.addError(self.cur_line, "compile output too large: jump target exceeds int16. ");
            self.prog.opcodes.items[pos] = 0;
            return;
        }
        self.prog.opcodes.items[pos] = @bitCast(@as(i16, @intCast(target)));
    }
    fn addError(self: *Compiler, line: i32, msg: []const u8) anyerror!void {
        try self.errors.append(self.alloc, try std.fmt.allocPrint(self.alloc, "line {d}: {s}", .{ line, msg }));
    }

    // ------------------------------------------------------------ 作用域/变量
    fn fileScope(self: *Compiler) *BlockScope {
        return self.scopes.items[0].block.?;
    }
    fn pushBlockScope(self: *Compiler) anyerror!*BlockScope {
        const bs = try self.alloc.create(BlockScope);
        bs.* = BlockScope.init(self.alloc);
        try self.scopes.append(self.alloc, .{ .tag = .block, .block = bs });
        return bs;
    }
    fn pushWhileScope(self: *Compiler) anyerror!*WhileScope {
        const ws = try self.alloc.create(WhileScope);
        ws.* = .{ .break_indices = std.ArrayList(usize).empty };
        try self.scopes.append(self.alloc, .{ .tag = .while_, .while_ = ws });
        return ws;
    }
    fn popScope(self: *Compiler) void {
        _ = self.scopes.pop();
    }
    fn topBlockScope(self: *Compiler) ?*BlockScope {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].tag == .block) return self.scopes.items[i].block.?;
        }
        return null;
    }
    fn newVar(self: *Compiler) anyerror!i32 {
        if (self.recycled.items.len > 0) {
            const idx = self.recycled.pop().?;
            self.var_names.items[@intCast(idx)] = "";
            return idx;
        }
        const i: i32 = @intCast(self.var_names.items.len);
        try self.var_names.append(self.alloc, "");
        return i;
    }
    fn newUniqueVar(self: *Compiler, name: []const u8) anyerror!i32 {
        const i: i32 = @intCast(self.var_names.items.len);
        try self.var_names.append(self.alloc, name);
        return i;
    }
    fn freeVar(self: *Compiler, idx: i32) anyerror!void {
        for (self.recycled.items) |v| if (v == idx) return;
        try self.recycled.append(self.alloc, idx);
    }
    fn nextDeclOrder(self: *Compiler) i32 {
        const o = self.decl_counter;
        self.decl_counter += 1;
        return o;
    }
    fn declareLocal(self: *Compiler, bs: *BlockScope, name: []const u8, idx: i32) anyerror!void {
        try bs.id_map.put(name, idx);
        try bs.id_order.put(name, self.nextDeclOrder());
    }
    fn declareExported(self: *Compiler, name: []const u8, idx: i32, implicit: bool) anyerror!void {
        const fs = self.fileScope();
        try fs.id_map.put(name, idx);
        try fs.id_order.put(name, if (implicit) -1 else self.nextDeclOrder());
        try self.prog.exports.put(name, idx);
    }
    fn findIdentHost(self: *Compiler, name: []const u8) ?*BlockScope {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const sc = self.scopes.items[i];
            if (sc.tag == .block and sc.block.?.id_map.contains(name)) return sc.block.?;
        }
        return null;
    }
    fn findIdentHostFrozen(self: *Compiler, name: []const u8, floor: i32) ?*BlockScope {
        var payload_idx: isize = -1;
        var i: isize = @intCast(self.scopes.items.len);
        while (i > 0) {
            i -= 1;
            const sc = self.scopes.items[@intCast(i)];
            if (sc.tag == .block and sc.block.?.is_defer_payload) {
                payload_idx = i;
                break;
            }
        }
        i = @intCast(self.scopes.items.len);
        while (i > 0) {
            i -= 1;
            const sc = self.scopes.items[@intCast(i)];
            if (sc.tag != .block) continue;
            const bs = sc.block.?;
            if (!bs.id_map.contains(name)) continue;
            if (i < payload_idx) {
                if (bs.id_order.get(name)) |order| {
                    if (order >= 0 and order >= floor) continue;
                }
            }
            return bs;
        }
        return null;
    }
    fn resolveAtSplice(self: *Compiler, name: []const u8) anyerror!?*BlockScope {
        if (self.findIdentHostFrozen(name, self.defer_order_floor)) |f| return f;
        const fs = self.fileScope();
        if (fs.id_map.contains(name)) {
            try self.addError(self.defer_err_line, try std.fmt.allocPrint(self.alloc, "duplicate export of \"{s}\". ", .{name}));
            return fs;
        }
        return null;
    }
    fn identSlot(self: *Compiler, name: []const u8) anyerror!i32 {
        var host: ?*BlockScope = null;
        if (self.defer_order_floor >= 0) {
            host = try self.resolveAtSplice(name);
        } else {
            host = self.findIdentHost(name);
        }
        if (host) |h| return h.id_map.get(name).?;
        const idx = try self.newUniqueVar(name);
        try self.declareExported(name, idx, true);
        return self.fileScope().id_map.get(name).?;
    }

    // ------------------------------------------------------------ defer
    fn spliceDefers(self: *Compiler, bs: *BlockScope) anyerror!void {
        if (bs.defers.items.len == 0 or self.errors.items.len > 0) return;
        var k = bs.defers.items.len;
        while (k > 0) {
            k -= 1;
            if (self.errors.items.len > 0) return;
            const d = bs.defers.items[k];
            const saved_floor = self.defer_order_floor;
            const saved_line = self.defer_err_line;
            self.defer_order_floor = d.order_baseline;
            self.defer_err_line = d.line;
            const ps = try self.pushBlockScope();
            ps.is_defer_payload = true;
            if (d.stmt) |s| try self.visitStmt(s);
            try self.spliceDefers(ps);
            self.popScope();
            var it = ps.id_map.valueIterator();
            while (it.next()) |v| try self.freeVar(v.*);
            self.defer_order_floor = saved_floor;
            self.defer_err_line = saved_line;
        }
    }

    // ------------------------------------------------------------ 语句
    fn visitProg(self: *Compiler, p: *const ast.Prog) anyerror!void {
        var terminated = false;
        for (p.stmts.items) |s| {
            if (terminated) break;
            self.stmt_terminates = false;
            self.cur_line = s.line;
            try self.visitStmt(s);
            terminated = self.stmt_terminates;
        }
    }

    fn visitBodyAsBlock(self: *Compiler, p: *const ast.Prog) anyerror!void {
        const bs = try self.pushBlockScope();
        try self.visitProg(p);
        if (!self.stmt_terminates) try self.spliceDefers(bs);
        bs.defers.clearRetainingCapacity();
        self.popScope();
        var it = bs.id_map.valueIterator();
        while (it.next()) |v| try self.freeVar(v.*);
    }

    fn visitStmt(self: *Compiler, s: *const Stmt) anyerror!void {
        self.cur_line = s.line;
        switch (s.data) {
            .expr_stmt => |e| {
                try self.visitExpr(e);
                try self.emitOp(.Pop);
                self.stack.dec(1);
            },
            .let_stmt => |l| try self.visitLet(l),
            .return_stmt => |es| try self.visitReturn(es),
            .export_stmt => |ids| try self.visitExport(ids),
            .block_stmt => |p| {
                const bs = try self.pushBlockScope();
                try self.visitProg(p);
                if (!self.stmt_terminates) try self.spliceDefers(bs);
                bs.defers.clearRetainingCapacity();
                self.popScope();
                var it = bs.id_map.valueIterator();
                while (it.next()) |v| try self.freeVar(v.*);
            },
            .if_stmt => |iv| try self.visitIf(iv),
            .while_stmt => |w| try self.visitWhile(w),
            .assign_stmt => |a| {
                if (a.left.data == .ident_expr) {
                    const name = a.left.data.ident_expr;
                    const idx = try self.identSlot(name);
                    try self.emitOp(.PushId);
                    try self.emitIndex(idx);
                    self.stack.inc(1);
                } else try self.visitExpr(a.left);
                try self.visitExpr(a.right);
                try self.emitOp(.Assign);
                self.stack.dec(2);
            },
            .break_stmt => try self.visitBreak(),
            .continue_stmt => try self.visitContinue(),
            .defer_stmt => |inner| {
                if (self.topBlockScope()) |bs| {
                    try bs.defers.append(self.alloc, .{ .stmt = inner, .line = s.line, .order_baseline = self.decl_counter });
                }
            },
            .err => {},
        }
    }

    fn visitLet(self: *Compiler, l: ast.LetData) anyerror!void {
        const bs = self.topBlockScope() orelse return;
        if (l.has_assign) {
            if (l.idents.len == 0) return;
            const name = l.idents[0];
            if (bs.id_map.contains(name)) {
                try self.addError(self.cur_line, try std.fmt.allocPrint(self.alloc, "duplicate declaration of '{s}'. ", .{name}));
                return;
            }
            const idx = try self.newVar();
            try self.declareLocal(bs, name, idx);
            try self.emitOp(.PushId);
            try self.emitIndex(idx);
            self.stack.inc(1);
            if (l.expr) |e| try self.visitExpr(e);
            try self.emitOp(.Assign);
            self.stack.dec(2);
        } else {
            for (l.idents) |name| {
                if (bs.id_map.contains(name)) {
                    try self.addError(self.cur_line, try std.fmt.allocPrint(self.alloc, "duplicate declaration of '{s}'. ", .{name}));
                    continue;
                }
                const idx = try self.newVar();
                try self.declareLocal(bs, name, idx);
            }
        }
    }

    fn visitReturn(self: *Compiler, es: []const *Expr) anyerror!void {
        var i: usize = 0;
        while (i < self.scopes.items.len) : (i += 1) {
            const sc = self.scopes.items[i];
            if (sc.tag == .block and sc.block.?.is_defer_payload) {
                try self.addError(self.cur_line, "\"return\" cannot be used in a defer statement. ");
                return;
            }
        }
        i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].tag == .block) try self.spliceDefers(self.scopes.items[i].block.?);
        }
        for (es) |e| try self.visitExpr(e);
        try self.emitOp(.Return);
        try self.emitIndex(@intCast(es.len));
        if (@as(i32, @intCast(es.len)) > self.prog.max_return_num) self.prog.max_return_num = @intCast(es.len);
        self.stmt_terminates = true;
    }

    fn visitExport(self: *Compiler, ids: []const []const u8) anyerror!void {
        if (self.scopes.items.len > 1) try self.addError(self.cur_line, "\"export\" can only be used at top scope. ");
        const fs = self.fileScope();
        for (ids) |name| {
            if (fs.id_map.contains(name)) {
                try self.addError(self.cur_line, try std.fmt.allocPrint(self.alloc, "duplicate export of \"{s}\". ", .{name}));
                continue;
            }
            const idx = try self.newUniqueVar(name);
            try self.declareExported(name, idx, false);
        }
    }

    // ------------------------------------------------------------ if / while
    fn constCondTruth(e: ?*const Expr) ?bool {
        if (e == null) return null;
        const k = kindOfExpr(e.?);
        if (k == .not_const) return null;
        return truthyExpr(e.?);
    }

    fn visitIf(self: *Compiler, iv: ast.IfData) anyerror!void {
        if (iv.cond == null) return;
        var goto_end = std.ArrayList(usize).empty;
        var pending_false: isize = -1;
        var all_terminate = true;
        var any_emitted = false;
        var fallthrough = false;
        var chain_ended = false;

        const truth = constCondTruth(iv.cond);
        if (truth) |t| {
            if (t) {
                try self.visitBodyAsBlock(iv.first);
                all_terminate = all_terminate and self.stmt_terminates;
                any_emitted = true;
                fallthrough = true;
                chain_ended = true;
            }
        } else {
            try self.visitExpr(iv.cond.?);
            try self.emitOp(.If);
            self.stack.dec(1);
            pending_false = @intCast(try self.emitPlaceholder());
            try self.visitBodyAsBlock(iv.first);
            const term = self.stmt_terminates;
            all_terminate = all_terminate and term;
            any_emitted = true;
            if (!term) {
                try self.emitOp(.GoTo);
                try goto_end.append(self.alloc, try self.emitPlaceholder());
            }
        }
        for (iv.elifs) |ei| {
            if (chain_ended or ei.cond == null) continue;
            const et = constCondTruth(ei.cond);
            if (et) |t| {
                if (t) {
                    if (pending_false >= 0) try self.patchIndex(@intCast(pending_false), self.codeSize());
                    pending_false = -1;
                    try self.visitBodyAsBlock(ei.prog);
                    all_terminate = all_terminate and self.stmt_terminates;
                    any_emitted = true;
                    fallthrough = true;
                    chain_ended = true;
                }
                continue;
            }
            if (pending_false >= 0) try self.patchIndex(@intCast(pending_false), self.codeSize());
            pending_false = -1;
            try self.visitExpr(ei.cond.?);
            try self.emitOp(.If);
            self.stack.dec(1);
            pending_false = @intCast(try self.emitPlaceholder());
            try self.visitBodyAsBlock(ei.prog);
            const term = self.stmt_terminates;
            all_terminate = all_terminate and term;
            any_emitted = true;
            if (!term) {
                try self.emitOp(.GoTo);
                try goto_end.append(self.alloc, try self.emitPlaceholder());
            }
        }
        if (!chain_ended and iv.else_prog != null) {
            if (pending_false >= 0) try self.patchIndex(@intCast(pending_false), self.codeSize());
            pending_false = -1;
            try self.visitBodyAsBlock(iv.else_prog.?);
            all_terminate = all_terminate and self.stmt_terminates;
            any_emitted = true;
            fallthrough = true;
        }
        if (pending_false >= 0) try self.patchIndex(@intCast(pending_false), self.codeSize());
        for (goto_end.items) |pos| try self.patchIndex(pos, self.codeSize());
        self.stmt_terminates = any_emitted and all_terminate and fallthrough;
    }

    fn visitWhile(self: *Compiler, w: ast.WhileData) anyerror!void {
        const truth = constCondTruth(w.cond);
        const cond_const = truth != null;
        const eliminate = cond_const and !truth.?;
        const ws = try self.pushWhileScope();
        ws.start_index = self.codeSize();
        var case_goto_end: isize = -1;
        if (w.cond != null and !cond_const) {
            try self.visitExpr(w.cond.?);
            try self.emitOp(.If);
            self.stack.dec(1);
            case_goto_end = @intCast(try self.emitPlaceholder());
        }
        if (eliminate) {
            self.stmt_terminates = false;
            self.popScope();
            return;
        }
        const saved_saw_break = self.saw_break;
        self.saw_break = false;
        try self.visitBodyAsBlock(w.prog);
        const body_term = self.stmt_terminates;
        const body_saw_break = self.saw_break;
        self.saw_break = saved_saw_break;
        if (!body_term) {
            try self.emitOp(.GoTo);
            try self.emitIndex(@intCast(ws.start_index));
        }
        for (ws.break_indices.items) |pos| try self.patchIndex(pos, self.codeSize());
        if (case_goto_end >= 0) try self.patchIndex(@intCast(case_goto_end), self.codeSize());
        self.stmt_terminates = ((w.cond == null or (cond_const and truth.?)) and !body_saw_break);
        self.popScope();
    }

    fn findWhile(self: *Compiler) ?struct { idx: usize, ws: *WhileScope } {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const sc = self.scopes.items[i];
            if (sc.tag == .while_) return .{ .idx = i, .ws = sc.while_.? };
            if (sc.tag == .block and sc.block.?.is_defer_payload) {
                return null; // 由调用方报跨 defer 错
            }
        }
        return null;
    }

    fn spliceDefersAbove(self: *Compiler, while_idx: usize) anyerror!void {
        var i = self.scopes.items.len;
        while (i > while_idx) {
            i -= 1;
            if (self.scopes.items[i].tag == .block) try self.spliceDefers(self.scopes.items[i].block.?);
        }
    }

    fn visitBreak(self: *Compiler) anyerror!void {
        // 先分辨是「撞到 defer 载荷」还是「没有循环」
        var wi: ?usize = null;
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const sc = self.scopes.items[i];
            if (sc.tag == .while_) { wi = i; break; }
            if (sc.tag == .block and sc.block.?.is_defer_payload) {
                try self.addError(self.cur_line, "\"break\" cannot cross a defer statement. ");
                return;
            }
        }
        if (wi == null) {
            try self.addError(self.cur_line, "cannot use \"break\" outside of a loop. ");
            return;
        }
        try self.spliceDefersAbove(wi.?);
        try self.emitOp(.GoTo);
        const ws = self.scopes.items[wi.?].while_.?;
        try ws.break_indices.append(self.alloc, try self.emitPlaceholder());
        self.saw_break = true;
        self.stmt_terminates = true;
    }

    fn visitContinue(self: *Compiler) anyerror!void {
        var wi: ?usize = null;
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const sc = self.scopes.items[i];
            if (sc.tag == .while_) { wi = i; break; }
            if (sc.tag == .block and sc.block.?.is_defer_payload) {
                try self.addError(self.cur_line, "\"continue\" cannot cross a defer statement. ");
                return;
            }
        }
        if (wi == null) {
            try self.addError(self.cur_line, "cannot use \"continue\" outside of a loop. ");
            return;
        }
        try self.spliceDefersAbove(wi.?);
        try self.emitOp(.GoTo);
        try self.emitIndex(@intCast(self.scopes.items[wi.?].while_.?.start_index));
        self.stmt_terminates = true;
    }

    // ------------------------------------------------------------ 表达式
    fn visitExpr(self: *Compiler, e: *const Expr) anyerror!void {
        switch (e.data) {
            .err => {},
            .null_expr => {
                try self.emitOp(.PushNull);
                self.stack.inc(1);
            },
            .bool_expr => |v| {
                try self.emitOp(if (v) .PushTrue else .PushFalse);
                self.stack.inc(1);
            },
            .int_expr => |v| {
                try self.emitOp(.PushInt);
                try self.emitIndex(try constIndex(i64, self.alloc, &self.prog.int_consts, v));
                self.stack.inc(1);
            },
            .float_expr => |v| {
                try self.emitOp(.PushFloat);
                try self.emitIndex(try constIndex(f64, self.alloc, &self.prog.float_consts, v));
                self.stack.inc(1);
            },
            .string_expr => |v| {
                try self.emitOp(.PushString);
                try self.emitIndex(try constIndex([]const u8, self.alloc, &self.prog.string_consts, v));
                self.stack.inc(1);
            },
            .binarr_expr => |v| {
                try self.emitOp(.PushBinArr);
                try self.emitIndex(try constIndex([]const u8, self.alloc, &self.prog.binarr_consts, v));
                self.stack.inc(1);
            },
            .ident_expr => |name| {
                const idx = try self.identSlot(name);
                try self.emitOp(.PushValue);
                try self.emitIndex(idx);
                self.stack.inc(1);
            },
            .argc_expr => {
                try self.emitOp(.ArgNum);
                self.stack.inc(1);
            },
            .args_expr => |key| {
                if (key) |k| try self.visitExpr(k);
                try self.emitOp(.GetArg);
            },
            .unary_op => |u| {
                try self.visitExpr(u.expr);
                if (u.op == .Not) try self.emitOp(.Not) else if (u.op == .Sub) try self.emitOp(.Minus);
            },
            .binary_op => |b| {
                if (b.op == .Or) return self.visitOr(b);
                if (b.op == .And) return self.visitAnd(b);
                try self.visitExpr(b.left);
                try self.visitExpr(b.right);
                try self.emitOp(binaryOpcode(b.op));
                self.stack.dec(1);
            },
            .call => |c| {
                try self.visitExpr(c.callee);
                for (c.args) |a| try self.visitExpr(a);
                try self.emitOp(.Call);
                try self.emitIndex(@intCast(c.args.len));
                self.stack.dec(@intCast(c.args.len));
            },
            .at => |a| {
                try self.visitExpr(a.container);
                for (a.keys) |k| try self.visitExpr(k);
                try self.emitOp(.At);
                try self.emitIndex(@intCast(a.keys.len));
                self.stack.dec(@intCast(a.keys.len));
            },
            .custom => |c| {
                var info: ?op.CustomOpcode = null;
                if (self.custom) |cfg| info = cfg.find(c.name);
                if (info == null) {
                    try self.addError(self.cur_line, try std.fmt.allocPrint(self.alloc, "undefined custom opcode \"{s}\". ", .{c.name}));
                    return;
                }
                const ci = info.?;
                const is_var = ci.is_var_arg;
                if (!is_var and ci.arg_num != @as(i32, @intCast(c.args.len))) {
                    try self.addError(self.cur_line, try std.fmt.allocPrint(self.alloc, "custom opcode \"{s}\" expected {d} args, but got {d}. ", .{ c.name, ci.arg_num, c.args.len }));
                }
                for (c.args) |a| try self.visitExpr(a);
                try self.prog.opcodes.append(self.alloc, ci.opcode);
                if (is_var) try self.emitIndex(@intCast(c.args.len));
                self.stack.dec(@as(i32, @intCast(c.args.len)) - 1);
            },
        }
    }

    fn visitOr(self: *Compiler, b: ast.BinaryData) anyerror!void {
        try self.visitExpr(b.left);
        try self.emitOp(.If);
        self.stack.dec(1);
        const first_if = try self.emitPlaceholder();
        const depth1 = self.stack.size;
        try self.emitOp(.PushTrue);
        self.stack.inc(1);
        try self.emitOp(.GoTo);
        const goto1 = try self.emitPlaceholder();
        try self.patchIndex(first_if, self.codeSize());
        self.stack.converge(depth1);
        try self.visitExpr(b.right);
        try self.emitOp(.If);
        self.stack.dec(1);
        const second_if = try self.emitPlaceholder();
        const depth2 = self.stack.size;
        try self.emitOp(.PushTrue);
        self.stack.inc(1);
        try self.emitOp(.GoTo);
        const goto2 = try self.emitPlaceholder();
        try self.patchIndex(second_if, self.codeSize());
        self.stack.converge(depth2);
        try self.emitOp(.PushFalse);
        self.stack.inc(1);
        try self.patchIndex(goto1, self.codeSize());
        try self.patchIndex(goto2, self.codeSize());
    }

    fn visitAnd(self: *Compiler, b: ast.BinaryData) anyerror!void {
        try self.visitExpr(b.left);
        try self.emitOp(.If);
        self.stack.dec(1);
        const first_if = try self.emitPlaceholder();
        try self.visitExpr(b.right);
        try self.emitOp(.If);
        self.stack.dec(1);
        const second_if = try self.emitPlaceholder();
        const depth = self.stack.size;
        try self.emitOp(.PushTrue);
        self.stack.inc(1);
        try self.emitOp(.GoTo);
        const goto_end = try self.emitPlaceholder();
        try self.patchIndex(first_if, self.codeSize());
        try self.patchIndex(second_if, self.codeSize());
        self.stack.converge(depth);
        try self.emitOp(.PushFalse);
        self.stack.inc(1);
        try self.patchIndex(goto_end, self.codeSize());
    }
};

fn constIndex(comptime T: type, alloc: std.mem.Allocator, pool: *std.ArrayList(T), v: T) anyerror!i32 {
    for (pool.items, 0..) |cur, i| {
        if (valuesEqual(T, cur, v)) return @intCast(i);
    }
    try pool.append(alloc, v);
    return @intCast(pool.items.len - 1);
}

fn valuesEqual(comptime T: type, a: T, b: T) bool {
    if (T == []const u8) return std.mem.eql(u8, a, b);
    return a == b;
}

fn binaryOpcode(t: TokenType) Opcode {
    return switch (t) {
        .EQ => .EQ, .NE => .NE, .LT => .LT, .LE => .LE, .GT => .GT, .GE => .GE,
        .Add => .Add, .Sub => .Sub, .Mul => .Mul, .Div => .Div, .IDiv => .IDiv,
        .Mod => .Mod, .Pow => .Pow, else => .Pop,
    };
}

// 供 constCondTruth 用：与 expr_optim 同一真值表。
const Kind = enum(u8) { not_const, null_, bool_, int_, float_, string, binarr };
fn kindOfExpr(e: *const Expr) Kind {
    return switch (e.data) {
        .null_expr => .null_,
        .bool_expr => .bool_,
        .int_expr => .int_,
        .float_expr => .float_,
        .string_expr => .string,
        .binarr_expr => .binarr,
        else => .not_const,
    };
}
fn truthyExpr(e: *const Expr) bool {
    return switch (e.data) {
        .null_expr => false,
        .bool_expr => |v| v,
        .int_expr => |v| v != 0,
        .float_expr => |v| v != 0.0,
        .string_expr => |s| s.len != 0,
        .binarr_expr => |b| b.len != 0,
        else => false,
    };
}
